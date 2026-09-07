// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MemeCoin} from "../src/MemeCoin.sol";
import {V4Launch} from "../src/V4Launch.sol";

/// NAME="sPONS Test v4" SYMBOL=TSPONS START_TICK=191148 SPAN=69000 \
///   forge script script/LaunchMeme.s.sol --rpc-url $RH_RPC_URL --private-key $LONG_PK --broadcast
contract LaunchMeme is Script {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    function run() external {
        address SPONS = vm.envOr("SPONS", address(0xB4b4365e53f8c486710aBad50D66EEBEaFDb2ae2));
        string memory name = vm.envString("NAME");
        string memory symbol = vm.envString("SYMBOL");
        uint256 supply = vm.envOr("SUPPLY", uint256(1_000_000_000e18));
        int24 startTick = int24(vm.envInt("START_TICK"));
        int24 span = int24(vm.envOr("SPAN", int256(69_000)));
        uint24 fee = uint24(vm.envOr("FEE", uint256(10_000)));
        int24 ts = int24(vm.envOr("TICK_SPACING", int256(200)));
        vm.startBroadcast();
        address owner = msg.sender;
        MemeCoin coin = new MemeCoin(name, symbol, supply, owner);
        V4Launch launch = new V4Launch(PM, address(coin), SPONS, fee, ts, startTick, span, owner);
        coin.transfer(address(launch), supply);
        launch.launch();
        vm.stopBroadcast();
        console.log("coin:", address(coin));
        console.log("launcher (locked LP):", address(launch));
        console.log("coin is currency0:", launch.coinIsCurrency0());
        console.log("tickLower:", int256(launch.tickLower()));
        console.log("tickUpper:", int256(launch.tickUpper()));
        console.log("liquidity:", launch.liquidity());
    }
}
