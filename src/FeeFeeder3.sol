// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

interface IPunzBurn { function burn(uint256) external; }

/// @title FeeFeeder3 — principal-preserving liquidity whose FEES feed Backing v2 (the Lighter short).
/// @notice Depositors add ETH + PUNZ, receive shares, and can withdraw their slice of the principal at any time. Fees never go to
///         depositors: on every harvest / add / withdraw / recenter the ETH fees go to `sink` (LighterBacking) and PUNZ fees are burned.
/// @dev    Fixes FeeFeeder2, which bricked itself after a one-sided range exit (recenter re-added zero liquidity, then every function
///         reverted). Here:
///           * principal = position + idle balances, always; shares are valued in ETH terms, so no state has "shares but nothing to own"
///           * recenter places a ONE-SIDED range next to the price when only one token is left (ETH-only above the tick, PUNZ-only below),
///             and never leaves liquidity at zero while the contract holds anything
///           * withdraw pays the share of idle balances even when liquidity is zero; zero-delta position calls are never made
///           * nothing owned by anyone; no exit for fees other than the sink and the burn
contract FeeFeeder3 is ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address public immutable punz;
    address payable public immutable sink;
    PoolKey public key;
    int24 public immutable halfRange;
    uint256 public constant RECENTER_COOLDOWN = 20 minutes;
    uint256 public constant DUST_ETH = 1e13;          // 0.00001 ETH
    uint256 public constant DUST_PUNZ = 1e18;         // 1 PUNZ

    int24 public tickLower; int24 public tickUpper; uint128 public liquidity; uint256 public lastRecenter;
    uint256 public totalShares; mapping(address => uint256) public shares;
    uint256 public totalEthFed; uint256 public totalPunzBurned;

    uint256 private _feeEth; uint256 private _feePunz; uint256 private _principalEth; uint256 private _principalPunz;

    event Added(address who, uint256 eth, uint256 punz, uint256 sharesMinted);
    event Withdrawn(address who, uint256 sharesBurned, uint256 eth, uint256 punz);
    event Harvested(uint256 ethToSink, uint256 punzBurned);
    event Recentered(int24 lower, int24 upper, uint128 liquidity);
    error NotPoolManager(); error InRange(); error Cooldown(); error Empty(); error TooMany();

    constructor(address punz_, address payable sink_, uint24 fee_, int24 tickSpacing_, int24 halfRange_) {
        punz = punz_; sink = sink_; halfRange = halfRange_;
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(punz_), fee: fee_, tickSpacing: tickSpacing_, hooks: IHooks(address(0))});
    }
    receive() external payable {}

    // ------------------------------------------------------------------ views
    function _slot() internal view returns (uint160 sqrtP, int24 tick) { (sqrtP, tick,,) = PM.getSlot0(key.toId()); }
    /// PUNZ → ETH at the current pool price (token1 → token0)
    function _toEth(uint256 punzAmt, uint160 sqrtP) internal pure returns (uint256) {
        if (punzAmt == 0) return 0;
        uint256 p = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96);     // (sqrtP^2 / 2^96) = price * 2^96
        return FullMath.mulDiv(punzAmt, 1 << 96, p);
    }
    /// principal held by the contract (position + idle), fees excluded (they are routed before any accounting)
    function holdings() public view returns (uint256 eth, uint256 punzAmt) {
        (uint160 sqrtP,) = _slot();
        if (liquidity > 0) (eth, punzAmt) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity);
        eth += address(this).balance; punzAmt += IERC20(punz).balanceOf(address(this));
    }
    /// total principal in ETH terms at the current price
    function totalValueEth() public view returns (uint256) { (uint256 e, uint256 p) = holdings(); (uint160 sqrtP,) = _slot(); return e + _toEth(p, sqrtP); }
    function principalOf(address who) external view returns (uint256 eth, uint256 punzAmt) {
        if (totalShares == 0) return (0, 0);
        (uint256 e, uint256 p) = holdings(); eth = e * shares[who] / totalShares; punzAmt = p * shares[who] / totalShares;
    }
    function inRange() public view returns (bool) { (, int24 tick) = _slot(); return liquidity > 0 && tick >= tickLower && tick < tickUpper; }

    // ------------------------------------------------------------------ add / withdraw
    /// Add ETH (msg.value) and/or PUNZ (allowance). Shares are minted by value; anything that does not fit the current range stays as idle
    /// principal (still yours) until the next recenter puts it to work.
    function add(uint256 punzAmount) external payable nonReentrant returns (uint256 minted) {
        if (msg.value == 0 && punzAmount == 0) revert Empty();
        if (liquidity > 0) _collectFees();
        (uint160 sqrtP,) = _slot();
        uint256 before = totalValueEth() - msg.value;                       // value already owned by existing shares
        if (punzAmount > 0) IERC20(punz).transferFrom(msg.sender, address(this), punzAmount);
        uint256 depositValue = msg.value + _toEth(punzAmount, sqrtP);
        minted = totalShares == 0 || before == 0 ? depositValue : FullMath.mulDiv(depositValue, totalShares, before);
        if (minted == 0) revert Empty();
        totalShares += minted; shares[msg.sender] += minted;
        _deploy();                                                          // put idle balances into the position (range set if needed)
        emit Added(msg.sender, msg.value, punzAmount, minted);
    }

    /// Withdraw your slice of the principal (position share + idle share). Fees accrued so far are routed to the short / burn, not to you.
    function withdraw(uint256 sharesAmt) external nonReentrant returns (uint256 eth, uint256 punzOut) {
        if (sharesAmt == 0 || sharesAmt > shares[msg.sender]) revert TooMany();
        _feeEth = _feePunz = _principalEth = _principalPunz = 0;
        if (liquidity > 0) {
            uint128 dL = uint128(FullMath.mulDiv(liquidity, sharesAmt, totalShares));
            if (dL > 0) { liquidity -= dL; PM.unlock(abi.encode(uint8(2), dL)); }
            else PM.unlock(abi.encode(uint8(1), uint128(0)));                 // collect fees only
            _routeFees();
        }
        // idle share (after removing the position slice; idle now includes the removed principal, which belongs to this withdrawer)
        uint256 idleEth = address(this).balance - _principalEth; uint256 idlePunz = IERC20(punz).balanceOf(address(this)) - _principalPunz;
        eth = _principalEth + idleEth * sharesAmt / totalShares; punzOut = _principalPunz + idlePunz * sharesAmt / totalShares;
        shares[msg.sender] -= sharesAmt; totalShares -= sharesAmt; _principalEth = _principalPunz = 0;
        if (eth > 0) { (bool ok,) = msg.sender.call{value: eth}(""); require(ok); }
        if (punzOut > 0) IERC20(punz).transfer(msg.sender, punzOut);
        emit Withdrawn(msg.sender, sharesAmt, eth, punzOut);
    }

    // ------------------------------------------------------------------ fees
    function harvest() external nonReentrant { if (liquidity == 0) revert Empty(); _collectFees(); }
    function _collectFees() internal { _feeEth = _feePunz = 0; PM.unlock(abi.encode(uint8(1), uint128(0))); _routeFees(); }
    function _routeFees() internal {
        if (_feeEth > 0) { (bool ok,) = sink.call{value: _feeEth}(""); require(ok); totalEthFed += _feeEth; }
        if (_feePunz > 0) { IPunzBurn(punz).burn(_feePunz); totalPunzBurned += _feePunz; }
        if (_feeEth > 0 || _feePunz > 0) emit Harvested(_feeEth, _feePunz);
        _feeEth = _feePunz = 0;
    }

    // ------------------------------------------------------------------ recenter
    /// Price left the range (or the position is empty while the contract holds principal): pull everything, route fees, re-place the
    /// principal next to the current price. One-sided when only one token is left. Shares unchanged.
    function recenter() external nonReentrant {
        if (block.timestamp < lastRecenter + RECENTER_COOLDOWN) revert Cooldown();
        if (liquidity > 0) {
            (, int24 tick) = _slot();
            if (tick >= tickLower && tick < tickUpper) revert InRange();
            _feeEth = _feePunz = _principalEth = _principalPunz = 0;
            uint128 L = liquidity; liquidity = 0;
            PM.unlock(abi.encode(uint8(2), L)); _routeFees(); _principalEth = _principalPunz = 0;
        }
        lastRecenter = block.timestamp;
        _deploy();
        if (liquidity == 0) revert Empty();
        emit Recentered(tickLower, tickUpper, liquidity);
    }

    /// Put the idle balances into the position. If there is no position yet, choose the range from what we hold.
    function _deploy() internal {
        uint256 e = address(this).balance; uint256 p = IERC20(punz).balanceOf(address(this));
        if (e < DUST_ETH && p < DUST_PUNZ) return;
        (uint160 sqrtP, int24 tick) = _slot();
        if (liquidity == 0) _chooseRange(sqrtP, tick, e, p);
        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), e, p);
        if (dL == 0) return;
        PM.unlock(abi.encode(uint8(0), dL));
        liquidity += dL;
    }
    /// Slide a window of 2*halfRange ticks from "entirely below the tick" (PUNZ-only) to "entirely above" (ETH-only) and keep the placement
    /// that turns the MOST of what we hold into liquidity. Whatever the mix (all ETH after a pump, all PUNZ after a dump, or anything in
    /// between), the capital goes to work next to the price instead of sitting idle. This is the FeeFeeder2 fix.
    function _chooseRange(uint160 sqrtP, int24 tick, uint256 e, uint256 p) internal {
        int24 ts = key.tickSpacing; int24 n = (2 * halfRange) / ts; if (n < 1) n = 1;
        int24 base = _floor(tick, ts);
        uint128 best; int24 bestLo = base - (n - 1) * ts; int24 bestHi = bestLo + n * ts;
        for (int24 i = -1; i <= n; i++) {
            int24 lo = base - (n - 1) * ts + i * ts; int24 hi = lo + n * ts;
            if (lo < TickMath.MIN_TICK || hi > TickMath.MAX_TICK) continue;
            uint128 L = LiquidityAmounts.getLiquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), e, p);
            if (L > best) { best = L; bestLo = lo; bestHi = hi; }
        }
        tickLower = bestLo; tickUpper = bestHi;
    }
    function _floor(int24 t, int24 ts) internal pure returns (int24 r) { r = (t / ts) * ts; if (t < 0 && r != t) r -= ts; }

    // ------------------------------------------------------------------ v4 callback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(PM)) revert NotPoolManager();
        (uint8 mode, uint128 amt) = abi.decode(data, (uint8, uint128));
        if (mode == 0) {
            (BalanceDelta d,) = PM.modifyLiquidity(key, _params(int256(uint256(amt))), "");
            _settleNegative(key.currency0, d.amount0()); _settleNegative(key.currency1, d.amount1());
        } else if (mode == 1) {
            (, BalanceDelta f) = PM.modifyLiquidity(key, _params(0), "");
            (uint256 a0, uint256 a1) = _take(f); _feeEth += a0; _feePunz += a1;
        } else {
            (BalanceDelta d, BalanceDelta f) = PM.modifyLiquidity(key, _params(-int256(uint256(amt))), "");
            (uint256 t0, uint256 t1) = _take(d);
            uint256 f0 = f.amount0() > 0 ? uint256(uint128(f.amount0())) : 0; uint256 f1 = f.amount1() > 0 ? uint256(uint128(f.amount1())) : 0;
            _feeEth += f0; _feePunz += f1; _principalEth += t0 - f0; _principalPunz += t1 - f1;
        }
        return "";
    }
    function _take(BalanceDelta d) internal returns (uint256 a0, uint256 a1) {
        if (d.amount0() > 0) { a0 = uint256(uint128(d.amount0())); PM.take(key.currency0, address(this), a0); }
        if (d.amount1() > 0) { a1 = uint256(uint128(d.amount1())); PM.take(key.currency1, address(this), a1); }
    }
    function _params(int256 delta) internal view returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: delta, salt: 0});
    }
    function _settleNegative(Currency c, int128 amt) internal {
        if (amt >= 0) return; uint256 owed = uint256(uint128(-amt));
        if (Currency.unwrap(c) == address(0)) PM.settle{value: owed}();
        else { PM.sync(c); IERC20(Currency.unwrap(c)).transfer(address(PM), owed); PM.settle(); }
    }
}
