// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BankFixture} from "./helpers/BankFixture.sol";
import {MockToken, MockOracle} from "./helpers/Mocks.sol";
import {IMDBank} from "src/IMDBank.sol";

/// @notice Independent cash/claim ledgers; only successful actions update ghost accounting.
/// Expected protocol errors are checked explicitly. Harness panics and unexpected reverts fail the run.
contract ThreeReserveHandler is Test {
    IMDBank public immutable bank;
    MockToken public immutable imd;
    MockOracle public immutable oracle;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE)];
    uint256[3] public expectedCash;
    uint256[3] public expectedLoss;
    uint256[3] public expectedCollateral;
    uint256 public donatedCollateral;
    uint256[10] public successes;

    constructor(IMDBank b, MockToken c, MockOracle o) {
        bank = b;
        imd = c;
        oracle = o;
        for (uint256 i; i < 3; ++i) {
            MockToken token = MockToken(bank.assets(i));
            expectedCash[i] = token.balanceOf(address(bank));
            token.approve(address(bank), type(uint256).max);
        }
    }

    function supply(uint8 payerRaw, uint8 ownerRaw, uint96 amountRaw) public {
        uint256 owner = ownerRaw % 3;
        address payer = actors[payerRaw % 3];
        uint256 amount = bound(amountRaw, 1, 1000e18);
        imd.mint(payer, amount);
        bool enabledBefore = bank.collateralEnabled(actors[owner]);
        vm.prank(payer);
        bank.supply(amount, actors[owner]);
        expectedCollateral[owner] += amount;
        assertEq(bank.collateralEnabled(actors[owner]), enabledBefore, "sponsor changed collateral consent");
        vm.prank(actors[owner]);
        bank.setCollateralEnabled(true);
        successes[0]++;
    }

    function borrow(uint8 actorRaw, uint8 assetRaw, uint96 amountRaw) public {
        uint256 i = assetRaw % 3;
        address actor = actors[actorRaw % 3];
        address recipient = actors[(uint256(actorRaw) + 1) % 3];
        MockToken token = MockToken(bank.assets(i));
        uint256 amount = bound(amountRaw, 1, i == 2 ? 0.1e18 : 500e6);
        uint256 beforeDebt = bank.previewDebt(actor, address(token));
        uint256 receivedBefore = token.balanceOf(recipient);
        vm.prank(actor);
        try bank.borrow(address(token), amount, recipient) {
            expectedCash[i] -= amount;
            assertEq(token.balanceOf(recipient), receivedBefore + amount, "borrow transfer/fee mismatch");
            assertGe(bank.previewDebt(actor, address(token)), beforeDebt + amount);
            (, uint256 debt, uint256 capacity,,) = bank.accountData(actor);
            assertLe(debt, capacity, "borrow crossed LTV");
            successes[1]++;
        } catch (bytes memory reason) {
            bytes4 error = _selector(reason);
            assertTrue(
                error == IMDBank.Frozen.selector || error == IMDBank.UnsafePosition.selector
                    || error == IMDBank.CapExceeded.selector
                    || error == IMDBank.InsufficientLiquidity.selector,
                "unexpected borrow error"
            );
            assertEq(bank.previewDebt(actor, address(token)), beforeDebt, "failed borrow changed debt");
        }
    }

    function repay(uint8 actorRaw, uint8 assetRaw, uint96 raw, bool full) public {
        uint256 i = assetRaw % 3;
        address actor = actors[actorRaw % 3];
        MockToken token = MockToken(bank.assets(i));
        uint256 debt = bank.previewDebt(actor, address(token));
        uint256 budget = full ? type(uint256).max : bound(raw, 1, debt == 0 ? 1 : debt);
        token.mint(address(this), debt);
        uint256 beforeBalance = token.balanceOf(address(this));
        try bank.repay(address(token), budget, actor) returns (uint256 paid) {
            expectedCash[i] += paid;
            assertGt(paid, 0);
            assertLe(paid, budget);
            assertEq(debt - bank.previewDebt(actor, address(token)), paid, "debt erased without payment");
            assertEq(token.balanceOf(address(this)), beforeBalance - paid);
            if (full) assertEq(bank.debtShares(actor, address(token)), 0);
            successes[2]++;
        } catch (bytes memory reason) {
            assertEq(_selector(reason), IMDBank.Dust.selector);
            assertEq(bank.previewDebt(actor, address(token)), debt);
        }
    }

    function withdraw(uint8 actorRaw, uint96 raw, bool full) public {
        uint256 a = actorRaw % 3;
        uint256 claim = expectedCollateral[a];
        if (claim == 0) return;
        uint256 amount = full ? claim : bound(raw, 1, claim);
        address actor = actors[a];
        uint256 wallet = imd.balanceOf(actor);
        vm.prank(actor);
        try bank.withdraw(amount, actor) {
            expectedCollateral[a] -= amount;
            assertEq(imd.balanceOf(actor), wallet + amount);
            (, uint256 debt, uint256 capacity,,) = bank.accountData(actor);
            assertLe(debt, capacity);
            successes[3]++;
        } catch (bytes memory reason) {
            bytes4 error = _selector(reason);
            assertTrue(error == IMDBank.Frozen.selector || error == IMDBank.UnsafePosition.selector);
            assertEq(imd.balanceOf(actor), wallet);
            assertEq(bank.collateralBalance(actor), claim);
        }
    }

    function donate(uint8 assetRaw, uint96 raw, bool direct) public {
        uint256 i = assetRaw % 4;
        uint256 amount = bound(raw, 1, i >= 2 ? 1e18 : 1000e6);
        MockToken token = i == 3 ? imd : MockToken(bank.assets(i));
        token.mint(address(this), amount);
        if (direct || i == 3) token.transfer(address(bank), amount);
        else bank.donateLiquidity(address(token), amount);
        if (i == 3) donatedCollateral += amount;
        else expectedCash[i] += amount;
        successes[4]++;
    }

    function elapse(uint32 raw) public {
        uint256[3] memory previousIndex;
        for (uint256 i; i < 3; ++i) {
            (,, previousIndex[i],,,,) = bank.reserveData(bank.assets(i));
        }
        vm.warp(vm.getBlockTimestamp() + bound(raw, 0, 30 days));
        for (uint256 i; i < 3; ++i) {
            address asset = bank.assets(i);
            (,, uint256 preview,,,,) = bank.reserveData(asset);
            bank.accrue(asset);
            (,, uint256 stored,,,,) = bank.reserveData(asset);
            assertEq(stored, preview, "checkpoint differs from preview");
            assertGe(stored, previousIndex[i], "interest index decreased");
        }
        successes[5]++;
    }

    function shock(uint8 assetRaw, uint96 raw) public {
        uint256 i = assetRaw % 4;
        address asset = i == 3 ? address(imd) : bank.assets(i);
        uint256 low = i == 2 ? 500e18 : (i == 3 ? 1 : 0.5e18);
        uint256 high = i == 2 ? 6000e18 : (i == 3 ? 20e18 : 2e18);
        oracle.setPrice(asset, bound(raw, low, high));
    }

    function liquidate(uint8 actorRaw, uint8 assetRaw, uint96 budgetRaw) public {
        uint256 a = actorRaw % 3;
        uint256 i = assetRaw % 3;
        address actor = actors[a];
        address asset = bank.assets(i);
        uint256[3] memory debts = _debts(actor);
        uint256 budget = bound(budgetRaw, 1, debts[i] == 0 ? 1 : debts[i]);
        MockToken(asset).mint(address(this), debts[i]);
        uint256 payerBefore = MockToken(asset).balanceOf(address(this));
        uint256 collateralBefore = imd.balanceOf(address(this));
        // Check a successful preview against execution without advancing time or changing feeds.
        try bank.previewLiquidation(actor, asset, budget) returns (uint256 quotedPaid, uint256 quotedSeized) {
            (uint256 paid, uint256 seized) =
                bank.liquidate(actor, asset, budget, quotedSeized, block.timestamp);
            assertEq(paid, quotedPaid);
            assertEq(seized, quotedSeized);
            assertGt(paid, 0);
            assertGt(seized, 0);
            assertLe(paid, budget);
            assertLe(seized, expectedCollateral[a]);
            assertEq(MockToken(asset).balanceOf(address(this)), payerBefore - paid);
            assertEq(imd.balanceOf(address(this)), collateralBefore + seized);
            expectedCash[i] += paid;
            expectedCollateral[a] -= seized;
            debts[i] -= paid;
            _checkRemainingDebt(a, debts);
            successes[6]++;
        } catch (bytes memory reason) {
            bytes4 error = _selector(reason);
            assertTrue(error == IMDBank.HealthyPosition.selector || error == IMDBank.Dust.selector);
        }
    }

    function finalizeDust(uint8 actorRaw) public {
        uint256 a = actorRaw % 3;
        uint256[3] memory debts = _debts(actors[a]);
        uint256 beforeBalance = imd.balanceOf(address(this));
        try bank.finalizeDust(actors[a]) {
            assertEq(imd.balanceOf(address(this)), beforeBalance + expectedCollateral[a]);
            expectedCollateral[a] = 0;
            _checkRemainingDebt(a, debts);
            successes[7]++;
        } catch (bytes memory reason) {
            bytes4 error = _selector(reason);
            assertTrue(error == IMDBank.HealthyPosition.selector || error == IMDBank.InvalidAmount.selector);
        }
    }

    function recovery(uint8 assetRaw, uint96 raw, bool full) public {
        uint256 i = assetRaw % 3;
        address asset = bank.assets(i);
        if (expectedLoss[i] > 0) {
            uint256 amount = full ? expectedLoss[i] : bound(raw, 1, expectedLoss[i]);
            MockToken(asset).mint(address(this), amount);
            bank.coverBadDebt(asset, amount);
            expectedCash[i] += amount;
            expectedLoss[i] -= amount;
        }
        address governor = bank.governor();
        if (expectedLoss[i] == 0) {
            vm.prank(governor);
            bank.setReserveFrozen(asset, false);
        }
        if (expectedLoss[0] + expectedLoss[1] + expectedLoss[2] == 0) {
            vm.prank(governor);
            bank.setFrozen(false);
        }
        successes[8]++;
    }

    function toggle(uint8 actorRaw, bool enabled, bool freeze) public {
        address actor = actors[actorRaw % 3];
        vm.prank(actor);
        try bank.setCollateralEnabled(enabled) {
            if (!enabled) {
                uint256[3] memory debts = _debts(actor);
                assertEq(debts[0] + debts[1] + debts[2], 0);
            }
        } catch (bytes memory reason) {
            assertFalse(enabled);
            assertEq(_selector(reason), IMDBank.UnsafePosition.selector);
        }
        if (freeze) {
            address guardian = bank.guardian();
            vm.prank(guardian);
            bank.setFrozen(true);
        }
        successes[9]++;
    }

    function _debts(address actor) private view returns (uint256[3] memory debts) {
        for (uint256 i; i < 3; ++i) {
            debts[i] = bank.previewDebt(actor, bank.assets(i));
        }
    }

    function _checkRemainingDebt(uint256 a, uint256[3] memory debts) private {
        for (uint256 i; i < 3; ++i) {
            if (expectedCollateral[a] == 0) {
                expectedLoss[i] += debts[i];
                assertEq(bank.debtShares(actors[a], bank.assets(i)), 0, "exhaustion left hidden debt");
            } else {
                assertEq(
                    bank.previewDebt(actors[a], bank.assets(i)), debts[i], "liquidation erased excess debt"
                );
            }
        }
    }

    function _selector(bytes memory reason) private pure returns (bytes4 result) {
        if (reason.length >= 4) {
            assembly ("memory-safe") { result := mload(add(reason, 32)) }
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract ThreeReserveInvariantTest is BankFixture {
    ThreeReserveHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ThreeReserveHandler(bank, imd, oracle);
        for (uint8 a; a < 3; ++a) {
            handler.supply(a, a, 1000e18);
            for (uint8 i; i < 3; ++i) {
                handler.borrow(a, i, i == 2 ? uint96(0.1e18) : uint96(100e6));
            }
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.supply.selector;
        selectors[1] = handler.borrow.selector;
        selectors[2] = handler.repay.selector;
        selectors[3] = handler.withdraw.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.elapse.selector;
        selectors[6] = handler.shock.selector;
        selectors[7] = handler.liquidate.selector;
        selectors[8] = handler.finalizeDust.selector;
        selectors[9] = handler.recovery.selector;
        selectors[10] = handler.toggle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_allReserveCashClaimsLossesAndRoundingAreAccountedFor() public view {
        uint256 claims;
        for (uint256 a; a < 3; ++a) {
            address actor = handler.actors(a);
            uint256 expected = handler.expectedCollateral(a);
            assertEq(bank.collateralBalance(actor), expected, "claim differs from external flow ledger");
            claims += expected;
            if (!bank.collateralEnabled(actor) || expected == 0) {
                for (uint256 i; i < 3; ++i) {
                    assertEq(bank.debtShares(actor, bank.assets(i)), 0);
                }
            }
        }
        assertEq(bank.totalCollateral(), claims);
        assertEq(imd.balanceOf(address(bank)), claims + handler.donatedCollateral());
        for (uint256 i; i < 3; ++i) {
            address asset = bank.assets(i);
            (uint256 cash, uint256 totalDebt, uint256 index, uint256 rate,, uint256 loss, bool isFrozen) =
                bank.reserveData(asset);
            assertEq(cash, handler.expectedCash(i), "reserve cash differs from external flow ledger");
            assertEq(loss, handler.expectedLoss(i), "writeoff/recapitalization mismatch");
            uint256 userDebt;
            for (uint256 a; a < 3; ++a) {
                userDebt += bank.previewDebt(handler.actors(a), asset);
            }
            assertGe(userDebt, totalDebt);
            assertLe(userDebt - totalDebt, 2, "aggregate debt rounding exceeds one unit per actor");
            assertGe(index, 1e27);
            assertLe(index, 1e36);
            assertLe(rate, 1e27);
            if (loss != 0) {
                assertTrue(bank.frozen());
                assertTrue(isFrozen);
            }
        }
        assertGe(handler.successes(0), 3, "unseeded collateral campaign");
        assertGe(handler.successes(1), 9, "unseeded debt campaign");
    }

    function test_handlerReachesLiquidationWriteoffRecoveryAndExit() public {
        handler.elapse(1 days);
        handler.shock(3, 1e18);
        handler.liquidate(0, 0, type(uint96).max);
        assertGt(handler.successes(6), 0);
        handler.shock(3, 1);
        handler.finalizeDust(1);
        assertEq(handler.successes(7), 1);
        for (uint8 i; i < 3; ++i) {
            handler.recovery(i, 0, true);
        }
        handler.shock(3, 10e18);
        for (uint8 a; a < 3; ++a) {
            for (uint8 i; i < 3; ++i) {
                handler.repay(a, i, 0, true);
            }
            handler.withdraw(a, 0, true);
        }
        invariant_allReserveCashClaimsLossesAndRoundingAreAccountedFor();
        assertEq(bank.totalCollateral(), 0);
        assertEq(handler.successes(8), 3);
        assertGt(handler.successes(2), 0);
        assertGt(handler.successes(3), 0);
    }

    function afterInvariant() public {
        // Every sequence must unwind all user claims, even after freezes or price collapses.
        for (uint8 a; a < 3; ++a) {
            for (uint8 i; i < 3; ++i) {
                handler.repay(a, i, 0, true);
            }
            handler.withdraw(a, 0, true);
        }
        invariant_allReserveCashClaimsLossesAndRoundingAreAccountedFor();
        assertEq(bank.totalCollateral(), 0, "debt-free exit is not live");
    }
}
