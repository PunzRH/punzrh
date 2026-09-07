// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PonsPerpPool} from "../src/PonsPerpPool.sol";

interface IV3Pool {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
}
interface IBacking { function floorWeiPerToken() external view returns (uint256); function sponsBacking() external view returns (uint256); }

/// Fork demo on the REAL PUNZ deployment: crash PONS on its real Uniswap v3 pool, let the vault's 2-min TWAP absorb it,
/// rebalance, and print what happens to sPONS / lPONS / the PUNZ floor.  RH_RPC_URL=... forge test --mc PunzCrashDemo -vv
contract PunzCrashDemo is Test {
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    IV3Pool constant PONS_POOL = IV3Pool(0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA); // token0 WETH, token1 PONS
    PonsPerpPool constant PERP = PonsPerpPool(payable(0xd1C0B5E2eA749F738da9E4c13858b4fEb0f6C39D));
    IBacking constant BACKING = IBacking(0xfCD2b6a649b4Bbf417D24B5A743D1A067cC3A348);

    function setUp() public { vm.createSelectFork(vm.envString("RH_RPC_URL")); }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a1 > 0) IERC20(PONS).transfer(msg.sender, uint256(a1));
        if (a0 > 0) IERC20(WETH).transfer(msg.sender, uint256(a0));
    }

    function _bps(uint256 after_, uint256 before_) internal pure returns (int256) { return int256(after_ * 10000 / before_) - 10000; }

    function _run(uint256 dumpPons, string memory label) internal {
        // settle the vault to "now" so the only move we measure is the crash
        vm.warp(block.timestamp + 40); PERP.rebalance();
        uint256 p0 = PERP.twapPriceX96(); uint256 s0 = PERP.sharePriceWei(PonsPerpPool.Side.SHORT); uint256 l0 = PERP.sharePriceWei(PonsPerpPool.Side.LONG);
        uint256 f0 = BACKING.floorWeiPerToken(); uint256 L0 = PERP.longBal(); uint256 S0 = PERP.shortBal();
        deal(PONS, address(this), dumpPons);
        PONS_POOL.swap(address(this), false, int256(dumpPons), TickMath.MAX_SQRT_PRICE - 1, "");
        // 2-min TWAP window fully after the crash, then rebalance (the keeper does this every 30s in production)
        vm.warp(block.timestamp + 130); PERP.rebalance();
        uint256 p1 = PERP.twapPriceX96(); uint256 s1 = PERP.sharePriceWei(PonsPerpPool.Side.SHORT); uint256 l1 = PERP.sharePriceWei(PonsPerpPool.Side.LONG);
        uint256 f1 = BACKING.floorWeiPerToken();
        console.log("==== %s ====", label);
        console.log("vault before: long %s wei | short %s wei", L0, S0);
        console.log("PONS  bps:", _bps(p1, p0));
        console.log("sPONS bps:", _bps(s1, s0));
        console.log("lPONS bps:", _bps(l1, l0));
        console.log("PUNZ floor bps:", _bps(f1, f0));
        console.log("vault after:  long %s wei | short %s wei", PERP.longBal(), PERP.shortBal());
        assertGt(s1, s0, "short must gain"); assertLt(l1, l0, "long must lose"); assertGt(f1, f0, "floor must rise");
    }

    function test_crash_1M() public { _run(1_000_000e18, "dump 1,000,000 PONS"); }
    function test_crash_4M() public { _run(4_000_000e18, "dump 4,000,000 PONS"); }
    function test_crash_10M() public { _run(10_000_000e18, "dump 10,000,000 PONS"); }
}
