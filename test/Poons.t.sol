// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PonsPerpPool} from "../src/PonsPerpPool.sol";
import {V4Launch} from "../src/V4Launch.sol";
import {PoonsToken} from "../src/PoonsToken.sol";
import {Backing, IPerp, ILaunch, IPoons} from "../src/Backing.sol";

/// Fork test of the full POONS stack against the live test vault: launch -> trades -> harvest -> claim -> redeem.
contract PoonsForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    PonsPerpPool constant PERP = PonsPerpPool(payable(0x34dC2FA6391D10Bd9dFE38BE96b5EdEFBCC8F46b));
    address constant SPONS = 0xB4b4365e53f8c486710aBad50D66EEBEaFDb2ae2;
    address constant WETH_ZERO = address(0);
    uint256 constant SUPPLY = 1_000_000_000e18;
    // coin-per-ETH start tick: 1B supply at 2 ETH FDV => 5e8 coin per ETH => ln(5e8)/ln(1.0001) ~= 200_353
    int24 constant START_TICK = 200_353;

    Backing backing;
    PoonsToken coin;
    V4Launch launch;
    PoolSwapTest router;

    function setUp() public {
        vm.createSelectFork(vm.envString("RH_RPC_URL"));
        router = new PoolSwapTest(PM);
        vm.deal(address(this), 5 ether);
        backing = new Backing(IPerp(address(PERP)), IERC20(SPONS), PM, 3000, 60, 300);
        coin = new PoonsToken("Poons", "POONS", SUPPLY, address(this), address(backing), "https://punzrh.com/token.json");
        // ETH-quoted locked curve, 3% fee, owner = backing (fees flow there)
        launch = new V4Launch(PM, address(coin), WETH_ZERO, 30_000, 200, START_TICK, 69_000, address(backing));
        coin.transfer(address(launch), SUPPLY);
        backing.init(IPoons(address(coin)), ILaunch(address(launch)));
    }

    function _key() internal view returns (PoolKey memory k) {
        (k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks) = launch.key();
    }

    function _buy(uint256 eth) internal returns (uint256 got) {
        uint256 b = coin.balanceOf(address(this));
        router.swap{value: eth}(_key(), SwapParams(true, -int256(eth), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false), "");
        got = coin.balanceOf(address(this)) - b;
    }

    function test_fullLifecycle() public {
        assertTrue(launch.launched());
        assertTrue(launch.coinIsCurrency0() == false, "ETH is currency0");
        // 1) buyers just buy with ETH
        uint256 got1 = _buy(0.5 ether);
        uint256 got2 = _buy(0.5 ether);
        console.log("0.5 ETH bought:", got1 / 1e18, "then", got2 / 1e18);
        assertGt(got1, got2, "curve rises");
        // sell some back (fees accrue in both currencies)
        coin.approve(address(router), got2 / 2);
        router.swap(_key(), SwapParams(false, -int256(got2 / 2), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false), "");

        // 2) harvest: 3% fees -> sPONS. The live sPONS/ETH pool is tiny, so 0.03 ETH overshoots the 3% premium
        //    guard and falls back to the vault mint; a small harvest takes the INSTANT market path.
        uint256 supply0 = coin.totalSupply();
        backing.harvest();
        console.log("ETH committed (vault path):", backing.totalEthCommitted());
        console.log("ETH swapped (instant path):", backing.totalEthSwapped());
        console.log("coin burned from fees:", backing.totalCoinBurned() / 1e18);
        assertGt(backing.totalEthCommitted() + backing.totalEthSwapped(), 0.02 ether, "~3% of ~1 ETH volume");
        assertLt(coin.totalSupply(), supply0, "fee coin burned");

        // 3) settle whatever went the vault path
        vm.warp(block.timestamp + 301);
        PERP.rebalance();
        backing.claim();
        uint256 sb = backing.sponsBacking();
        console.log("sPONS backing:", sb / 1e18);
        assertGt(sb, 0); assertEq(backing.pendingCount(), 0);

        // 3b) a small trade -> harvest: instant market path if the live sPONS/ETH pool is within 3% of NAV,
        //     otherwise the vault fallback. Either way the fee ETH must end up committed to the short.
        _buy(0.02 ether);
        uint256 sbBefore = backing.sponsBacking(); uint256 swapped0 = backing.totalEthSwapped(); uint256 comm0 = backing.totalEthCommitted();
        backing.harvest();
        bool instant = backing.totalEthSwapped() > swapped0;
        console.log(instant ? "harvest path: INSTANT (market)" : "harvest path: VAULT fallback (market >3% off NAV right now)");
        assertTrue(instant || backing.totalEthCommitted() > comm0, "fee ETH must go to the short by one path or the other");
        if (instant) assertGt(backing.sponsBacking(), sbBefore, "backing grew instantly");
        uint256 floor = backing.floorWeiPerToken();
        console.log("floor wei per 1e18 coin:", floor);
        assertGt(floor, 0);

        // 4) redeem: burn coin -> pro-rata sPONS
        uint256 myCoin = coin.balanceOf(address(this));
        uint256 expect = backing.sponsBacking() * myCoin / coin.totalSupply();
        coin.redeem(myCoin);
        assertEq(IERC20(SPONS).balanceOf(address(this)), expect, "pro-rata sPONS");
        assertEq(coin.balanceOf(address(this)), 0);

        // 5) nobody else can pull backing
        vm.expectRevert(Backing.NotToken.selector);
        backing.payout(address(this), 1, 1);
    }

    function test_harvestIsPermissionless_andIdempotent() public {
        _buy(0.1 ether);
        vm.prank(address(0xBEEF));
        backing.harvest();
        uint256 c = backing.totalEthCommitted();
        vm.prank(address(0xBEEF));
        backing.harvest(); // nothing new to harvest
        assertEq(backing.totalEthCommitted(), c);
    }

    receive() external payable {}
}
