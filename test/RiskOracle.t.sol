// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RiskOracle} from "../src/RiskOracle.sol";
import {MockToken, MockFeed} from "./helpers/Mocks.sol";

contract RiskOracleTest is Test {
    RiskOracle oracle;
    MockFeed a;
    MockFeed b;
    MockToken token;
    address constant GUARDIAN = address(0xBEEF);

    function setUp() public {
        vm.warp(10 days);
        token = new MockToken(18);
        a = new MockFeed();
        b = new MockFeed();
        oracle = new RiskOracle(address(this), GUARDIAN);
        _configure(true);
    }

    function _configure(bool isCollateral) internal {
        oracle.configure(
            address(token), address(a), address(b), 1 hours, 1 hours, 1000, 0.1e18, 10e18, isCollateral
        );
    }

    function test_conservativeDirectionAndDecimals() public {
        b.setDecimals(18);
        b.setAnswer(1.05e18);
        _configure(true);
        assertEq(oracle.price(address(token)), 1e18);
        _configure(false);
        assertEq(oracle.price(address(token)), 1.05e18);
    }

    function test_depegIsPricedNotAssumedOneDollar() public {
        a.setAnswer(80_000_000);
        b.setAnswer(81_000_000);
        _configure(false);
        assertEq(oracle.price(address(token)), 0.81e18);
    }

    function test_rejectsBadRoundsAndTimes() public {
        a.setAnswer(0);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        oracle.price(address(token));
        a.setAnswer(-1);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        oracle.price(address(token));
        a.setAnswer(1e8);
        a.setRound(2, 1, block.timestamp);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        oracle.price(address(token));
        a.setRound(2, 2, block.timestamp + 1);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        oracle.price(address(token));
        a.setRound(2, 2, block.timestamp - 1 hours - 1);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        oracle.price(address(token));
        a.setRound(2, 2, 0);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        oracle.price(address(token));
    }

    function test_ageBoundaryAndCircuitBreaker() public {
        a.setRound(2, 2, block.timestamp - 1 hours);
        assertEq(oracle.price(address(token)), 1e18);
        b.setAnswer(2e8);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        oracle.price(address(token));
        b.setAnswer(1000e8);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        oracle.price(address(token));
    }

    function test_feedDecimalsCannotSilentlyChange() public {
        a.setDecimals(18);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        oracle.price(address(token));
    }

    function test_governanceAndGuardianSeparation() public {
        vm.prank(GUARDIAN);
        oracle.setEnabled(address(token), false);
        vm.expectRevert(RiskOracle.Disabled.selector);
        oracle.price(address(token));
        vm.prank(GUARDIAN);
        vm.expectRevert(RiskOracle.Unauthorized.selector);
        oracle.setEnabled(address(token), true);
        oracle.setEnabled(address(token), true);
        vm.prank(address(99));
        vm.expectRevert(RiskOracle.Unauthorized.selector);
        oracle.setEnabled(address(token), false);
        vm.prank(GUARDIAN);
        vm.expectRevert(RiskOracle.Unauthorized.selector);
        oracle.configure(address(token), address(a), address(b), 60, 60, 500, 1, 2e18, true);
        vm.expectRevert(RiskOracle.InvalidConfiguration.selector);
        oracle.configure(address(token), address(a), address(a), 60, 60, 500, 1, 2e18, true);
        vm.expectRevert(RiskOracle.Disabled.selector);
        oracle.price(address(123));
    }

    function testFuzz_agreementAlwaysUsesSafeSide(uint64 rawA, uint64 delta) public {
        uint256 p = bound(uint256(rawA), 10_000_001, 900_000_000);
        uint256 q = p + bound(uint256(delta), 0, p / 10);
        a.setAnswer(int256(p));
        b.setAnswer(int256(q));
        _configure(true);
        assertEq(oracle.price(address(token)), p * 1e10);
        _configure(false);
        assertEq(oracle.price(address(token)), q * 1e10);
    }
}
