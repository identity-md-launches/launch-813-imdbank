// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDBank} from "src/IMDBank.sol";
import {DeployMainnet} from "../script/DeployMainnet.s.sol";
import {MockOracle} from "./helpers/Mocks.sol";

interface IForkAsset {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Offline-safe fork extension using the existing deployment's asset addresses and pinned block.
/// These scenarios use synthetic IMD prices, not a production oracle or risk calibration.
contract OptionalMainnetTest is Test {
    IMDBank internal bank;
    MockOracle internal oracle;
    address internal imd;
    address[3] internal assets;
    address internal constant ALICE = address(0xA11CE);
    address internal constant LIQUIDATOR = address(0xCAFE);
    // Same funded account and block as the previously accepted test-fork/Mainnet.t.sol fixture.
    address internal constant IMD_HOLDER = 0xE54d6571aCa515614927F3A70B8957c2B511603C;

    function setUp() public {
        string memory rpc = vm.envOr("IMDBANK_TEST_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 26_134_012);
        assertEq(block.chainid, 1);
        assertEq(block.number, 26_134_012);
        DeployMainnet addresses = new DeployMainnet();
        imd = addresses.IMD();
        assets = [addresses.USDC(), addresses.USDT(), addresses.WETH()];
        assertEq(IForkAsset(imd).symbol(), "IMD");
        assertEq(IForkAsset(imd).decimals(), 18);
        assertEq(IForkAsset(assets[0]).symbol(), "USDC");
        assertEq(IForkAsset(assets[1]).symbol(), "USDT");
        assertEq(IForkAsset(assets[2]).symbol(), "WETH");
        oracle = new MockOracle();
        oracle.setPrice(imd, 10e18);
        bank = new IMDBank(
            address(this), address(0xBEEF), imd, address(oracle), assets[0], assets[1], assets[2]
        );
        bank.configureRisk(2500, 3500, 800, 5000, 100_000e18);
        bank.setFrozen(false);
        for (uint256 i; i < 3; ++i) {
            assertGt(assets[i].code.length, 0);
            assertEq(IForkAsset(assets[i]).decimals(), i == 2 ? 18 : 6);
            uint256 cash = i == 2 ? 100e18 : 100_000e6;
            oracle.setPrice(assets[i], i == 2 ? 2000e18 : 1e18);
            bank.configureReserve(assets[i], cash, 0.02e27, 0.08e27, 0.9e27, 8000);
            deal(assets[i], address(this), cash);
            _approve(assets[i], cash);
            bank.donateLiquidity(assets[i], cash);
        }
        vm.prank(IMD_HOLDER);
        assertTrue(IForkAsset(imd).transfer(ALICE, 1000e18));
        vm.prank(ALICE);
        _approve(imd, 1000e18);
    }

    function test_forkAccruedDebtThreeAssetRepaymentAndExit() public {
        vm.startPrank(ALICE);
        bank.supply(1000e18, ALICE);
        bank.setCollateralEnabled(true);
        bank.borrow(assets[0], 1000e6, ALICE);
        bank.borrow(assets[1], 500e6, ALICE);
        bank.borrow(assets[2], 0.1e18, ALICE);
        vm.expectRevert(IMDBank.UnsafePosition.selector);
        bank.withdraw(900e18, ALICE);
        vm.expectRevert(IMDBank.UnsafePosition.selector);
        bank.borrow(assets[0], 1000e6, ALICE);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256[3] memory principal = [uint256(1000e6), uint256(500e6), uint256(0.1e18)];
        for (uint256 i; i < 3; ++i) {
            uint256 debt = bank.previewDebt(ALICE, assets[i]);
            assertGt(debt, principal[i]);
            // Test-account funding only; this does not assume mainnet mint authority.
            deal(assets[i], ALICE, debt);
            uint256 cash = IForkAsset(assets[i]).balanceOf(address(bank));
            vm.startPrank(ALICE);
            _approve(assets[i], debt);
            assertEq(bank.repay(assets[i], type(uint256).max, ALICE), debt);
            vm.stopPrank();
            assertEq(bank.previewDebt(ALICE, assets[i]), 0);
            assertEq(IForkAsset(assets[i]).balanceOf(address(bank)), cash + debt);
        }
        vm.startPrank(ALICE);
        bank.setCollateralEnabled(false);
        bank.withdraw(1000e18, ALICE);
        vm.stopPrank();
        assertEq(bank.totalCollateral(), 0);
        assertEq(IForkAsset(imd).balanceOf(ALICE), 1000e18);
    }

    function test_forkCollateralExhaustionAndActualTokenRecapitalization() public {
        vm.startPrank(ALICE);
        bank.supply(1000e18, ALICE);
        bank.setCollateralEnabled(true);
        bank.borrow(assets[0], 2500e6, ALICE);
        vm.stopPrank();
        oracle.setPrice(imd, 2e18);
        deal(assets[0], LIQUIDATOR, 3000e6);
        vm.startPrank(LIQUIDATOR);
        _approve(assets[0], 3000e6);
        (uint256 paid, uint256 seized) =
            bank.liquidate(ALICE, assets[0], type(uint256).max, 1000e18, block.timestamp);
        vm.stopPrank();
        assertEq(seized, 1000e18);
        assertEq(IForkAsset(imd).balanceOf(LIQUIDATOR), seized);
        assertEq(bank.previewDebt(ALICE, assets[0]), 0);
        (,,,,, uint256 loss,) = bank.reserveData(assets[0]);
        assertEq(loss, 2500e6 - paid);
        assertTrue(bank.frozen());
        vm.expectRevert(IMDBank.OutstandingBadDebt.selector);
        bank.setFrozen(false);
        vm.prank(LIQUIDATOR);
        bank.coverBadDebt(assets[0], loss);
        bank.setReserveFrozen(assets[0], false);
        bank.setFrozen(false);
        assertFalse(bank.frozen());
        assertEq(IForkAsset(assets[0]).balanceOf(address(bank)), 100_000e6);
    }

    function _approve(address asset, uint256 amount) private {
        (bool ok, bytes memory data) =
            asset.call(abi.encodeWithSelector(bytes4(0x095ea7b3), address(bank), amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "fork approval failed");
    }
}
