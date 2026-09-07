// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {EthPairPool} from "../src/EthPairPool.sol";

contract EthPairPoolForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant TSPONS = 0x23E1ACD296651A6270e9f5201229805E0A878A00;

    EthPairPool pool;
    PoolSwapTest router;

    function setUp() public {
        vm.createSelectFork(vm.envString("RH_RPC_URL"));
        // odd tier: the 1%/200 ETH-TSPONS pool is already initialized live (chart pool), so avoid that key
        pool = new EthPairPool(PM, TSPONS, 7_000, 140, 4060, address(this));
        router = new PoolSwapTest(PM);
        deal(TSPONS, address(this), 10_000_000e18);
        vm.deal(address(this), 1 ether);
    }

    function _key() internal view returns (PoolKey memory k) {
        (k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks) = pool.key();
    }

    function test_seed_swap_exit() public {
        uint160 sqrtP = uint160(vm.envOr("TSPONS_ETH_SQRTP", uint256(1904021413381644515703916484100096)));
        IERC20(TSPONS).approve(address(pool), 2_000_000e18);
        pool.seed{value: 0.02 ether}(sqrtP, 2_000_000e18);
        assertTrue(pool.seeded());
        console.log("tick:", int256(TickMath.getTickAtSqrtPrice(sqrtP)));
        console.log("liquidity:", pool.liquidity());
        assertEq(address(pool).balance, 0);
        assertEq(IERC20(TSPONS).balanceOf(address(pool)), 0);

        uint256 before = IERC20(TSPONS).balanceOf(address(this));
        router.swap{value: 0.001 ether}(
            _key(),
            SwapParams({zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 got = IERC20(TSPONS).balanceOf(address(this)) - before;
        console.log("0.001 ETH bought TSPONS:", got / 1e18);
        assertGt(got, 100_000e18);

        uint256 e0 = address(this).balance;
        pool.exit();
        assertGt(address(this).balance - e0, 0.001 ether, "eth back (seed + bought eth)");
        assertEq(pool.liquidity(), 0);
    }

    receive() external payable {}
}
