// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {EthPairPool} from "../src/EthPairPool.sol";

/// TOKEN=0x... SQRTP=<sqrtPriceX96 token-per-ETH> ETH_AMOUNT=<wei> TOKEN_AMOUNT=<wei> \
///   forge script script/EthPair.s.sol --rpc-url $RH_RPC_URL --private-key $LONG_PK --broadcast
contract EthPairScript is Script {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    function run() external {
        address token = vm.envAddress("TOKEN");
        uint160 sqrtP = uint160(vm.envUint("SQRTP"));
        uint256 ethAmt = vm.envUint("ETH_AMOUNT");
        uint256 tokAmt = vm.envUint("TOKEN_AMOUNT");
        vm.startBroadcast();
        EthPairPool pool = new EthPairPool(PM, token, 10_000, 200, 4000, msg.sender);
        IERC20(token).approve(address(pool), tokAmt);
        pool.seed{value: ethAmt}(sqrtP, tokAmt);
        vm.stopBroadcast();
        console.log("EthPairPool:", address(pool));
        console.log("liquidity:", pool.liquidity());
        console.log("tickLower:", int256(pool.tickLower()));
        console.log("tickUpper:", int256(pool.tickUpper()));
    }
}
