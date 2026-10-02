// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {StandingOrders} from "../src/StandingOrders.sol";

/// arc-forge script script/Deploy.s.sol --rpc-url arc --broadcast --private-key $PRIVATE_KEY
contract Deploy is Script {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;

    function run() external {
        address owner = vm.envOr("OWNER", msg.sender);
        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = EURC;
        vm.broadcast();
        StandingOrders so = new StandingOrders(owner, 30, tokens);
        console.log("StandingOrders:", address(so));
        console.log("owner:", owner);
    }
}
