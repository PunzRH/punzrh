// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MemeCoin} from "../src/MemeCoin.sol";
import {V4Launch} from "../src/V4Launch.sol";

/// Fork test against Robinhood Chain: launch a coin quoted in sPONS on the REAL PoolManager, then buy and sell.
contract V4LaunchForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant SPONS = 0xB4b4365e53f8c486710aBad50D66EEBEaFDb2ae2;
    uint256 constant SUPPLY = 1_000_000_000e18;
    // coin-per-quote start tick: 1B supply at FDV 5 sPONS => 2e8 coin per sPONS => ln(2e8)/ln(1.0001) ~= 191_148
    int24 constant START_TICK = 191_148;
    int24 constant SPAN = 69_000; // ~1000x price range

    MemeCoin coin;
    V4Launch launch;
    PoolSwapTest router;

    function setUp() public {
        vm.createSelectFork(vm.envString("RH_RPC_URL"));
        launch = new V4Launch(PM, address(0), SPONS, 10_000, 200, START_TICK, SPAN, address(this));
    }

    function _deployAndLaunch() internal {
        // compute coin address by deploying it with supply to a launcher created after it (2-step)
        coin = new MemeCoin("sPONS Test v4", "TSPONS", SUPPLY, address(this));
        launch = new V4Launch(PM, address(coin), SPONS, 10_000, 200, START_TICK, SPAN, address(this));
        coin.transfer(address(launch), SUPPLY);
        launch.launch();
        router = new PoolSwapTest(PM);
    }

    function _key() internal view returns (PoolKey memory k) {
        (k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks) = launch.key();
    }

    function test_launch_buy_sell() public {
        _deployAndLaunch();
        assertTrue(launch.launched());
        assertLt(coin.balanceOf(address(launch)), 1e6, "all supply deposited (rounding dust only)");
        console.log("coin is currency0:", launch.coinIsCurrency0());
        console.log("liquidity:", launch.liquidity());

        // give this test 10 sPONS and buy with 1 sPONS
        deal(SPONS, address(this), 10e18);
        IERC20(SPONS).approve(address(router), type(uint256).max);
        coin.approve(address(router), type(uint256).max);
        bool zeroForOne = !launch.coinIsCurrency0(); // selling quote for coin
        uint256 coinBefore = coin.balanceOf(address(this));
        router.swap(
            _key(),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 got = coin.balanceOf(address(this)) - coinBefore;
        console.log("1 sPONS bought coin:", got / 1e18);
        assertGt(got, 100_000_000e18, "should get ~2e8 coin minus fee/slippage");
        assertEq(IERC20(SPONS).balanceOf(address(this)), 9e18);

        // sell half back for sPONS
        uint256 sponsBefore = IERC20(SPONS).balanceOf(address(this));
        router.swap(
            _key(),
            SwapParams({
                zeroForOne: !zeroForOne,
                amountSpecified: -int256(got / 2),
                sqrtPriceLimitX96: !zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 back = IERC20(SPONS).balanceOf(address(this)) - sponsBefore;
        console.log("sold half back for sPONS (wei):", back);
        assertGt(back, 0.4e18, "roughly half the sPONS back minus 1% fees");

        // fees collectable by owner, principal locked
        uint256 ownerSpons = IERC20(SPONS).balanceOf(address(this));
        launch.collectFees();
        assertGt(IERC20(SPONS).balanceOf(address(this)), ownerSpons, "LP fees in sPONS collected");
    }

    function test_onlyOwnerLaunch() public {
        coin = new MemeCoin("x", "X", SUPPLY, address(this));
        launch = new V4Launch(PM, address(coin), SPONS, 10_000, 200, START_TICK, SPAN, address(this));
        coin.transfer(address(launch), SUPPLY);
        vm.prank(address(0xBAD));
        vm.expectRevert(V4Launch.NotOwner.selector);
        launch.launch();
    }
}
