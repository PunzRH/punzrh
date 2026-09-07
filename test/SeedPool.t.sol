// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SeedPool, IPerpNav} from "../src/SeedPool.sol";

contract SeedPoolForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant SPONS = 0xB4b4365e53f8c486710aBad50D66EEBEaFDb2ae2;
    address constant PERP = 0x34dC2FA6391D10Bd9dFE38BE96b5EdEFBCC8F46b;

    SeedPool seed;
    PoolSwapTest router;

    function setUp() public {
        vm.createSelectFork(vm.envString("RH_RPC_URL"));
        // odd fee tier so the test never collides with any sPONS/ETH pool already initialized on-chain
        seed = new SeedPool(PM, SPONS, IPerpNav(PERP), 7000, 140, 1820, address(this));
        router = new PoolSwapTest(PM);
        deal(SPONS, address(this), 100e18);
        vm.deal(address(this), 1 ether);
    }

    function _key() internal view returns (PoolKey memory k) {
        (k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks) = seed.key();
    }

    function test_seed_swap_exit() public {
        uint160 sqrtP = seed.navSqrtPriceX96();
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        console.log("NAV tick:", int256(tick));
        assertGt(tick, 70_000); assertLt(tick, 90_000); // ~2956 sPONS per ETH => ~79920

        IERC20(SPONS).approve(address(seed), 50e18);
        seed.seed{value: 0.017 ether}(50e18);
        assertTrue(seed.seeded());
        console.log("liquidity:", seed.liquidity());
        console.log("tickLower:", int256(seed.tickLower()));
        console.log("tickUpper:", int256(seed.tickUpper()));
        assertEq(address(seed).balance, 0, "eth refunded");
        assertEq(IERC20(SPONS).balanceOf(address(seed)), 0, "spons refunded");

        // buy sPONS with 0.001 ETH (native), zeroForOne
        uint256 sBefore = IERC20(SPONS).balanceOf(address(this));
        router.swap{value: 0.001 ether}(
            _key(),
            SwapParams({zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 got = IERC20(SPONS).balanceOf(address(this)) - sBefore;
        console.log("0.001 ETH bought sPONS (wei):", got);
        assertApproxEqRel(got, 2.956e18, 0.05e18, "~2.9 sPONS for 0.001 ETH at NAV"); // within 5% (fee+impact)

        // sell it back
        IERC20(SPONS).approve(address(router), type(uint256).max);
        uint256 eBefore = address(this).balance;
        router.swap(
            _key(),
            SwapParams({zeroForOne: false, amountSpecified: -int256(got), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 ethBack = address(this).balance - eBefore;
        console.log("sold back for ETH (wei):", ethBack);
        assertGt(ethBack, 0.00095 ether);

        // fees then exit -> funds back to owner
        uint256 e0 = address(this).balance; uint256 s0 = IERC20(SPONS).balanceOf(address(this));
        seed.collectFees();
        seed.exit();
        assertGt(address(this).balance - e0, 0.016 ether, "eth returned");
        // whatever wasn't deposited was refunded at seed time; what was deposited comes back on exit.
        // Net of the two round-trip swap fees we must end within 1% of the 100 sPONS we started with.
        assertGt(IERC20(SPONS).balanceOf(address(this)), 99e18, "spons conserved (refund + exit)");
        assertEq(seed.liquidity(), 0);
    }

    receive() external payable {}
}
