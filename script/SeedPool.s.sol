// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SeedPool, IPerpNav} from "../src/SeedPool.sol";

/// ETH_AMOUNT=17000000000000000 SPONS_AMOUNT=50000000000000000000 \
///   forge script script/SeedPool.s.sol --rpc-url $RH_RPC_URL --private-key $LONG_PK --broadcast
contract SeedPoolScript is Script {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    function run() external {
        address SPONS = vm.envOr("SPONS", address(0xB4b4365e53f8c486710aBad50D66EEBEaFDb2ae2));
        address PERP = vm.envOr("PERP", address(0x34dC2FA6391D10Bd9dFE38BE96b5EdEFBCC8F46b));
        uint256 ethAmt = vm.envUint("ETH_AMOUNT");
        uint256 sAmt = vm.envUint("SPONS_AMOUNT");
        vm.startBroadcast();
        SeedPool seed = new SeedPool(PM, SPONS, IPerpNav(PERP), 3000, 60, 1800, msg.sender);
        IERC20(SPONS).approve(address(seed), sAmt);
        seed.seed{value: ethAmt}(sAmt);
        vm.stopBroadcast();
        console.log("SeedPool:", address(seed));
        console.log("liquidity:", seed.liquidity());
        console.log("tickLower:", int256(seed.tickLower()));
        console.log("tickUpper:", int256(seed.tickUpper()));
    }
}
