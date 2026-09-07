// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// ZkLighter bridge on Robinhood Chain — L1 priority operations (forced inclusion; the rollup executes them in ~1–7 min).
interface IZkLighter {
    function deposit(address _to, uint16 _assetIndex, uint8 _routeType, uint256 _amount) external payable;
    function createOrder(uint48 _accountIndex, uint16 _marketIndex, uint48 _baseAmount, uint32 _price, uint8 _isAsk, uint8 _orderType) external; // reduce-only IOC
    function changePubKey(uint48 _accountIndex, uint8 _apiKeyIndex, bytes calldata _pubKey) external;
    function withdraw(uint48 _accountIndex, uint16 _assetIndex, uint8 _routeType, uint64 _baseAmount) external;
    function withdrawPendingBalance(address _owner, uint16 _assetIndex, uint128 _baseAmount) external;
    function getPendingBalance(address _owner, uint16 _assetIndex) external view returns (uint128);
    function addressToAccountIndex(address) external view returns (uint48);
}
interface IPunz is IERC20 { function burn(uint256) external; }
interface ISwapRouter02 {
    struct ExactInputSingleParams { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96; }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}
interface IWETH { function deposit() external payable; function approve(address, uint256) external returns (bool); }
interface IPerpOracle { function twapPriceX96() external view returns (uint256); }          // WETH per PONS, Q96 (v1 vault)
interface IV3Slot0 { function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool); }

/// @title LighterBacking — Backing v2: a REAL PONS short on Lighter (Robinhood Chain), custodied by this contract, redeemable by PUNZ holders.
/// @notice Lives beside Backing v1 (immutable). No new coin. Nobody owns this contract.
///
///  CUSTODY  All collateral sits in THIS CONTRACT's Lighter account. The bridge only pays withdrawals to the account's L1 owner (= this
///           contract), and L2 transfers to other accounts need the owner's L1 private key, which does not exist. No key, keeper or human
///           can move the money anywhere but back here.
///  OPENING  Lighter's L1 `createOrder` is reduce-only, so the short cannot be opened from L1. One trading API key is registered on this
///           account, once (`registerKey`, deployer-only, one shot). The keeper holding it sells PONS-PERP against the collateral, sized to
///           `leverageBps`. That key can trade and nothing else: worst case of a rogue key is bad trades, never theft.
///  IN       ETH arrives here (FeeFeeder LP fees, peg-bot profit, donations) → `fund()` swaps to USDG and deposits it.
///  SYNC     The contract can't read the rollup. The keeper mirrors the L2 position with `sync(baseTicks, entryNotional)`; anyone may call it
///           but values are clamped to what the collateral and leverage could possibly support, so a liar can only understate equity.
///  OUT      `redeem(punz)` burns PUNZ, L1-force-closes that share of the short (reduce-only IOC, works without any key) and withdraws that
///           share of estimated equity, capped at what the rollup will have free. USDG lands here directly; `settle()` pays claims in order.
contract LighterBacking is ReentrancyGuard {
    IZkLighter public constant LIGHTER = IZkLighter(0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d);
    IERC20 public constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IWETH public constant WETH = IWETH(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    ISwapRouter02 public constant ROUTER = ISwapRouter02(0xCaf681a66D020601342297493863E78C959E5cb2);
    IV3Slot0 public constant WETH_USDG = IV3Slot0(0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca); // v3 0.01%, token0 = WETH
    uint16 public constant USDG_ASSET = 3;
    uint8 public constant ROUTE_PERPS = 0;
    uint8 public constant MARKET_ORDER = 1;
    uint24 public constant SWAP_FEE = 500;
    uint256 constant Q96 = 2 ** 96;
    uint256 public constant IMF_BPS = 5000;   // PONS-PERP initial margin fraction on Robinhood Lighter (50%) — bounds withdrawals while short

    IPunz public immutable punz;
    IPerpOracle public immutable oracle;
    uint16 public immutable market;           // PONS-PERP = 44
    uint8 public immutable sizeDecimals;      // 1
    uint8 public immutable priceDecimals;     // 5
    uint256 public immutable leverageBps;     // 15000 = 1.5x
    address public immutable deployer;        // only right: registerKey once, then nothing
    bool public keyRegistered;

    uint256 public collateralUnits;   // USDG 6-dp units deposited minus withdrawals requested
    uint256 public baseTicks;         // PONS short size in size ticks (0.1 PONS), mirrored from L2
    uint256 public entryNotional;     // USDG units at entry for the mirrored size (PnL estimate)
    uint256 public totalPunzBurned;
    uint256 public totalPaid;

    struct Claim { address who; uint256 punz; uint256 requested; uint256 paid; }
    Claim[] public claims;
    uint256 public nextClaim;
    uint256 public reserved;          // USDG on this contract already assigned to paid claims (accounting only)

    event KeyRegistered(uint8 slot, bytes pubKey);
    event Funded(uint256 ethIn, uint256 usdgIn);
    event Synced(uint256 baseTicks, uint256 entryNotional, address by);
    event RedeemQueued(uint256 id, address who, uint256 punz, uint256 requestedUsdg, uint256 closeTicks);
    event ClaimPaid(uint256 id, address who, uint256 usdg);

    constructor(address punz_, address oracle_, uint16 market_, uint8 sizeDecimals_, uint8 priceDecimals_, uint256 leverageBps_) {
        punz = IPunz(punz_); oracle = IPerpOracle(oracle_); market = market_;
        sizeDecimals = sizeDecimals_; priceDecimals = priceDecimals_; leverageBps = leverageBps_; deployer = msg.sender;
    }
    receive() external payable {}

    function accountIndex() public view returns (uint48) { return LIGHTER.addressToAccountIndex(address(this)); }

    /// One-shot: register the trading key on this contract's Lighter account (account must exist → after the first deposit).
    function registerKey(uint8 slot, bytes calldata pubKey) external {
        require(msg.sender == deployer && !keyRegistered, "once");
        keyRegistered = true;
        LIGHTER.changePubKey(accountIndex(), slot, pubKey);
        emit KeyRegistered(slot, pubKey);
    }

    // ---- on-chain PONS/USD estimate
    function ethUsd6() public view returns (uint256) {
        (uint160 s,,,,,,) = WETH_USDG.slot0();
        return (uint256(s) * uint256(s) / Q96) * 1e18 / Q96;                     // USDG units per 1 ETH
    }
    function ponsPriceTicks() public view returns (uint256) {
        return oracle.twapPriceX96() * ethUsd6() / Q96 * (10 ** priceDecimals) / 1e6;
    }
    function notionalUnits(uint256 ticks, uint256 priceTicks) public view returns (uint256) {
        return ticks * priceTicks * 1e6 / (10 ** sizeDecimals) / (10 ** priceDecimals);
    }
    function equityUnits() public view returns (uint256) {
        uint256 cur = notionalUnits(baseTicks, ponsPriceTicks());
        uint256 eq = collateralUnits + entryNotional;
        return eq > cur ? eq - cur : 0;
    }
    function floorUnitsPerPunz() external view returns (uint256) {
        uint256 s = punz.totalSupply(); return s == 0 ? 0 : equityUnits() * 1e18 / s;
    }
    /// the short size the keeper should be running for the current collateral (size ticks)
    function targetBaseTicks() public view returns (uint256) {
        uint256 px = ponsPriceTicks(); if (px == 0) return 0;
        return collateralUnits * leverageBps * (10 ** sizeDecimals) * (10 ** priceDecimals) / (px * 1e6 * 1e4);
    }

    /// Anyone: ETH held here → USDG → this contract's Lighter account. The keeper then sells PONS-PERP against it.
    function fund() external nonReentrant {
        uint256 eth = address(this).balance;
        require(eth >= 0.002 ether, "nothing to fund");
        WETH.deposit{value: eth}(); WETH.approve(address(ROUTER), eth);
        uint256 usdg = ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(address(WETH), address(USDG), SWAP_FEE, address(this), eth, 0, 0));
        require(usdg >= 1e6, "dust");
        USDG.approve(address(LIGHTER), usdg);
        LIGHTER.deposit(address(this), USDG_ASSET, ROUTE_PERPS, usdg);
        collateralUnits += usdg;
        emit Funded(eth, usdg);
    }

    /// Anyone: mirror the L2 position. Clamped so a liar can only UNDER-state equity: size ≤ what leverage allows on the collateral,
    /// entry notional ≤ size × oracle price × 1.10.
    function sync(uint256 baseTicks_, uint256 entryNotional_) external {
        uint256 maxTicks = targetBaseTicks() * 110 / 100;
        if (baseTicks_ > maxTicks) baseTicks_ = maxTicks;
        uint256 maxEntry = notionalUnits(baseTicks_, ponsPriceTicks()) * 110 / 100;
        if (entryNotional_ > maxEntry) entryNotional_ = maxEntry;
        baseTicks = baseTicks_; entryNotional = entryNotional_;
        emit Synced(baseTicks_, entryNotional_, msg.sender);
    }

    /// Holder: burn PUNZ → your share of the estimated equity, in USDG, once the rollup settles (~1–7 min).
    function redeem(uint256 amount, uint32 maxBuyPriceTicks) external nonReentrant returns (uint256 id) {
        uint256 supply = punz.totalSupply();
        uint256 px = ponsPriceTicks();
        require(maxBuyPriceTicks >= px && maxBuyPriceTicks <= px * 103 / 100, "bad limit");
        require(punz.transferFrom(msg.sender, address(this), amount), "transfer");
        punz.burn(amount);
        uint256 owed = equityUnits() * amount / supply;
        uint256 closeTicks = baseTicks * amount / supply;
        if (closeTicks > 0) {
            LIGHTER.createOrder(accountIndex(), market, uint48(closeTicks), maxBuyPriceTicks, 0, MARKET_ORDER); // reduce-only IOC buy-back
            entryNotional -= entryNotional * closeTicks / baseTicks; baseTicks -= closeTicks;
        }
        uint256 marginNeeded = notionalUnits(baseTicks, px) * IMF_BPS / 1e4;
        uint256 eq = equityUnits();
        uint256 free = eq > marginNeeded ? (eq - marginNeeded) * 95 / 100 : 0;     // the rollup rejects over-withdrawals outright
        if (owed > free) owed = free;
        if (owed > 0) {
            LIGHTER.withdraw(accountIndex(), USDG_ASSET, ROUTE_PERPS, uint64(owed));
            collateralUnits = collateralUnits > owed ? collateralUnits - owed : 0;
        }
        claims.push(Claim(msg.sender, amount, owed, 0)); id = claims.length - 1;
        totalPunzBurned += amount;
        emit RedeemQueued(id, msg.sender, amount, owed, closeTicks);
    }

    /// Anyone: pay queued claims from the USDG the bridge has delivered here (and any pending balance).
    function settle() external nonReentrant {
        uint128 p = LIGHTER.getPendingBalance(address(this), USDG_ASSET);
        if (p > 0) LIGHTER.withdrawPendingBalance(address(this), USDG_ASSET, p);
        uint256 avail = USDG.balanceOf(address(this));
        while (nextClaim < claims.length && avail > 0) {
            Claim storage c = claims[nextClaim];
            uint256 pay = c.requested - c.paid; if (pay > avail) pay = avail;
            c.paid += pay; avail -= pay; totalPaid += pay;
            USDG.transfer(c.who, pay); emit ClaimPaid(nextClaim, c.who, pay);
            if (c.paid >= c.requested) nextClaim++; else break;
        }
        // USDG left over after all claims (estimation error, PnL surprises) goes back into the short on the next fund() — via deposit
        if (nextClaim >= claims.length && avail >= 1e6) { USDG.approve(address(LIGHTER), avail); LIGHTER.deposit(address(this), USDG_ASSET, ROUTE_PERPS, avail); collateralUnits += avail; }
    }
    function claimCount() external view returns (uint256) { return claims.length; }
}
