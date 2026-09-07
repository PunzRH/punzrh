// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PonsPerpPool} from "../src/PonsPerpPool.sol";
import {PerpToken} from "../src/PerpToken.sol";

/// Mock of a Uniswap v3 pool's oracle: constant tick since `start`, so TWAP == spot after a window.
contract MockOracle {
    address public token0;
    int24 public tick;
    // tickCumulative is modelled as tick * elapsed since a fixed epoch, with piecewise history ignored:
    // we just return tick*(now - secondsAgo). Fine for tests where tick changes are followed by a warp.
    int56 internal base;

    constructor(address token0_, int24 tick_) {
        token0 = token0_;
        tick = tick_;
    }

    function setTick(int24 t) external {
        tick = t;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tc, uint160[] memory s) {
        tc = new int56[](secondsAgos.length);
        s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            tc[i] = int56(tick) * int56(int256(block.timestamp - secondsAgos[i]));
        }
    }
}

contract PonsPerpPoolTest is Test {
    address constant WETH = address(0xBEEF);
    address constant PONS = address(0xCAFE);
    MockOracle oracle;
    PonsPerpPool pool;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint32 constant WINDOW = 300;
    uint32 constant INTERVAL = 60;

    function setUp() public {
        vm.warp(1_000_000);
        // token0 = WETH, token1 = PONS (matches the real pool). tick 80000 => PONS per WETH ~ 2980
        oracle = new MockOracle(WETH, 80000);
        pool = new PonsPerpPool(address(oracle), PONS, 1, WINDOW, INTERVAL, address(this));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _settle() internal {
        vm.warp(block.timestamp + WINDOW + 1);
        pool.rebalance();
    }

    function _mint(address who, PonsPerpPool.Side side, uint256 amt) internal returns (uint256 shares) {
        vm.prank(who);
        uint256 id = pool.commitMint{value: amt}(side);
        _settle();
        uint256 e = pool.claimableEpoch(id);
        vm.prank(who);
        shares = pool.claim(id, e);
    }

    function test_priceOrientation() public view {
        // WETH per PONS should be ~ 1/2980 = 3.35e-4 ETH
        uint256 p = pool.twapPriceX96();
        uint256 wei_ = p * 1e18 / 2 ** 96;
        assertApproxEqRel(wei_, 335_000_000_000_000, 0.01e18); // 3.35e14 wei
    }

    function test_mintBothSides_initialSharePrice() public {
        uint256 ls = _mint(alice, PonsPerpPool.Side.LONG, 1 ether);
        uint256 ss = _mint(bob, PonsPerpPool.Side.SHORT, 1 ether);
        // first shares priced so 1 share ~= 1 PONS of value (~3.35e-4 ETH): 1 ETH -> ~2980 shares
        assertApproxEqRel(ls, 2980e18, 0.02e18);
        assertApproxEqRel(ss, 2980e18, 0.02e18);
        assertEq(pool.longBal(), 1 ether);
        assertEq(pool.shortBal(), 1 ether);
        assertEq(address(pool).balance, 2 ether);
    }

    function test_ponsUp_shortsPayLongs() public {
        _mint(alice, PonsPerpPool.Side.LONG, 1 ether);
        _mint(bob, PonsPerpPool.Side.SHORT, 1 ether);
        // tick = PONS per WETH. PONS +10% vs WETH => fewer PONS per WETH => tick DOWN by ln(1.1)/ln(1.0001) ~= 953
        oracle.setTick(80000 - 953);
        _settle();
        // shorts lose S*(1 - 1/1.1) = 9.09%
        assertApproxEqRel(pool.shortBal(), 0.909 ether, 0.01e18);
        assertApproxEqRel(pool.longBal(), 1.091 ether, 0.01e18);
        assertEq(pool.longBal() + pool.shortBal(), 2 ether);
    }

    function test_ponsDown_longsPayShorts() public {
        _mint(alice, PonsPerpPool.Side.LONG, 1 ether);
        _mint(bob, PonsPerpPool.Side.SHORT, 1 ether);
        // PONS -20% => 1.25x more PONS per WETH => tick UP by ln(1.25)/ln(1.0001) ~= 2231
        oracle.setTick(80000 + 2231);
        _settle();
        // longs lose L*(1-0.8)=20%
        assertApproxEqRel(pool.longBal(), 0.8 ether, 0.01e18);
        assertApproxEqRel(pool.shortBal(), 1.2 ether, 0.01e18);
    }

    function test_shortTokenTracksInverse() public {
        _mint(alice, PonsPerpPool.Side.LONG, 1 ether);
        uint256 ss = _mint(bob, PonsPerpPool.Side.SHORT, 1 ether);
        uint256 p0 = pool.sharePriceWei(PonsPerpPool.Side.SHORT);
        oracle.setTick(80000 + 2231); // PONS -20%
        _settle();
        uint256 p1 = pool.sharePriceWei(PonsPerpPool.Side.SHORT);
        assertApproxEqRel(p1, p0 * 120 / 100, 0.01e18);
        // redeem everything
        vm.startPrank(bob);
        pool.shortToken().approve(address(pool), ss);
        uint256 id = pool.commitBurn(PonsPerpPool.Side.SHORT, ss);
        vm.stopPrank();
        _settle();
        uint256 before = bob.balance;
        uint256 e = pool.claimableEpoch(id);
        vm.prank(bob);
        uint256 out = pool.claim(id, e);
        assertApproxEqRel(out, 1.2 ether, 0.01e18);
        assertEq(bob.balance - before, out);
        assertEq(pool.shortToken().totalSupply(), 0);
    }

    function test_claimTooEarlyReverts() public {
        vm.prank(alice);
        uint256 id = pool.commitMint{value: 1 ether}(PonsPerpPool.Side.LONG);
        vm.warp(block.timestamp + INTERVAL + 1);
        pool.rebalance(); // epoch inside the window — not claimable
        uint256 e = pool.epochCount() - 1;
        vm.prank(alice);
        vm.expectRevert(PonsPerpPool.WrongEpoch.selector);
        pool.claim(id, e);
        assertEq(pool.claimableEpoch(id), type(uint256).max);
    }

    function test_cannotPickLaterEpoch() public {
        vm.prank(alice);
        uint256 id = pool.commitMint{value: 1 ether}(PonsPerpPool.Side.LONG);
        _settle(); // first valid epoch
        _settle(); // a later one
        uint256 last = pool.epochCount() - 1;
        vm.prank(alice);
        vm.expectRevert(PonsPerpPool.WrongEpoch.selector);
        pool.claim(id, last);
    }

    function test_rebalanceTooSoon() public {
        vm.expectRevert(PonsPerpPool.TooSoon.selector);
        pool.rebalance();
    }

    function test_feeCapAndCollection() public {
        vm.expectRevert(PonsPerpPool.FeeTooHigh.selector);
        pool.setFee(101);
        pool.setFee(50); // 0.5%
        uint256 ownerBefore = address(this).balance;
        vm.prank(alice);
        pool.commitMint{value: 1 ether}(PonsPerpPool.Side.LONG);
        assertEq(address(this).balance - ownerBefore, 0.005 ether);
        assertEq(pool.pendingEth(), 0.995 ether);
    }

    function test_emptySideNoTransfer() public {
        _mint(alice, PonsPerpPool.Side.LONG, 1 ether);
        oracle.setTick(80000 + 2231); // PONS -20%: longs would pay shorts, but there are no short holders
        _settle();
        assertEq(pool.longBal(), 1 ether); // nobody on the other side to receive
        assertEq(pool.shortBal(), 0);
    }

    function testFuzz_valueConserved(int24 dTick, uint96 a, uint96 b) public {
        dTick = int24(bound(int256(dTick), -20000, 20000));
        a = uint96(bound(a, 0.001 ether, 50 ether));
        b = uint96(bound(b, 0.001 ether, 50 ether));
        _mint(alice, PonsPerpPool.Side.LONG, a);
        _mint(bob, PonsPerpPool.Side.SHORT, b);
        oracle.setTick(80000 + dTick);
        _settle();
        assertEq(pool.longBal() + pool.shortBal(), uint256(a) + uint256(b));
        assertEq(address(pool).balance, pool.longBal() + pool.shortBal() + pool.pendingEth());
    }

    receive() external payable {}
}
