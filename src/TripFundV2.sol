pragma solidity 0.8.24;

import {TripFundV1} from "./TripFundV1.sol";

contract TripFundV2 is TripFundV1 {
    event ContributedFor(address indexed payer, address indexed beneficiary, uint256 amount);

    function contributeFor(address beneficiary, uint256 amount) external nonReentrant {
        _contribute(beneficiary, amount);
        emit ContributedFor(msg.sender, beneficiary, amount);
    }
}
