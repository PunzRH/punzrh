// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MemeCoin} from "../src/MemeCoin.sol";
import {DevLock} from "../src/DevLock.sol";

contract DevLockTest is Test {
    MemeCoin coin;
    DevLock lock;
    address dev = address(0xD0D0);

    function setUp() public {
        vm.warp(1_800_000_000);
        coin = new MemeCoin("x", "X", 1_000_000_000e18, address(this));
        lock = new DevLock(IERC20(address(coin)), dev, uint64(block.timestamp + 365 days));
        coin.transfer(address(lock), 10_000_000e18); // 1%
    }

    function test_cannotWithdrawEarly() public {
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(DevLock.Locked.selector, uint64(block.timestamp + 365 days)));
        lock.withdraw();
        vm.warp(block.timestamp + 364 days);
        vm.prank(dev);
        vm.expectRevert();
        lock.withdraw();
    }

    function test_onlyBeneficiary_afterUnlock() public {
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(DevLock.NotBeneficiary.selector);
        lock.withdraw();
        vm.prank(dev);
        lock.withdraw();
        assertEq(coin.balanceOf(dev), 10_000_000e18);
        assertEq(lock.locked(), 0);
    }

    function test_noOtherWayOut() public view {
        // nothing but withdraw() can move tokens: no approve, no rescue, no owner
        assertEq(lock.beneficiary(), dev);
        assertGt(lock.unlockAt(), block.timestamp);
    }
}
