// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BankFixture} from "./helpers/BankFixture.sol";
import {IMDBank} from "src/IMDBank.sol";
import {ExactToken} from "src/lib/ExactToken.sol";

/// @dev Models issuer switches, malformed return data and changes on either side of a transfer.
contract AdversarialTransferToken {
    enum Mode {
        Standard,
        NoReturn,
        FalseReturn,
        ShortReturn,
        ExtraReturn,
        InvalidBool,
        SenderSurcharge,
        ReceiverTax,
        SenderRefund,
        ReceiverBonus,
        Paused
    }
    uint8 public constant decimals = 18;
    Mode public mode;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setMode(Mode value) external {
        mode = value;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return _result();
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return _result();
    }

    function _move(address from, address to, uint256 amount) private {
        require(mode != Mode.Paused, "issuer paused");
        uint256 debit = amount;
        uint256 credit = amount;
        if (mode == Mode.SenderSurcharge) debit++;
        if (mode == Mode.ReceiverTax) credit--;
        if (mode == Mode.SenderRefund) debit--;
        if (mode == Mode.ReceiverBonus) credit++;
        balanceOf[from] -= debit;
        balanceOf[to] += credit;
        totalSupply = totalSupply + credit - debit;
    }

    function _result() private view returns (bool) {
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == Mode.ShortReturn) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 1)
            }
        }
        if (mode == Mode.ExtraReturn) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(32, 0)
                return(0, 64)
            }
        }
        if (mode == Mode.InvalidBool) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return mode != Mode.FalseReturn;
    }
}

contract ReentryProbe {
    IMDBank public immutable bank;
    bool public succeeded;
    bytes public result;
    uint256 public attempts;

    constructor(IMDBank bank_) {
        bank = bank_;
    }

    function attempt(bytes calldata data) external {
        attempts++;
        (succeeded, result) = address(bank).call(data);
    }
}

contract TokenBoundaryEdgesTest is BankFixture {
    function test_everyMutationRejectsCallbackReentryWithTheActualGuard() public {
        ReentryProbe probe = new ReentryProbe(bank);
        bytes[] memory calls = new bytes[](15);
        calls[0] = abi.encodeCall(bank.supply, (1, ALICE));
        calls[1] = abi.encodeCall(bank.setCollateralEnabled, (true));
        calls[2] = abi.encodeCall(bank.withdraw, (1, ALICE));
        calls[3] = abi.encodeCall(bank.borrow, (address(usdc), 1, ALICE));
        calls[4] = abi.encodeCall(bank.repay, (address(usdc), 1, ALICE));
        calls[5] = abi.encodeCall(bank.donateLiquidity, (address(usdc), 1));
        calls[6] = abi.encodeCall(bank.coverBadDebt, (address(usdc), 1));
        calls[7] = abi.encodeCall(bank.accrue, (address(usdc)));
        calls[8] = abi.encodeCall(bank.liquidate, (ALICE, address(usdc), 1, 0, block.timestamp));
        calls[9] = abi.encodeCall(bank.finalizeDust, (ALICE));
        calls[10] = abi.encodeCall(bank.configureRisk, (2500, 3500, 800, 5000, 1e30));
        calls[11] = abi.encodeCall(bank.configureReserve, (address(usdc), 1e30, 0, 0, 0, 8000));
        calls[12] = abi.encodeCall(bank.setFrozen, (true));
        calls[13] = abi.encodeCall(bank.setReserveFrozen, (address(usdc), true));
        calls[14] = abi.encodeCall(bank.setGuardian, (BOB));
        for (uint256 i; i < calls.length; ++i) {
            imd.setCallback(address(probe), abi.encodeCall(probe.attempt, (calls[i])));
            vm.prank(ALICE);
            bank.supply(1e18, ALICE);
            assertFalse(probe.succeeded());
            assertEq(probe.result(), abi.encodeWithSelector(IMDBank.Reentrancy.selector));
        }
        assertEq(probe.attempts(), 15);
        assertEq(bank.totalCollateral(), 15e18);
        assertEq(imd.balanceOf(address(bank)), 15e18);
        assertFalse(bank.frozen());
        assertEq(bank.guardian(), GUARDIAN);
    }

    function test_reentryGuardAlsoCoversOutgoingDebtRepaymentAndWithdrawal() public {
        _position(ALICE, 1000e18, 0);
        ReentryProbe probe = new ReentryProbe(bank);
        bytes memory payload =
            abi.encodeCall(probe.attempt, (abi.encodeCall(bank.setCollateralEnabled, (true))));
        usdc.setCallback(address(probe), payload);
        vm.startPrank(ALICE);
        bank.borrow(address(usdc), 100e6, ALICE);
        bank.repay(address(usdc), type(uint256).max, ALICE);
        vm.stopPrank();
        imd.setCallback(address(probe), payload);
        vm.prank(ALICE);
        bank.withdraw(1000e18, ALICE);
        assertEq(probe.attempts(), 3);
        assertFalse(probe.succeeded());
        assertEq(probe.result(), abi.encodeWithSelector(IMDBank.Reentrancy.selector));
        assertFalse(bank.collateralEnabled(address(probe)));
        assertEq(bank.totalCollateral(), 0);
    }

    function test_malformedAndInexactCollateralTransfersRollBackBothDirections() public {
        AdversarialTransferToken token = new AdversarialTransferToken();
        IMDBank target = new IMDBank(
            address(this),
            GUARDIAN,
            address(token),
            address(oracle),
            address(usdc),
            address(usdt),
            address(weth)
        );
        target.configureRisk(2500, 3500, 800, 5000, 1000e18);
        token.mint(ALICE, 1000e18);
        vm.startPrank(ALICE);
        token.approve(address(target), 1000e18);
        target.supply(100e18, ALICE);
        vm.stopPrank();
        for (uint256 i = 2; i <= 10; ++i) {
            token.setMode(AdversarialTransferToken.Mode(i));
            bytes32 beforeState = _state(token, target);
            vm.prank(ALICE);
            _expectTokenFailure(i);
            target.supply(10e18, ALICE);
            assertEq(
                _state(token, target), beforeState, "failed deposit changed custody, receipt, or allowance"
            );
            vm.prank(ALICE);
            _expectTokenFailure(i);
            target.withdraw(10e18, ALICE);
            assertEq(_state(token, target), beforeState, "failed withdrawal changed custody or receipt");
        }
        token.setMode(AdversarialTransferToken.Mode.NoReturn);
        vm.startPrank(ALICE);
        target.supply(10e18, ALICE);
        target.withdraw(110e18, ALICE);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 1000e18);
        assertEq(target.totalCollateral(), 0);
    }

    function test_malformedAndInexactDebtTransfersCannotCreateOrEraseDebt() public {
        AdversarialTransferToken token = new AdversarialTransferToken();
        IMDBank target = new IMDBank(
            address(this),
            GUARDIAN,
            address(imd),
            address(oracle),
            address(token),
            address(usdt),
            address(weth)
        );
        target.configureRisk(2500, 3500, 800, 5000, 1000e18);
        target.configureReserve(address(token), 1_000_000e18, 0, 0, 0, 8000);
        target.setFrozen(false);
        oracle.setPrice(address(token), 1e18);
        token.mint(address(this), 1_000_000e18);
        token.approve(address(target), type(uint256).max);
        target.donateLiquidity(address(token), 1_000_000e18);
        vm.startPrank(ALICE);
        imd.approve(address(target), type(uint256).max);
        token.approve(address(target), 1000e18);
        target.supply(1000e18, ALICE);
        target.setCollateralEnabled(true);
        target.borrow(address(token), 100e18, ALICE);
        vm.stopPrank();
        for (uint256 i = 2; i <= 10; ++i) {
            token.setMode(AdversarialTransferToken.Mode(i));
            bytes32 beforeState = _state(token, target);
            vm.prank(ALICE);
            _expectTokenFailure(i);
            target.borrow(address(token), 10e18, ALICE);
            assertEq(target.previewDebt(ALICE, address(token)), 100e18);
            assertEq(_state(token, target), beforeState);
            vm.prank(ALICE);
            _expectTokenFailure(i);
            target.repay(address(token), 10e18, ALICE);
            assertEq(target.previewDebt(ALICE, address(token)), 100e18);
            assertEq(_state(token, target), beforeState);
        }
        token.setMode(AdversarialTransferToken.Mode.NoReturn);
        vm.prank(ALICE);
        target.repay(address(token), type(uint256).max, ALICE);
        assertEq(target.previewDebt(ALICE, address(token)), 0);
        assertEq(token.balanceOf(address(target)), 1_000_000e18);
    }

    function _state(AdversarialTransferToken token, IMDBank target) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.balanceOf(ALICE),
                token.balanceOf(address(target)),
                token.allowance(ALICE, address(target)),
                token.totalSupply(),
                target.totalCollateral(),
                target.collateralBalance(ALICE)
            )
        );
    }

    function _expectTokenFailure(uint256 mode) private {
        if (mode >= 6 && mode <= 9) vm.expectRevert(ExactToken.InexactTransfer.selector);
        else if (mode == 5) vm.expectRevert(); // Solidity rejects the non-canonical ABI boolean before a library error.
        else vm.expectRevert(ExactToken.TransferFailed.selector);
    }
}
