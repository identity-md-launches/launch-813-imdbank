// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDBank} from "../src/IMDBank.sol";
import {MockOracle} from "../test/helpers/Mocks.sol";
import {IAggregator} from "../src/RiskOracle.sol";

interface IMainnetToken {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Run using the fork profile and an externally supplied fork URL. Never silently skips.
/// Canonical asset transfers use actual mainnet code; IMD valuation is an explicit test double.
contract MainnetIntegrationTest is Test {
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant IMD_HOLDER = 0xE54d6571aCa515614927F3A70B8957c2B511603C;
    address constant ALICE = address(0xA11CE);
    address constant LIQUIDATOR = address(0xCAFE);
    IMDBank bank;
    MockOracle oracle;

    function setUp() public {
        require(block.chainid == 1 && block.number == 26_134_012, "requires pinned Ethereum Mainnet fork");
        assertGt(IMD.code.length, 0);
        assertGt(USDC.code.length, 0);
        assertGt(USDT.code.length, 0);
        assertGt(WETH.code.length, 0);
        assertEq(IMainnetToken(IMD).symbol(), "IMD");
        assertEq(IMainnetToken(USDC).decimals(), 6);
        assertEq(IMainnetToken(USDT).decimals(), 6);
        assertEq(IMainnetToken(WETH).decimals(), 18);
        assertEq(IMainnetToken(IMD).decimals(), 18);
        oracle = new MockOracle();
        oracle.setPrice(IMD, 10e18);
        oracle.setPrice(USDC, 1e18);
        oracle.setPrice(USDT, 1e18);
        oracle.setPrice(WETH, 2000e18);
        bank = new IMDBank(address(this), address(0xBEEF), IMD, address(oracle), USDC, USDT, WETH);
        bank.configureRisk(2500, 3500, 800, 5000, 100_000e18);
        bank.setFrozen(false);
        _fund(USDC, 100_000e6);
        _fund(USDT, 100_000e6);
        _fund(WETH, 100e18);
        vm.prank(IMD_HOLDER);
        require(IMainnetToken(IMD).transfer(ALICE, 1000e18));
        vm.prank(ALICE);
        require(IMainnetToken(IMD).approve(address(bank), 1000e18));
        deal(USDC, LIQUIDATOR, 100_000e6);
        vm.prank(LIQUIDATOR);
        require(IMainnetToken(USDC).approve(address(bank), 100_000e6));
    }

    function _fund(address asset, uint256 amount) internal {
        // Storage deal is limited to fork test accounts; no issuance assumption is made about mainnet.
        deal(asset, address(this), amount);
        _approve(asset, address(bank), amount);
        bank.configureReserve(asset, amount, 0.02e27, 0.08e27, 0.9e27, 8000);
        bank.donateLiquidity(asset, amount);
    }

    function _approve(address asset, address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            asset.call(abi.encodeWithSelector(IMainnetToken.approve.selector, spender, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "approval failed");
    }

    function test_actualAssetsFullLifecycleAndUnsafeRejection() public {
        vm.startPrank(ALICE);
        bank.supply(1000e18, ALICE);
        bank.setCollateralEnabled(true);
        bank.borrow(USDC, 1000e6, ALICE);
        bank.borrow(USDT, 500e6, ALICE);
        bank.borrow(WETH, 0.1e18, ALICE);
        assertEq(IMainnetToken(USDT).balanceOf(ALICE), 500e6);
        vm.expectRevert();
        bank.withdraw(900e18, ALICE);
        vm.expectRevert();
        bank.borrow(USDC, 2000e6, ALICE);
        _approve(USDC, address(bank), 1000e6);
        _approve(USDT, address(bank), 500e6);
        _approve(WETH, address(bank), 0.1e18);
        bank.repay(USDC, 1000e6, ALICE);
        bank.repay(USDT, 500e6, ALICE);
        bank.repay(WETH, 0.1e18, ALICE);
        bank.setCollateralEnabled(false);
        bank.withdraw(1000e18, ALICE);
        vm.stopPrank();
        assertEq(bank.collateralBalance(ALICE), 0);
        assertEq(IMainnetToken(IMD).balanceOf(ALICE), 1000e18);
        assertEq(bank.previewDebt(ALICE, USDC), 0);
        assertEq(bank.previewDebt(ALICE, USDT), 0);
        assertEq(bank.previewDebt(ALICE, WETH), 0);
    }

    function test_oracleShockLiquidationAndBadDebtAccounting() public {
        vm.startPrank(ALICE);
        bank.supply(1000e18, ALICE);
        bank.setCollateralEnabled(true);
        bank.borrow(USDC, 2500e6, ALICE);
        vm.stopPrank();
        (,,,, uint256 beforeHf) = bank.accountData(ALICE);
        assertGt(beforeHf, 1e18);
        oracle.setPrice(IMD, 2e18);
        (,,,, uint256 afterHf) = bank.accountData(ALICE);
        assertLt(afterHf, 1e18);
        (uint256 paid, uint256 seized) = bank.previewLiquidation(ALICE, USDC, type(uint256).max);
        assertGt(paid, 0);
        assertEq(seized, 1000e18);
        vm.prank(LIQUIDATOR);
        bank.liquidate(ALICE, USDC, type(uint256).max, seized, block.timestamp);
        assertEq(bank.collateralBalance(ALICE), 0);
        assertEq(bank.previewDebt(ALICE, USDC), 0);
        (,,,,, uint256 badDebt, bool frozen) = bank.reserveData(USDC);
        assertEq(badDebt, 2500e6 - paid);
        assertTrue(frozen);
        assertEq(IMainnetToken(IMD).balanceOf(LIQUIDATOR), seized);
    }

    function test_realChainlinkRoundSanityAtPinnedBlock() public view {
        address[3] memory feeds = [
            address(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6),
            address(0x3E7d1eAB13ad0104d2750B8863b489D65364e32D),
            address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
        ];
        uint256[3] memory maximumAge = [uint256(86400), uint256(86400), uint256(3600)];
        for (uint256 i; i < 3; ++i) {
            (uint80 round, int256 answer,, uint256 updated, uint80 answered) =
                IAggregator(feeds[i]).latestRoundData();
            assertGt(answer, 0);
            assertGe(answered, round);
            assertLe(updated, block.timestamp);
            assertLe(block.timestamp - updated, maximumAge[i]);
            assertEq(IAggregator(feeds[i]).decimals(), 8);
        }
    }
}
