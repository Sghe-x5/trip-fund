pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TripToken is ERC20 {
    constructor(address recipient, uint256 supply) ERC20("Trip Token", "TRIP") {
        _mint(recipient, supply);
    }
}
