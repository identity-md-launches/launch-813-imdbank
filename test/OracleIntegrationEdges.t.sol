// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BankFixture} from "./helpers/BankFixture.sol";
import {IMDBank} from "src/IMDBank.sol";
import {RiskOracle} from "src/RiskOracle.sol";

/// @dev Synthetic aggregator exposing timestamps independently, including upstream outages.
contract BoundaryFeed {
    uint8 public decimals = 8;
    int256 public answer;
    uint80 public round = 10;
    uint80 public answered = 10;
    uint256 public started;
    uint256 public updated;
    bool public unavailable;

    error UpstreamUnavailable();

    constructor(int256 value) {
        answer = value;
        started = block.timestamp;
        updated = block.timestamp;
    }

    function setAnswer(int256 value) external {
        answer = value;
    }

    function setDecimals(uint8 value) external {
        decimals = value;
    }

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function setRound(uint80 r, uint80 a, uint256 s, uint256 u) external {
        round = r;
        answered = a;
        started = s;
        updated = u;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (unavailable) revert UpstreamUnavailable();
        return (round, answer, started, updated, answered);
    }
}

contract OracleIntegrationEdgesTest is BankFixture {
    RiskOracle internal guarded;
    BoundaryFeed[4] internal primary;
    BoundaryFeed[4] internal secondary;

    function setUp() public override {
        super.setUp();
        guarded = new RiskOracle(address(this), GUARDIAN);
        address[4] memory tokens = [address(imd), address(usdc), address(usdt), address(weth)];
        int256[4] memory prices = [int256(10e8), int256(1e8), int256(1e8), int256(2000e8)];
        for (uint256 i; i < 4; ++i) {
            primary[i] = new BoundaryFeed(prices[i]);
            secondary[i] = new BoundaryFeed(prices[i]);
            guarded.configure(
                tokens[i],
                address(primary[i]),
                address(secondary[i]),
                60,
                120,
                1000,
                0.1e18,
                10_000e18,
                i == 0
            );
        }
        bank = new IMDBank(
            address(this),
            GUARDIAN,
            address(imd),
            address(guarded),
            address(usdc),
            address(usdt),
            address(weth)
        );
        bank.configureRisk(2500, 3500, 800, 5000, 1_000_000e18);
        _reserve(usdc, 1_000_000e6);
        _reserve(usdt, 1_000_000e6);
        _reserve(weth, 1000e18);
        bank.setFrozen(false);
        _fundUser(ALICE);
        _fundUser(BOB);
        _fundUser(LIQUIDATOR);
    }

    function test_eachSourceEnforcesItsOwnHeartbeatInclusively() public {
        uint256 t = vm.getBlockTimestamp();
        primary[0].setRound(10, 10, t - 60, t - 60);
        secondary[0].setRound(10, 10, t - 120, t - 120);
        assertEq(guarded.price(address(imd)), 10e18);
        primary[0].setRound(10, 10, t - 61, t - 61);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        guarded.price(address(imd));
        primary[0].setRound(10, 10, t, t);
        secondary[0].setRound(10, 10, t - 121, t - 121);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        guarded.price(address(imd));
    }

    function test_zeroRoundMissingStartAndStartAfterUpdateFailOnBothSources() public {
        uint256 t = vm.getBlockTimestamp();
        for (uint256 i; i < 2; ++i) {
            BoundaryFeed feed = i == 0 ? primary[0] : secondary[0];
            feed.setRound(0, 10, t, t);
            vm.expectRevert(RiskOracle.InvalidPrice.selector);
            guarded.price(address(imd));
            feed.setRound(10, 10, 0, t);
            vm.expectRevert(RiskOracle.InvalidPrice.selector);
            guarded.price(address(imd));
            feed.setRound(10, 10, t, t - 1);
            vm.expectRevert(RiskOracle.InvalidPrice.selector);
            guarded.price(address(imd));
            feed.setRound(10, 9, t, t);
            vm.expectRevert(RiskOracle.InvalidPrice.selector);
            guarded.price(address(imd));
            feed.setRound(10, 10, t, t);
        }
    }

    function test_extremeAnswerRejectedBeforeNormalizationCanOverflow() public {
        for (uint256 i; i < 2; ++i) {
            BoundaryFeed feed = i == 0 ? primary[0] : secondary[0];
            feed.setAnswer(type(int256).max);
            vm.expectRevert(RiskOracle.InvalidPrice.selector);
            guarded.price(address(imd));
            feed.setAnswer(type(int256).min);
            vm.expectRevert(RiskOracle.InvalidPrice.selector);
            guarded.price(address(imd));
            feed.setAnswer(10e8);
        }
    }

    function test_priceBandsRejectOvervaluationButAcceptCollateralCrash() public {
        guarded.configure(
            address(imd), address(primary[0]), address(secondary[0]), 60, 120, 1000, 9e18, 11e18, true
        );
        primary[0].setAnswer(9e8);
        secondary[0].setAnswer(9e8);
        assertEq(guarded.price(address(imd)), 9e18);
        primary[0].setAnswer(9e8 - 1);
        assertEq(guarded.price(address(imd)), 9e18 - 1e10);
        primary[0].setAnswer(11e8);
        secondary[0].setAnswer(11e8);
        assertEq(guarded.price(address(imd)), 11e18);
        secondary[0].setAnswer(11e8 + 1);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        guarded.price(address(imd));
    }

    function test_failedFeedReplacementPreservesOriginalPairAndConfiguration() public {
        BoundaryFeed bad = new BoundaryFeed(-1);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        guarded.configure(address(imd), address(bad), address(secondary[0]), 1, 1, 1, 1, 1e30, false);
        (
            address p,
            address s,
            uint256 min,
            uint256 max,
            uint32 ageP,
            uint32 ageS,
            uint16 deviation,,,
            bool collateralSide,
            bool enabled,
            uint64 pausedUntil
        ) = guarded.feeds(address(imd));
        assertEq(p, address(primary[0]));
        assertEq(s, address(secondary[0]));
        assertEq(min, 0.1e18);
        assertEq(max, 10_000e18);
        assertEq(ageP, 60);
        assertEq(ageS, 120);
        assertEq(deviation, 1000);
        assertTrue(collateralSide);
        assertTrue(enabled);
        assertEq(pausedUntil, 0);
        assertEq(guarded.price(address(imd)), 10e18);
    }

    function test_agreedCollateralCrashBelowConfiguredFloorStillLiquidates() public {
        guarded.configure(
            address(imd), address(primary[0]), address(secondary[0]), 60, 120, 1000, 5e18, 11e18, true
        );
        _position(ALICE, 1000e18, 2500e6);
        primary[0].setAnswer(4e8);
        secondary[0].setAnswer(4e8);
        assertEq(guarded.price(address(imd)), 4e18);
        (,,,, uint256 hf) = bank.accountData(ALICE);
        assertLt(hf, 1e18);
        uint256 cash = usdc.balanceOf(address(bank));
        uint256 recipient = imd.balanceOf(LIQUIDATOR);
        vm.prank(LIQUIDATOR);
        (uint256 paid, uint256 seized) = bank.liquidate(ALICE, address(usdc), 1000e6, 270e18, block.timestamp);
        assertEq(paid, 1000e6);
        assertEq(seized, 270e18);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 1500e6);
        assertEq(bank.collateralBalance(ALICE), 730e18);
        assertEq(usdc.balanceOf(address(bank)), cash + paid);
        assertEq(imd.balanceOf(LIQUIDATOR), recipient + seized);
    }

    function test_agreedDebtSpikeAboveConfiguredCeilingStillLiquidates() public {
        guarded.configure(
            address(usdc), address(primary[1]), address(secondary[1]), 60, 120, 1000, 0.5e18, 1.1e18, false
        );
        _position(ALICE, 1000e18, 2500e6);
        primary[1].setAnswer(2e8);
        secondary[1].setAnswer(2e8);
        assertEq(guarded.price(address(usdc)), 2e18);
        (, uint256 debt,,, uint256 hf) = bank.accountData(ALICE);
        assertEq(debt, 5000e18);
        assertLt(hf, 1e18);
        vm.prank(LIQUIDATOR);
        (uint256 paid, uint256 seized) = bank.liquidate(ALICE, address(usdc), 100e6, 21.6e18, block.timestamp);
        assertEq(paid, 100e6);
        assertEq(seized, 21.6e18);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 2400e6);
        assertEq(bank.collateralBalance(ALICE), 978.4e18);
    }

    function test_guardianPauseExpiresAndLiquidationResumesWhileBankFrozen() public {
        _position(ALICE, 1000e18, 2500e6);
        uint256 expiry = vm.getBlockTimestamp() + guarded.guardianPause();
        vm.startPrank(GUARDIAN);
        guarded.setEnabled(address(imd), false);
        bank.setFrozen(true);
        vm.expectRevert(RiskOracle.Unauthorized.selector);
        guarded.setEnabled(address(imd), false);
        vm.stopPrank();
        vm.prank(LIQUIDATOR);
        vm.expectRevert(RiskOracle.Disabled.selector);
        bank.liquidate(ALICE, address(usdc), 100e6, 0, block.timestamp);
        // Users can still add collateral and repay while pricing is paused.
        vm.startPrank(ALICE);
        bank.supply(1e18, ALICE);
        bank.repay(address(usdc), 1e6, ALICE);
        vm.stopPrank();
        assertEq(bank.previewDebt(ALICE, address(usdc)), 2499e6);

        vm.warp(expiry - 1);
        vm.expectRevert(RiskOracle.Disabled.selector);
        guarded.price(address(imd));
        vm.warp(expiry);
        // Fresh independent observations are still required at expiry.
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        guarded.price(address(imd));
        for (uint256 i; i < 4; ++i) {
            primary[i].setRound(11, 11, expiry, expiry);
            secondary[i].setRound(11, 11, expiry, expiry);
        }
        primary[0].setAnswer(4e8);
        secondary[0].setAnswer(4e8);
        vm.prank(GUARDIAN);
        vm.expectRevert(RiskOracle.Unauthorized.selector);
        guarded.setEnabled(address(imd), false);
        // Rotating the guardian also cannot replenish a consumed per-feed pause.
        address replacement = address(0xD00D);
        guarded.setGuardian(replacement);
        vm.prank(replacement);
        vm.expectRevert(RiskOracle.Unauthorized.selector);
        guarded.setEnabled(address(imd), false);

        uint256 beforeDebt = bank.previewDebt(ALICE, address(usdc));
        uint256 cash = usdc.balanceOf(address(bank));
        (uint256 quotedPaid, uint256 quotedSeized) = bank.previewLiquidation(ALICE, address(usdc), 100e6);
        vm.prank(LIQUIDATOR);
        (uint256 paid, uint256 seized) =
            bank.liquidate(ALICE, address(usdc), 100e6, quotedSeized, block.timestamp);
        assertEq(paid, quotedPaid);
        assertEq(seized, quotedSeized);
        assertGt(paid, 0);
        assertGt(seized, 0);
        assertEq(bank.previewDebt(ALICE, address(usdc)), beforeDebt - paid);
        assertEq(usdc.balanceOf(address(bank)), cash + paid);
        assertTrue(bank.frozen());
    }

    function test_brokenFeedCannotBeReenabledAndFailedEnableRemainsDisabled() public {
        vm.prank(GUARDIAN);
        guarded.setEnabled(address(imd), false);
        primary[0].setAnswer(0);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        guarded.setEnabled(address(imd), true);
        vm.expectRevert(RiskOracle.Disabled.selector);
        guarded.price(address(imd));
        (,,,,,,,,,, bool enabled, uint64 pausedUntil) = guarded.feeds(address(imd));
        assertTrue(enabled);
        assertEq(pausedUntil, vm.getBlockTimestamp() + guarded.guardianPause());
        primary[0].setAnswer(10e8);
        guarded.setEnabled(address(imd), true);
        (,,,,,,,,,,, pausedUntil) = guarded.feeds(address(imd));
        assertEq(pausedUntil, 0);
        assertEq(guarded.price(address(imd)), 10e18);
    }

    function test_bankRejectsStaleCollateralButAllowsOracleIndependentRescue() public {
        _position(ALICE, 1000e18, 1000e6);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.startPrank(ALICE);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        bank.borrow(address(usdc), 1, ALICE);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        bank.withdraw(1, ALICE);
        vm.stopPrank();
        vm.prank(LIQUIDATOR);
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        bank.liquidate(ALICE, address(usdc), 1e6, 0, block.timestamp);
        vm.startPrank(ALICE);
        bank.supply(1e18, ALICE);
        bank.repay(address(usdc), type(uint256).max, ALICE);
        bank.setCollateralEnabled(false);
        bank.withdraw(1001e18, ALICE);
        vm.stopPrank();
        assertEq(bank.totalCollateral(), 0);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 0);
    }

    function test_invalidExistingDebtFeedBlocksCrossReserveBorrowAndWithdrawal() public {
        _position(ALICE, 1000e18, 1000e6);
        primary[1].setUnavailable(true);
        vm.startPrank(ALICE);
        vm.expectRevert(BoundaryFeed.UpstreamUnavailable.selector);
        bank.borrow(address(weth), 0.1e18, ALICE);
        vm.expectRevert(BoundaryFeed.UpstreamUnavailable.selector);
        bank.withdraw(1, ALICE);
        assertEq(bank.previewDebt(ALICE, address(weth)), 0);
        assertEq(bank.collateralBalance(ALICE), 1000e18);
        bank.repay(address(usdc), type(uint256).max, ALICE);
        bank.borrow(address(weth), 0.1e18, ALICE);
        vm.stopPrank();
        assertEq(bank.previewDebt(ALICE, address(weth)), 0.1e18);
    }

    function test_oracleAgreementDoesNotAssumeStablecoinPegAndCanTriggerLiquidation() public {
        _position(ALICE, 1000e18, 2500e6);
        primary[1].setAnswer(1.5e8);
        secondary[1].setAnswer(1.55e8);
        (, uint256 debt,,, uint256 hf) = bank.accountData(ALICE);
        assertEq(debt, 3875e18);
        assertLt(hf, 1e18);
        uint256 beforeCash = usdc.balanceOf(address(bank));
        vm.prank(LIQUIDATOR);
        (uint256 paid, uint256 seized) = bank.liquidate(ALICE, address(usdc), 100e6, 0, block.timestamp);
        assertEq(paid, 100e6);
        assertGt(seized, 0);
        assertEq(usdc.balanceOf(address(bank)), beforeCash + paid);
        assertEq(bank.previewDebt(ALICE, address(usdc)), 2400e6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_decimalNormalizationAcrossFullSupportedRange(uint8 pdRaw, uint8 sdRaw, uint16 priceRaw)
        public
    {
        uint8 pd = uint8(bound(pdRaw, 0, 18));
        uint8 sd = uint8(bound(sdRaw, 0, 18));
        uint256 dollars = bound(priceRaw, 1, 1000);
        primary[0].setDecimals(pd);
        secondary[0].setDecimals(sd);
        primary[0].setAnswer(int256(dollars * 10 ** pd));
        secondary[0].setAnswer(int256(dollars * 10 ** sd));
        guarded.configure(
            address(imd), address(primary[0]), address(secondary[0]), 60, 120, 1000, 1, 10_000e18, true
        );
        assertEq(guarded.price(address(imd)), dollars * 1e18);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_deviationLimitAcceptsEqualityButRejectsOneWeiMore(uint16 raw) public {
        uint16 deviation = uint16(bound(raw, 1, 2000));
        primary[0].setDecimals(18);
        secondary[0].setDecimals(18);
        primary[0].setAnswer(1e18);
        uint256 high = 1e18 + uint256(deviation) * 1e14;
        secondary[0].setAnswer(int256(high));
        guarded.configure(
            address(imd), address(primary[0]), address(secondary[0]), 60, 120, deviation, 1, 2e18, true
        );
        assertEq(guarded.price(address(imd)), 1e18);
        secondary[0].setAnswer(int256(high + 1));
        vm.expectRevert(RiskOracle.InvalidPrice.selector);
        guarded.price(address(imd));
    }
}
