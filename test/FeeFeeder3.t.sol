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

contract Sink3 { receive() external payable {} }

/// Fork tests on the live PUNZ/ETH pool. The first test is exactly what killed FeeFeeder2 on 7 Sep 2026:
/// seed → PUNZ pumps ~2x (range exit, position becomes all ETH) → recenter → withdraw.
contract FeeFeeder3Test is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant PUNZ = 0x03a0e8FC8b5485CF6F66B6264F1fE295F4C24896;
    address constant HOLDER = 0x2aC5b84de496039Cfbf74cb85AD4E06BB6d6564D;
    address constant OTHER = address(0xBEEF);
    FeeFeeder3 f; Sink3 sink; PoolSwapTest router;
    receive() external payable {}
    function key() internal pure returns (PoolKey memory k) { k = PoolKey(Currency.wrap(address(0)), Currency.wrap(PUNZ), 30000, 200, IHooks(address(0))); }
    function tick() internal view returns (int24 t) { (, t,,) = PM.getSlot0(key().toId()); }
    function setUp() public {
        vm.createSelectFork(vm.envString("RH_RPC_URL"));
        sink = new Sink3(); router = new PoolSwapTest(PM); f = new FeeFeeder3(PUNZ, payable(address(sink)), 30000, 200, int24(int256(vm.envOr("FF_HALF", uint256(4000)))));
        vm.deal(HOLDER, 5 ether); vm.deal(address(this), 50 ether); vm.deal(OTHER, 2 ether);
    }
    function buy(uint256 ethIn) internal { router.swap{value: ethIn}(key(), SwapParams(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""); }
    function sellAll() internal { uint256 got = IERC20(PUNZ).balanceOf(address(this)); IERC20(PUNZ).approve(address(router), got); router.swap(key(), SwapParams(false, -int256(got), TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""); }
    function seed(address who, uint256 e, uint256 p) internal returns (uint256 sh) { vm.startPrank(who); IERC20(PUNZ).approve(address(f), p); sh = f.add{value: e}(p); vm.stopPrank(); }

    /// THE FEEFEEDER2 FAILURE, replayed
    function test_pump_exit_recenter_withdraw() public {
        uint256 e0 = HOLDER.balance; uint256 p0 = IERC20(PUNZ).balanceOf(HOLDER);
        uint256 sh = seed(HOLDER, 0.5 ether, 12_500_000e18);
        uint256 vIn = f.totalValueEth(); assertTrue(f.inRange());
        int24 t0 = tick();
        buy(6 ether);                                    // ~2x pump: tick falls (fewer PUNZ per ETH)
        assertLt(tick(), t0 - 1000, "price left the range");
        assertFalse(f.inRange());
        vm.warp(block.timestamp + 21 minutes);
        f.recenter();                                    // FeeFeeder2 died here
        assertGt(f.liquidity(), 0, "recenter must re-place liquidity even when one-sided");
        { (uint256 he, uint256 hp) = f.holdings(); assertLt(address(f).balance * 100 / (he + 1), 10, "at most 10% of the ETH left idle after recenter"); assertGt(f.tickUpper(), tick(), "range reaches above the tick so ETH is at work"); }
        assertGt(address(sink).balance, 0, "fees from the pump reached the short");
        uint256 burnedBefore = f.totalPunzBurned();
        // dip back into the new range: the ETH-only range starts earning again
        sellAll();
        vm.warp(block.timestamp + 21 minutes);
        f.harvest(); assertGt(f.totalPunzBurned(), burnedBefore, "new range earns fees (sells pay in PUNZ -> burned)");
        // and the depositor can leave with their principal
        vm.prank(HOLDER); (uint256 eth, uint256 punz) = f.withdraw(sh);
        assertEq(f.shares(HOLDER), 0); assertEq(f.totalShares(), 0);
        uint256 vOut = eth + (punz * 1e18 / 1e18 == 0 ? 0 : _punzToEth(punz));
        console.log("value in (ETH)  ", vIn); console.log("value out (ETH) ", vOut); console.log("out ETH / PUNZ  ", eth, punz);
        assertGt(vOut, vIn * 55 / 100, "principal survives a 2x pump-and-dump round trip (IL, not leakage)");
        assertLt(address(f).balance, 1e13, "no ETH left behind"); assertLt(IERC20(PUNZ).balanceOf(address(f)), 1e18, "no PUNZ left behind");
        // holder's wallet: got ETH back, spent PUNZ into the pump (converted at up to +10% before exit)
        assertGe(HOLDER.balance, e0 - 0.5 ether); assertGe(IERC20(PUNZ).balanceOf(HOLDER) + punz, p0 - 12_500_000e18);
    }

    /// dump instead: position becomes all PUNZ, recenter places a PUNZ-only range below the tick
    function test_dump_exit_recenter() public {
        seed(HOLDER, 0.5 ether, 12_500_000e18);
        buy(3 ether); sellAll();                          // acquire PUNZ then dump a lot
        vm.startPrank(HOLDER); IERC20(PUNZ).approve(address(router), 14_000_000e18);
        router.swap(key(), SwapParams(false, -int256(14_000_000e18), TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        vm.warp(block.timestamp + 21 minutes);
        if (f.inRange()) { vm.expectRevert(FeeFeeder3.InRange.selector); f.recenter(); return; }   // wide range absorbed the dump: nothing to do
        f.recenter();
        assertGt(f.liquidity(), 0); assertLe(f.tickUpper(), tick(), "PUNZ-only range sits below the tick");
    }

    /// a second depositor joining while the position is one-sided gets fair shares and both can leave
    function test_join_while_one_sided_and_fair_exit() public {
        uint256 sh1 = seed(HOLDER, 0.5 ether, 12_500_000e18);
        buy(6 ether); vm.warp(block.timestamp + 21 minutes); f.recenter();
        uint256 v1 = f.totalValueEth();
        uint256 sh2 = seed(OTHER, 1 ether, 0);          // ETH only, matches the one-sided range → straight in
        assertApproxEqRel(sh2 * 1e18 / sh1, 1 ether * 1e18 / v1, 0.02e18, "shares minted by value");
        sellAll(); vm.warp(block.timestamp + 21 minutes);
        (uint256 oe, uint256 op) = f.principalOf(OTHER); (uint256 he, uint256 hp) = f.principalOf(HOLDER);
        assertGt(oe + op, 0); assertGt(he + hp, 0);
        vm.prank(OTHER); f.withdraw(sh2); vm.prank(HOLDER); f.withdraw(sh1);
        assertEq(f.totalShares(), 0); assertLt(address(f).balance, 1e13);
    }

    /// normal life: fees go to the sink and burn, principal comes back
    function test_fees_to_sink_principal_back() public {
        uint256 sh = seed(HOLDER, 0.3 ether, 7_000_000e18);
        buy(0.3 ether); sellAll(); f.harvest();
        assertGt(address(sink).balance, 0); assertGt(f.totalPunzBurned(), 0);
        vm.prank(HOLDER); (uint256 e, uint256 p) = f.withdraw(sh); assertGt(e, 0); assertGt(p, 0);
    }

    function _punzToEth(uint256 p) internal view returns (uint256) { (uint160 sq,,,) = PM.getSlot0(key().toId()); uint256 pr = (uint256(sq) * uint256(sq)) >> 96; return p * (1 << 96) / pr; }
}
