// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsPerpPool} from "../src/PonsPerpPool.sol";

/// forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $LONG_PK
contract Deploy is Script {
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address constant PONS_WETH_1PCT_POOL = 0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA;

    function run() external {
        uint256 leverage = vm.envOr("LEVERAGE", uint256(1));
        uint32 window = uint32(vm.envOr("TWAP_WINDOW", uint256(300)));
        uint32 interval = uint32(vm.envOr("REBALANCE_INTERVAL", uint256(60)));
        vm.startBroadcast();
        address owner = msg.sender;
        PonsPerpPool pool = new PonsPerpPool(PONS_WETH_1PCT_POOL, PONS, leverage, window, interval, owner);
        vm.stopBroadcast();
        console.log("PonsPerpPool:", address(pool));
        console.log("lPONS (long): ", address(pool.longToken()));
        console.log("sPONS (short):", address(pool.shortToken()));
        console.log("initial priceX96:", pool.lastPriceX96());
    }
}
