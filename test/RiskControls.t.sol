// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BankFixture} from "./helpers/BankFixture.sol";
import {IMDBank} from "../src/IMDBank.sol";

contract RiskControlsTest is BankFixture {
    function test_capReductionCannotBlockRepayment() public {
        _position(ALICE, 1000e18, 2000e6);
        bank.configureReserve(address(usdc), 1, 0.02e27, 0.08e27, 0.9e27, 8000);
        vm.startPrank(ALICE);
        vm.expectRevert();
        bank.borrow(address(usdc), 1, ALICE);
        bank.repay(address(usdc), type(uint256).max, ALICE);
        bank.withdraw(1000e18, ALICE);
        vm.stopPrank();
    }

    function test_lossRecognitionRecapitalizationAndRestart() public {
        _position(ALICE, 1000e18, 2500e6);
        oracle.setPrice(address(imd), 2e18);
        (uint256 paid, uint256 seized) = bank.previewLiquidation(ALICE, address(usdc), type(uint256).max);
        assertEq(seized, 1000e18);
        assertLt(paid, 2500e6);
        vm.prank(LIQUIDATOR);
        bank.liquidate(ALICE, address(usdc), type(uint256).max, seized, block.timestamp);
        (,,,,, uint256 badDebt, bool frozen) = bank.reserveData(address(usdc));
        assertEq(badDebt, 2500e6 - paid);
        assertTrue(frozen);
        assertTrue(bank.frozen());
        vm.expectRevert();
        bank.setFrozen(false);
        vm.prank(LIQUIDATOR);
        bank.coverBadDebt(address(usdc), badDebt);
        bank.setReserveFrozen(address(usdc), false);
        bank.setFrozen(false);
        assertFalse(bank.frozen());
        assertEq(bank.previewDebt(ALICE, address(usdc)), 0);
    }

    function test_multiReserveDebtWrittenOffAfterCollateralExhausted() public {
        _position(ALICE, 1000e18, 1500e6);
        vm.startPrank(ALICE);
        bank.borrow(address(usdt), 500e6, ALICE);
        bank.borrow(address(weth), 0.1e18, ALICE);
        vm.stopPrank();
        oracle.setPrice(address(imd), 0.1e18);
        vm.prank(LIQUIDATOR);
        bank.liquidate(ALICE, address(usdc), type(uint256).max, 1000e18, block.timestamp);
        (,,,,, uint256 usdtLoss,) = bank.reserveData(address(usdt));
        (,,,,, uint256 wethLoss,) = bank.reserveData(address(weth));
        assertEq(usdtLoss, 500e6);
        assertEq(wethLoss, 0.1e18);
        assertEq(bank.previewDebt(ALICE, address(usdt)), 0);
        assertEq(bank.previewDebt(ALICE, address(weth)), 0);
    }

    function test_tokenBalanceDonationCannotRetroactivelyChangeRate() public {
        _position(ALICE, 1000e18, 2000e6);
        uint256 snap = vm.snapshotState();
        uint256 t = block.timestamp;
        vm.warp(t + 30 days);
        uint256 baseline = bank.previewDebt(ALICE, address(usdc));
        vm.revertToState(snap);
        usdc.mint(address(bank), 1e30);
        vm.warp(t + 30 days);
        assertEq(bank.previewDebt(ALICE, address(usdc)), baseline);
    }

    function test_liquidityExhaustionRevertsWithoutMintingDebt() public {
        _position(ALICE, 1000e18, 0);
        // Model token issuer confiscation, an external risk. Debt creation still cannot exceed cash.
        usdc.burn(address(bank), usdc.balanceOf(address(bank)));
        vm.prank(ALICE);
        vm.expectRevert(IMDBank.InsufficientLiquidity.selector);
        bank.borrow(address(usdc), 1, ALICE);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 0);
    }

    function test_hardRiskBoundsCannotBeBypassedByGovernor() public {
        vm.expectRevert();
        bank.configureRisk(5000, 5001, 0, 5000, 1e30);
        vm.expectRevert();
        bank.configureRisk(2500, 2400, 0, 5000, 1e30);
        vm.expectRevert();
        bank.configureRisk(2500, 3500, 1501, 5000, 1e30);
        vm.expectRevert();
        bank.configureReserve(address(usdc), 1e30, 1e27, 1, 0, 8000);
        vm.expectRevert();
        bank.setGuardian(address(0));
    }

    function test_permissionlessLiquidationFitsGasBudget() public {
        _position(ALICE, 1000e18, 2000e6);
        oracle.setPrice(address(imd), 5e18);
        vm.prank(LIQUIDATOR);
        uint256 beforeGas = gasleft();
        bank.liquidate(ALICE, address(usdc), 1000e6, 0, block.timestamp);
        assertLt(beforeGas - gasleft(), 1_000_000);
    }
}
