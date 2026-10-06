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
/// A guardian pause is bounded and single-use per governance decision, so the emergency key can delay
/// but never permanently block liquidation or loss recognition.
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
        uint64 guardianPausedUntil;
    }

    uint256 public constant MAX_AGE = 2 days;
    uint256 public constant MIN_GUARDIAN_PAUSE = 2 days;
    uint256 public constant MAX_GUARDIAN_PAUSE = 30 days;

    address public immutable governor;
    address public guardian;
    /// @notice Length of one guardian pause. Governance should keep it at least the timelock delay.
    uint256 public guardianPause = 2 days;
    mapping(address => Feed) public feeds;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidPrice();
    error Disabled();

    event FeedConfigured(address indexed asset, address primary, address secondary, bool collateralSide);
    event FeedEnabled(address indexed asset, bool enabled);
    event FeedPaused(address indexed asset, uint256 until);
    event GuardianChanged(address indexed guardian);
    event GuardianPauseChanged(uint256 duration);

    constructor(address governor_, address guardian_) {
        if (governor_ == address(0) || guardian_ == address(0) || governor_ == guardian_) {
            revert InvalidConfiguration();
        }
        governor = governor_;
        guardian = guardian_;
    }

    /// @notice Call only through the production governance timelock. Prices use 18 USD decimals.
    /// @dev Bounds reject only prices that would overvalue a borrower: a collateral feed is capped at
    /// `maxPrice`, a debt feed is floored at `minPrice` (zero means no floor). A collateral crash or a
    /// debt spike is therefore priced as reported, so liquidation and loss recognition stay live.
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
                || primaryMaxAge > MAX_AGE || secondaryMaxAge > MAX_AGE || maxDeviationBps == 0
                || maxDeviationBps > 2000 || maxPrice <= minPrice || maxPrice > 1e36
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
            true,
            0
        );
        // Do not activate a broken pair even through governance.
        price(asset);
        emit FeedConfigured(asset, primary, secondary, collateralSide);
        emit FeedEnabled(asset, true);
    }

    /// @notice Governance enables or disables a feed indefinitely and re-arms the guardian pause.
    /// The guardian may only start one bounded pause of an enabled feed per governance decision.
    function setEnabled(address asset, bool enabled) external {
        Feed storage f = feeds[asset];
        if (f.primary == address(0)) revert InvalidConfiguration();
        if (msg.sender == governor) {
            f.enabled = enabled;
            f.guardianPausedUntil = 0;
            if (enabled) price(asset);
            emit FeedEnabled(asset, enabled);
        } else if (msg.sender == guardian && !enabled) {
            if (!f.enabled || f.guardianPausedUntil != 0) revert Unauthorized();
            uint256 until = block.timestamp + guardianPause;
            f.guardianPausedUntil = uint64(until);
            emit FeedPaused(asset, until);
        } else {
            revert Unauthorized();
        }
    }

    function setGuardian(address guardian_) external {
        if (msg.sender != governor) revert Unauthorized();
        if (guardian_ == address(0) || guardian_ == governor) revert InvalidConfiguration();
        guardian = guardian_;
        emit GuardianChanged(guardian_);
    }

    function setGuardianPause(uint256 duration) external {
        if (msg.sender != governor) revert Unauthorized();
        if (duration < MIN_GUARDIAN_PAUSE || duration > MAX_GUARDIAN_PAUSE) revert InvalidConfiguration();
        guardianPause = duration;
        emit GuardianPauseChanged(duration);
    }

    function price(address asset) public view returns (uint256) {
        Feed memory f = feeds[asset];
        if (!f.enabled || block.timestamp < f.guardianPausedUntil) revert Disabled();
        uint256 a = _read(f.primary, f.primaryDecimals, f.primaryMaxAge);
        uint256 b = _read(f.secondary, f.secondaryDecimals, f.secondaryMaxAge);
        uint256 low = Math.min(a, b);
        uint256 high = Math.max(a, b);
        if (
            (f.collateralSide ? high > f.maxPrice : low < f.minPrice)
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
