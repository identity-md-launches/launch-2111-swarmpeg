// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmPeg} from "../src/SwarmPeg.sol";
import {TokenFactoryHarness} from "./helpers/TokenFactoryHarness.sol";

/// @dev Unlike the closed four-holder handler, this one lets the fuzzer pick arbitrary recipients and
/// spenders (including the token itself and the handler), so balances spread over an open, growing
/// set of accounts. Every address that ever received tokens is recorded so the invariants can sum them.
contract SwarmPegOpenHandler is Test {
    SwarmPeg internal immutable token;
    address[] public holders;
    mapping(address => bool) public seen;
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    uint256 public ghostReverts;
    uint256 public ghostMoved;

    constructor(SwarmPeg token_, address genesis) {
        token = token_;
        _track(genesis);
        ghostBalance[genesis] = token_.totalSupply();
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function _track(address account) internal {
        if (!seen[account]) {
            seen[account] = true;
            holders.push(account);
        }
    }

    function _holder(uint256 seed) internal view returns (address) {
        return holders[seed % holders.length];
    }

    function _recipient(uint256 seed, address fuzzed) internal view returns (address) {
        // Half the time an existing holder, half the time a fresh fuzzed address (never zero).
        if (seed % 2 == 0 || fuzzed == address(0)) return holders[(seed / 2) % holders.length];
        return fuzzed;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, address toFuzz, uint256 rawAmount) external {
        address from = _holder(fromSeed);
        address to = _recipient(toSeed, toFuzz);
        uint256 amount = bound(rawAmount, 0, ghostBalance[from]);
        _track(to);

        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
    }

    function approve(uint256 ownerSeed, address spender, uint256 amount) external {
        if (spender == address(0)) spender = address(this);
        address owner = _holder(ownerSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 fromSeed, address spender, uint256 toSeed, address toFuzz, uint256 rawAmount)
        external
    {
        if (spender == address(0)) spender = address(this);
        address from = _holder(fromSeed);
        address to = _recipient(toSeed, toFuzz);
        uint256 approved = ghostAllowance[from][spender];
        uint256 cap = approved < ghostBalance[from] ? approved : ghostBalance[from];
        uint256 amount = bound(rawAmount, 0, cap);
        _track(to);

        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (approved != type(uint256).max) ghostAllowance[from][spender] = approved - amount;
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
    }

    /// @dev Any amount above the balance must revert and leave both sides untouched.
    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 rawExcess) external {
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 balance = ghostBalance[from];
        uint256 amount = balance + bound(rawExcess, 1, type(uint256).max - balance);

        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        assertFalse(ok, "a transfer above the balance succeeded");
        ghostReverts++;
    }

    /// @dev Any amount above the allowance must revert, and must not consume the allowance.
    function transferFromTooMuch(uint256 fromSeed, address spender, uint256 toSeed, uint256 rawExcess) external {
        if (spender == address(0)) spender = address(this);
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 approved = ghostAllowance[from][spender];
        if (approved == type(uint256).max) return;
        uint256 amount = approved + bound(rawExcess, 1, type(uint256).max - approved);

        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeCall(token.transferFrom, (from, to, amount)));
        assertFalse(ok, "a transferFrom above the allowance succeeded");
        ghostReverts++;
    }

    /// @dev Nobody can burn by sending to the zero address, from any holder, for any amount.
    function sendToZero(uint256 fromSeed, uint256 rawAmount) external {
        address from = _holder(fromSeed);
        uint256 amount = bound(rawAmount, 0, ghostBalance[from]);
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (address(0), amount)));
        assertFalse(ok, "a transfer to the zero address succeeded");
        ghostReverts++;
    }
}

contract SwarmPegOpenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    SwarmPeg internal token;
    SwarmPegOpenHandler internal handler;

    function setUp() public {
        token = new SwarmPeg();
        address genesis = makeAddr("genesis");
        handler = new SwarmPegOpenHandler(token, genesis);
        assertTrue(token.transfer(genesis, SUPPLY));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_SumOfEveryHolderEqualsFixedSupply() public view {
        uint256 sum;
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address holder = handler.holders(i);
            uint256 balance = token.balanceOf(holder);
            assertEq(balance, handler.ghostBalance(holder), "balance diverged from the ghost ledger");
            sum += balance;
        }
        assertEq(sum, SUPPLY, "tokens appeared or vanished");
        assertEq(token.totalSupply(), SUPPLY, "total supply changed");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_NoHolderExceedsSupply() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            assertLe(token.balanceOf(handler.holders(i)), SUPPLY);
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_MetadataNeverChanges() public view {
        assertEq(token.name(), "SwarmPeg");
        assertEq(token.symbol(), "SWARMPEG");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }
}

/// @dev Plays the launch: the factory forwards the swarm share to a distributor, seeds a pool and sends
/// the remainder; the distributor pays claimants; traders trade with the pool in random order. The
/// distributor can never pay out more than it received, and nobody but the factory adds to the launch.
contract SwarmPegLaunchHandler is Test {
    SwarmPeg public immutable token;
    TokenFactoryHarness public immutable factory;
    address public immutable distributor = makeAddr("launch distributor");
    address public immutable pool = makeAddr("launch pool");
    address public immutable remainder = makeAddr("launch remainder");
    address[3] public traders = [makeAddr("trader a"), makeAddr("trader b"), makeAddr("trader c")];
    address[3] public claimants = [makeAddr("claimant a"), makeAddr("claimant b"), makeAddr("claimant c")];

    uint256 public ghostSwarmIn;
    uint256 public ghostClaimed;
    bool public launched;

    constructor() {
        factory = new TokenFactoryHarness();
        token = factory.deploy(keccak256("SwarmPeg launch invariant"));
    }

    function launch(uint256 rawPoolBps) external {
        if (launched) return;
        uint256 supply = token.totalSupply();
        uint256 swarm = supply / 10;
        uint256 poolShare = (supply * bound(rawPoolBps, 0, 9_000)) / 10_000;
        uint256 rest = supply - swarm - poolShare;
        assertTrue(factory.forward(token, distributor, swarm));
        assertTrue(factory.forward(token, pool, poolShare));
        assertTrue(factory.forward(token, remainder, rest));
        ghostSwarmIn += swarm;
        launched = true;
    }

    function claim(uint256 seed, uint256 rawAmount) external {
        address claimant = claimants[seed % claimants.length];
        uint256 amount = bound(rawAmount, 0, token.balanceOf(distributor));
        vm.prank(distributor);
        assertTrue(token.transfer(claimant, amount));
        ghostClaimed += amount;
    }

    function buy(uint256 seed, uint256 rawAmount) external {
        address trader = traders[seed % traders.length];
        uint256 amount = bound(rawAmount, 0, token.balanceOf(pool));
        vm.prank(pool);
        assertTrue(token.transfer(trader, amount));
    }

    function sell(uint256 seed, uint256 rawAmount) external {
        address trader = traders[seed % traders.length];
        uint256 amount = bound(rawAmount, 0, token.balanceOf(trader));
        vm.prank(trader);
        assertTrue(token.approve(address(this), amount));
        assertTrue(token.transferFrom(trader, pool, amount));
    }

    function overclaim(uint256 seed) external {
        address claimant = claimants[seed % claimants.length];
        uint256 held = token.balanceOf(distributor);
        vm.prank(distributor);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (claimant, held + 1)));
        assertFalse(ok, "the distributor paid out more than it held");
    }
}

contract SwarmPegLaunchInvariantTest is Test {
    SwarmPegLaunchHandler internal handler;
    SwarmPeg internal token;

    function setUp() public {
        handler = new SwarmPegLaunchHandler();
        token = handler.token();
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_LaunchAccountsSumToSupply() public view {
        uint256 sum = token.balanceOf(address(handler.factory())) + token.balanceOf(handler.distributor())
            + token.balanceOf(handler.pool()) + token.balanceOf(handler.remainder());
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(handler.traders(i)) + token.balanceOf(handler.claimants(i));
        }
        assertEq(sum, token.totalSupply());
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_DistributorPaysExactlyWhatItReceived() public view {
        assertEq(token.balanceOf(handler.distributor()), handler.ghostSwarmIn() - handler.ghostClaimed());
        uint256 claimed;
        for (uint256 i; i < 3; ++i) {
            claimed += token.balanceOf(handler.claimants(i));
        }
        assertEq(claimed, handler.ghostClaimed(), "a claim arrived short or long");
        assertLe(handler.ghostClaimed(), token.totalSupply() / 10, "claims exceeded the swarm share");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_FactoryHoldsAllUntilLaunchThenNothing() public view {
        uint256 held = token.balanceOf(address(handler.factory()));
        if (handler.launched()) assertEq(held, 0, "the factory kept part of the supply");
        else assertEq(held, token.totalSupply(), "supply left the factory before launch");
    }
}

/// @dev Stateless properties and pinned edges the existing unit suite does not cover.
contract SwarmPegEdgeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    SwarmPeg internal token;

    function setUp() public {
        token = new SwarmPeg();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ArbitraryCallerCannotMoveAnotherHoldersTokens(address caller, address to, uint256 rawAmount)
        public
    {
        vm.assume(caller != address(this) && to != address(0));
        uint256 amount = bound(rawAmount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, caller, 0, amount));
        vm.prank(caller);
        token.transferFrom(address(this), to, amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ApproveOverwritesRatherThanAccumulates(address spender, uint256 first, uint256 second) public {
        vm.assume(spender != address(0));
        assertTrue(token.approve(spender, first));
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(address(this), spender), second);
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(address(this), spender), second, "repeating an approval is not idempotent");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RoundTripRestoresBalances(address other, uint256 rawAmount) public {
        vm.assume(other != address(0) && other != address(this));
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(other, amount));
        vm.prank(other);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(other), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SplitTransfersEqualOneTransfer(address to, uint256 rawA, uint256 rawB) public {
        vm.assume(to != address(0) && to != address(this));
        uint256 a = bound(rawA, 0, SUPPLY);
        uint256 b = bound(rawB, 0, SUPPLY - a);
        assertTrue(token.transfer(to, a));
        assertTrue(token.transfer(to, b));
        assertEq(token.balanceOf(to), a + b);
        assertEq(token.balanceOf(address(this)), SUPPLY - a - b);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_CannotReachOtherAccountsViaFromEqualsSpender(address victim, uint256 rawAmount) public {
        vm.assume(victim != address(0) && victim != address(this));
        uint256 amount = bound(rawAmount, 1, SUPPLY);
        assertTrue(token.transfer(victim, amount));
        // The victim approving itself grants nothing to anybody else.
        vm.prank(victim);
        assertTrue(token.approve(victim, type(uint256).max));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, amount)
        );
        token.transferFrom(victim, address(this), amount);
        assertEq(token.balanceOf(victim), amount);
    }

    function test_SpendingAllowanceEmitsOnlyTransferAndNoApproval() public {
        assertTrue(token.approve(address(0xA11CE), 10));
        vm.recordLogs();
        vm.prank(address(0xA11CE));
        assertTrue(token.transferFrom(address(this), address(0xB0B), 4));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(token.allowance(address(this), address(0xA11CE)), 6);
    }

    function test_ApproveRejectsZeroOwnerCaller() public {
        // The zero address as msg.sender cannot approve (OZ rejects an invalid approver).
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(address(0xA11CE), 1);
    }

    function test_ZeroAddressCallerCannotTransfer() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(address(0xA11CE), 0);
    }

    /// @dev Tokens sent to the token contract itself are accepted and then unrecoverable: there is no
    /// rescue function, by design of a token without admin powers. Pinned so a change is noticed.
    function test_TokensSentToTokenAddressAreStuckButSupplyIsUnchanged() public {
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1 ether)
        );
        token.transferFrom(address(token), address(this), 1 ether);
    }

    function test_OneWeiEdges() public {
        assertTrue(token.transfer(address(0xA11CE), 1));
        assertEq(token.balanceOf(address(0xA11CE)), 1);
        vm.startPrank(address(0xA11CE));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(0xA11CE), 1, 2));
        token.transfer(address(0xB0B), 2);
        assertTrue(token.transfer(address(0xB0B), 1));
        vm.stopPrank();
        assertEq(token.balanceOf(address(0xA11CE)), 0);
        assertEq(token.balanceOf(address(0xB0B)), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_SupplyIsExactlyOneBillionWholeTokens() public view {
        assertEq(token.totalSupply() / 10 ** token.decimals(), 1_000_000_000);
        assertEq(token.totalSupply() % 10 ** token.decimals(), 0);
    }
}
