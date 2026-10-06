// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IAggregator {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Two-source USD oracle. Governance must verify source independence off chain.
/// @dev Unconfigured/disabled/invalid feeds revert. There is deliberately no manual price fallback.
contract RiskOracle {
    struct Feed {
        address primary;
        address secondary;
        uint256 minPrice;
        uint256 maxPrice;
        uint32 primaryMaxAge;
        uint32 secondaryMaxAge;
        uint16 maxDeviationBps;
        uint8 primaryDecimals;
        uint8 secondaryDecimals;
        bool collateralSide;
        bool enabled;
    }

    address public immutable governor;
    address public immutable guardian;
    mapping(address => Feed) public feeds;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidPrice();
    error Disabled();

    event FeedConfigured(address indexed asset, address primary, address secondary, bool collateralSide);
    event FeedEnabled(address indexed asset, bool enabled);

    constructor(address governor_, address guardian_) {
        if (governor_ == address(0) || guardian_ == address(0) || governor_ == guardian_) {
            revert InvalidConfiguration();
        }
        governor = governor_;
        guardian = guardian_;
    }

    /// @notice Call only through the production governance timelock. Prices use 18 USD decimals.
    function configure(
        address asset,
        address primary,
        address secondary,
        uint32 primaryMaxAge,
        uint32 secondaryMaxAge,
        uint16 maxDeviationBps,
        uint256 minPrice,
        uint256 maxPrice,
        bool collateralSide
    ) external {
        if (msg.sender != governor) revert Unauthorized();
        if (
            asset.code.length == 0 || primary.code.length == 0 || secondary.code.length == 0
                || primary == secondary || primaryMaxAge == 0 || secondaryMaxAge == 0
                || primaryMaxAge > 1 days || secondaryMaxAge > 1 days || maxDeviationBps == 0
                || maxDeviationBps > 2000 || minPrice == 0 || maxPrice <= minPrice || maxPrice > 1e36
        ) revert InvalidConfiguration();
        uint8 pd = IAggregator(primary).decimals();
        uint8 sd = IAggregator(secondary).decimals();
        if (pd > 18 || sd > 18) revert InvalidConfiguration();
        feeds[asset] = Feed(
            primary,
            secondary,
            minPrice,
            maxPrice,
            primaryMaxAge,
            secondaryMaxAge,
            maxDeviationBps,
            pd,
            sd,
            collateralSide,
            true
        );
        // Do not activate a broken pair even through governance.
        price(asset);
        emit FeedConfigured(asset, primary, secondary, collateralSide);
        emit FeedEnabled(asset, true);
    }

    function setEnabled(address asset, bool enabled) external {
        if (msg.sender != governor && (msg.sender != guardian || enabled)) revert Unauthorized();
        if (feeds[asset].primary == address(0)) revert InvalidConfiguration();
        feeds[asset].enabled = enabled;
        if (enabled) price(asset);
        emit FeedEnabled(asset, enabled);
    }

    function price(address asset) public view returns (uint256) {
        Feed memory f = feeds[asset];
        if (!f.enabled) revert Disabled();
        uint256 a = _read(f.primary, f.primaryDecimals, f.primaryMaxAge);
        uint256 b = _read(f.secondary, f.secondaryDecimals, f.secondaryMaxAge);
        uint256 low = Math.min(a, b);
        uint256 high = Math.max(a, b);
        if (
            low < f.minPrice || high > f.maxPrice
                || Math.mulDiv(high - low, 10_000, low, Math.Rounding.Ceil) > f.maxDeviationBps
        ) revert InvalidPrice();
        // Debt uses the higher price; collateral uses the lower. No assumed stablecoin peg.
        return f.collateralSide ? low : high;
    }

    function _read(address feed, uint8 decimals_, uint32 maxAge) private view returns (uint256) {
        (uint80 round, int256 answer, uint256 started, uint256 updated, uint80 answered) =
            IAggregator(feed).latestRoundData();
        if (
            answer <= 0 || round == 0 || answered < round || updated == 0 || updated > block.timestamp
                || started == 0 || started > updated || block.timestamp - updated > maxAge
                || IAggregator(feed).decimals() != decimals_
        ) revert InvalidPrice();
        if (uint256(answer) > 1e36 / 10 ** (18 - decimals_)) revert InvalidPrice();
        return uint256(answer) * 10 ** (18 - decimals_);
    }
}
