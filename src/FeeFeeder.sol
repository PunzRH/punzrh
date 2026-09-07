// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

interface IPunzBurn { function burn(uint256) external; }

/// @title FeeFeeder — a LOCKED, permissionless liquidity position in the PUNZ/ETH pool whose fees feed Backing v2 (the Lighter short).
/// @notice Anyone can add ETH+PUNZ liquidity here; nobody can ever take it out. Fees are collected by anyone via `harvest()`:
///         the ETH goes to LighterBacking (→ USDG → PONS short on Lighter), the PUNZ is burned. If price walks out of the range,
///         anyone can `recenter()` (after a cooldown): the position is pulled and re-added around the current price — inside this
///         contract, never to a person. This is how PUNZ volume feeds the second short without touching the immutable v1 plumbing.
contract FeeFeeder {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address public immutable punz;
    address payable public immutable sink;      // LighterBacking
    PoolKey public key;
    int24 public immutable halfRange;           // ticks each side of the price
    uint256 public constant RECENTER_COOLDOWN = 30 minutes;

    int24 public tickLower; int24 public tickUpper; uint128 public liquidity; uint256 public lastRecenter;
    uint256 public totalEthFed; uint256 public totalPunzBurned;

    event Added(address who, uint256 eth, uint256 punzIn, uint128 liquidityDelta, int24 lower, int24 upper);
    event Harvested(uint256 ethToSink, uint256 punzBurned);
    event Recentered(int24 lower, int24 upper, uint128 liquidity);

    error NotPoolManager(); error InRange(); error Cooldown(); error Empty();

    constructor(address punz_, address payable sink_, uint24 fee_, int24 tickSpacing_, int24 halfRange_) {
        punz = punz_; sink = sink_; halfRange = halfRange_;
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(punz_), fee: fee_, tickSpacing: tickSpacing_, hooks: IHooks(address(0))});
    }
    receive() external payable {}

    // ---- anyone: add liquidity (ETH with the call, PUNZ pulled via allowance). Leftovers are returned.
    function add(uint256 punzAmount) external payable {
        if (msg.value == 0 && punzAmount == 0) revert Empty();
        if (punzAmount > 0) IERC20(punz).transferFrom(msg.sender, address(this), punzAmount);
        if (liquidity == 0) _setRange();
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), msg.value, punzAmount);
        if (dL == 0) revert Empty();
        uint256 e0 = address(this).balance; uint256 p0 = IERC20(punz).balanceOf(address(this));
        PM.unlock(abi.encode(uint8(0), dL));
        liquidity += dL;
        // return what the position didn't take
        uint256 ethLeft = address(this).balance - (e0 - msg.value) ; // balance that came from this call and wasn't used
        uint256 punzLeft = IERC20(punz).balanceOf(address(this)) - (p0 - punzAmount);
        if (ethLeft > 0) { (bool ok,) = msg.sender.call{value: ethLeft}(""); require(ok); }
        if (punzLeft > 0) IERC20(punz).transfer(msg.sender, punzLeft);
        emit Added(msg.sender, msg.value - ethLeft, punzAmount - punzLeft, dL, tickLower, tickUpper);
    }

    // ---- anyone: collect fees → ETH to the Lighter short, PUNZ burned
    function harvest() external {
        if (liquidity == 0) revert Empty();
        uint256 e0 = address(this).balance; uint256 p0 = IERC20(punz).balanceOf(address(this));
        PM.unlock(abi.encode(uint8(1), uint128(0)));
        uint256 eth = address(this).balance - e0; uint256 p = IERC20(punz).balanceOf(address(this)) - p0;
        if (eth > 0) { (bool ok,) = sink.call{value: eth}(""); require(ok); totalEthFed += eth; }
        if (p > 0) { IPunzBurn(punz).burn(p); totalPunzBurned += p; }
        emit Harvested(eth, p);
    }

    // ---- anyone, when price has left the range: pull and re-add around the current price (nothing leaves the contract)
    function recenter() external {
        if (liquidity == 0) revert Empty();
        if (block.timestamp < lastRecenter + RECENTER_COOLDOWN) revert Cooldown();
        (, int24 tick,,) = PM.getSlot0(key.toId());
        if (tick >= tickLower && tick < tickUpper) revert InRange();
        PM.unlock(abi.encode(uint8(2), liquidity)); liquidity = 0;   // fees + principal now sit in this contract
        uint256 p = IERC20(punz).balanceOf(address(this)); uint256 eth = address(this).balance;
        _setRange();
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), eth, p);
        if (dL > 0) { PM.unlock(abi.encode(uint8(0), dL)); liquidity = dL; }
        lastRecenter = block.timestamp;
        emit Recentered(tickLower, tickUpper, dL);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(PM)) revert NotPoolManager();
        (uint8 mode, uint128 amt) = abi.decode(data, (uint8, uint128));
        if (mode == 0) {
            (BalanceDelta d,) = PM.modifyLiquidity(key, _params(int256(uint256(amt))), "");
            _settleNegative(key.currency0, d.amount0()); _settleNegative(key.currency1, d.amount1());
        } else if (mode == 1) {
            (, BalanceDelta f) = PM.modifyLiquidity(key, _params(0), "");
            _takePositive(f);
        } else {
            (BalanceDelta d,) = PM.modifyLiquidity(key, _params(-int256(uint256(amt))), "");
            _takePositive(d);
        }
        return "";
    }

    function _setRange() internal {
        (, int24 tick,,) = PM.getSlot0(key.toId());
        int24 ts = key.tickSpacing;
        int24 lo = tick - halfRange; int24 hi = tick + halfRange;
        lo = (lo / ts) * ts; if (lo < 0 && lo % ts != 0) lo -= ts;
        hi = (hi / ts) * ts; if (hi <= lo) hi = lo + ts;
        tickLower = lo; tickUpper = hi;
    }
    function _params(int256 delta) internal view returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: delta, salt: 0});
    }
    function _takePositive(BalanceDelta d) internal {
        if (d.amount0() > 0) PM.take(key.currency0, address(this), uint256(uint128(d.amount0())));
        if (d.amount1() > 0) PM.take(key.currency1, address(this), uint256(uint128(d.amount1())));
    }
    function _settleNegative(Currency c, int128 amt) internal {
        if (amt >= 0) return;
        uint256 owed = uint256(uint128(-amt));
        if (Currency.unwrap(c) == address(0)) PM.settle{value: owed}();
        else { PM.sync(c); IERC20(Currency.unwrap(c)).transfer(address(PM), owed); PM.settle(); }
    }
    function inRange() external view returns (bool) { (, int24 tick,,) = PM.getSlot0(key.toId()); return tick >= tickLower && tick < tickUpper; }
}
