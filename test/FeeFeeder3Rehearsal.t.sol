// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FeeFeeder3} from "../src/FeeFeeder3.sol";

/// Rehearsal with James's exact seed against the DEPLOYED FeeFeeder3 on a fork of the live pool.
/// For every scenario: value that comes back on withdraw vs. the value of simply holding the same ETH + PUNZ at the end price.
contract FeeFeeder3Rehearsal is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant PUNZ = 0x03a0e8FC8b5485CF6F66B6264F1fE295F4C24896;
    address constant HOLDER = 0x2aC5b84de496039Cfbf74cb85AD4E06BB6d6564D;
    FeeFeeder3 constant F = FeeFeeder3(payable(0xb7D53B0Adac72cAA6eb94b39aa5C81DAEbCec17E));
    uint256 constant SEED_ETH = 1 ether; uint256 constant SEED_PUNZ = 12_000_000e18;
    PoolSwapTest router; address whale = address(0xCAFE);
    receive() external payable {}
    function key() internal pure returns (PoolKey memory k) { k = PoolKey(Currency.wrap(address(0)), Currency.wrap(PUNZ), 30000, 200, IHooks(address(0))); }
    function px() internal view returns (uint256) { (uint160 sq,,,) = PM.getSlot0(key().toId()); return (uint256(sq) * uint256(sq)) >> 96; } // PUNZ per ETH * 2^96
    function toEth(uint256 p) internal view returns (uint256) { return p * (1 << 96) / px(); }
    function setUp() public { vm.createSelectFork(vm.envString("RH_RPC_URL")); router = new PoolSwapTest(PM); vm.deal(whale, 100 ether); vm.deal(HOLDER, 5 ether); }
    function pump(uint256 ethIn) internal { vm.prank(whale); router.swap{value: ethIn}(key(), SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""); }
    function dump(uint256 punzIn) internal { vm.startPrank(whale); IERC20(PUNZ).approve(address(router), punzIn); router.swap(key(), SwapParams(false, -int256(punzIn), TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""); vm.stopPrank(); }
    function seed() internal returns (uint256 sh) { vm.startPrank(HOLDER); IERC20(PUNZ).approve(address(F), SEED_PUNZ); sh = F.add{value: SEED_ETH}(SEED_PUNZ); vm.stopPrank(); }
    function maybeRecenter() internal { vm.warp(block.timestamp + 21 minutes); if (!F.inRange()) F.recenter(); }
    function report(string memory name, uint256 sh) internal {
        uint256 e0 = HOLDER.balance; uint256 p0 = IERC20(PUNZ).balanceOf(HOLDER);
        vm.prank(HOLDER); F.withdraw(sh);
        uint256 eOut = HOLDER.balance - e0; uint256 pOut = IERC20(PUNZ).balanceOf(HOLDER) - p0;
        uint256 got = eOut + toEth(pOut); uint256 hold = SEED_ETH + toEth(SEED_PUNZ);
        int256 diffBps = (int256(got) - int256(hold)) * 10000 / int256(hold);
        console.log(name);
        console.log("   back: ETH x1e4 | PUNZ x1e-6 | vs holding (bps)", eOut / 1e14, pOut / 1e24, uint256(diffBps < 0 ? -diffBps : diffBps));
        console.log("   sign (1=behind holding) / fees to short so far (ETH x1e6)", diffBps < 0 ? 1 : 0, F.totalEthFed() / 1e12);
    }

    function test_1_deposit_then_withdraw_immediately() public { uint256 sh = seed(); report("A. in and straight back out", sh); }
    function test_2_pons_up_25pct() public { uint256 sh = seed(); pump(1.5 ether); maybeRecenter(); report("B. PUNZ +25% then withdraw", sh); }
    function test_3_pons_down_25pct() public { pump(3 ether); uint256 sh = seed(); dump(IERC20(PUNZ).balanceOf(whale) / 2); maybeRecenter(); report("C. PUNZ -25% then withdraw", sh); }
    function test_4_double_out_of_range_recenter() public { uint256 sh = seed(); pump(6 ether); maybeRecenter(); report("D. PUNZ 2x (out of range) + recenter, withdraw at the top", sh); }
    function test_5_half_out_of_range_recenter() public { pump(6 ether); uint256 sh = seed(); dump(IERC20(PUNZ).balanceOf(whale)); maybeRecenter(); report("E. PUNZ -50% (out of range) + recenter, withdraw at the bottom", sh); }
    function test_6_round_trip_2x_and_back() public { uint256 sh = seed(); pump(6 ether); maybeRecenter(); dump(IERC20(PUNZ).balanceOf(whale)); maybeRecenter(); report("F. 2x pump, recenter, full dump back, recenter, withdraw", sh); }
    function test_7_busy_day_in_range_with_fees() public {
        uint256 sh = seed();
        for (uint256 i = 0; i < 20; i++) { pump(0.3 ether); dump(IERC20(PUNZ).balanceOf(whale)); }
        F.harvest(); report("G. 20 round-trip trades inside the range (fees flow, price ends ~flat)", sh);
    }
}
