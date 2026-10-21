pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV1} from "../src/TripFundV1.sol";

contract DeployTripFund is Script {
    function run() external returns (TripFund fund) {
        address token = vm.envAddress("TOKEN");
        address organizer = vm.envAddress("ORGANIZER");
        uint256 goal = vm.envUint("GOAL");
        uint256 deadline = vm.envUint("DEADLINE");
        vm.startBroadcast();
        fund = new TripFund(token, organizer, goal, deadline);
        vm.stopBroadcast();
    }
}

contract DeployTripFundProxy is Script {
    function run() external returns (TransparentUpgradeableProxy proxy, TripFundV1 implementation) {
        address token = vm.envAddress("TOKEN");
        address organizer = vm.envAddress("ORGANIZER");
        address owner = vm.envAddress("PROXY_ADMIN_OWNER");
        uint256 goal = vm.envUint("GOAL");
        uint256 deadline = vm.envUint("DEADLINE");
        bytes memory data = abi.encodeCall(TripFundV1.initialize, (token, organizer, goal, deadline));
        vm.startBroadcast();
        implementation = new TripFundV1();
        proxy = new TransparentUpgradeableProxy(address(implementation), owner, data);
        vm.stopBroadcast();
    }
}
