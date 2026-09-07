// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

interface IPerpNav {
    function sharePriceWei(uint8 side) external view returns (uint256);
}

/// @title SeedPool — native-ETH / sPONS Uniswap v4 pool seeded at the perp pool's redemption NAV.
/// @notice Gives sPONS a market so routers can reach it from ETH and indexers can price it (and every coin
///         quoted in it). Two-sided concentrated position ±halfRange ticks around NAV. Owner can collect fees
///         or exit (pull the whole position) at any time — this is the owner's own liquidity, not locked.
contract SeedPool is IUnlockCallback {
    IPoolManager public immutable pm;
    address public immutable spons;
    IPerpNav public immutable perp;
    address public immutable owner;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    int24 public immutable halfRange;

    PoolKey public key;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;
    bool public seeded;

    error NotOwner();
    error NotPoolManager();
    error AlreadySeeded();
    error NotSeeded();

    event Seeded(uint160 sqrtPriceX96, int24 tick, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 eth, uint256 sponsIn);
    event Exited(uint256 eth, uint256 sponsOut);
    event FeesCollected(uint256 eth, uint256 sponsOut);

    constructor(IPoolManager pm_, address spons_, IPerpNav perp_, uint24 fee_, int24 tickSpacing_, int24 halfRange_, address owner_) {
        pm = pm_;
        spons = spons_;
        perp = perp_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        halfRange = halfRange_;
        owner = owner_;
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(spons_),
            fee: fee_,
            tickSpacing: tickSpacing_,
            hooks: IHooks(address(0))
        });
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice NAV price as sqrtPriceX96 for the ETH/sPONS pool: price = sPONS-wei per ETH-wei = 1e18 / sharePriceWei.
    function navSqrtPriceX96() public view returns (uint160) {
        uint256 spw = perp.sharePriceWei(1); // SHORT side share price in wei
        require(spw > 0, "no nav");
        // sqrt(P * 2^192) with P = 1e18 / spw  ->  sqrt((1e18 << 192) / spw)
        uint256 v = (uint256(1e18) << 192) / spw;
        return uint160(_sqrt(v));
    }

    /// @notice Initialize the pool at NAV and add `msg.value` ETH + `sponsAmount` sPONS (pulled from owner) as
    ///         a ±halfRange position. Leftovers are refunded to the owner.
    function seed(uint256 sponsAmount) external payable onlyOwner {
        if (seeded) revert AlreadySeeded();
        seeded = true;
        IERC20(spons).transferFrom(msg.sender, address(this), sponsAmount);
        uint160 sqrtP = navSqrtPriceX96();
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        tickLower = _floorTs(tick - halfRange);
        tickUpper = _ceilTs(tick + halfRange);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), msg.value, sponsAmount
        );
        pm.initialize(key, sqrtP);
        pm.unlock(abi.encode(uint8(0)));
        // refund anything not consumed
        uint256 ethLeft = address(this).balance;
        if (ethLeft > 0) _sendEth(owner, ethLeft);
        uint256 sLeft = IERC20(spons).balanceOf(address(this));
        if (sLeft > 0) IERC20(spons).transfer(owner, sLeft);
        emit Seeded(sqrtP, tick, tickLower, tickUpper, liquidity, msg.value - ethLeft, sponsAmount - sLeft);
    }

    function collectFees() external onlyOwner {
        if (!seeded) revert NotSeeded();
        pm.unlock(abi.encode(uint8(1)));
    }

    /// @notice Remove the whole position; ETH and sPONS go straight to the owner.
    function exit() external onlyOwner {
        if (!seeded) revert NotSeeded();
        pm.unlock(abi.encode(uint8(2)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        uint8 mode = abi.decode(data, (uint8));
        if (mode == 0) {
            (BalanceDelta d,) = pm.modifyLiquidity(key, _params(int256(uint256(liquidity))), "");
            _settleNegative(key.currency0, d.amount0());
            _settleNegative(key.currency1, d.amount1());
        } else if (mode == 1) {
            (, BalanceDelta f) = pm.modifyLiquidity(key, _params(0), "");
            (uint256 a0, uint256 a1) = _takePositive(f);
            emit FeesCollected(a0, a1);
        } else {
            (BalanceDelta d,) = pm.modifyLiquidity(key, _params(-int256(uint256(liquidity))), "");
            liquidity = 0;
            (uint256 a0, uint256 a1) = _takePositive(d);
            emit Exited(a0, a1);
        }
        return "";
    }

    function _params(int256 delta) internal view returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: delta, salt: 0});
    }

    function _takePositive(BalanceDelta d) internal returns (uint256 a0, uint256 a1) {
        if (d.amount0() > 0) { a0 = uint256(uint128(d.amount0())); pm.take(key.currency0, owner, a0); }
        if (d.amount1() > 0) { a1 = uint256(uint128(d.amount1())); pm.take(key.currency1, owner, a1); }
    }

    function _settleNegative(Currency c, int128 amt) internal {
        if (amt >= 0) return;
        uint256 owed = uint256(uint128(-amt));
        if (Currency.unwrap(c) == address(0)) {
            pm.settle{value: owed}();
        } else {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), owed);
            pm.settle();
        }
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "eth send");
    }

    function _floorTs(int24 t) internal view returns (int24) {
        int24 r = t / tickSpacing;
        if (t < 0 && t % tickSpacing != 0) r--;
        return r * tickSpacing;
    }

    function _ceilTs(int24 t) internal view returns (int24) {
        int24 f = _floorTs(t);
        return f == t ? f : f + tickSpacing;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    receive() external payable {}
}
