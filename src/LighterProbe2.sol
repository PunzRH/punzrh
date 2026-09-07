// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IZkLighter2 {
    function deposit(address _to, uint16 _assetIndex, uint8 _routeType, uint256 _amount) external payable;
    function createOrder(uint48 _accountIndex, uint16 _marketIndex, uint48 _baseAmount, uint32 _price, uint8 _isAsk, uint8 _orderType) external;
    function changePubKey(uint48 _accountIndex, uint8 _apiKeyIndex, bytes calldata _pubKey) external;
    function cancelAllOrders(uint48 _accountIndex) external;
    function withdraw(uint48 _accountIndex, uint16 _assetIndex, uint8 _routeType, uint64 _baseAmount) external;
    function addressToAccountIndex(address) external view returns (uint48);
}

/// Probe #2: does the rollup only honour L1 orders once the account has a registered API public key?
contract LighterProbe2 {
    IZkLighter2 public constant L = IZkLighter2(0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d);
    IERC20 public constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address public immutable owner;
    modifier onlyOwner() { require(msg.sender == owner, "owner"); _; }
    constructor() { owner = msg.sender; }
    function acct() public view returns (uint48) { return L.addressToAccountIndex(address(this)); }
    function depositUSDG(uint256 amount) external onlyOwner { USDG.transferFrom(msg.sender, address(this), amount); USDG.approve(address(L), amount); L.deposit(address(this), 3, 0, amount); }
    function registerKey(uint8 slot, bytes calldata pubKey) external onlyOwner { L.changePubKey(acct(), slot, pubKey); }
    function order(uint16 market, uint48 base, uint32 price, uint8 isAsk, uint8 otype) external onlyOwner { L.createOrder(acct(), market, base, price, isAsk, otype); }
    function cancelAll() external onlyOwner { L.cancelAllOrders(acct()); }
    function withdrawUnits(uint64 units) external onlyOwner { L.withdraw(acct(), 3, 0, units); }
    function sweep() external onlyOwner { USDG.transfer(owner, USDG.balanceOf(address(this))); }
}
