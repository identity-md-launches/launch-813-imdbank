// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDBank} from "../../src/IMDBank.sol";
import {MockToken, MockOracle} from "./Mocks.sol";

abstract contract BankFixture is Test {
    IMDBank internal bank;
    MockToken internal imd;
    MockToken internal usdc;
    MockToken internal usdt;
    MockToken internal weth;
    MockOracle internal oracle;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant GUARDIAN = address(0xBEEF);
    address internal constant LIQUIDATOR = address(0xCAFE);

    function setUp() public virtual {
        vm.warp(100 days);
        imd = new MockToken(18);
        usdc = new MockToken(6);
        usdt = new MockToken(6);
        weth = new MockToken(18);
        oracle = new MockOracle();
        oracle.setPrice(address(imd), 10e18);
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(usdt), 1e18);
        oracle.setPrice(address(weth), 2000e18);
        bank = new IMDBank(
            address(this),
            GUARDIAN,
            address(imd),
            address(oracle),
            address(usdc),
            address(usdt),
            address(weth)
        );
        bank.configureRisk(2500, 3500, 800, 5000, 1_000_000e18);
        _reserve(usdc, 1_000_000e6);
        _reserve(usdt, 1_000_000e6);
        _reserve(weth, 1_000e18);
        bank.setFrozen(false);
        _fundUser(ALICE);
        _fundUser(BOB);
        _fundUser(LIQUIDATOR);
    }

    function _reserve(MockToken token, uint256 amount) internal {
        bank.configureReserve(address(token), amount, 0.02e27, 0.08e27, 0.9e27, 8000);
        bank.setReserveFrozen(address(token), false);
        token.mint(address(this), amount);
        token.approve(address(bank), amount);
        bank.donateLiquidity(address(token), amount);
    }

    function _fundUser(address user) internal {
        imd.mint(user, 10_000e18);
        usdc.mint(user, 1_000_000e6);
        usdt.mint(user, 1_000_000e6);
        weth.mint(user, 1_000e18);
        vm.startPrank(user);
        imd.approve(address(bank), type(uint256).max);
        usdc.approve(address(bank), type(uint256).max);
        usdt.approve(address(bank), type(uint256).max);
        weth.approve(address(bank), type(uint256).max);
        vm.stopPrank();
    }

    function _position(address user, uint256 supply, uint256 borrow) internal {
        vm.startPrank(user);
        bank.supply(supply, user);
        bank.setCollateralEnabled(true);
        if (borrow != 0) bank.borrow(address(usdc), borrow, user);
        vm.stopPrank();
    }
}
