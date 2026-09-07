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
import {FeeFeeder} from "../src/FeeFeeder.sol";

contract Sink { receive() external payable {} }

/// Fork test on the live PUNZ/ETH pool: anyone adds ETH+PUNZ, trades happen, harvest sends ETH fees to the sink and burns PUNZ fees.
contract FeeFeederTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant PUNZ = 0x03a0e8FC8b5485CF6F66B6264F1fE295F4C24896;
    address constant HOLDER = 0x2aC5b84de496039Cfbf74cb85AD4E06BB6d6564D;
    FeeFeeder f; Sink sink; PoolSwapTest router;

    function key() internal pure returns (PoolKey memory k) { k = PoolKey(Currency.wrap(address(0)), Currency.wrap(PUNZ), 30000, 200, IHooks(address(0))); }

    function setUp() public {
        vm.createSelectFork(vm.envString("RH_RPC_URL"));
        sink = new Sink(); router = new PoolSwapTest(PM);
        f = new FeeFeeder(PUNZ, payable(address(sink)), 30000, 200, 1000);
        vm.deal(HOLDER, 1 ether); vm.deal(address(this), 2 ether);
    }

    function test_add_harvest_burn() public {
        // holder adds 0.2 ETH + 5M PUNZ
        vm.startPrank(HOLDER);
        IERC20(PUNZ).approve(address(f), 5_000_000e18);
        f.add{value: 0.2 ether}(5_000_000e18);
        vm.stopPrank();
        assertGt(f.liquidity(), 0, "position added");
        assertTrue(f.inRange());
        console.log("liquidity", f.liquidity());
        console.log("range lower/upper", uint256(int256(f.tickLower())), uint256(int256(f.tickUpper())));
        // generate volume: buy then sell through the pool
        router.swap{value: 0.3 ether}(key(), SwapParams(true, -int256(0.3 ether), TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), "");
        uint256 got = IERC20(PUNZ).balanceOf(address(this));
        IERC20(PUNZ).approve(address(router), got);
        router.swap(key(), SwapParams(false, -int256(got), TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), "");
        uint256 supply0 = IERC20(PUNZ).totalSupply();
        f.harvest();
        console.log("ETH fed to sink (wei)", address(sink).balance, "| PUNZ burned", f.totalPunzBurned() / 1e18);
        assertGt(address(sink).balance, 0, "ETH fees reached the Lighter sink");
        assertGt(f.totalPunzBurned(), 0, "PUNZ fees burned");
        assertEq(IERC20(PUNZ).totalSupply(), supply0 - f.totalPunzBurned());
        // nobody can pull liquidity: there is no such function; recenter reverts while in range
        vm.expectRevert(FeeFeeder.InRange.selector); f.recenter();
    }

    receive() external payable {}
}
