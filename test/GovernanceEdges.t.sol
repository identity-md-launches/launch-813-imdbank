// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BankFixture} from "./helpers/BankFixture.sol";
import {IMDBank} from "src/IMDBank.sol";
import {GovernanceTimelock} from "src/GovernanceTimelock.sol";

contract ExecutionProbe {
    uint256 public calls;
    bool public reject;
    address public callbackTarget;
    bytes public callbackData;
    bool public nestedSucceeded;
    bytes public nestedResult;

    error ProbeRejected();

    function setReject(bool value) external {
        reject = value;
    }

    function setCallback(address target, bytes memory data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function run() external returns (uint256) {
        if (reject) revert ProbeRejected();
        calls++;
        if (callbackTarget != address(0)) {
            (nestedSucceeded, nestedResult) = callbackTarget.call(callbackData);
        }
        return calls;
    }
}

contract TimelockEdgesTest is Test {
    GovernanceTimelock internal timelock;
    ExecutionProbe internal probe;
    address internal constant CANCELLER = address(0xCA11);

    function setUp() public {
        vm.warp(100 days);
        timelock = new GovernanceTimelock(address(this), CANCELLER, 2 days);
        probe = new ExecutionProbe();
    }

    function test_exactDelayAndGracePeriodEndpoints() public {
        bytes memory data = abi.encodeCall(probe.run, ());
        bytes32 id = timelock.schedule(address(probe), data, 0);
        uint256 ready = timelock.readyAt(id);
        vm.warp(ready - 1);
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        timelock.execute(address(probe), data, 0);
        vm.warp(ready);
        vm.prank(address(0xB0B));
        bytes memory returned = timelock.execute(address(probe), data, 0);
        assertEq(abi.decode(returned, (uint256)), 1);
        bytes32 next = timelock.schedule(address(probe), data, bytes32(uint256(1)));
        uint256 finalSecond = timelock.readyAt(next) + timelock.GRACE_PERIOD();
        vm.warp(finalSecond);
        timelock.execute(address(probe), data, bytes32(uint256(1)));
        assertEq(probe.calls(), 2);
        assertTrue(timelock.done(next));
        assertEq(timelock.readyAt(next), 0);
    }

    function test_expiredProposalRequiresCancellationAndFreshDelay() public {
        bytes memory data = abi.encodeCall(probe.run, ());
        bytes32 id = timelock.schedule(address(probe), data, 0);
        vm.warp(timelock.readyAt(id) + timelock.GRACE_PERIOD() + 1);
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        timelock.execute(address(probe), data, 0);
        vm.expectRevert(GovernanceTimelock.InvalidOperation.selector);
        timelock.schedule(address(probe), data, 0);
        vm.prank(CANCELLER);
        timelock.cancel(id);
        timelock.schedule(address(probe), data, 0);
        assertEq(timelock.readyAt(id), vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        timelock.execute(address(probe), data, 0);
        assertEq(probe.calls(), 0);
    }

    function test_cancelledProposalCannotUseOriginalMaturityAfterReschedule() public {
        bytes memory data = abi.encodeCall(probe.run, ());
        bytes32 id = timelock.schedule(address(probe), data, 0);
        uint256 originalReady = timelock.readyAt(id);
        vm.warp(originalReady - 1);
        timelock.cancel(id);
        timelock.schedule(address(probe), data, 0);
        vm.warp(originalReady);
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        timelock.execute(address(probe), data, 0);
        vm.warp(timelock.readyAt(id));
        timelock.execute(address(probe), data, 0);
        assertEq(probe.calls(), 1);
    }

    function test_failedTargetRetainsProposalAndCanRetryWithoutRescheduling() public {
        bytes memory data = abi.encodeCall(probe.run, ());
        bytes32 id = timelock.schedule(address(probe), data, 0);
        uint256 ready = timelock.readyAt(id);
        vm.warp(ready);
        probe.setReject(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceTimelock.ExecutionFailed.selector,
                abi.encodeWithSelector(ExecutionProbe.ProbeRejected.selector)
            )
        );
        timelock.execute(address(probe), data, 0);
        assertFalse(timelock.done(id));
        assertEq(timelock.readyAt(id), ready);
        assertEq(probe.calls(), 0);
        probe.setReject(false);
        timelock.execute(address(probe), data, 0);
        assertTrue(timelock.done(id));
        assertEq(probe.calls(), 1);
    }

    function test_nestedExecutionCannotConsumeAnotherMaturedProposal() public {
        ExecutionProbe second = new ExecutionProbe();
        bytes memory data = abi.encodeCall(probe.run, ());
        bytes32 firstId = timelock.schedule(address(probe), data, 0);
        bytes32 secondId = timelock.schedule(address(second), data, 0);
        probe.setCallback(
            address(timelock), abi.encodeCall(timelock.execute, (address(second), data, bytes32(0)))
        );
        uint256 ready = timelock.readyAt(firstId);
        vm.warp(ready);
        timelock.execute(address(probe), data, 0);
        assertFalse(probe.nestedSucceeded());
        assertEq(probe.nestedResult(), abi.encodeWithSelector(GovernanceTimelock.NotReady.selector));
        assertEq(second.calls(), 0);
        assertFalse(timelock.done(secondId));
        assertEq(timelock.readyAt(secondId), ready);
        timelock.execute(address(second), data, 0);
        assertEq(second.calls(), 1);
    }

    function test_domainBindsExecutorTargetCalldataAndSalt() public {
        GovernanceTimelock other = new GovernanceTimelock(address(this), CANCELLER, 2 days);
        ExecutionProbe second = new ExecutionProbe();
        bytes memory data = abi.encodeCall(probe.run, ());
        bytes32 id = timelock.schedule(address(probe), data, 0);
        assertNotEq(id, other.hashOperation(address(probe), data, 0));
        assertNotEq(id, timelock.hashOperation(address(second), data, 0));
        assertNotEq(id, timelock.hashOperation(address(probe), abi.encodeCall(probe.setReject, (true)), 0));
        assertNotEq(id, timelock.hashOperation(address(probe), data, bytes32(uint256(1))));
        vm.warp(timelock.readyAt(id));
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        other.execute(address(probe), data, 0);
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        timelock.execute(address(second), data, 0);
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        timelock.execute(address(probe), abi.encodeCall(probe.setReject, (true)), 0);
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        timelock.execute(address(probe), data, bytes32(uint256(1)));
        assertEq(probe.calls(), 0);
        timelock.execute(address(probe), data, 0);
        assertEq(probe.calls(), 1);
    }

    function test_duplicateScheduleMalformedTargetsAndUnknownCancellation() public {
        bytes memory data = abi.encodeCall(probe.run, ());
        timelock.schedule(address(probe), data, 0);
        vm.expectRevert(GovernanceTimelock.InvalidOperation.selector);
        timelock.schedule(address(probe), data, 0);
        vm.expectRevert(GovernanceTimelock.InvalidOperation.selector);
        timelock.schedule(address(0xB0B), data, 0);
        vm.expectRevert(GovernanceTimelock.InvalidOperation.selector);
        timelock.schedule(address(probe), hex"010203", 0);
        vm.expectRevert(GovernanceTimelock.InvalidOperation.selector);
        timelock.cancel(bytes32(uint256(99)));
    }

    function test_constructorRejectsRoleCollisionsAndDelayOutOfBounds() public {
        vm.expectRevert(GovernanceTimelock.InvalidOperation.selector);
        new GovernanceTimelock(address(0), CANCELLER, 2 days);
        vm.expectRevert(GovernanceTimelock.InvalidOperation.selector);
        new GovernanceTimelock(address(this), address(0), 2 days);
        vm.expectRevert(GovernanceTimelock.InvalidOperation.selector);
        new GovernanceTimelock(CANCELLER, CANCELLER, 2 days);
        vm.expectRevert(GovernanceTimelock.InvalidOperation.selector);
        new GovernanceTimelock(address(this), CANCELLER, 2 days - 1);
        vm.expectRevert(GovernanceTimelock.InvalidOperation.selector);
        new GovernanceTimelock(address(this), CANCELLER, 30 days + 1);
    }
}

contract BankAuthorityEdgesTest is BankFixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unprivilegedAccountCannotChangeAnyRiskControl(address caller) public {
        if (caller == address(this) || caller == GUARDIAN) caller = ALICE;
        vm.startPrank(caller);
        vm.expectRevert(IMDBank.Unauthorized.selector);
        bank.configureRisk(2500, 3500, 800, 5000, 1e30);
        vm.expectRevert(IMDBank.Unauthorized.selector);
        bank.configureReserve(address(usdc), 1e30, 0, 0, 0, 8000);
        vm.expectRevert(IMDBank.Unauthorized.selector);
        bank.setGuardian(caller);
        vm.expectRevert(IMDBank.Unauthorized.selector);
        bank.setFrozen(true);
        vm.expectRevert(IMDBank.Unauthorized.selector);
        bank.setFrozen(false);
        vm.expectRevert(IMDBank.Unauthorized.selector);
        bank.setReserveFrozen(address(usdc), true);
        vm.expectRevert(IMDBank.Unauthorized.selector);
        bank.setReserveFrozen(address(usdc), false);
        vm.stopPrank();
        assertFalse(bank.frozen());
        assertEq(bank.guardian(), GUARDIAN);
    }

    function test_guardianRotationRevokesOldAuthorityAndReserveFreezeIsIsolated() public {
        bank.setGuardian(BOB);
        vm.prank(GUARDIAN);
        vm.expectRevert(IMDBank.Unauthorized.selector);
        bank.setFrozen(true);
        vm.startPrank(BOB);
        bank.setReserveFrozen(address(usdc), true);
        vm.expectRevert(IMDBank.Unauthorized.selector);
        bank.setReserveFrozen(address(usdc), false);
        vm.stopPrank();
        _position(ALICE, 1000e18, 0);
        vm.startPrank(ALICE);
        vm.expectRevert(IMDBank.Frozen.selector);
        bank.borrow(address(usdc), 1, ALICE);
        bank.borrow(address(usdt), 100e6, ALICE);
        bank.repay(address(usdt), type(uint256).max, ALICE);
        bank.withdraw(1000e18, ALICE);
        vm.stopPrank();
        assertEq(bank.totalCollateral(), 0);
        assertFalse(bank.frozen());
    }
}
