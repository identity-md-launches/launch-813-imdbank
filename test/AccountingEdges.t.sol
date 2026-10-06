// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BankFixture} from "./helpers/BankFixture.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {IMDBank} from "src/IMDBank.sol";
import {ExactToken} from "src/lib/ExactToken.sol";

contract AccountingEdgesTest is BankFixture {
    function test_zeroAndOversizedInputsFailBeforeMovingFunds() public {
        uint256[3] memory amounts = [uint256(0), uint256(1e30 + 1), type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            vm.startPrank(ALICE);
            vm.expectRevert(IMDBank.InvalidAmount.selector);
            bank.supply(amounts[i], ALICE);
            vm.expectRevert(IMDBank.InvalidAmount.selector);
            bank.withdraw(amounts[i], ALICE);
            vm.expectRevert(IMDBank.InvalidAmount.selector);
            bank.borrow(address(usdc), amounts[i], ALICE);
            vm.expectRevert(IMDBank.InvalidAmount.selector);
            bank.donateLiquidity(address(usdc), amounts[i]);
            vm.expectRevert(IMDBank.InvalidAmount.selector);
            bank.coverBadDebt(address(usdc), amounts[i]);
            vm.stopPrank();
        }
        vm.expectRevert(IMDBank.InvalidAmount.selector);
        bank.repay(address(usdc), 0, ALICE);
        assertEq(bank.totalCollateral(), 0);
        assertEq(usdc.balanceOf(address(bank)), 1_000_000e6);
    }

    function test_zeroAndBankRecipientsAreRejectedOnEveryUserPath() public {
        _position(ALICE, 1000e18, 100e6);
        address[2] memory recipients = [address(0), address(bank)];
        for (uint256 i; i < recipients.length; ++i) {
            vm.startPrank(ALICE);
            vm.expectRevert(IMDBank.InvalidRecipient.selector);
            bank.supply(1, recipients[i]);
            vm.expectRevert(IMDBank.InvalidRecipient.selector);
            bank.withdraw(1, recipients[i]);
            vm.expectRevert(IMDBank.InvalidRecipient.selector);
            bank.borrow(address(usdc), 1, recipients[i]);
            vm.expectRevert(IMDBank.InvalidRecipient.selector);
            bank.repay(address(usdc), 1, recipients[i]);
            vm.stopPrank();
        }
        assertEq(bank.collateralBalance(ALICE), 1000e18);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 100e6);
    }

    function test_unsupportedReserveCannotReachAnyDebtPath() public {
        address unsupported = address(imd);
        vm.expectRevert(IMDBank.UnsupportedAsset.selector);
        bank.borrow(unsupported, 1, ALICE);
        vm.expectRevert(IMDBank.UnsupportedAsset.selector);
        bank.repay(unsupported, 1, ALICE);
        vm.expectRevert(IMDBank.UnsupportedAsset.selector);
        bank.donateLiquidity(unsupported, 1);
        vm.expectRevert(IMDBank.UnsupportedAsset.selector);
        bank.coverBadDebt(unsupported, 1);
        vm.expectRevert(IMDBank.UnsupportedAsset.selector);
        bank.accrue(unsupported);
        vm.expectRevert(IMDBank.UnsupportedAsset.selector);
        bank.liquidate(ALICE, unsupported, 1, 0, block.timestamp);
        vm.expectRevert(IMDBank.UnsupportedAsset.selector);
        bank.previewDebt(ALICE, unsupported);
        vm.expectRevert(IMDBank.UnsupportedAsset.selector);
        bank.reserveData(unsupported);
    }

    function test_supplyCapCountsAllAccountsAndDirectDonationsMintNoClaims() public {
        bank.configureRisk(2500, 3500, 800, 5000, 10e18);
        vm.startPrank(ALICE);
        imd.transfer(address(bank), 100e18);
        bank.supply(4e18, ALICE);
        vm.stopPrank();
        vm.prank(BOB);
        bank.supply(6e18, BOB);
        vm.prank(BOB);
        vm.expectRevert(IMDBank.CapExceeded.selector);
        bank.supply(1, BOB);
        assertEq(bank.totalCollateral(), 10e18);
        vm.prank(ALICE);
        bank.withdraw(4e18, ALICE);
        vm.prank(BOB);
        bank.withdraw(6e18, BOB);
        assertEq(bank.totalCollateral(), 0);
        assertEq(imd.balanceOf(address(bank)), 100e18);
    }

    function test_borrowCapCountsOtherBorrowersAndAccruedInterest() public {
        bank.configureReserve(address(usdc), 100e6, 0.02e27, 0, 0, 8000);
        _position(ALICE, 1000e18, 60e6);
        _position(BOB, 1000e18, 40e6);
        vm.prank(BOB);
        vm.expectRevert(IMDBank.CapExceeded.selector);
        bank.borrow(address(usdc), 1, BOB);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ALICE);
        vm.expectRevert(IMDBank.CapExceeded.selector);
        bank.borrow(address(usdc), 1, ALICE);
        vm.prank(BOB);
        bank.repay(address(usdc), type(uint256).max, BOB);
        vm.prank(ALICE);
        bank.borrow(address(usdc), 1, ALICE);
    }

    function test_exactBorrowCapacityAndWithdrawalBoundary() public {
        _position(ALICE, 1000e18, 2500e6);
        vm.startPrank(ALICE);
        vm.expectRevert(IMDBank.UnsafePosition.selector);
        bank.borrow(address(usdc), 1, ALICE);
        vm.expectRevert(IMDBank.UnsafePosition.selector);
        bank.withdraw(1, ALICE);
        bank.repay(address(usdc), 250e6, ALICE);
        bank.withdraw(100e18, BOB);
        vm.expectRevert(IMDBank.UnsafePosition.selector);
        bank.withdraw(1, ALICE);
        vm.stopPrank();
        assertEq(imd.balanceOf(BOB), 10_100e18);
        assertEq(bank.collateralBalance(ALICE), 900e18);
    }

    function test_repayThirdPartyChargesOnlyDebtAndDoesNotTransferOwnership() public {
        _position(ALICE, 1000e18, 100e6);
        uint256 bobBefore = usdc.balanceOf(BOB);
        vm.prank(BOB);
        uint256 paid = bank.repay(address(usdc), type(uint256).max, ALICE);
        assertEq(paid, 100e6);
        assertEq(usdc.balanceOf(BOB), bobBefore - paid);
        assertEq(bank.collateralBalance(ALICE), 1000e18);
        assertEq(bank.collateralBalance(BOB), 0);
        vm.prank(BOB);
        vm.expectRevert(IMDBank.Dust.selector);
        bank.repay(address(usdc), type(uint256).max, ALICE);
        vm.prank(BOB);
        vm.expectRevert(IMDBank.InvalidAmount.selector);
        bank.withdraw(1, BOB);
    }

    function test_interestUpdatesProspectivelyAtGovernanceRateChange() public {
        bank.configureReserve(address(usdc), 1_000_000e6, 0, 0, 0, 8000);
        _position(ALICE, 1000e18, 1000e6);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        bank.configureReserve(address(usdc), 1_000_000e6, 1e27, 0, 0, 8000);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 1000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 accrued = bank.previewDebt(ALICE, address(usdc));
        assertGt(accrued, 1000e6);
        bank.configureReserve(address(usdc), 1_000_000e6, 0, 0, 0, 8000);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(bank.previewDebt(ALICE, address(usdc)), accrued);
    }

    function test_kinkAndFullUtilizationRatesThenIdleIndex() public {
        imd.mint(ALICE, 400_000e18);
        _position(ALICE, 400_000e18, 800_000e6);
        (,,, uint256 rate,,,) = bank.reserveData(address(usdc));
        assertEq(rate, 0.1e27);
        vm.prank(ALICE);
        bank.borrow(address(usdc), 100_000e6, ALICE);
        (,,, rate,,,) = bank.reserveData(address(usdc));
        assertEq(rate, 0.55e27);
        vm.prank(ALICE);
        bank.borrow(address(usdc), 100_000e6, ALICE);
        (,,, rate,,,) = bank.reserveData(address(usdc));
        assertEq(rate, 1e27);
        vm.prank(ALICE);
        bank.repay(address(usdc), type(uint256).max, ALICE);
        (,, uint256 index, uint256 idleRate,,,) = bank.reserveData(address(usdc));
        assertEq(idleRate, 0.02e27);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        bank.accrue(address(usdc));
        (,, uint256 idleIndex,,,,) = bank.reserveData(address(usdc));
        assertEq(idleIndex, index);
    }

    function test_saturatedIndexStopsNewDebtButAllowsFullRepayAndExit() public {
        bank.configureReserve(address(usdc), 1e30, 1e27, 0, 0, 8000);
        _position(ALICE, 1000e18, 100e6);
        vm.warp(vm.getBlockTimestamp() + 100 * 365 days);
        bank.accrue(address(usdc));
        (,, uint256 index,,,, bool isFrozen) = bank.reserveData(address(usdc));
        assertEq(index, bank.MAX_INDEX());
        assertTrue(isFrozen);
        vm.startPrank(ALICE);
        vm.expectRevert(IMDBank.Frozen.selector);
        bank.borrow(address(usdc), 1, ALICE);
        vm.expectRevert(IMDBank.Dust.selector);
        bank.repay(address(usdc), 1, ALICE);
        vm.stopPrank();
        uint256 debt = bank.previewDebt(ALICE, address(usdc));
        usdc.mint(ALICE, debt);
        vm.startPrank(ALICE);
        assertEq(bank.repay(address(usdc), type(uint256).max, ALICE), debt);
        bank.withdraw(1000e18, ALICE);
        vm.stopPrank();
        assertEq(bank.previewDebt(ALICE, address(usdc)), 0);
        assertEq(bank.totalCollateral(), 0);
    }

    function test_exactHealthAndCloseFactorBoundaries() public {
        _position(ALICE, 100e18, 35e6);
        oracle.setPrice(address(imd), 1e18);
        (,,,, uint256 hf) = bank.accountData(ALICE);
        assertEq(hf, 1e18);
        vm.expectRevert(IMDBank.HealthyPosition.selector);
        bank.previewLiquidation(ALICE, address(usdc), type(uint256).max);
        oracle.setPrice(address(imd), 0.95e18);
        (uint256 atBoundary,) = bank.previewLiquidation(ALICE, address(usdc), type(uint256).max);
        assertEq(atBoundary, 17_500_000);
        oracle.setPrice(address(imd), 0.95e18 - 1);
        (uint256 belowBoundary, uint256 seized) =
            bank.previewLiquidation(ALICE, address(usdc), type(uint256).max);
        assertEq(belowBoundary, 35e6);
        vm.prank(LIQUIDATOR);
        (uint256 paid, uint256 actualSeized) =
            bank.liquidate(ALICE, address(usdc), belowBoundary, seized, block.timestamp);
        assertEq(paid, belowBoundary);
        assertEq(actualSeized, seized);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 0);
    }

    function test_liquidationTransferFailureRestoresAllThreeReservesAndWriteoffs() public {
        _position(ALICE, 1000e18, 1000e6);
        vm.startPrank(ALICE);
        bank.borrow(address(usdt), 500e6, ALICE);
        bank.borrow(address(weth), 0.1e18, ALICE);
        vm.stopPrank();
        oracle.setPrice(address(imd), 0.1e18);
        uint256 cash = usdc.balanceOf(address(bank));
        uint256 payerBalance = usdc.balanceOf(LIQUIDATOR);
        imd.setReturnMode(2);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(ExactToken.TransferFailed.selector);
        bank.liquidate(ALICE, address(usdc), type(uint256).max, 0, block.timestamp);
        assertEq(bank.collateralBalance(ALICE), 1000e18);
        assertEq(bank.totalCollateral(), 1000e18);
        assertEq(imd.balanceOf(address(bank)), 1000e18);
        assertEq(usdc.balanceOf(address(bank)), cash);
        assertEq(usdc.balanceOf(LIQUIDATOR), payerBalance);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 1000e6);
        assertEq(bank.previewDebt(ALICE, address(usdt)), 500e6);
        assertEq(bank.previewDebt(ALICE, address(weth)), 0.1e18);
        for (uint256 i; i < 3; ++i) {
            (,,,,, uint256 loss, bool isFrozen) = bank.reserveData(bank.assets(i));
            assertEq(loss, 0);
            assertFalse(isFrozen);
        }
        assertFalse(bank.frozen());
    }

    function test_failedRepaymentDoesNotBurnSharesOrConsumeAllowance() public {
        _position(ALICE, 1000e18, 100e6);
        vm.prank(BOB);
        usdc.approve(address(bank), 10e6);
        usdc.setFee(100);
        uint256 shares = bank.debtShares(ALICE, address(usdc));
        uint256 cash = usdc.balanceOf(address(bank));
        uint256 payerBalance = usdc.balanceOf(BOB);
        vm.prank(BOB);
        vm.expectRevert(ExactToken.InexactTransfer.selector);
        bank.repay(address(usdc), 10e6, ALICE);
        assertEq(bank.debtShares(ALICE, address(usdc)), shares);
        assertEq(usdc.balanceOf(address(bank)), cash);
        assertEq(usdc.balanceOf(BOB), payerBalance);
        assertEq(usdc.allowance(BOB, address(bank)), 10e6);
    }

    function test_partialRecapitalizationCannotReopenAnyRisk() public {
        _position(ALICE, 1000e18, 2000e6);
        oracle.setPrice(address(imd), 1);
        bank.finalizeDust(ALICE);
        vm.startPrank(BOB);
        vm.expectRevert(IMDBank.InvalidAmount.selector);
        bank.coverBadDebt(address(usdc), 2000e6 + 1);
        bank.coverBadDebt(address(usdc), 1999e6);
        vm.stopPrank();
        vm.expectRevert(IMDBank.OutstandingBadDebt.selector);
        bank.setFrozen(false);
        vm.expectRevert(IMDBank.OutstandingBadDebt.selector);
        bank.setReserveFrozen(address(usdc), false);
        usdc.setReturnMode(2);
        vm.prank(BOB);
        vm.expectRevert(ExactToken.TransferFailed.selector);
        bank.coverBadDebt(address(usdc), 1e6);
        (,,,,, uint256 loss,) = bank.reserveData(address(usdc));
        assertEq(loss, 1e6);
        usdc.setReturnMode(0);
        vm.prank(BOB);
        bank.coverBadDebt(address(usdc), 1e6);
        assertTrue(bank.frozen());
        bank.setReserveFrozen(address(usdc), false);
        bank.setFrozen(false);
        assertFalse(bank.frozen());
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partialRepaymentMatchesCashAndDebtAcrossDecimals(
        uint8 reserveRaw,
        uint32 timeRaw,
        uint256 budgetRaw
    ) public {
        MockToken token = MockToken(bank.assets(reserveRaw % 3));
        uint256 principal = address(token) == address(weth) ? 0.1e18 : 200e6;
        _position(ALICE, 1000e18, 0);
        vm.prank(ALICE);
        bank.borrow(address(token), principal, ALICE);
        vm.warp(vm.getBlockTimestamp() + bound(timeRaw, 1, 365 days));
        uint256 debt = bank.previewDebt(ALICE, address(token));
        (,, uint256 index,,,,) = bank.reserveData(address(token));
        uint256 budget = bound(budgetRaw, (index + 1e27 - 1) / 1e27, debt);
        uint256 cash = token.balanceOf(address(bank));
        uint256 payerBalance = token.balanceOf(BOB);
        vm.prank(BOB);
        uint256 paid = bank.repay(address(token), budget, ALICE);
        assertGt(paid, 0);
        assertLe(paid, budget);
        assertEq(debt - bank.previewDebt(ALICE, address(token)), paid);
        assertEq(token.balanceOf(address(bank)), cash + paid);
        assertEq(token.balanceOf(BOB), payerBalance - paid);
        if (bank.previewDebt(ALICE, address(token)) != 0) {
            vm.prank(BOB);
            bank.repay(address(token), type(uint256).max, ALICE);
        }
        assertEq(bank.previewDebt(ALICE, address(token)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_minimumDebtUsesReservePriceAndPostBorrowBalance(uint8 reserveRaw, uint16 priceRaw)
        public
    {
        MockToken token = MockToken(bank.assets(reserveRaw % 3));
        uint256 price = address(token) == address(weth)
            ? bound(priceRaw, 500, 6000) * 1e18
            : bound(priceRaw, 50, 200) * 1e16;
        oracle.setPrice(address(token), price);
        uint256 unit = bank.assetUnit(address(token));
        uint256 minimum = (1e18 * unit + price - 1) / price;
        _position(ALICE, 1000e18, 0);
        uint256 cash = token.balanceOf(address(bank));
        uint256 wallet = token.balanceOf(ALICE);
        vm.startPrank(ALICE);
        vm.expectRevert(IMDBank.MinimumDebt.selector);
        bank.borrow(address(token), minimum - 1, ALICE);
        assertEq(bank.debtShares(ALICE, address(token)), 0);
        assertEq(token.balanceOf(address(bank)), cash);
        assertEq(token.balanceOf(ALICE), wallet);

        bank.borrow(address(token), minimum, ALICE);
        bank.borrow(address(token), 1, ALICE);
        assertEq(bank.previewDebt(ALICE, address(token)), minimum + 1);
        assertEq(token.balanceOf(ALICE), wallet + minimum + 1);
        assertEq(bank.repay(address(token), minimum, ALICE), minimum);
        assertEq(bank.previewDebt(ALICE, address(token)), 1);
        // Repayment may leave dust, but a borrow must bring that reserve back above the minimum.
        vm.expectRevert(IMDBank.MinimumDebt.selector);
        bank.borrow(address(token), 1, ALICE);
        assertEq(bank.previewDebt(ALICE, address(token)), 1);
        assertEq(token.balanceOf(address(bank)), cash - 1);
        bank.borrow(address(token), minimum - 1, ALICE);
        assertEq(bank.previewDebt(ALICE, address(token)), minimum);
        bank.repay(address(token), type(uint256).max, ALICE);
        vm.stopPrank();
        assertEq(token.balanceOf(address(bank)), cash);
        assertEq(token.balanceOf(ALICE), wallet);
        assertEq(bank.previewDebt(ALICE, address(token)), 0);
    }

    function test_minimumDebtCannotBeSatisfiedByAnotherAccountOrReserve() public {
        _position(ALICE, 1000e18, 100e6);
        _position(BOB, 1000e18, 0);
        vm.prank(ALICE);
        vm.expectRevert(IMDBank.MinimumDebt.selector);
        bank.borrow(address(weth), 1, ALICE);
        vm.prank(BOB);
        vm.expectRevert(IMDBank.MinimumDebt.selector);
        bank.borrow(address(usdc), 1, BOB);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 100e6);
        assertEq(bank.previewDebt(ALICE, address(weth)), 0);
        assertEq(bank.previewDebt(BOB, address(usdc)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_repeatedTinyBorrowRepayCyclesCannotExtractCash(uint8 raw, uint32 timeRaw) public {
        MockToken token = MockToken(bank.assets(raw % 3));
        uint256 minimum = address(token) == address(weth) ? 5e14 : 1e6;
        _position(ALICE, 1000e18, 0);
        uint256 userBefore = token.balanceOf(ALICE);
        uint256 bankBefore = token.balanceOf(address(bank));
        vm.prank(ALICE);
        bank.borrow(address(token), minimum, ALICE);
        vm.warp(vm.getBlockTimestamp() + bound(timeRaw, 1, 365 days));
        // Keep an admitted position open so one-unit top-ups exercise the rounding boundary.
        // Repayments can leave sub-minimum residual debt; opening a new such position cannot.
        bank.accrue(address(token));
        uint256 debtBeforeCycles = bank.previewDebt(ALICE, address(token));
        vm.startPrank(ALICE);
        for (uint256 i = 1; i <= 16; ++i) {
            bank.borrow(address(token), i, ALICE);
            uint256 debtBeforeRepay = bank.previewDebt(ALICE, address(token));
            uint256 paid = bank.repay(address(token), i + 1, ALICE);
            assertLe(paid, i + 1);
            assertEq(debtBeforeRepay - bank.previewDebt(ALICE, address(token)), paid);
        }
        assertGe(bank.previewDebt(ALICE, address(token)), debtBeforeCycles);
        bank.repay(address(token), type(uint256).max, ALICE);
        vm.stopPrank();
        assertLe(token.balanceOf(ALICE), userBefore);
        assertGe(token.balanceOf(address(bank)), bankBefore);
        assertEq(bank.previewDebt(ALICE, address(token)), 0);
    }
}
