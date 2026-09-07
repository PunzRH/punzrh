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
import {IPerpNav} from "./SeedPool.sol";

/// @title PegRange — the peg keeper's re-seatable liquidity in the (already initialised) ETH/sPONS pool.
/// @notice SeedPool's range is fixed at seeding time; once PONS moves ~20% NAV leaves the range and the peg bot has nothing to trade
///         against. PegRange is the same position, owned by the ops wallet, that can be exited and re-placed around the current NAV
///         any number of times. It is the operator's own market-making inventory: not holder funds, not fee routing.
///         Same read interface as SeedPool (tickLower/tickUpper/liquidity/navSqrtPriceX96) so the keeper code is unchanged.
contract PegRange is IUnlockCallback {
    IPoolManager public immutable pm;
    address public immutable spons;
    IPerpNav public immutable perp;
    address public immutable owner;
    int24 public immutable halfRange;
    PoolKey public key;
    int24 public tickLower; int24 public tickUpper; uint128 public liquidity;
    error NotOwner(); error NotPoolManager(); error HasPosition(); error NoPosition();
    event Placed(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 eth, uint256 sponsIn);
    event Exited(uint256 eth, uint256 sponsOut); event FeesCollected(uint256 eth, uint256 sponsOut);

    constructor(IPoolManager pm_, address spons_, IPerpNav perp_, uint24 fee_, int24 tickSpacing_, int24 halfRange_, address owner_) {
        pm = pm_; spons = spons_; perp = perp_; halfRange = halfRange_; owner = owner_;
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(spons_), fee: fee_, tickSpacing: tickSpacing_, hooks: IHooks(address(0))});
    }
    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    receive() external payable {}

    function navSqrtPriceX96() public view returns (uint160) {
        uint256 spw = perp.sharePriceWei(1); require(spw > 0, "no nav");
        return uint160(_sqrt((uint256(1e18) << 192) / spw));
    }
    function inRange() external view returns (bool) { int24 t = TickMath.getTickAtSqrtPrice(navSqrtPriceX96()); return liquidity > 0 && t >= tickLower && t < tickUpper; }

    /// Place msg.value ETH + sponsAmount sPONS as a ±halfRange position around the CURRENT pool price (so the add is two-sided) —
    /// the keeper then trades the pool to NAV. Leftovers refunded.
    function seed(uint256 sponsAmount) external payable onlyOwner {
        if (liquidity > 0) revert HasPosition();
        if (sponsAmount > 0) IERC20(spons).transferFrom(msg.sender, address(this), sponsAmount);
        (uint160 sqrtP, int24 tick,,) = _slot0();
        int24 navTick = TickMath.getTickAtSqrtPrice(navSqrtPriceX96());
        int24 center = (tick + navTick) / 2;                                   // straddle both so the peg trade and NAV are covered
        tickLower = _floorTs(center - halfRange); tickUpper = _ceilTs(center + halfRange);
        if (tickLower > tick - key.tickSpacing) tickLower = _floorTs(tick - key.tickSpacing);
        if (tickUpper < tick + key.tickSpacing) tickUpper = _ceilTs(tick + key.tickSpacing);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), msg.value, sponsAmount);
        require(liquidity > 0, "nothing to add");
        pm.unlock(abi.encode(uint8(0)));
        uint256 ethLeft = address(this).balance; if (ethLeft > 0) _sendEth(owner, ethLeft);
        uint256 sLeft = IERC20(spons).balanceOf(address(this)); if (sLeft > 0) IERC20(spons).transfer(owner, sLeft);
        emit Placed(tickLower, tickUpper, liquidity, msg.value - ethLeft, sponsAmount - sLeft);
    }
    function collectFees() external onlyOwner { if (liquidity == 0) revert NoPosition(); pm.unlock(abi.encode(uint8(1))); }
    function exit() external onlyOwner { if (liquidity == 0) revert NoPosition(); pm.unlock(abi.encode(uint8(2))); }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(pm)) revert NotPoolManager();
        uint8 mode = abi.decode(data, (uint8));
        if (mode == 0) {
            (BalanceDelta d,) = pm.modifyLiquidity(key, _params(int256(uint256(liquidity))), "");
            _settleNegative(key.currency0, d.amount0()); _settleNegative(key.currency1, d.amount1());
        } else if (mode == 1) {
            (, BalanceDelta f) = pm.modifyLiquidity(key, _params(0), "");
            (uint256 a0, uint256 a1) = _takePositive(f); emit FeesCollected(a0, a1);
        } else {
            (BalanceDelta d,) = pm.modifyLiquidity(key, _params(-int256(uint256(liquidity))), "");
            liquidity = 0; (uint256 a0, uint256 a1) = _takePositive(d); emit Exited(a0, a1);
        }
        return "";
    }
    function _slot0() internal view returns (uint160 sqrtP, int24 tick, uint24 pf, uint24 lf) {
        bytes32 v = pm.extsload(keccak256(abi.encode(_poolId(), uint256(6))));
        sqrtP = uint160(uint256(v)); tick = int24(int256(uint256(v) >> 160)); pf = 0; lf = 0;
    }
    function _poolId() internal view returns (bytes32) { return keccak256(abi.encode(key)); }
    function _params(int256 delta) internal view returns (ModifyLiquidityParams memory) { return ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: delta, salt: 0}); }
    function _takePositive(BalanceDelta d) internal returns (uint256 a0, uint256 a1) {
        if (d.amount0() > 0) { a0 = uint256(uint128(d.amount0())); pm.take(key.currency0, owner, a0); }
        if (d.amount1() > 0) { a1 = uint256(uint128(d.amount1())); pm.take(key.currency1, owner, a1); }
    }
    function _settleNegative(Currency c, int128 amt) internal {
        if (amt >= 0) return; uint256 owed = uint256(uint128(-amt));
        if (Currency.unwrap(c) == address(0)) pm.settle{value: owed}();
        else { pm.sync(c); IERC20(Currency.unwrap(c)).transfer(address(pm), owed); pm.settle(); }
    }
    function _sendEth(address to, uint256 amount) internal { (bool ok,) = to.call{value: amount}(""); require(ok, "eth send"); }
    function _floorTs(int24 t) internal view returns (int24) { int24 ts = key.tickSpacing; int24 r = t / ts; if (t < 0 && t % ts != 0) r--; return r * ts; }
    function _ceilTs(int24 t) internal view returns (int24) { int24 f = _floorTs(t); return f == t ? f : f + key.tickSpacing; }
    function _sqrt(uint256 x) internal pure returns (uint256 y) { if (x == 0) return 0; uint256 z = (x + 1) / 2; y = x; while (z < y) { y = z; z = (x / z + z) / 2; } }
}
