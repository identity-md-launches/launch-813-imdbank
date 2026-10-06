// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployMainnet} from "../script/DeployMainnet.s.sol";
import {GovernanceTimelock} from "../src/GovernanceTimelock.sol";
import {RiskOracle} from "../src/RiskOracle.sol";
import {IMDBank} from "../src/IMDBank.sol";
import {MockToken} from "./helpers/Mocks.sol";

contract RehearsalRole {}

contract DeploymentRehearsalTest is Test {
    function test_explicitRolesFromFactoryLikeCallerAndTimelockedRisk() public {
        vm.chainId(1);
        DeployMainnet deployer = new DeployMainnet();
        MockToken token18 = new MockToken(18);
        MockToken token6 = new MockToken(6);
        vm.etch(deployer.IMD(), address(token18).code);
        vm.etch(deployer.USDC(), address(token6).code);
        vm.etch(deployer.USDT(), address(token6).code);
        vm.etch(deployer.WETH(), address(token18).code);
        address proposer = address(new RehearsalRole());
        address guardian = address(new RehearsalRole());
        (GovernanceTimelock timelock, RiskOracle oracle, IMDBank bank) = deployer.deploy(proposer, guardian);
        assertEq(timelock.proposer(), proposer);
        assertEq(timelock.canceller(), guardian);
        assertEq(bank.governor(), address(timelock));
        assertEq(oracle.governor(), address(timelock));
        assertEq(bank.guardian(), guardian);
        assertEq(oracle.guardian(), guardian);
        assertEq(bank.supplyCap(), 0);
        assertTrue(bank.frozen());
        vm.expectRevert();
        bank.configureRisk(2500, 3500, 800, 5000, 100e18);
        bytes memory data = abi.encodeCall(bank.configureRisk, (2500, 3500, 800, 5000, 100e18));
        vm.prank(proposer);
        timelock.schedule(address(bank), data, 0);
        vm.expectRevert();
        timelock.execute(address(bank), data, 0);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(bank), data, 0);
        assertEq(bank.supplyCap(), 100e18);
        assertTrue(bank.frozen());
    }

    function test_wrongChainAndEOARolesRejected() public {
        DeployMainnet deployer = new DeployMainnet();
        vm.chainId(2);
        vm.expectRevert();
        deployer.deploy(address(1), address(2));
        vm.chainId(1);
        vm.expectRevert();
        deployer.deploy(address(1), address(2));
    }
}
