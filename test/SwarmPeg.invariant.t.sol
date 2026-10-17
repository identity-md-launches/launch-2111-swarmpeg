// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmPeg} from "../src/SwarmPeg.sol";

/// @dev Drives a closed set of holders and independently tracks expected balances and allowances.
contract SwarmPegHandler is Test {
    SwarmPeg internal immutable token;
    address[4] internal actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(SwarmPeg token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = 1_000_000_000_000_000_000_000_000_000;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);

        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];

        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function spend(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 approved = expectedAllowance[from][spender];
        uint256 balance = expectedBalance[from];
        uint256 amount = bound(rawAmount, 0, approved < balance ? approved : balance);

        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (approved != type(uint256).max) expectedAllowance[from][spender] -= amount;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function overdraw(uint256 fromSeed, uint256 toSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = expectedBalance[from];

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + 1)
        );
        vm.prank(from);
        token.transfer(to, balance + 1);
    }

    function overspend(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 approved = expectedAllowance[from][spender];
        if (approved == type(uint256).max) return;

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, approved + 1)
        );
        vm.prank(spender);
        token.transferFrom(from, to, approved + 1);
    }

    function rejectZeroRecipient(uint256 fromSeed, uint256 rawAmount) external {
        address from = actors[fromSeed % actors.length];
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
    }
}

contract SwarmPegInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;
    SwarmPeg internal token;
    SwarmPegHandler internal handler;
    address[4] internal actors;

    function setUp() public {
        actors = [makeAddr("holder one"), makeAddr("holder two"), makeAddr("holder three"), makeAddr("holder four")];
        token = new SwarmPeg();
        handler = new SwarmPegHandler(token, actors);
        assertTrue(token.transfer(actors[0], SUPPLY));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = SwarmPegHandler.transfer.selector;
        selectors[1] = SwarmPegHandler.approve.selector;
        selectors[2] = SwarmPegHandler.spend.selector;
        selectors[3] = SwarmPegHandler.overdraw.selector;
        selectors[4] = SwarmPegHandler.overspend.selector;
        selectors[5] = SwarmPegHandler.rejectZeroRecipient.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_SupplyAndHolderBalancesAreConserved() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            uint256 balance = token.balanceOf(actors[i]);
            assertEq(balance, handler.expectedBalance(actors[i]));
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function invariant_AllowancesMatchApprovalsAndSpending() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.expectedAllowance(actors[i], actors[j]));
            }
        }
    }
}
