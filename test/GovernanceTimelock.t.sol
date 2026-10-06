// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GovernanceTimelock} from "../src/GovernanceTimelock.sol";

contract GovernedTarget {
    uint256 public value;

    function setValue(uint256 v) external {
        require(v != 13, "unlucky");
        value = v;
    }
}

contract GovernanceTimelockTest is Test {
    GovernanceTimelock timelock;
    GovernedTarget target;
    address constant GUARDIAN = address(0xBEEF);

    function setUp() public {
        vm.warp(10 days);
        timelock = new GovernanceTimelock(address(this), GUARDIAN, 2 days);
        target = new GovernedTarget();
    }

    function test_delayPermissionlessExecutionAndReplay() public {
        bytes memory data = abi.encodeCall(target.setValue, (7));
        bytes32 id = timelock.schedule(address(target), data, 0);
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        timelock.execute(address(target), data, 0);
        vm.warp(block.timestamp + 2 days);
        vm.prank(address(33));
        timelock.execute(address(target), data, 0);
        assertEq(target.value(), 7);
        assertTrue(timelock.done(id));
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        timelock.execute(address(target), data, 0);
        vm.expectRevert(GovernanceTimelock.InvalidOperation.selector);
        timelock.schedule(address(target), data, 0);
    }

    function test_cancellationAndAccess() public {
        bytes memory data = abi.encodeCall(target.setValue, (7));
        vm.prank(GUARDIAN);
        vm.expectRevert(GovernanceTimelock.Unauthorized.selector);
        timelock.schedule(address(target), data, 0);
        bytes32 id = timelock.schedule(address(target), data, 0);
        vm.prank(GUARDIAN);
        timelock.cancel(id);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        timelock.execute(address(target), data, 0);
        timelock.schedule(address(target), data, 0);
        assertEq(timelock.readyAt(id), block.timestamp + 2 days);
    }

    function test_expiryAndFailureAtomicity() public {
        bytes memory data = abi.encodeCall(target.setValue, (13));
        bytes32 id = timelock.schedule(address(target), data, 0);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert();
        timelock.execute(address(target), data, 0);
        assertFalse(timelock.done(id));
        assertGt(timelock.readyAt(id), 0);
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(GovernanceTimelock.NotReady.selector);
        timelock.execute(address(target), data, 0);
    }

    function test_domainSeparation() public {
        bytes memory data = abi.encodeCall(target.setValue, (7));
        bytes32 id = timelock.hashOperation(address(target), data, 0);
        vm.chainId(99);
        assertNotEq(id, timelock.hashOperation(address(target), data, 0));
    }
}
