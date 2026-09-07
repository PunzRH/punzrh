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

/// @title EthPairPool — a small native-ETH / token hookless Uniswap v4 pool at a given price, two-sided ±range.
/// @notice Used as the "chart & route" pool for a coin whose main liquidity is quoted in sPONS: terminals only
///         price pairs quoted in whitelisted assets (ETH/USDG/stocks), so this pool gives them one to read, while
///         arbitrage keeps it in line with the sPONS pool. Owner-only collectFees()/exit() — not locked.
contract EthPairPool is IUnlockCallback {
    IPoolManager public immutable pm;
    address public immutable token;
    address public immutable owner;
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

    event Seeded(uint160 sqrtPriceX96, int24 tick, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 eth, uint256 tokens);
    event Exited(uint256 eth, uint256 tokens);
    event FeesCollected(uint256 eth, uint256 tokens);

    constructor(IPoolManager pm_, address token_, uint24 fee_, int24 tickSpacing_, int24 halfRange_, address owner_) {
        require(token_ != address(0), "token");
        pm = pm_;
        token = token_;
        tickSpacing = tickSpacing_;
        halfRange = halfRange_;
        owner = owner_;
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token_),
            fee: fee_,
            tickSpacing: tickSpacing_,
            hooks: IHooks(address(0))
        });
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param sqrtPriceX96 sqrt(token-wei per ETH-wei) * 2^96 — the pool's opening price
    function seed(uint160 sqrtPriceX96, uint256 tokenAmount) external payable onlyOwner {
        if (seeded) revert AlreadySeeded();
        seeded = true;
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        tickLower = _floorTs(tick - halfRange);
        tickUpper = _ceilTs(tick + halfRange);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), msg.value, tokenAmount
        );
        pm.initialize(key, sqrtPriceX96);
        pm.unlock(abi.encode(uint8(0)));
        uint256 ethLeft = address(this).balance;
        if (ethLeft > 0) _sendEth(owner, ethLeft);
        uint256 tLeft = IERC20(token).balanceOf(address(this));
        if (tLeft > 0) IERC20(token).transfer(owner, tLeft);
        emit Seeded(sqrtPriceX96, tick, tickLower, tickUpper, liquidity, msg.value - ethLeft, tokenAmount - tLeft);
    }

    function collectFees() external onlyOwner {
        if (!seeded) revert NotSeeded();
        pm.unlock(abi.encode(uint8(1)));
    }

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

    receive() external payable {}
}
