// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PegRange} from "../src/PegRange.sol";
import {IPerpNav} from "../src/SeedPool.sol";

/// Fork: ops wallet places a range in the LIVE ETH/sPONS pool (already initialised), the peg trade fills, exit returns everything, re-seat works.
contract PegRangeTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant SPONS = 0x7c5e0547bcCdd474B3922188AB8d91d32a10DEf9;
    address constant VAULT = 0xd1C0B5E2eA749F738da9E4c13858b4fEb0f6C39D;
    address constant OPS = 0xfCBa0Dcb1668f94fF1cef112D04a4D2F3A537ae5;
    PegRange r; PoolSwapTest router;
    receive() external payable {}
    function key() internal pure returns (PoolKey memory k) { k = PoolKey(Currency.wrap(address(0)), Currency.wrap(SPONS), 3000, 60, IHooks(address(0))); }
    function setUp() public {
        vm.createSelectFork(vm.envString("RH_RPC_URL")); router = new PoolSwapTest(PM);
        r = new PegRange(PM, SPONS, IPerpNav(VAULT), 3000, 60, 1800, OPS); vm.deal(OPS, 1 ether); vm.deal(address(this), 1 ether);
    }
    function test_place_trade_exit_reseat() public {
        uint256 e0 = OPS.balance; uint256 s0 = IERC20(SPONS).balanceOf(OPS);
        vm.startPrank(OPS); IERC20(SPONS).approve(address(r), 100e18); r.seed{value: 0.02 ether}(100e18); vm.stopPrank();
        assertGt(r.liquidity(), 0); assertTrue(r.inRange(), "NAV inside the placed range");
        uint256 used = (e0 - OPS.balance); console.log("ETH used", used, "sPONS used", s0 - IERC20(SPONS).balanceOf(OPS));
        // a sell of sPONS into the pool (what the peg bot does) now fills against our range
        vm.startPrank(OPS); IERC20(SPONS).approve(address(router), 20e18);
        router.swap(key(), SwapParams(false, -int256(20e18), TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        vm.prank(OPS); r.collectFees();
        vm.prank(OPS); r.exit(); assertEq(r.liquidity(), 0);
        assertLt(address(r).balance, 1e12); assertLt(IERC20(SPONS).balanceOf(address(r)), 1e12);
        // re-seat straight away
        vm.startPrank(OPS); IERC20(SPONS).approve(address(r), 50e18); r.seed{value: 0.01 ether}(50e18); vm.stopPrank();
        assertGt(r.liquidity(), 0); assertTrue(r.inRange());
    }
}
