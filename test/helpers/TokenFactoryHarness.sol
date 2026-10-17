// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmPeg} from "../../src/SwarmPeg.sol";

/// @dev Test-only factory: demonstrates actual CREATE2 deployment and subsequent transfers.
contract TokenFactoryHarness {
    function deploy(bytes32 salt) external returns (SwarmPeg) {
        return new SwarmPeg{salt: salt}();
    }

    function forward(SwarmPeg token, address recipient, uint256 amount) external returns (bool) {
        return token.transfer(recipient, amount);
    }
}
