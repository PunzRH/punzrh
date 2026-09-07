// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface IPerp {
    enum Side { LONG, SHORT }
    function commitMint(Side side) external payable returns (uint256 id);
    function claim(uint256 id, uint256 e) external returns (uint256 out);
    function claimableEpoch(uint256 id) external view returns (uint256);
    function sharePriceWei(Side side) external view returns (uint256);
}

interface ILaunch {
    function collectFees() external;
    function launch() external;
}

interface IPoons is IERC20 {
    function burn(uint256 amount) external;
}

/// @title Backing — turns the coin's trading fees into a PONS short that backs the coin.
/// @notice Owns the locked-liquidity launcher. `harvest()` (anyone) pulls the LP fees: fee ETH becomes sPONS
///         INSTANTLY by buying it on the sPONS/ETH pool when that pool is within `maxPremiumBps` of NAV; otherwise
///         it is minted directly from the vault (5-min settle, claimed by `claim()`). Fee coin is burned.
///         Holders redeem via PoonsToken.redeem(): burn coin, receive pro-rata sPONS. No admin keys after `init`.
contract Backing is ReentrancyGuard, IUnlockCallback {
    IPerp public immutable perp;
    IERC20 public immutable spons;
    IPoolManager public immutable pm;
    address public immutable deployer;
    uint256 public immutable maxPremiumBps; // e.g. 300 = accept paying up to 3% over NAV on the market path
    PoolKey public sponsEthKey;               // native ETH / sPONS pool used for instant buys

    IPoons public token;
    ILaunch public launch;
    bool public initialized;

    uint256[] public pendingCommits;
    uint256 public totalEthCommitted;   // via vault mint (slow path)
    uint256 public totalEthSwapped;     // via market buy (instant path)
    uint256 public totalCoinBurned;

    error AlreadyInit();
    error NotDeployer();
    error NotToken();
    error NotPoolManager();
    error TooExpensive();

    event Harvested(uint256 ethInstant, uint256 sponsBought, uint256 ethCommitted, uint256 coinBurned);
    event Claimed(uint256 id, uint256 sponsOut);
    event Payout(address indexed to, uint256 burned, uint256 sponsOut);

    constructor(IPerp perp_, IERC20 spons_, IPoolManager pm_, uint24 poolFee, int24 poolTickSpacing, uint256 maxPremiumBps_) {
        perp = perp_;
        spons = spons_;
        pm = pm_;
        maxPremiumBps = maxPremiumBps_;
        deployer = msg.sender;
        sponsEthKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(spons_)),
            fee: poolFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function init(IPoons token_, ILaunch launch_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (initialized) revert AlreadyInit();
        initialized = true;
        token = token_;
        launch = launch_;
        launch_.launch();
    }

    /// @notice Pull LP fees; ETH -> sPONS (instant if the market is fair, else vault mint); coin -> burned.
    function harvest() external nonReentrant {
        uint256 e0 = address(this).balance;
        uint256 c0 = token.balanceOf(address(this));
        launch.collectFees();
        uint256 eth = address(this).balance - e0;
        uint256 coin = token.balanceOf(address(this)) - c0;
        uint256 bought; uint256 committed;
        if (eth > 0) {
            // try the instant path: swap on the sPONS/ETH pool, revert (and fall back) if worse than NAV*(1+premium)
            try pm.unlock(abi.encode(eth)) returns (bytes memory r) {
                bought = abi.decode(r, (uint256));
                totalEthSwapped += eth;
            } catch {
                uint256 id = perp.commitMint{value: eth}(IPerp.Side.SHORT);
                pendingCommits.push(id);
                totalEthCommitted += eth;
                committed = eth;
            }
        }
        if (coin > 0) {
            token.burn(coin);
            totalCoinBurned += coin;
        }
        emit Harvested(eth - committed, bought, committed, coin);
    }

    /// @dev swap `eth` for sPONS on the sPONS/ETH pool; enforce a NAV-based minimum out.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        uint256 eth = abi.decode(data, (uint256));
        BalanceDelta d = pm.swap(
            sponsEthKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(eth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        uint256 out = uint256(uint128(d.amount1()));
        // fair amount at NAV: eth * 1e18 / sharePriceWei ; require out >= fair * (1 - premium)
        uint256 fair = eth * 1e18 / perp.sharePriceWei(IPerp.Side.SHORT);
        if (out < fair * (10_000 - maxPremiumBps) / 10_000) revert TooExpensive();
        pm.settle{value: uint256(uint128(-d.amount0()))}();
        pm.take(sponsEthKey.currency1, address(this), out);
        return abi.encode(out);
    }

    /// @notice Settle any matured vault commits into sPONS. Anyone can call.
    function claim() external nonReentrant {
        uint256 i = 0;
        while (i < pendingCommits.length) {
            uint256 id = pendingCommits[i];
            uint256 e = perp.claimableEpoch(id);
            if (e == type(uint256).max) { i++; continue; }
            uint256 out = perp.claim(id, e);
            emit Claimed(id, out);
            pendingCommits[i] = pendingCommits[pendingCommits.length - 1];
            pendingCommits.pop();
        }
    }

    function payout(address to, uint256 burned, uint256 supplyBefore) external nonReentrant {
        if (msg.sender != address(token)) revert NotToken();
        uint256 out = spons.balanceOf(address(this)) * burned / supplyBefore;
        if (out > 0) spons.transfer(to, out);
        emit Payout(to, burned, out);
    }

    function sponsBacking() external view returns (uint256) { return spons.balanceOf(address(this)); }
    function pendingCount() external view returns (uint256) { return pendingCommits.length; }
    function floorWeiPerToken() external view returns (uint256) {
        uint256 supply = token.totalSupply();
        if (supply == 0) return 0;
        return spons.balanceOf(address(this)) * perp.sharePriceWei(IPerp.Side.SHORT) / supply;
    }

    receive() external payable {}
}
