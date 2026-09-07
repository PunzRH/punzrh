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

/// @title V4Launch — launch a coin on a plain (hookless) Uniswap v4 pool, quoted in any ERC-20.
/// @notice Deposits the ENTIRE coin supply as a single-sided range position starting at `startTick`
///         (price expressed as coin-per-quote), so no quote token is needed up front: buyers walk the
///         price up the curve, pump-style. The position is owned by this contract and there is no
///         function to remove it — liquidity is locked forever. Only the LP fees are collectable (owner).
contract V4Launch is IUnlockCallback {
    IPoolManager public immutable pm;
    address public immutable coin;
    address public immutable quote;
    address public immutable owner;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    int24 public immutable spanTicks; // how far the curve runs (multiple of tickSpacing)
    int24 public immutable startTickCoinPerQuote; // tick of price = coin units per 1 quote unit

    PoolKey public key;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;
    bool public launched;
    bool public coinIsCurrency0;

    error NotOwner();
    error NotPoolManager();
    error AlreadyLaunched();
    error NotLaunched();

    event Launched(PoolKey key, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 coinDeposited);
    event FeesCollected(uint256 amountCoin, uint256 amountQuote);

    constructor(
        IPoolManager pm_,
        address coin_,
        address quote_,
        uint24 fee_,
        int24 tickSpacing_,
        int24 startTickCoinPerQuote_,
        int24 spanTicks_,
        address owner_
    ) {
        require(spanTicks_ > 0 && spanTicks_ % tickSpacing_ == 0, "span");
        pm = pm_;
        coin = coin_;
        quote = quote_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        startTickCoinPerQuote = startTickCoinPerQuote_;
        spanTicks = spanTicks_;
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Initialize the pool and deposit this contract's whole coin balance as one-sided liquidity.
    function launch() external onlyOwner {
        if (launched) revert AlreadyLaunched();
        launched = true;
        uint256 supply = IERC20(coin).balanceOf(address(this));
        coinIsCurrency0 = coin < quote;
        key = PoolKey({
            currency0: Currency.wrap(coinIsCurrency0 ? coin : quote),
            currency1: Currency.wrap(coinIsCurrency0 ? quote : coin),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        int24 initTick;
        if (coinIsCurrency0) {
            // pool price = quote per coin = 1/(coin per quote) -> tick = -startTick. Coin-only range sits ABOVE price.
            tickLower = _ceilTs(-startTickCoinPerQuote);
            tickUpper = tickLower + spanTicks;
            initTick = tickLower;
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), supply
            );
        } else {
            // pool price = coin per quote -> tick = startTick. Coin-only range sits BELOW price.
            tickUpper = _floorTs(startTickCoinPerQuote);
            tickLower = tickUpper - spanTicks;
            initTick = tickUpper;
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), supply
            );
        }
        pm.initialize(key, TickMath.getSqrtPriceAtTick(initTick));
        pm.unlock(abi.encode(uint8(0)));
        emit Launched(key, tickLower, tickUpper, liquidity, supply);
    }

    /// @notice Owner collects accrued LP fees (both tokens) without touching principal liquidity.
    function collectFees() external onlyOwner {
        if (!launched) revert NotLaunched();
        pm.unlock(abi.encode(uint8(1)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        uint8 mode = abi.decode(data, (uint8));
        if (mode == 0) {
            (BalanceDelta delta,) = pm.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: 0
                }),
                ""
            );
            _settleNegative(key.currency0, delta.amount0());
            _settleNegative(key.currency1, delta.amount1());
        } else {
            (, BalanceDelta feesAccrued) = pm.modifyLiquidity(
                key, ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: 0}), ""
            );
            uint256 a0 = feesAccrued.amount0() > 0 ? uint256(uint128(feesAccrued.amount0())) : 0;
            uint256 a1 = feesAccrued.amount1() > 0 ? uint256(uint128(feesAccrued.amount1())) : 0;
            if (a0 > 0) pm.take(key.currency0, owner, a0);
            if (a1 > 0) pm.take(key.currency1, owner, a1);
            emit FeesCollected(coinIsCurrency0 ? a0 : a1, coinIsCurrency0 ? a1 : a0);
        }
        return "";
    }

    function _settleNegative(Currency c, int128 amt) internal {
        if (amt >= 0) return;
        uint256 owed = uint256(uint128(-amt));
        pm.sync(c);
        IERC20(Currency.unwrap(c)).transfer(address(pm), owed);
        pm.settle();
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
}
