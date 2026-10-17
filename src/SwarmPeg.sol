// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SwarmPeg
/// @notice A fixed-supply ERC-20 with 18 decimals and unrestricted, fee-free transfers.
/// @dev The constructor mints the entire supply to its immediate caller (the launch factory
/// during an IMD launch). There are no administrative powers or subsequent mint/burn entry points.
contract SwarmPeg is ERC20 {
    /// @notice One billion whole tokens, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("SwarmPeg", "SWARMPEG") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
