// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
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

/// @title FeeFeeder2 — principal-preserving liquidity whose FEES feed Backing v2 (the Lighter short).
/// @notice Anyone adds ETH+PUNZ to one concentrated position in the PUNZ/ETH pool and receives shares. Shares can be withdrawn at any time
///         for their slice of the position's principal. The fees the position earns never go to depositors: on every harvest, add and
///         withdraw, the ETH fees go to LighterBacking (→ USDG → PONS short on Lighter) and the PUNZ fees are burned.
///         If price walks out of the range, anyone can `recenter()` (30-min cooldown). Nobody owns this contract.
contract FeeFeeder2 is ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address public immutable punz;
    address payable public immutable sink;      // LighterBacking
    PoolKey public key;
    int24 public immutable halfRange;
    uint256 public constant RECENTER_COOLDOWN = 30 minutes;

    int24 public tickLower; int24 public tickUpper; uint128 public liquidity; uint256 public lastRecenter;
    uint256 public totalShares; mapping(address => uint256) public shares;
    uint256 public totalEthFed; uint256 public totalPunzBurned;

    // transient accounting for the unlock callback
    uint256 private _feeEth; uint256 private _feePunz; uint256 private _principalEth; uint256 private _principalPunz;

    event Added(address who, uint256 eth, uint256 punz, uint128 dL, uint256 sharesMinted);
    event Withdrawn(address who, uint256 sharesBurned, uint256 eth, uint256 punz);
    event Harvested(uint256 ethToSink, uint256 punzBurned);
    event Recentered(int24 lower, int24 upper, uint128 liquidity);
    error NotPoolManager(); error InRange(); error Cooldown(); error Empty(); error TooMany();

    constructor(address punz_, address payable sink_, uint24 fee_, int24 tickSpacing_, int24 halfRange_) {
        punz = punz_; sink = sink_; halfRange = halfRange_;
        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(punz_), fee: fee_, tickSpacing: tickSpacing_, hooks: IHooks(address(0))});
    }
    receive() external payable {}

    /// Add ETH (msg.value) + PUNZ (allowance). Unused leftovers are returned. Fees earned so far are routed first so you never buy into them.
    function add(uint256 punzAmount) external payable nonReentrant returns (uint256 minted) {
        if (msg.value == 0 && punzAmount == 0) revert Empty();
        if (liquidity > 0) _harvest();
        if (punzAmount > 0) IERC20(punz).transferFrom(msg.sender, address(this), punzAmount);
        if (liquidity == 0) _setRange();
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), msg.value, punzAmount);
        if (dL == 0) revert Empty();
        uint256 e0 = address(this).balance - msg.value; uint256 p0 = IERC20(punz).balanceOf(address(this)) - punzAmount;
        PM.unlock(abi.encode(uint8(0), dL));
        minted = totalShares == 0 ? uint256(dL) : uint256(dL) * totalShares / liquidity;
        liquidity += dL; totalShares += minted; shares[msg.sender] += minted;
        uint256 ethLeft = address(this).balance - e0; uint256 punzLeft = IERC20(punz).balanceOf(address(this)) - p0;
        if (ethLeft > 0) { (bool ok,) = msg.sender.call{value: ethLeft}(""); require(ok); }
        if (punzLeft > 0) IERC20(punz).transfer(msg.sender, punzLeft);
        emit Added(msg.sender, msg.value - ethLeft, punzAmount - punzLeft, dL, minted);
    }

    /// Withdraw your principal: burn shares, receive that slice of the position. Accrued fees are routed to the short/burn, not to you.
    function withdraw(uint256 sharesAmt) external nonReentrant returns (uint256 eth, uint256 punzOut) {
        if (sharesAmt == 0 || sharesAmt > shares[msg.sender]) revert TooMany();
        uint128 dL = uint128(uint256(liquidity) * sharesAmt / totalShares);
        shares[msg.sender] -= sharesAmt; totalShares -= sharesAmt; liquidity -= dL;
        _feeEth = _feePunz = _principalEth = _principalPunz = 0;
        PM.unlock(abi.encode(uint8(2), dL));
        _routeFees();
        eth = _principalEth; punzOut = _principalPunz;
        if (eth > 0) { (bool ok,) = msg.sender.call{value: eth}(""); require(ok); }
        if (punzOut > 0) IERC20(punz).transfer(msg.sender, punzOut);
        emit Withdrawn(msg.sender, sharesAmt, eth, punzOut);
    }

    function harvest() external nonReentrant { if (liquidity == 0) revert Empty(); _harvest(); }
    function _harvest() internal {
        _feeEth = _feePunz = 0;
        PM.unlock(abi.encode(uint8(1), uint128(0)));
        _routeFees();
    }
    function _routeFees() internal {
        if (_feeEth > 0) { (bool ok,) = sink.call{value: _feeEth}(""); require(ok); totalEthFed += _feeEth; }
        if (_feePunz > 0) { IPunzBurn(punz).burn(_feePunz); totalPunzBurned += _feePunz; }
        emit Harvested(_feeEth, _feePunz); _feeEth = _feePunz = 0;
    }

    /// Price left the range: pull everything (fees routed), re-add principal around the current price. Shares unchanged.
    function recenter() external nonReentrant {
        if (liquidity == 0) revert Empty();
        if (block.timestamp < lastRecenter + RECENTER_COOLDOWN) revert Cooldown();
        (, int24 tick,,) = PM.getSlot0(key.toId());
        if (tick >= tickLower && tick < tickUpper) revert InRange();
        _feeEth = _feePunz = _principalEth = _principalPunz = 0;
        uint128 L = liquidity; liquidity = 0;
        PM.unlock(abi.encode(uint8(2), L)); _routeFees();
        _setRange();
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        uint128 dL = LiquidityAmounts.getLiquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), address(this).balance, IERC20(punz).balanceOf(address(this)));
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
            (_feeEth, _feePunz) = _take(f);
        } else {
            (BalanceDelta d, BalanceDelta f) = PM.modifyLiquidity(key, _params(-int256(uint256(amt))), "");
            (uint256 t0, uint256 t1) = _take(d);                       // d already includes fees
            (uint256 f0, uint256 f1) = (f.amount0() > 0 ? uint256(uint128(f.amount0())) : 0, f.amount1() > 0 ? uint256(uint128(f.amount1())) : 0);
            _feeEth += f0; _feePunz += f1; _principalEth += t0 - f0; _principalPunz += t1 - f1;
        }
        return "";
    }
    function _take(BalanceDelta d) internal returns (uint256 a0, uint256 a1) {
        if (d.amount0() > 0) { a0 = uint256(uint128(d.amount0())); PM.take(key.currency0, address(this), a0); }
        if (d.amount1() > 0) { a1 = uint256(uint128(d.amount1())); PM.take(key.currency1, address(this), a1); }
    }
    function _setRange() internal {
        (, int24 tick,,) = PM.getSlot0(key.toId()); int24 ts = key.tickSpacing;
        int24 lo = tick - halfRange; int24 hi = tick + halfRange;
        lo = (lo / ts) * ts; if (lo < 0 && lo % ts != 0) lo -= ts;
        hi = (hi / ts) * ts; if (hi <= lo) hi = lo + ts;
        tickLower = lo; tickUpper = hi;
    }
    function _params(int256 delta) internal view returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: delta, salt: 0});
    }
    function _settleNegative(Currency c, int128 amt) internal {
        if (amt >= 0) return; uint256 owed = uint256(uint128(-amt));
        if (Currency.unwrap(c) == address(0)) PM.settle{value: owed}();
        else { PM.sync(c); IERC20(Currency.unwrap(c)).transfer(address(PM), owed); PM.settle(); }
    }
    function inRange() external view returns (bool) { (, int24 tick,,) = PM.getSlot0(key.toId()); return tick >= tickLower && tick < tickUpper; }
    /// principal a share-holder could withdraw right now (approx, ignores fee split)
    function principalOf(address who) external view returns (uint256 eth, uint256 punzAmt) {
        if (totalShares == 0) return (0, 0);
        uint128 dL = uint128(uint256(liquidity) * shares[who] / totalShares);
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        (eth, punzAmt) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), dL);
    }
}
