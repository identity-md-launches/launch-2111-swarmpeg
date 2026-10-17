// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmPeg} from "../src/SwarmPeg.sol";
import {TokenFactoryHarness} from "./helpers/TokenFactoryHarness.sol";

contract SwarmPegTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;

    SwarmPeg internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new SwarmPeg();
    }

    function test_ConstructorSetsMetadataAndMintsWholeSupplyToDeployer() public view {
        assertEq(token.name(), "SwarmPeg");
        assertEq(token.symbol(), "SWARMPEG");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_ConstructorEmitsExactlyOneMintEvent() public {
        vm.recordLogs();
        SwarmPeg deployed = new SwarmPeg();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_Create2MintsToFactoryAndNotItsCaller() public {
        TokenFactoryHarness factory = new TokenFactoryHarness();
        bytes32 salt = keccak256("SwarmPeg deployment test");
        address expected = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(type(SwarmPeg).creationCode))
                    )
                )
            )
        );

        vm.prank(alice, alice);
        SwarmPeg deployed = factory.deploy(salt);

        assertEq(address(deployed), expected);
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(alice), 0);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    /// @dev Tests exact token movements only; this does not simulate pool initialization or pricing.
    function test_LaunchTransferLegsAndClaimsArriveWhole() public {
        TokenFactoryHarness factory = new TokenFactoryHarness();
        SwarmPeg launched = factory.deploy(keccak256("launch transfer test"));
        address distributor = makeAddr("test distributor");
        address pool = makeAddr("test pool manager");
        address remainder = makeAddr("test remainder recipient");
        uint256 swarmShare = SUPPLY / 10;
        uint256 poolShare = SUPPLY * 8 / 10;
        uint256 remainderShare = SUPPLY - swarmShare - poolShare;

        assertTrue(factory.forward(launched, distributor, swarmShare));
        assertTrue(factory.forward(launched, pool, poolShare));
        assertTrue(factory.forward(launched, remainder, remainderShare));
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarmShare);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.balanceOf(remainder), remainderShare);

        vm.prank(distributor);
        assertTrue(launched.transfer(alice, swarmShare));
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.balanceOf(alice), swarmShare);

        uint256 traded = 123 ether;
        vm.prank(pool);
        assertTrue(launched.transfer(bob, traded));
        assertEq(launched.balanceOf(bob), traded);
        assertEq(launched.balanceOf(pool), poolShare - traded);
        vm.prank(bob);
        assertTrue(launched.approve(spender, traded));
        vm.prank(spender);
        assertTrue(launched.transferFrom(bob, pool, traded));
        assertEq(launched.balanceOf(bob), 0);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.allowance(bob, spender), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_TransferMovesExactAmountAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), alice, 12 ether);
        assertTrue(token.transfer(alice, 12 ether));
        assertEq(token.balanceOf(alice), 12 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 12 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferEntireSupply() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferPreservesBalanceAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), address(this), SUPPLY);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroTransferToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_TransferOverBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_MaximumTransferCannotOverflowBalances() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_UnfundedAccountCannotTransfer() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_ApproveEmitsEventAndDoesNotMoveTokens() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), spender, 50 ether);
        assertTrue(token.approve(spender, 50 ether));
        assertEq(token.allowance(address(this), spender), 50 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_ApprovalCanBeReplacedAndRevoked() public {
        assertTrue(token.approve(spender, 50 ether));
        assertTrue(token.approve(spender, 20 ether));
        assertEq(token.allowance(address(this), spender), 20 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), spender, 0);
        assertTrue(token.approve(spender, 0));
        assertEq(token.allowance(address(this), spender), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_ApproveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 10 ether);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_ZeroApprovalToZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
    }

    function test_ApprovalDoesNotRequireExistingBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, 10 ether));
        assertEq(token.allowance(alice, spender), 10 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_TransferFromConsumesFiniteAllowanceAndEmitsTransfer() public {
        assertTrue(token.approve(spender, 50 ether));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), alice, 20 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 20 ether));
        assertEq(token.allowance(address(this), spender), 30 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 20 ether);
        assertEq(token.balanceOf(alice), 20 ether);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 30 ether));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), 50 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferFromPreservesInfiniteAllowance() public {
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_ZeroTransferFromNeedsNoAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferFromConsumesAllowanceWithoutMovingBalance() public {
        assertTrue(token.approve(spender, SUPPLY));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), SUPPLY));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_TransferFromWithoutApprovalReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_HolderAlsoNeedsAllowanceForTransferFrom() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
    }

    function test_ApprovalCannotBeUsedByAnotherSpender() public {
        assertTrue(token.approve(spender, SUPPLY));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), spender), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFromOverAllowanceRevertsWithoutChangingState() public {
        assertTrue(token.approve(spender, 10));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10, 11));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 11);
        assertEq(token.allowance(address(this), spender), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_TransferFromOverBalanceRollsBackAllowance() public {
        assertTrue(token.approve(spender, SUPPLY + 1));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, SUPPLY + 1);
        assertEq(token.allowance(address(this), spender), SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_TransferFromToZeroRollsBackAllowance() public {
        assertTrue(token.approve(spender, 10));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 10);
        assertEq(token.allowance(address(this), spender), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_DeployerCannotSpendHolderTokensWithoutApproval() public {
        assertTrue(token.transfer(alice, 100 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, address(this), 1);
        assertEq(token.balanceOf(alice), 100 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100 ether));
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_NoPostDeploymentMintBurnOrAdministrativeEntryPoints() public {
        assertTrue(token.transfer(alice, 100 ether));
        bytes[] memory attempts = new bytes[](12);
        attempts[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1);
        attempts[1] = abi.encodeWithSignature("mint(uint256)", 1);
        attempts[2] = abi.encodeWithSignature("burn(uint256)", 1);
        attempts[3] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1);
        attempts[4] = abi.encodeWithSignature("pause()");
        attempts[5] = abi.encodeWithSignature("blacklist(address)", alice);
        attempts[6] = abi.encodeWithSignature("freeze(address)", alice);
        attempts[7] = abi.encodeWithSignature("seize(address)", alice);
        attempts[8] = abi.encodeWithSignature("transferOwnership(address)", bob);
        attempts[9] = abi.encodeWithSignature("upgradeTo(address)", bob);
        attempts[10] = abi.encodeWithSignature("initialize(address)", bob);
        attempts[11] = abi.encodeWithSignature("setMinter(address)", bob);

        for (uint256 i; i < attempts.length; ++i) {
            (bool deployerSucceeded,) = address(token).call(attempts[i]);
            assertFalse(deployerSucceeded, "deployer reached an unexpected entry point");
            vm.prank(bob);
            (bool strangerSucceeded,) = address(token).call(attempts[i]);
            assertFalse(strangerSucceeded, "stranger reached an unexpected entry point");
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(bob), 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100 ether));
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_RejectsDirectEtherAndUnknownCalls() public {
        vm.deal(address(this), 1 ether);
        (bool etherAccepted,) = address(token).call{value: 1 ether}("");
        assertFalse(etherAccepted);
        (bool unknownAccepted,) = address(token).call(hex"ffffffff");
        assertFalse(unknownAccepted);
        assertEq(address(token).balance, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RuntimeHasNoForbiddenInstructions() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4, "DELEGATECALL");
            assertTrue(opcode != 0xf2, "CALLCODE");
            assertTrue(opcode != 0xff, "SELFDESTRUCT");
        }
    }

    function testFuzz_TransferConservesBalances(address recipient, uint256 rawAmount) public {
        vm.assume(recipient != address(0) && recipient != address(this));
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_OverBalanceTransferIsAtomic(uint256 excess) public {
        excess = bound(excess, 1, type(uint256).max - SUPPLY);
        uint256 amount = SUPPLY + excess;
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferFromTracksBalanceAndAllowance(uint256 approved, uint256 rawAmount) public {
        uint256 available = approved < SUPPLY ? approved : SUPPLY;
        uint256 amount = bound(rawAmount, 0, available);
        assertTrue(token.approve(spender, approved));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.allowance(address(this), spender), approved == type(uint256).max ? approved : approved - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_OverAllowanceTransferIsAtomic(uint256 rawApproved, uint256 rawAmount) public {
        uint256 approved = bound(rawApproved, 0, SUPPLY - 1);
        uint256 amount = bound(rawAmount, approved + 1, SUPPLY);
        assertTrue(token.approve(spender, approved));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, amount);
        assertEq(token.allowance(address(this), spender), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_SelfTransferCannotInflateSupply(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
