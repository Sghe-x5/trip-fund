pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";

contract UpgradeTripFund is Script {
    error DeadlinePassed();

    function run() external returns (TripFundV2 implementation) {
        address proxy = vm.envAddress("PROXY");
        ProxyAdmin admin = ProxyAdmin(vm.envAddress("PROXY_ADMIN"));
        if (block.timestamp >= TripFundV1(proxy).deadline()) revert DeadlinePassed();
        vm.startBroadcast();
        implementation = new TripFundV2();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), address(implementation), "");
        vm.stopBroadcast();
    }
}
