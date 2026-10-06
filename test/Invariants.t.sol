// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BankFixture} from "./helpers/BankFixture.sol";
import {MockToken, MockOracle} from "./helpers/Mocks.sol";
import {IMDBank} from "../src/IMDBank.sol";

contract BankHandler is Test {
    IMDBank public bank;
    MockToken public imd;
    MockToken public usdc;
    MockOracle public oracle;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE)];
    uint256 public borrowed;
    uint256 public repaid;
    uint256 public donated;
    uint256 public successfulActions;

    constructor(IMDBank b, MockToken c, MockToken d, MockOracle o) {
        bank = b;
        imd = c;
        usdc = d;
        oracle = o;
    }

    function supply(uint8 raw, uint96 amountRaw) external {
        address actor = actors[raw % 3];
        uint256 balance = imd.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(uint256(amountRaw), 1, balance);
        vm.prank(actor);
        try bank.supply(amount, actor) {
            successfulActions++;
        } catch {}
        vm.prank(actor);
        bank.setCollateralEnabled(true);
    }

    function borrow(uint8 raw, uint64 amountRaw) external {
        address actor = actors[raw % 3];
        uint256 amount = bound(uint256(amountRaw), 1, 10_000e6);
        vm.prank(actor);
        try bank.borrow(address(usdc), amount, actor) {
            borrowed += amount;
            successfulActions++;
        } catch {}
    }

    function repay(uint8 raw, uint64 amountRaw) external {
        address actor = actors[raw % 3];
        uint256 amount = bound(uint256(amountRaw), 1, 100_000e6);
        vm.prank(actor);
        try bank.repay(address(usdc), amount, actor) returns (uint256 paid) {
            repaid += paid;
            successfulActions++;
        } catch {}
    }

    function withdraw(uint8 raw, uint96 amountRaw) external {
        address actor = actors[raw % 3];
        uint256 amount = bound(uint256(amountRaw), 1, 10_000e18);
        vm.prank(actor);
        try bank.withdraw(amount, actor) {
            successfulActions++;
        } catch {}
    }

    function donate(uint64 amountRaw) external {
        uint256 amount = bound(uint256(amountRaw), 1, 1000e6);
        usdc.mint(address(this), amount);
        usdc.approve(address(bank), amount);
        bank.donateLiquidity(address(usdc), amount);
        donated += amount;
        successfulActions++;
    }

    function elapse(uint32 durationRaw) external {
        vm.warp(block.timestamp + bound(uint256(durationRaw), 0, 30 days));
        bank.accrue(address(usdc));
        successfulActions++;
    }

    function shockAndLiquidate(uint8 raw, uint64 priceRaw) external {
        uint256 p = bound(uint256(priceRaw), 1, 20e18);
        oracle.setPrice(address(imd), p);
        address actor = actors[raw % 3];
        address liquidator = actors[(raw + uint16(1)) % 3];
        vm.prank(liquidator);
        try bank.liquidate(actor, address(usdc), type(uint256).max, 0, block.timestamp) returns (
            uint256 paid, uint256
        ) {
            repaid += paid;
            successfulActions++;
        } catch {}
    }
}

contract BankInvariantTest is BankFixture {
    BankHandler handler;
    uint256 initialCash;

    function setUp() public override {
        super.setUp();
        initialCash = usdc.balanceOf(address(bank));
        handler = new BankHandler(bank, imd, usdc, oracle);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.supply.selector;
        selectors[1] = handler.borrow.selector;
        selectors[2] = handler.repay.selector;
        selectors[3] = handler.withdraw.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.elapse.selector;
        selectors[6] = handler.shockAndLiquidate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_collateralConservation() public view {
        uint256 claims =
            bank.collateralBalance(ALICE) + bank.collateralBalance(BOB) + bank.collateralBalance(LIQUIDATOR);
        assertEq(bank.totalCollateral(), claims);
        assertEq(imd.balanceOf(address(bank)), claims);
    }

    function invariant_cashFlowConservation() public view {
        assertEq(
            usdc.balanceOf(address(bank)),
            initialCash + handler.repaid() + handler.donated() - handler.borrowed()
        );
    }

    function invariant_debtSharesAndAggregateRounding() public view {
        uint256 total = bank.previewDebt(ALICE, address(usdc)) + bank.previewDebt(BOB, address(usdc))
            + bank.previewDebt(LIQUIDATOR, address(usdc));
        (, uint256 aggregate, uint256 index,,,,) = bank.reserveData(address(usdc));
        assertGe(total, aggregate);
        assertLe(total - aggregate, 2);
        assertGe(index, 1e27);
        assertLe(index, 1e36);
        (,,,,, uint256 badDebt, bool reserveFrozen) = bank.reserveData(address(usdc));
        // USDC is pinned at $1 in this fixture: a loss above the halt threshold must freeze everything.
        if (badDebt * 1e12 > bank.LOSS_FREEZE_USD()) {
            assertTrue(bank.frozen());
            assertTrue(reserveFrozen);
            assertTrue(bank.lossHalted(address(usdc)));
        }
        if (badDebt == 0) assertFalse(bank.lossHalted(address(usdc)));
    }
}
