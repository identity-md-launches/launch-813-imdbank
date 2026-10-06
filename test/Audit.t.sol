// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDBank} from "../src/IMDBank.sol";
import {RiskOracle} from "../src/RiskOracle.sol";
import {MockToken, MockOracle, MockFeed} from "./helpers/Mocks.sol";

/// @notice Independent contributor regression/reproduction suite; never accesses network or environment.
contract IndependentAuditTest is Test {
    MockToken imd;
    MockToken usdc;
    MockToken usdt;
    MockToken weth;
    MockOracle prices;
    IMDBank bank;
    address constant ALICE = address(0xA11CE);
    address constant GUARDIAN = address(0xBEEF);

    function setUp() public {
        vm.warp(100 days);
        imd = new MockToken(18);
        usdc = new MockToken(6);
        usdt = new MockToken(6);
        weth = new MockToken(18);
        prices = new MockOracle();
        prices.setPrice(address(imd), 10e18);
        prices.setPrice(address(usdc), 1e18);
        prices.setPrice(address(usdt), 1e18);
        prices.setPrice(address(weth), 2000e18);
        bank = new IMDBank(
            address(this),
            GUARDIAN,
            address(imd),
            address(prices),
            address(usdc),
            address(usdt),
            address(weth)
        );
        bank.configureRisk(2500, 3500, 800, 5000, 1_000_000e18);
        bank.configureReserve(address(usdc), 1_000_000e6, 1e27, 0, 0, 8000);
        bank.setFrozen(false);
        bank.setReserveFrozen(address(usdc), false);
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(bank), type(uint256).max);
        bank.donateLiquidity(address(usdc), 1_000_000e6);
        imd.mint(ALICE, 1000e18);
        vm.startPrank(ALICE);
        imd.approve(address(bank), type(uint256).max);
        bank.supply(1000e18, ALICE);
        bank.setCollateralEnabled(true);
        bank.borrow(address(usdc), 1500e6, ALICE);
        vm.stopPrank();
    }

    /// @dev M-01 regression: permissionless checkpoint frequency must not materially alter debt or HF.
    function testAudit_checkpointFrequencyCannotMateriallyChangeBorrowerDebt() public {
        uint256 start = vm.getBlockTimestamp();
        uint256 snapshot = vm.snapshotState();
        vm.warp(start + 365 days);
        bank.accrue(address(usdc));
        uint256 yearlyDebt = bank.previewDebt(ALICE, address(usdc));
        (,,,, uint256 yearlyHf) = bank.accountData(ALICE);
        vm.revertToState(snapshot);
        for (uint256 day = 1; day <= 365; ++day) {
            vm.warp(start + day * 1 days);
            bank.accrue(address(usdc));
        }
        uint256 dailyDebt = bank.previewDebt(ALICE, address(usdc));
        (,,,, uint256 dailyHf) = bank.accountData(ALICE);
        assertApproxEqAbs(dailyDebt, yearlyDebt, 1);
        assertApproxEqAbs(dailyHf, yearlyHf, 1e9);
        assertLt(yearlyHf, 1e18);
        assertLt(dailyHf, 1e18);
    }

    /// @dev M-02 regression: economically worthless collateral can finalize and freeze real losses.
    function testAudit_extremeCollapseRecordsBadDebt() public {
        prices.setPrice(address(imd), 1);
        bank.finalizeDust(ALICE);
        (, uint256 totalDebt,,,, uint256 badDebt, bool frozen) = bank.reserveData(address(usdc));
        assertEq(totalDebt, 0);
        assertEq(badDebt, 1500e6);
        assertTrue(frozen);
        assertTrue(bank.frozen());
        assertEq(bank.collateralBalance(ALICE), 0);
        assertEq(imd.balanceOf(address(this)), 1000e18);
    }

    function testAudit_dustFinalizationRejectsHealthyValuableAndInvalidPrice() public {
        vm.expectRevert();
        bank.finalizeDust(ALICE);
        prices.setPrice(address(imd), 1e18);
        vm.expectRevert();
        bank.finalizeDust(ALICE);
        prices.setPrice(address(imd), 1);
        prices.setBroken(true);
        vm.expectRevert();
        bank.finalizeDust(ALICE);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 1500e6);
    }

    function testAudit_dustTransferFailureRollsBackWriteoff() public {
        prices.setPrice(address(imd), 1);
        imd.setFee(100);
        vm.expectRevert();
        bank.finalizeDust(ALICE);
        (, uint256 totalDebt,,,, uint256 badDebt, bool frozen) = bank.reserveData(address(usdc));
        assertEq(totalDebt, 1500e6);
        assertEq(badDebt, 0);
        assertFalse(frozen);
        assertEq(bank.collateralBalance(ALICE), 1000e18);
    }

    /// @dev M-04 regression: small recoverable position cannot trigger a needless writeoff.
    function testAudit_smallRecoverablePositionCannotTriggerGlobalFreeze() public {
        address borrower = address(0xD057);
        imd.mint(borrower, 4e17);
        vm.startPrank(borrower);
        imd.approve(address(bank), type(uint256).max);
        bank.supply(4e17, borrower); // $4 at initial $10 price.
        bank.setCollateralEnabled(true);
        bank.borrow(address(usdc), 1e6, borrower); // $1, the smallest admitted debt.
        vm.stopPrank();
        prices.setPrice(address(imd), 5e18); // Collateral now $2, HF 0.70, solvent.
        (uint256 repayable,) = bank.previewLiquidation(borrower, address(usdc), 1e6);
        assertEq(repayable, 1e6);
        vm.expectRevert();
        bank.finalizeDust(borrower);
        (,,,,, uint256 badDebt, bool frozen) = bank.reserveData(address(usdc));
        assertEq(badDebt, 0);
        assertFalse(frozen);
        assertFalse(bank.frozen());
        usdc.mint(address(this), 1e6);
        bank.liquidate(borrower, address(usdc), 1e6, 0, block.timestamp);
        assertEq(bank.previewDebt(borrower, address(usdc)), 0);
    }

    /// @dev R2-02 regression: one-base-unit debts are not admitted, and a dust loss that still arises
    /// through repayment/withdrawal is recorded and coverable without halting the bank.
    function testAudit_minimumDebtAndDustLossDoNotHaltLending() public {
        address borrower = address(0x1055);
        imd.mint(borrower, 1e18);
        vm.startPrank(borrower);
        imd.approve(address(bank), type(uint256).max);
        bank.supply(1e18, borrower);
        bank.setCollateralEnabled(true);
        vm.expectRevert(IMDBank.MinimumDebt.selector);
        bank.borrow(address(usdc), 1, borrower);
        vm.expectRevert(IMDBank.MinimumDebt.selector);
        bank.borrow(address(usdc), 999_999, borrower);
        bank.borrow(address(usdc), 1e6, borrower);
        bank.borrow(address(usdc), 1, borrower); // Top-ups above the minimum stay unrestricted.
        usdc.approve(address(bank), type(uint256).max);
        bank.repay(address(usdc), 1e6, borrower); // Leaves one base unit of debt.
        assertEq(bank.previewDebt(borrower, address(usdc)), 1);
        bank.withdraw(1e18 - 4e11, borrower); // $0.000004 of collateral remains at $10.
        vm.stopPrank();
        prices.setPrice(address(imd), 2.4e18); // Residual is $0.00000096, below one repayable unit.
        bank.finalizeDust(borrower);
        (,,,,, uint256 badDebt, bool reserveFrozen) = bank.reserveData(address(usdc));
        assertEq(badDebt, 1);
        assertFalse(reserveFrozen);
        assertFalse(bank.frozen());
        assertFalse(bank.lossHalted(address(usdc)));
        assertEq(bank.previewDebt(borrower, address(usdc)), 0);
        // Lending continues for everyone, and anyone can still cover the recorded dust.
        prices.setPrice(address(imd), 10e18);
        vm.prank(ALICE);
        bank.borrow(address(usdc), 1e6, ALICE);
        usdc.mint(address(this), 1);
        bank.coverBadDebt(address(usdc), 1);
        (,,,,, badDebt,) = bank.reserveData(address(usdc));
        assertEq(badDebt, 0);
    }

    function testAudit_insolventButPartlyRecoverableDustMustLiquidateFirst() public {
        // Collateral is below the $0.001 dust threshold, but can recover 92 USDC base units.
        prices.setPrice(address(imd), 1e11);
        (uint256 repayable,) = bank.previewLiquidation(ALICE, address(usdc), type(uint256).max);
        assertGt(repayable, 0);
        vm.expectRevert();
        bank.finalizeDust(ALICE);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 1500e6);
    }

    /// @dev R2-07 regression: a collateral-limited payment whose seizure floors to zero still sweeps the
    /// residual wei, so the position is closed by an ordinary liquidation instead of being stuck.
    function testAudit_seizureFlooringToZeroStillSweepsResidue() public {
        bank.configureReserve(address(weth), 1_000e18, 0, 0, 0, 8000);
        bank.setReserveFrozen(address(weth), false);
        weth.mint(address(this), 1_000e18);
        weth.approve(address(bank), type(uint256).max);
        bank.donateLiquidity(address(weth), 1_000e18);
        address borrower = address(0x5EED);
        imd.mint(borrower, 1e18);
        vm.startPrank(borrower);
        imd.approve(address(bank), type(uint256).max);
        weth.approve(address(bank), type(uint256).max);
        bank.supply(1e18, borrower);
        bank.setCollateralEnabled(true);
        bank.borrow(address(weth), 5e14, borrower); // $1 of WETH.
        bank.repay(address(weth), 5e14 - 125_000, borrower); // 125,000 wei of debt remain.
        vm.stopPrank();
        prices.setPrice(address(imd), 1e27); // Accepted ceiling: one wei of IMD is worth 1e9 USD-wei.
        vm.prank(borrower);
        bank.withdraw(1e18 - 1, borrower);
        prices.setPrice(address(imd), 2e26); // Collateral 2e8 USD-wei against 2.5e8 of debt.
        (,,,, uint256 hf) = bank.accountData(borrower);
        assertLt(hf, 1e18);
        (uint256 repaid, uint256 seized) = bank.previewLiquidation(borrower, address(weth), type(uint256).max);
        assertEq(seized, 1);
        assertGt(repaid, 0);
        weth.mint(address(this), repaid);
        bank.liquidate(borrower, address(weth), type(uint256).max, 1, block.timestamp);
        assertEq(bank.collateralBalance(borrower), 0);
        assertEq(bank.previewDebt(borrower, address(weth)), 0);
        (,,,,, uint256 badDebt,) = bank.reserveData(address(weth));
        assertEq(badDebt, 125_000 - repaid);
        assertFalse(bank.frozen());
    }

    /// @dev Governance cannot bypass the oracle's rejection of independent-source divergence.
    function testAudit_oracleConfigurationRollsBackIfBroken() public {
        RiskOracle guarded = new RiskOracle(address(this), GUARDIAN);
        MockFeed first = new MockFeed();
        MockFeed second = new MockFeed();
        guarded.configure(address(imd), address(first), address(second), 3600, 3600, 500, 1, 100e18, true);
        second.setAnswer(2e8);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        guarded.configure(address(imd), address(first), address(second), 3600, 3600, 500, 1, 100e18, true);
        second.setAnswer(1e8);
        assertEq(guarded.price(address(imd)), 1e18);
    }

    function testAudit_collateralCallbackCannotLiquidateOrBorrow() public {
        imd.setCallback(address(bank), abi.encodeCall(bank.borrow, (address(usdc), 1e6, ALICE)));
        vm.startPrank(ALICE);
        imd.mint(ALICE, 1e18);
        vm.expectRevert();
        bank.supply(1e18, ALICE);
        vm.stopPrank();
        assertEq(bank.collateralBalance(ALICE), 1000e18);
    }
}
