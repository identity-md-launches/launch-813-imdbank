// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ExactToken} from "./lib/ExactToken.sol";

interface IBankOracle {
    function price(address token) external view returns (uint256 usdWad);
}

/// @notice Immutable, isolated IMD collateral lending with three treasury-funded debt reserves.
/// @dev IMDBANK is a nontransferable collateral receipt ledger, not a tradable ERC20.
/// Caps start at zero: governance must complete oracle/liquidity/risk review before activation.
contract IMDBank {
    using ExactToken for address;

    string public constant name = "IMDBANK";
    string public constant symbol = "IMDBANK";
    uint256 public constant feeBps = 0;
    uint256 public constant RAY = 1e27;
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_AMOUNT = 1e30;
    uint256 public constant MAX_INDEX = 1e36;
    uint256 public constant MAX_PRICE = 1e27;
    uint256 public constant LIQUIDATION_DUST_USD = 1e15;
    /// @notice Smallest debt per account and reserve a borrow may leave, so one-share positions whose
    /// rounded debt doubles on first accrual and that no liquidation path can clear cannot be opened.
    uint256 public constant MIN_DEBT_USD = 1e18;
    /// @notice Recorded loss per reserve above which lending halts until recapitalized. Smaller dust
    /// losses are recorded and visible but cannot be used to stop the whole bank.
    uint256 public constant LOSS_FREEZE_USD = 1e18;

    address public immutable governor;
    address public guardian;
    address public immutable collateral;
    address public immutable oracle;
    uint256 public immutable collateralUnit;
    address[3] public assets;
    mapping(address => uint256) public assetUnit;
    mapping(address => uint256) public collateralBalance;
    mapping(address => bool) public collateralEnabled;
    mapping(address => mapping(address => uint256)) public debtShares;
    uint256 public totalCollateral;
    uint256 public supplyCap;
    uint256 public ltvBps = 2500;
    uint256 public liquidationThresholdBps = 3500;
    uint256 public liquidationBonusBps = 800;
    uint256 public closeFactorBps = 5000;
    bool public frozen = true;
    uint256 private entered = 1;

    struct Reserve {
        uint256 totalDebtShares;
        uint256 index;
        uint256 lastAccrual;
        uint256 borrowCap;
        uint256 badDebt;
        uint256 baseRateRay;
        uint256 slope1Ray;
        uint256 slope2Ray;
        uint256 kinkBps;
        uint256 cachedRateRay;
        bool frozen;
        bool lossHalt;
    }
    mapping(address => Reserve) private reserves;

    struct LiquidationQuote {
        uint256 index;
        uint256 collateralPrice;
        uint256 debtPrice;
        uint256 available;
        uint256 coveredAmount;
        uint256 budget;
    }

    error Unauthorized();
    error InvalidConfiguration();
    error UnsupportedAsset();
    error InvalidAmount();
    error InvalidRecipient();
    error Reentrancy();
    error Frozen();
    error CapExceeded();
    error InsufficientLiquidity();
    error UnsafePosition();
    error HealthyPosition();
    error InvalidPrice();
    error Dust();
    error Expired();
    error Slippage();
    error OutstandingBadDebt();
    error MinimumDebt();

    event Supplied(address indexed payer, address indexed account, uint256 amount);
    event CollateralChanged(address indexed account, bool enabled);
    event Withdrawn(address indexed account, address indexed to, uint256 amount);
    event Borrowed(
        address indexed account, address indexed asset, address indexed to, uint256 amount, uint256 shares
    );
    event Repaid(
        address indexed payer, address indexed account, address indexed asset, uint256 amount, uint256 shares
    );
    event Liquidated(
        address indexed liquidator,
        address indexed account,
        address indexed asset,
        uint256 repaid,
        uint256 seized
    );
    event LiquidityDonated(address indexed donor, address indexed asset, uint256 amount);
    event Accrued(address indexed asset, uint256 index, uint256 rateRay);
    event BadDebtRecorded(address indexed account, address indexed asset, uint256 amount);
    event BadDebtCovered(address indexed donor, address indexed asset, uint256 amount);
    event DustFinalized(address indexed caller, address indexed account, uint256 collateralSeized);
    event RiskConfigured(
        uint256 ltv, uint256 threshold, uint256 bonus, uint256 closeFactor, uint256 supplyCap
    );
    event ReserveConfigured(
        address indexed asset, uint256 cap, uint256 baseRate, uint256 slope1, uint256 slope2, uint256 kink
    );
    event FrozenStateChanged(address indexed asset, bool frozen);
    event GuardianChanged(address indexed guardian);

    modifier nonReentrant() {
        if (entered != 1) revert Reentrancy();
        entered = 2;
        _;
        entered = 1;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert Unauthorized();
        _;
    }

    constructor(
        address governor_,
        address guardian_,
        address collateral_,
        address oracle_,
        address asset0,
        address asset1,
        address asset2
    ) {
        if (
            governor_ == address(0) || guardian_ == address(0) || governor_ == guardian_
                || oracle_.code.length == 0
        ) {
            revert InvalidConfiguration();
        }
        governor = governor_;
        guardian = guardian_;
        collateral = collateral_;
        oracle = oracle_;
        collateralUnit = collateral_.unit();
        assets = [asset0, asset1, asset2];
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            if (asset == collateral_ || assetUnit[asset] != 0) revert InvalidConfiguration();
            assetUnit[asset] = asset.unit();
            reserves[asset] = Reserve({
                totalDebtShares: 0,
                index: RAY,
                lastAccrual: block.timestamp,
                borrowCap: 0,
                badDebt: 0,
                baseRateRay: RAY / 50,
                slope1Ray: RAY * 8 / 100,
                slope2Ray: RAY * 90 / 100,
                kinkBps: 8000,
                cachedRateRay: RAY / 50,
                frozen: false,
                lossHalt: false
            });
        }
    }

    function supply(uint256 amount, address onBehalfOf) external nonReentrant {
        _amount(amount);
        _recipient(onBehalfOf);
        if (amount > supplyCap || totalCollateral > supplyCap - amount) revert CapExceeded();
        collateralBalance[onBehalfOf] += amount;
        totalCollateral += amount;
        collateral.pull(msg.sender, amount);
        emit Supplied(msg.sender, onBehalfOf, amount);
    }

    function setCollateralEnabled(bool enabled) external nonReentrant {
        if (!enabled && _hasDebt(msg.sender)) revert UnsafePosition();
        collateralEnabled[msg.sender] = enabled;
        emit CollateralChanged(msg.sender, enabled);
    }

    function withdraw(uint256 amount, address to) external nonReentrant {
        _amount(amount);
        _recipient(to);
        if (amount > collateralBalance[msg.sender]) revert InvalidAmount();
        collateralBalance[msg.sender] -= amount;
        totalCollateral -= amount;
        if (_hasDebt(msg.sender)) {
            if (frozen) revert Frozen();
            _accrueAll();
            _requireBorrowSafe(msg.sender);
        }
        collateral.push(to, amount);
        emit Withdrawn(msg.sender, to, amount);
    }

    function borrow(address asset, uint256 amount, address to) external nonReentrant {
        Reserve storage reserve = _reserve(asset);
        _amount(amount);
        _recipient(to);
        if (frozen || reserve.frozen) revert Frozen();
        _accrueAll();
        if (reserve.index == MAX_INDEX) revert Frozen();
        if (ExactToken.balance(asset, address(this)) < amount) revert InsufficientLiquidity();
        uint256 shares = Math.mulDiv(amount, RAY, reserve.index, Math.Rounding.Ceil);
        reserve.totalDebtShares += shares;
        debtShares[msg.sender][asset] += shares;
        if (_debt(reserve.totalDebtShares, reserve.index) > reserve.borrowCap) revert CapExceeded();
        _requireBorrowSafe(msg.sender);
        if (_debtValue(asset, _debt(debtShares[msg.sender][asset], reserve.index)) < MIN_DEBT_USD) {
            revert MinimumDebt();
        }
        asset.push(to, amount);
        _updateRate(asset, reserve);
        emit Borrowed(msg.sender, asset, to, amount, shares);
    }

    /// @notice Repay at most maxAmount; MAX_UINT repays all. Only the exact debt reduction is charged.
    function repay(address asset, uint256 maxAmount, address onBehalfOf)
        external
        nonReentrant
        returns (uint256 paid)
    {
        Reserve storage reserve = _reserve(asset);
        if (maxAmount == 0) revert InvalidAmount();
        _recipient(onBehalfOf);
        _accrue(asset, reserve);
        uint256 burned;
        (paid, burned) = _repayQuote(debtShares[onBehalfOf][asset], reserve.index, maxAmount);
        if (paid == 0) revert Dust();
        _burnDebt(onBehalfOf, asset, reserve, burned);
        asset.pull(msg.sender, paid);
        _updateRate(asset, reserve);
        emit Repaid(msg.sender, onBehalfOf, asset, paid, burned);
    }

    function donateLiquidity(address asset, uint256 amount) external nonReentrant {
        Reserve storage reserve = _reserve(asset);
        _amount(amount);
        _accrue(asset, reserve);
        asset.pull(msg.sender, amount);
        _updateRate(asset, reserve);
        emit LiquidityDonated(msg.sender, asset, amount);
    }

    function coverBadDebt(address asset, uint256 amount) external nonReentrant {
        Reserve storage reserve = _reserve(asset);
        _amount(amount);
        if (amount > reserve.badDebt) revert InvalidAmount();
        _accrue(asset, reserve);
        reserve.badDebt -= amount;
        if (reserve.badDebt == 0) reserve.lossHalt = false;
        asset.pull(msg.sender, amount);
        _updateRate(asset, reserve);
        emit BadDebtCovered(msg.sender, asset, amount);
    }

    function accrue(address asset) external nonReentrant {
        Reserve storage reserve = _reserve(asset);
        _accrue(asset, reserve);
    }

    function liquidate(
        address account,
        address asset,
        uint256 maxRepay,
        uint256 minCollateralOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 repaid, uint256 seized) {
        if (block.timestamp > deadline) revert Expired();
        _reserve(asset);
        _accrueAll();
        uint256 burned;
        (repaid, burned, seized) = _liquidationQuote(account, asset, maxRepay);
        if (seized < minCollateralOut) revert Slippage();
        Reserve storage reserve = reserves[asset];
        _burnDebt(account, asset, reserve, burned);
        collateralBalance[account] -= seized;
        totalCollateral -= seized;
        if (collateralBalance[account] == 0) _writeOff(account);
        asset.pull(msg.sender, repaid);
        collateral.push(msg.sender, seized);
        _updateRate(asset, reserve);
        emit Liquidated(msg.sender, account, asset, repaid, seized);
    }

    /// @notice Recognize insolvency when valid prices value all residual collateral at <= $0.001.
    /// The caller receives that residual collateral; unpaid debt is recorded and lending freezes.
    function finalizeDust(address account) external nonReentrant {
        _accrueAll();
        (, uint256 debtUsd,,, uint256 hf) = accountData(account);
        if (hf >= WAD || !_hasDebt(account)) revert HealthyPosition();
        uint256 amount = collateralBalance[account];
        uint256 collateralPrice = _price(collateral);
        uint256 collateralValue = Math.mulDiv(amount, collateralPrice, collateralUnit, Math.Rounding.Ceil);
        if (amount == 0 || collateralValue > LIQUIDATION_DUST_USD || collateralValue >= debtUsd) {
            revert InvalidAmount();
        }
        // Preserve every economically possible ordinary repayment. Only positions for
        // which no reserve can burn even one debt share may use the zero-payment path.
        _requireUnliquidatableDust(account, Math.mulDiv(amount, collateralPrice, collateralUnit));
        collateralBalance[account] = 0;
        totalCollateral -= amount;
        _writeOff(account);
        collateral.push(msg.sender, amount);
        emit DustFinalized(msg.sender, account, amount);
    }

    function previewLiquidation(address account, address asset, uint256 maxRepay)
        public
        view
        returns (uint256 repaid, uint256 seized)
    {
        (repaid,, seized) = _liquidationQuote(account, asset, maxRepay);
    }

    function previewDebt(address account, address asset) public view returns (uint256) {
        Reserve storage reserve = _reserve(asset);
        return _debt(debtShares[account][asset], _previewIndex(reserve));
    }

    function accountData(address account)
        public
        view
        returns (
            uint256 collateralUsd,
            uint256 debtUsd,
            uint256 borrowCapacityUsd,
            uint256 liquidationThresholdUsd,
            uint256 healthFactor
        )
    {
        if (collateralEnabled[account] && collateralBalance[account] != 0) {
            collateralUsd = Math.mulDiv(collateralBalance[account], _price(collateral), collateralUnit);
            borrowCapacityUsd = Math.mulDiv(collateralUsd, ltvBps, BPS);
            liquidationThresholdUsd = Math.mulDiv(collateralUsd, liquidationThresholdBps, BPS);
        }
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            uint256 amount = previewDebt(account, asset);
            if (amount != 0) {
                debtUsd += Math.mulDiv(amount, _price(asset), assetUnit[asset], Math.Rounding.Ceil);
            }
        }
        healthFactor = debtUsd == 0 ? type(uint256).max : Math.mulDiv(liquidationThresholdUsd, WAD, debtUsd);
    }

    function reserveData(address asset)
        external
        view
        returns (
            uint256 cash,
            uint256 totalDebt,
            uint256 index,
            uint256 rateRay,
            uint256 cap,
            uint256 badDebt,
            bool isFrozen
        )
    {
        Reserve storage reserve = _reserve(asset);
        index = _previewIndex(reserve);
        return (
            ExactToken.balance(asset, address(this)),
            _debt(reserve.totalDebtShares, index),
            index,
            reserve.cachedRateRay,
            reserve.borrowCap,
            reserve.badDebt,
            frozen || reserve.frozen || index == MAX_INDEX
        );
    }

    /// @notice True while a recorded loss above `LOSS_FREEZE_USD` keeps the reserve and bank halted.
    function lossHalted(address asset) external view returns (bool) {
        return _reserve(asset).lossHalt;
    }

    function configureRisk(
        uint256 ltv,
        uint256 threshold,
        uint256 bonus,
        uint256 closeFactor,
        uint256 supplyCap_
    ) external nonReentrant onlyGovernor {
        if (
            ltv > 4000 || threshold > 5000 || threshold <= ltv || bonus > 1500
                || threshold * (BPS + bonus) >= BPS * BPS || closeFactor < 1000 || closeFactor > BPS
                || supplyCap_ > MAX_AMOUNT
        ) revert InvalidConfiguration();
        ltvBps = ltv;
        liquidationThresholdBps = threshold;
        liquidationBonusBps = bonus;
        closeFactorBps = closeFactor;
        supplyCap = supplyCap_;
        emit RiskConfigured(ltv, threshold, bonus, closeFactor, supplyCap_);
    }

    function configureReserve(
        address asset,
        uint256 borrowCap,
        uint256 baseRateRay,
        uint256 slope1Ray,
        uint256 slope2Ray,
        uint256 kinkBps
    ) external nonReentrant onlyGovernor {
        Reserve storage reserve = _reserve(asset);
        if (
            borrowCap > MAX_AMOUNT || baseRateRay > RAY || slope1Ray > RAY || slope2Ray > RAY
                || baseRateRay + slope1Ray + slope2Ray > RAY || kinkBps < 1000 || kinkBps > 9500
        ) revert InvalidConfiguration();
        _accrue(asset, reserve);
        reserve.borrowCap = borrowCap;
        reserve.baseRateRay = baseRateRay;
        reserve.slope1Ray = slope1Ray;
        reserve.slope2Ray = slope2Ray;
        reserve.kinkBps = kinkBps;
        _updateRate(asset, reserve);
        emit ReserveConfigured(asset, borrowCap, baseRateRay, slope1Ray, slope2Ray, kinkBps);
    }

    function setFrozen(bool value) external nonReentrant {
        _freezeAuthority(value);
        if (!value) {
            for (uint256 i; i < 3; ++i) {
                if (reserves[assets[i]].lossHalt) revert OutstandingBadDebt();
            }
        }
        frozen = value;
        emit FrozenStateChanged(address(0), value);
    }

    function setReserveFrozen(address asset, bool value) external nonReentrant {
        _freezeAuthority(value);
        Reserve storage reserve = _reserve(asset);
        if (!value && reserve.lossHalt) revert OutstandingBadDebt();
        reserve.frozen = value;
        emit FrozenStateChanged(asset, value);
    }

    function setGuardian(address guardian_) external nonReentrant onlyGovernor {
        if (guardian_ == address(0) || guardian_ == governor) revert InvalidConfiguration();
        guardian = guardian_;
        emit GuardianChanged(guardian_);
    }

    function _liquidationQuote(address account, address asset, uint256 maxRepay)
        private
        view
        returns (uint256 paid, uint256 burned, uint256 seized)
    {
        _reserve(asset);
        if (maxRepay == 0) revert InvalidAmount();
        LiquidationQuote memory quote;
        quote.index = _previewIndex(reserves[asset]);
        quote.collateralPrice = _price(collateral);
        quote.debtPrice = _price(asset);
        quote.available = collateralBalance[account];
        {
            uint256 collateralValue = Math.mulDiv(quote.available, quote.collateralPrice, collateralUnit);
            quote.coveredAmount = Math.mulDiv(
                Math.mulDiv(collateralValue, BPS, BPS + liquidationBonusBps),
                assetUnit[asset],
                quote.debtPrice
            );
        }
        {
            (,,,, uint256 hf) = accountData(account);
            if (hf >= WAD) revert HealthyPosition();
            uint256 userDebt = _debt(debtShares[account][asset], quote.index);
            uint256 closeLimit =
                hf < 0.95e18 ? userDebt : Math.mulDiv(userDebt, closeFactorBps, BPS, Math.Rounding.Ceil);
            quote.budget = Math.min(maxRepay, Math.min(closeLimit, quote.coveredAmount));
        }
        (paid, burned) = _repayQuote(debtShares[account][asset], quote.index, quote.budget);
        uint256 seizedValue =
            Math.mulDiv(Math.mulDiv(paid, quote.debtPrice, assetUnit[asset]), BPS + liquidationBonusBps, BPS);
        seized = Math.min(quote.available, Math.mulDiv(seizedValue, collateralUnit, quote.collateralPrice));
        // A collateral-limited payment buys the whole position, including residue that floors to zero.
        if (
            quote.budget == quote.coveredAmount
                && Math.mulDiv(
                        quote.available - seized, quote.collateralPrice, collateralUnit, Math.Rounding.Ceil
                    ) <= LIQUIDATION_DUST_USD
        ) {
            seized = quote.available;
        }
        if (paid == 0 || seized == 0) revert Dust();
    }

    function _requireUnliquidatableDust(address account, uint256 collateralValue) private view {
        uint256 coveredValue = Math.mulDiv(collateralValue, BPS, BPS + liquidationBonusBps);
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            uint256 shares = debtShares[account][asset];
            if (shares == 0) continue;
            uint256 coveredAmount = Math.mulDiv(coveredValue, assetUnit[asset], _price(asset));
            (uint256 paid,) = _repayQuote(shares, reserves[asset].index, coveredAmount);
            if (paid != 0) revert InvalidAmount();
        }
    }

    function _writeOff(address account) private {
        collateralEnabled[account] = false;
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            Reserve storage reserve = reserves[asset];
            uint256 shares = debtShares[account][asset];
            if (shares == 0) continue;
            uint256 amount = _debt(shares, reserve.index);
            _burnDebt(account, asset, reserve, shares);
            reserve.badDebt += amount;
            _updateRate(asset, reserve);
            emit BadDebtRecorded(account, asset, amount);
            // Dust losses stay recorded and coverable without halting; material losses halt lending
            // in the reserve and the bank until fully recapitalized and reviewed by governance.
            if (!reserve.lossHalt && _debtValue(asset, reserve.badDebt) > LOSS_FREEZE_USD) {
                reserve.lossHalt = true;
                reserve.frozen = true;
                frozen = true;
                emit FrozenStateChanged(asset, true);
                emit FrozenStateChanged(address(0), true);
            }
        }
    }

    function _debtValue(address asset, uint256 amount) private view returns (uint256) {
        return Math.mulDiv(amount, _price(asset), assetUnit[asset], Math.Rounding.Ceil);
    }

    function _repayQuote(uint256 shares, uint256 index, uint256 budget)
        private
        pure
        returns (uint256 paid, uint256 burned)
    {
        uint256 oldDebt = _debt(shares, index);
        if (budget >= oldDebt) return (oldDebt, shares);
        burned = Math.mulDiv(budget, RAY, index);
        if (burned != 0) paid = oldDebt - _debt(shares - burned, index);
    }

    function _burnDebt(address account, address asset, Reserve storage reserve, uint256 shares) private {
        debtShares[account][asset] -= shares;
        reserve.totalDebtShares -= shares;
    }

    function _requireBorrowSafe(address account) private view {
        (, uint256 debtUsd, uint256 capacity,,) = accountData(account);
        if (!collateralEnabled[account] || debtUsd > capacity) revert UnsafePosition();
    }

    function _hasDebt(address account) private view returns (bool) {
        for (uint256 i; i < 3; ++i) {
            if (debtShares[account][assets[i]] != 0) return true;
        }
        return false;
    }

    function _accrueAll() private {
        for (uint256 i; i < 3; ++i) {
            _accrue(assets[i], reserves[assets[i]]);
        }
    }

    function _accrue(address asset, Reserve storage reserve) private {
        reserve.index = _previewIndex(reserve);
        reserve.lastAccrual = block.timestamp;
        emit Accrued(asset, reserve.index, reserve.cachedRateRay);
    }

    function _previewIndex(Reserve storage reserve) private view returns (uint256) {
        if (reserve.totalDebtShares == 0 || block.timestamp == reserve.lastAccrual) return reserve.index;
        // Ethereum timestamps cannot approach this bound; avoid unchecked cast/overflow assumptions.
        if (block.timestamp > type(uint64).max || block.timestamp < reserve.lastAccrual) {
            revert InvalidConfiguration();
        }
        uint256 elapsed = block.timestamp - reserve.lastAccrual;
        uint256 factor = RAY + Math.ceilDiv(reserve.cachedRateRay, YEAR);
        uint256 accumulated = RAY;
        // At most 64 rounds. Per-second compounding prevents permissionless checkpoint
        // frequency from materially changing the interest charged at a fixed rate.
        while (elapsed != 0) {
            if (elapsed & 1 != 0) accumulated = _rayMulCapped(accumulated, factor);
            elapsed >>= 1;
            if (elapsed != 0) factor = _rayMulCapped(factor, factor);
        }
        return _rayMulCapped(reserve.index, accumulated);
    }

    function _rayMulCapped(uint256 a, uint256 b) private pure returns (uint256) {
        return Math.min(MAX_INDEX, Math.mulDiv(a, b, RAY, Math.Rounding.Ceil));
    }

    function _updateRate(address asset, Reserve storage reserve) private {
        uint256 debt = _debt(reserve.totalDebtShares, reserve.index);
        uint256 cash = Math.min(ExactToken.balance(asset, address(this)), MAX_AMOUNT);
        uint256 utilization = debt == 0 ? 0 : Math.mulDiv(debt, RAY, cash + debt);
        uint256 kink = reserve.kinkBps * RAY / BPS;
        reserve.cachedRateRay = utilization <= kink
            ? reserve.baseRateRay + Math.mulDiv(reserve.slope1Ray, utilization, kink)
            : reserve.baseRateRay + reserve.slope1Ray
                + Math.mulDiv(reserve.slope2Ray, utilization - kink, RAY - kink);
    }

    function _debt(uint256 shares, uint256 index) private pure returns (uint256) {
        return Math.mulDiv(shares, index, RAY, Math.Rounding.Ceil);
    }

    function _price(address token) private view returns (uint256 price_) {
        price_ = IBankOracle(oracle).price(token);
        if (price_ == 0 || price_ > MAX_PRICE) revert InvalidPrice();
    }

    function _reserve(address asset) private view returns (Reserve storage reserve) {
        if (assetUnit[asset] == 0) revert UnsupportedAsset();
        reserve = reserves[asset];
    }

    function _amount(uint256 amount) private pure {
        if (amount == 0 || amount > MAX_AMOUNT) revert InvalidAmount();
    }

    function _recipient(address recipient) private view {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
    }

    function _freezeAuthority(bool value) private view {
        if (msg.sender != governor && (msg.sender != guardian || !value)) revert Unauthorized();
    }
}
