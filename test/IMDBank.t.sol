// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BankFixture} from "./helpers/BankFixture.sol";
import {IMDBank} from "../src/IMDBank.sol";

contract IMDBankTest is BankFixture {
    function test_completeLifecycleThreeReserves() public {
        assertEq(bank.name(), "IMDBANK");
        assertEq(bank.symbol(), "IMDBANK");
        assertEq(bank.feeBps(), 0);
        _position(ALICE, 1000e18, 1000e6);
        vm.startPrank(ALICE);
        bank.borrow(address(usdt), 500e6, ALICE);
        bank.borrow(address(weth), 0.1e18, ALICE);
        (uint256 c, uint256 d, uint256 power,, uint256 hf) = bank.accountData(ALICE);
        assertEq(c, 10_000e18);
        assertEq(d, 1700e18);
        assertEq(power, 2500e18);
        assertGt(hf, 1e18);
        vm.warp(block.timestamp + 30 days);
        assertGt(bank.previewDebt(ALICE, address(usdc)), 1000e6);
        bank.repay(address(usdc), type(uint256).max, ALICE);
        bank.repay(address(usdt), type(uint256).max, ALICE);
        bank.repay(address(weth), type(uint256).max, ALICE);
        bank.setCollateralEnabled(false);
        bank.withdraw(1000e18, ALICE);
        vm.stopPrank();
        assertEq(bank.collateralBalance(ALICE), 0);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 0);
        assertEq(imd.balanceOf(ALICE), 10_000e18);
        assertEq(imd.balanceOf(address(bank)), 0);
    }

    function test_initialDeploymentCannotTakeRisk() public {
        IMDBank fresh = new IMDBank(
            address(this),
            GUARDIAN,
            address(imd),
            address(oracle),
            address(usdc),
            address(usdt),
            address(weth)
        );
        vm.startPrank(ALICE);
        imd.approve(address(fresh), 1e18);
        vm.expectRevert();
        fresh.supply(1e18, ALICE);
        vm.expectRevert();
        fresh.borrow(address(usdc), 1, ALICE);
        vm.stopPrank();
    }

    function test_rejectsOverborrowWithdrawalAndCollateralDisable() public {
        _position(ALICE, 1000e18, 2400e6);
        vm.startPrank(ALICE);
        vm.expectRevert();
        bank.borrow(address(usdc), 101e6, ALICE);
        vm.expectRevert();
        bank.withdraw(900e18, ALICE);
        vm.expectRevert();
        bank.setCollateralEnabled(false);
        vm.expectRevert();
        bank.withdraw(0, ALICE);
        vm.expectRevert();
        bank.borrow(address(usdc), 1, address(0));
        vm.stopPrank();
        assertEq(bank.collateralBalance(ALICE), 1000e18);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 2400e6);
    }

    function test_oracleOutageStillAllowsRepaymentAndDebtFreeExit() public {
        _position(ALICE, 1000e18, 1000e6);
        oracle.setBroken(true);
        vm.startPrank(ALICE);
        vm.expectRevert();
        bank.borrow(address(usdc), 1, ALICE);
        vm.expectRevert();
        bank.withdraw(1, ALICE);
        bank.repay(address(usdc), type(uint256).max, ALICE);
        bank.withdraw(1000e18, ALICE);
        vm.stopPrank();
        assertEq(bank.collateralBalance(ALICE), 0);
    }

    function test_guardianCannotUnfreezeOrChangeRisk() public {
        _position(ALICE, 1000e18, 1000e6);
        vm.startPrank(GUARDIAN);
        bank.setFrozen(true);
        vm.expectRevert();
        bank.setFrozen(false);
        vm.expectRevert();
        bank.configureRisk(4000, 5000, 800, 5000, 1e30);
        vm.expectRevert();
        bank.configureReserve(address(usdc), 1e30, 0, 0, 0, 8000);
        vm.stopPrank();
        vm.startPrank(ALICE);
        vm.expectRevert();
        bank.borrow(address(usdc), 1, ALICE);
        bank.supply(1e18, ALICE);
        bank.repay(address(usdc), type(uint256).max, ALICE);
        bank.withdraw(1001e18, ALICE);
        vm.stopPrank();
    }

    function test_supplyOnBehalfDoesNotEnableOthersCollateral() public {
        vm.prank(BOB);
        bank.supply(10e18, ALICE);
        assertFalse(bank.collateralEnabled(ALICE));
        vm.prank(BOB);
        vm.expectRevert();
        bank.withdraw(1e18, BOB);
        assertEq(bank.collateralBalance(ALICE), 10e18);
    }

    function test_noReturnTokensWorkAndFalseReturnRejected() public {
        usdt.setReturnMode(1);
        _position(ALICE, 1000e18, 0);
        vm.startPrank(ALICE);
        bank.borrow(address(usdt), 100e6, ALICE);
        bank.repay(address(usdt), type(uint256).max, ALICE);
        vm.stopPrank();
        imd.setReturnMode(2);
        vm.prank(ALICE);
        vm.expectRevert();
        bank.supply(1e18, ALICE);
        assertEq(bank.collateralBalance(ALICE), 1000e18);
    }

    function test_taxedTransfersFailAtomicallyInAndOut() public {
        imd.setFee(100);
        vm.prank(ALICE);
        vm.expectRevert();
        bank.supply(100e18, ALICE);
        assertEq(bank.collateralBalance(ALICE), 0);
        assertEq(imd.balanceOf(address(bank)), 0);
        imd.setFee(0);
        _position(ALICE, 1000e18, 0);
        imd.setFee(100);
        vm.prank(ALICE);
        vm.expectRevert();
        bank.withdraw(100e18, ALICE);
        usdc.setFee(100);
        vm.prank(ALICE);
        vm.expectRevert();
        bank.borrow(address(usdc), 100e6, ALICE);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 0);
    }

    function test_reentrancyTransferCallbackCannotMintUnbackedReceipts() public {
        imd.setCallback(address(bank), abi.encodeCall(bank.supply, (1e18, ALICE)));
        vm.prank(ALICE);
        vm.expectRevert();
        bank.supply(100e18, ALICE);
        assertEq(imd.balanceOf(address(bank)), 0);
        assertEq(bank.collateralBalance(ALICE), 0);
    }

    function test_safeHealthRejectsLiquidation() public {
        _position(ALICE, 1000e18, 2000e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert();
        bank.liquidate(ALICE, address(usdc), 1000e6, 0, block.timestamp);
    }

    function test_priceDropLiquidationAndCloseFactor() public {
        _position(ALICE, 1000e18, 2500e6);
        oracle.setPrice(address(imd), 7e18);
        (,,,, uint256 hf) = bank.accountData(ALICE);
        assertLt(hf, 1e18);
        (uint256 paid, uint256 seized) = bank.previewLiquidation(ALICE, address(usdc), 2500e6);
        assertLe(paid, 1250e6);
        assertGt(seized, 0);
        vm.prank(LIQUIDATOR);
        bank.liquidate(ALICE, address(usdc), 2500e6, seized, block.timestamp);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 2500e6 - paid);
        assertEq(bank.collateralBalance(ALICE), 1000e18 - seized);
        assertEq(imd.balanceOf(LIQUIDATOR), 10_000e18 + seized);
        (,,,, uint256 newHf) = bank.accountData(ALICE);
        assertGt(newHf, hf);
    }

    function test_liquidationSlippageAndExpiryProtectPayer() public {
        _position(ALICE, 1000e18, 2500e6);
        oracle.setPrice(address(imd), 7e18);
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert();
        bank.liquidate(ALICE, address(usdc), 100e6, 1000e18, block.timestamp);
        vm.expectRevert();
        bank.liquidate(ALICE, address(usdc), 100e6, 0, block.timestamp - 1);
        vm.stopPrank();
        assertEq(bank.previewDebt(ALICE, address(usdc)), 2500e6);
    }

    function test_flashSupplyBorrowWithdrawCannotEscapeDebt() public {
        vm.startPrank(ALICE);
        bank.supply(1000e18, ALICE);
        bank.setCollateralEnabled(true);
        bank.borrow(address(usdc), 2500e6, ALICE);
        vm.expectRevert();
        bank.withdraw(1000e18, ALICE);
        vm.stopPrank();
    }

    function test_stablecoinDepegAndWethSpikeChangeDebtValue() public {
        _position(ALICE, 1000e18, 1000e6);
        vm.prank(ALICE);
        bank.borrow(address(weth), 0.5e18, ALICE);
        (, uint256 beforeDebt,,,) = bank.accountData(ALICE);
        oracle.setPrice(address(usdc), 1.2e18);
        oracle.setPrice(address(weth), 5000e18);
        (, uint256 afterDebt,,, uint256 hf) = bank.accountData(ALICE);
        assertEq(beforeDebt, 2000e18);
        assertEq(afterDebt, 3700e18);
        assertLt(hf, 1e18);
    }

    function test_partialRepayNeverReducesDebtMoreThanPayment() public {
        _position(ALICE, 1000e18, 2000e6);
        vm.warp(block.timestamp + 365 days);
        uint256 beforeDebt = bank.previewDebt(ALICE, address(usdc));
        vm.prank(ALICE);
        uint256 paid = bank.repay(address(usdc), 77e6, ALICE);
        uint256 afterDebt = bank.previewDebt(ALICE, address(usdc));
        assertLe(beforeDebt - afterDebt, paid);
        assertLe(paid, 77e6);
        assertGt(paid, 0);
    }

    function testFuzz_roundTripNoCollateralGain(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1, 10_000e18);
        uint256 start = imd.balanceOf(ALICE);
        vm.startPrank(ALICE);
        bank.supply(amount, ALICE);
        bank.withdraw(amount, ALICE);
        vm.stopPrank();
        assertEq(imd.balanceOf(ALICE), start);
        assertEq(bank.collateralBalance(ALICE), 0);
    }

    function testFuzz_borrowRepayRoundingCannotCreateAssets(uint64 amountRaw, uint32 timeRaw) public {
        uint256 amount = bound(uint256(amountRaw), 1e6, 2500e6);
        uint256 elapsed = bound(uint256(timeRaw), 1, 365 days);
        _position(ALICE, 1000e18, amount);
        vm.warp(block.timestamp + elapsed);
        uint256 debt = bank.previewDebt(ALICE, address(usdc));
        assertGe(debt, amount);
        uint256 cash = usdc.balanceOf(address(bank));
        vm.prank(ALICE);
        uint256 paid = bank.repay(address(usdc), type(uint256).max, ALICE);
        assertEq(paid, debt);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 0);
        assertEq(usdc.balanceOf(address(bank)), cash + paid);
    }
}
