pragma solidity 0.8.24;

import {TripFundCore} from "./TripFundCore.sol";

contract TripFund is TripFundCore {
    constructor(address token_, address organizer_, uint256 goal_, uint256 deadline_) {
        _configure(token_, organizer_, goal_, deadline_);
    }
}
