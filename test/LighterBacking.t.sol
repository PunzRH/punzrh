// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console, Vm} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LighterBacking} from "../src/LighterBacking.sol";

/// Fork test against Robinhood Chain: the L1 half of Backing v2 (the rollup can't run here). Asserts what the bridge RECEIVED.
contract LighterBackingTest is Test {
    address constant PUNZ = 0x03a0e8FC8b5485CF6F66B6264F1fE295F4C24896;
    address constant VAULT = 0xd1C0B5E2eA749F738da9E4c13858b4fEb0f6C39D;
    address constant BRIDGE = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;
    address constant HOLDER = 0x2aC5b84de496039Cfbf74cb85AD4E06BB6d6564D;
    bytes32 constant NEW_PRIORITY = keccak256("NewPriorityRequest(address,uint64,uint8,bytes,uint64)");
    LighterBacking b;

    function setUp() public {
        vm.createSelectFork(vm.envString("RH_RPC_URL"));
        b = new LighterBacking(PUNZ, VAULT, 44, 1, 5, 15000);
    }
    function _types() internal returns (uint8[] memory types) {
        Vm.Log[] memory logs = vm.getRecordedLogs(); uint256 n;
        for (uint256 i = 0; i < logs.length; i++) if (logs[i].emitter == BRIDGE && logs[i].topics[0] == NEW_PRIORITY) n++;
        types = new uint8[](n); uint256 k;
        for (uint256 i = 0; i < logs.length; i++) if (logs[i].emitter == BRIDGE && logs[i].topics[0] == NEW_PRIORITY) {
            (, , uint8 t, , ) = abi.decode(logs[i].data, (address, uint64, uint8, bytes, uint64)); types[k++] = t;
        }
    }

    function test_fund_registerKey_sync() public {
        vm.deal(address(b), 0.05 ether);
        vm.recordLogs(); b.fund();
        uint8[] memory t = _types(); assertEq(t.length, 1); assertEq(t[0], 41, "L1Deposit only; no L1 order (reduce-only)");
        assertGt(b.collateralUnits(), 100e6); assertGt(b.accountIndex(), 0, "account created");
        // one-shot key registration by deployer
        bytes memory pk = hex"37a467bf00000000010203040000000005060708000000000a0b0c0d000000000e0f101100000000";
        vm.recordLogs(); b.registerKey(4, pk); t = _types(); assertEq(t[0], 42, "changePubKey");
        vm.expectRevert(bytes("once")); b.registerKey(5, pk);
        // keeper mirrors the position: clamped to leverage
        uint256 target = b.targetBaseTicks(); uint256 px = b.ponsPriceTicks();
        b.sync(target * 5, b.notionalUnits(target * 5, px) * 5);        // liar: 5x too big
        assertLe(b.baseTicks(), target * 110 / 100, "size clamped");
        assertLe(b.entryNotional(), b.notionalUnits(b.baseTicks(), px) * 110 / 100, "entry clamped");
        b.sync(target, b.notionalUnits(target, px));                      // honest
        assertEq(b.baseTicks(), target);
        console.log("collateral USDG", b.collateralUnits() / 1e6, "| target short x0.1 PONS", target);
        assertApproxEqRel(b.notionalUnits(target, px), b.collateralUnits() * 15 / 10, 0.02e18, "1.5x");
    }

    function test_redeem_forceCloses_and_withdraws() public {
        vm.deal(address(b), 0.05 ether); b.fund();
        uint256 px = b.ponsPriceTicks(); uint256 target = b.targetBaseTicks(); b.sync(target, b.notionalUnits(target, px));
        uint256 supply0 = IERC20(PUNZ).totalSupply(); uint256 amt = 1_000_000e18;
        vm.startPrank(HOLDER); IERC20(PUNZ).approve(address(b), amt);
        vm.recordLogs(); uint256 id = b.redeem(amt, uint32(px * 102 / 100)); vm.stopPrank();
        uint8[] memory t = _types(); assertEq(t.length, 2); assertEq(t[0], 47, "reduce-only close"); assertEq(t[1], 46, "withdraw");
        assertEq(IERC20(PUNZ).totalSupply(), supply0 - amt, "burned");
        (address who,, uint256 req, uint256 paid) = b.claims(id); assertEq(who, HOLDER); assertEq(paid, 0); assertGt(req, 0);
        // withdrawal must respect the 50% IMF on the remaining short
        uint256 marginNeeded = b.notionalUnits(b.baseTicks(), px) * 5000 / 1e4;
        assertLe(req, (b.equityUnits() + req - marginNeeded), "never asks for more than free");
        console.log("claim requested USDG 6dp", req);
        // simulate the bridge delivering USDG: settle pays the claim
        deal(address(b.USDG()), address(b), req);
        b.settle(); (, , , paid) = b.claims(id); assertEq(paid, req, "paid in full"); assertEq(b.nextClaim(), 1);
    }
}
