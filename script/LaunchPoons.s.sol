// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {V4Launch} from "../src/V4Launch.sol";
import {PoonsToken} from "../src/PoonsToken.sol";
import {Backing, IPerp, ILaunch, IPoons} from "../src/Backing.sol";
import {DevLock} from "../src/DevLock.sol";

/// PERP=0x... SPONS=0x... NAME="Poons" SYMBOL=POONS START_TICK=<coin-per-ETH tick> FEE=30000 \
///   forge script script/LaunchPoons.s.sol --rpc-url $RH_RPC_URL --private-key $DEV_PK --broadcast
contract LaunchPoons is Script {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    function run() external {
        address perp = vm.envAddress("PERP");
        address spons = vm.envAddress("SPONS");
        string memory name = vm.envString("NAME");
        string memory symbol = vm.envString("SYMBOL");
        uint256 supply = vm.envOr("SUPPLY", uint256(1_000_000_000e18));
        int24 startTick = int24(vm.envInt("START_TICK"));
        int24 span = int24(vm.envOr("SPAN", int256(69_000)));
        uint24 fee = uint24(vm.envOr("FEE", uint256(30_000)));
        vm.startBroadcast();
        Backing backing = new Backing(IPerp(perp), IERC20(spons), PM, 3000, 60, uint256(vm.envOr("MAX_PREMIUM_BPS", uint256(300))));
        PoonsToken coin = new PoonsToken(name, symbol, supply, msg.sender, address(backing), vm.envOr("TOKEN_URI", string("https://punzrh.com/token.json")));
        V4Launch launch = new V4Launch(PM, address(coin), address(0), fee, 200, startTick, span, address(backing));
        // optional dev allocation, locked in a timelock (DEV_PCT_BPS of supply, LOCK_DAYS); 0 = no dev bag
        uint256 devBps = vm.envOr("DEV_PCT_BPS", uint256(0));
        if (devBps > 0) {
            uint256 devAmt = supply * devBps / 10_000;
            DevLock lockc = new DevLock(IERC20(address(coin)), msg.sender, uint64(block.timestamp + vm.envOr("LOCK_DAYS", uint256(365)) * 1 days));
            coin.transfer(address(lockc), devAmt);
            supply -= devAmt;
            console.log("dev lock:", address(lockc));
            console.log("dev locked amount:", devAmt);
            console.log("dev unlock at:", lockc.unlockAt());
        }
        coin.transfer(address(launch), supply);
        backing.init(IPoons(address(coin)), ILaunch(address(launch)));
        vm.stopBroadcast();
        console.log("coin:", address(coin));
        console.log("backing:", address(backing));
        console.log("launcher (locked LP):", address(launch));
        console.log("liquidity:", launch.liquidity());
    }
}
