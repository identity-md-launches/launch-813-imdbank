// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IExactERC20 {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @dev Optional-return ERC20 calls with exact sender AND recipient deltas. Rebases, taxes,
/// false returns and callbacks that perturb the transfer are unsupported and rejected.
library ExactToken {
    error InvalidToken();
    error TransferFailed();
    error InexactTransfer();

    function balance(address token, address account) internal view returns (uint256) {
        return IExactERC20(token).balanceOf(account);
    }

    function unit(address token) internal view returns (uint256) {
        if (token.code.length == 0) revert InvalidToken();
        uint8 decimals = IExactERC20(token).decimals();
        if (decimals > 18) revert InvalidToken();
        return 10 ** uint256(decimals);
    }

    function pull(address token, address from, uint256 amount) internal {
        _move(
            token,
            from,
            address(this),
            amount,
            abi.encodeWithSelector(bytes4(0x23b872dd), from, address(this), amount)
        );
    }

    function push(address token, address to, uint256 amount) internal {
        _move(token, address(this), to, amount, abi.encodeWithSelector(bytes4(0xa9059cbb), to, amount));
    }

    function _move(address token, address from, address to, uint256 amount, bytes memory data) private {
        if (from == to || from == address(0) || to == address(0)) revert InvalidToken();
        uint256 beforeFrom = balance(token, from);
        uint256 beforeTo = balance(token, to);
        (bool success, bytes memory result) = token.call(data);
        if (!success || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TransferFailed();
        }
        uint256 afterFrom = balance(token, from);
        uint256 afterTo = balance(token, to);
        if (
            beforeFrom < afterFrom || afterTo < beforeTo || beforeFrom - afterFrom != amount
                || afterTo - beforeTo != amount
        ) {
            revert InexactTransfer();
        }
    }
}
