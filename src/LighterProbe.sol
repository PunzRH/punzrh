// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// Minimal interface of the ZkLighter bridge deployed on Robinhood Chain (proxy 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d).
/// All of these are L1 "priority requests": the rollup is forced to process them, and the caller must be the L1 owner of the account.
interface IZkLighter {
    function deposit(address _to, uint16 _assetIndex, uint8 _routeType, uint256 _amount) external payable;
    function createOrder(uint48 _accountIndex, uint16 _marketIndex, uint48 _baseAmount, uint32 _price, uint8 _isAsk, uint8 _orderType) external;
    function cancelAllOrders(uint48 _accountIndex) external;
    function withdraw(uint48 _accountIndex, uint16 _assetIndex, uint8 _routeType, uint64 _baseAmount) external;
    function withdrawPendingBalance(address _owner, uint16 _assetIndex, uint128 _baseAmount) external;
    function getPendingBalance(address _owner, uint16 _assetIndex) external view returns (uint128);
    function addressToAccountIndex(address) external view returns (uint48);
}

/// @title LighterProbe — $20 experiment: can a CONTRACT own a Lighter account and run a PONS short purely through L1 calls?
/// @notice Owner-only wrapper so the ops wallet can drive each step and we can watch the rollup react.
///         If every step works, the same calls go into Backing v2 (LighterBacking) with pro-rata redeem.
contract LighterProbe {
    IZkLighter public constant LIGHTER = IZkLighter(0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d);
    IERC20 public constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    uint16 public constant USDG_ASSET = 3;   // assetConfigs(3) == USDG on this bridge
    uint8 public constant ROUTE_PERPS = 0;   // TxTypes.RouteType.Perps
    uint8 public constant LIMIT = 0;
    uint8 public constant MARKET = 1;

    address public immutable owner;
    modifier onlyOwner() { require(msg.sender == owner, "owner"); _; }
    constructor() { owner = msg.sender; }

    /// step 1: pull USDG from the owner and deposit it into THIS CONTRACT's Lighter account (created on first deposit)
    function depositUSDG(uint256 amount) external onlyOwner {
        USDG.transferFrom(msg.sender, address(this), amount);
        USDG.approve(address(LIGHTER), amount);
        LIGHTER.deposit(address(this), USDG_ASSET, ROUTE_PERPS, amount);
    }
    function accountIndex() public view returns (uint48) { return LIGHTER.addressToAccountIndex(address(this)); }

    /// step 2: open (or extend) a SHORT: sell `baseAmount` ticks at up to `price` ticks (market order with a price limit)
    function openShort(uint16 market, uint48 baseAmount, uint32 price) external onlyOwner {
        LIGHTER.createOrder(accountIndex(), market, baseAmount, price, 1, MARKET);
    }
    /// step 3: close: buy back. baseAmount 0 = "whole position" per the bridge source; price = max you'll pay
    function closeShort(uint16 market, uint48 baseAmount, uint32 price) external onlyOwner {
        LIGHTER.createOrder(accountIndex(), market, baseAmount, price, 0, MARKET);
    }
    function cancelAll() external onlyOwner { LIGHTER.cancelAllOrders(accountIndex()); }

    /// step 4: withdraw collateral (in ticks: USDG tick = 1 USDG) — arrives as an L1 "pending balance" once the rollup processes it
    function requestWithdraw(uint64 ticks) external onlyOwner { LIGHTER.withdraw(accountIndex(), USDG_ASSET, ROUTE_PERPS, ticks); }
    function pending() external view returns (uint128) { return LIGHTER.getPendingBalance(address(this), USDG_ASSET); }
    /// step 5: pull the pending balance to this contract, then sweep to owner
    function claimPending(uint128 amount) external onlyOwner { LIGHTER.withdrawPendingBalance(address(this), USDG_ASSET, amount); }
    function sweep() external onlyOwner { USDG.transfer(owner, USDG.balanceOf(address(this))); }
}
