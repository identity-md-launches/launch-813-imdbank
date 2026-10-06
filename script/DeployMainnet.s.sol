// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GovernanceTimelock} from "../src/GovernanceTimelock.sol";
import {RiskOracle} from "../src/RiskOracle.sol";
import {IMDBank} from "../src/IMDBank.sol";

interface IDeploymentToken {
    function decimals() external view returns (uint8);
}

/// @notice Deterministic-parameter rehearsal helper. Does not broadcast or read wallet/environment data.
/// @dev The launch service deploys the three applications directly from their individual artifacts.
contract DeployMainnet {
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function deploy(address governanceMultisig, address emergencyMultisig)
        external
        returns (GovernanceTimelock timelock, RiskOracle oracle, IMDBank bank)
    {
        require(block.chainid == 1, "Ethereum Mainnet only");
        require(governanceMultisig != emergencyMultisig, "separate roles required");
        require(
            governanceMultisig.code.length > 0 && emergencyMultisig.code.length > 0,
            "multisig contracts required"
        );
        require(
            IDeploymentToken(IMD).decimals() == 18 && IDeploymentToken(USDC).decimals() == 6
                && IDeploymentToken(USDT).decimals() == 6 && IDeploymentToken(WETH).decimals() == 18,
            "unexpected token units"
        );
        timelock = new GovernanceTimelock(governanceMultisig, emergencyMultisig, 2 days);
        oracle = new RiskOracle(address(timelock), emergencyMultisig);
        bank = new IMDBank(address(timelock), emergencyMultisig, IMD, address(oracle), USDC, USDT, WETH);
        // Complete, intentionally inactive constructor state: no post-deploy initializer or owner handover.
        require(bank.supplyCap() == 0 && bank.frozen(), "activation gate violated");
    }
}
