// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PonsPerpPool} from "../src/PonsPerpPool.sol";

interface IV3Pool {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

/// Fork demo: crash PONS on its real Uniswap v3 pool and watch the whole stack reprice.
contract PonsCrashDemo is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    IV3Pool constant PONS_POOL = IV3Pool(0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA); // token0 WETH, token1 PONS
    PonsPerpPool constant PERP = PonsPerpPool(payable(0x34dC2FA6391D10Bd9dFE38BE96b5EdEFBCC8F46b));
    address constant SPONS = 0xB4b4365e53f8c486710aBad50D66EEBEaFDb2ae2;
    address constant TSPONS = 0x23E1ACD296651A6270e9f5201229805E0A878A00;

    PoolSwapTest router;

    function setUp() public {
        vm.createSelectFork(vm.envString("RH_RPC_URL"));
        router = new PoolSwapTest(PM);
        vm.deal(address(this), 10 ether);
    }

    // --- pool keys (all hookless) ---
    function _sponsEth() internal pure returns (PoolKey memory k) {
        k = PoolKey(Currency.wrap(address(0)), Currency.wrap(SPONS), 3000, 60, IHooks(address(0)));
    }
    function _tsponsSpons() internal pure returns (PoolKey memory k) {
        k = PoolKey(Currency.wrap(TSPONS), Currency.wrap(SPONS), 10_000, 200, IHooks(address(0)));
    }
    function _tsponsEth() internal pure returns (PoolKey memory k) {
        k = PoolKey(Currency.wrap(address(0)), Currency.wrap(TSPONS), 10_000, 200, IHooks(address(0)));
    }
    function _price(PoolKey memory k) internal view returns (uint256 p1per0_1e18) {
        (uint160 s,,,) = PM.getSlot0(k.toId());
        // (s/2^96)^2 * 1e18, overflow-safe
        p1per0_1e18 = FullMath.mulDiv(FullMath.mulDiv(uint256(s), uint256(s), 2 ** 96), 1e18, 2 ** 96);
    }

    /// TSPONS implied ETH price (wei per 1e18 TSPONS) via the sPONS route: sPONS-per-TSPONS * ETH-per-sPONS
    function _tsponsImpliedEthWei() internal view returns (uint256) {
        uint256 sponsPerTspons = _price(_tsponsSpons()); // 1e18-scaled
        uint256 nav = PERP.sharePriceWei(PonsPerpPool.Side.SHORT); // wei per sPONS
        return sponsPerTspons * nav / 1e18;
    }
    function _tsponsEthPoolWei() internal view returns (uint256) {
        uint256 tsponsPerEth = _price(_tsponsEth()); // 1e18-scaled TSPONS per ETH
        return 1e36 / tsponsPerEth;
    }

    // v3 swap callback: pay the pool what we owe
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a1 > 0) IERC20(PONS).transfer(msg.sender, uint256(a1));
        if (a0 > 0) IERC20(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73).transfer(msg.sender, uint256(a0));
    }

    function test_ponsCrash_repricesEverything() public {
        (, int24 t0,,,,,) = PONS_POOL.slot0();
        uint256 nav0 = PERP.sharePriceWei(PonsPerpPool.Side.SHORT);
        uint256 lnav0 = PERP.sharePriceWei(PonsPerpPool.Side.LONG);
        uint256 implied0 = _tsponsImpliedEthWei();
        uint256 ethPool0 = _tsponsEthPoolWei();
        console.log("=== BEFORE ===");
        console.log("PONS tick:", int256(t0));
        console.log("sPONS NAV (wei):", nav0);
        console.log("lPONS NAV (wei):", lnav0);
        console.log("TSPONS implied ETH price via sPONS (wei/1e18):", implied0);
        console.log("TSPONS ETH-pool price (wei/1e18):", ethPool0);

        // 1) CRASH: dump 4M PONS into the real PONS/WETH 1% pool (token1 -> token0)
        deal(PONS, address(this), 4_000_000e18);
        PONS_POOL.swap(address(this), false, int256(4_000_000e18), TickMath.MAX_SQRT_PRICE - 1, "");
        (, int24 t1,,,,,) = PONS_POOL.slot0();
        // tick is PONS-per-WETH: higher tick = more PONS per ETH = PONS cheaper
        int256 dTick = int256(t1) - int256(t0);
        console.log("=== CRASH === PONS tick moved by (PONS/ETH change ~ 1.0001^-dTick):", dTick);

        // 2) let the 5-min TWAP absorb it, then rebalance the perp pool
        vm.warp(block.timestamp + 301);
        PERP.rebalance();
        uint256 nav1 = PERP.sharePriceWei(PonsPerpPool.Side.SHORT);
        uint256 lnav1 = PERP.sharePriceWei(PonsPerpPool.Side.LONG);
        uint256 implied1 = _tsponsImpliedEthWei();
        console.log("=== AFTER REBALANCE ===");
        console.log("sPONS NAV (wei):", nav1);
        console.log("  sPONS change bps:", int256((nav1 * 10000) / nav0) - 10000);
        console.log("lPONS NAV (wei):", lnav1);
        console.log("  lPONS change bps:", int256((lnav1 * 10000) / lnav0) - 10000);
        console.log("TSPONS implied ETH price (wei/1e18):", implied1);
        console.log("  TSPONS implied change bps:", int256((implied1 * 10000) / implied0) - 10000);
        console.log("TSPONS ETH-pool price (unchanged until someone trades):", _tsponsEthPoolWei());
        assertGt(nav1, nav0, "short side must gain when PONS falls");
        assertLt(lnav1, lnav0, "long side must lose when PONS falls");
        assertGt(implied1, implied0, "coin implied ETH value must rise");

        // 3) ARB: buy TSPONS cheap in the ETH pool, sell into the sPONS pool, sell sPONS for ETH
        uint256 ethBefore = address(this).balance;
        uint256 spend = 0.003 ether;
        router.swap{value: spend}(_tsponsEth(), SwapParams(true, -int256(spend), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false), "");
        uint256 got = IERC20(TSPONS).balanceOf(address(this));
        IERC20(TSPONS).approve(address(router), got);
        router.swap(_tsponsSpons(), SwapParams(true, -int256(got), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false), "");
        uint256 sp = IERC20(SPONS).balanceOf(address(this));
        IERC20(SPONS).approve(address(router), sp);
        router.swap(_sponsEth(), SwapParams(false, -int256(sp), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false), "");
        int256 arbPnl = int256(address(this).balance) - int256(ethBefore);
        console.log("=== ARB === spent (wei ETH):", spend);
        console.log("  arb net ETH pnl (wei):", arbPnl);
        console.log("TSPONS ETH-pool price after arb (wei/1e18):", _tsponsEthPoolWei());
        console.log("  ETH-pool change bps vs before:", int256((_tsponsEthPoolWei() * 10000) / ethPool0) - 10000);
        assertGt(_tsponsEthPoolWei(), ethPool0, "ETH chart pool repriced upward by the arb");
    }

    receive() external payable {}
}
