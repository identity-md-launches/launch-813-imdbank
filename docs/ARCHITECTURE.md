# IMDBANK architecture and accounting

## Scope and activation status

IMDBANK is an immutable isolated lending application for IMD collateral and exactly three debt assets: USDC, USDT and WETH. It implements the lending lifecycle, but it is **not cleared for custody of real funds**. [Research](RESEARCH.md) has not established a sufficiently independent IMD oracle, executable liquidation depth, robust historical volatility or an acceptable bridge-administration trust model. Initial supply and debt caps are zero, borrowing is frozen and the oracle is unconfigured. These are executable release gates. No production oracle price or protocol address is invented.

The original requested Aave-style lifecycle is implemented with treasury-funded reserves. It is not a full fork of Aave, a deposit-taking stablecoin vault or an interest-bearing LP product. Aave's indexed debt and health-factor ideas informed the design; Aave code is not copied. The project does not deploy a new transferable launch token. `name()` and `symbol()` are both `IMDBANK`, describing the nontransferable 1:1 IMD receipt ledger. `collateralBalance(account)` records receipts; `totalCollateral()` records total custody obligations. There is no transferable ERC20 receipt, allowance, share exchange rate, receipt yield or leverage loop through a receipt token.

## Immutable components and trust boundaries

`IMDBank(governor, guardian, collateral, oracle, asset0, asset1, asset2)` validates four distinct token contracts with cached decimals in 0–18. The constructor takes explicit role holders, so a deployment factory never accidentally becomes the governor. In production the three asset parameters must be the researched Ethereum Mainnet USDC, USDT and WETH addresses, and collateral must be the specified IMD address. The reusable contract does not hardcode these addresses or restrict `chainid`; the deployment and frontend must enforce Ethereum chain ID 1. Constructors are nonpayable and contracts have no upgrade, delegatecall, arbitrary user callback, sweep or emergency administrator withdrawal function.

`RiskOracle(governor, guardian)` is an immutable oracle dispatcher. Each token needs two separately governed, economically independent USD feeds, independently verified by the deployer. It rejects unconfigured, disabled, stale, future-dated, incomplete, nonpositive, out-of-band or excessively divergent prices. Feed decimals are pinned and rechecked. Within the accepted band the collateral uses the lower feed value and debt uses the higher value. Stablecoins are priced at observed USD values. Address inequality does not establish source independence: two wrappers around one source are not two oracles. The bank independently bounds accepted price values to `1e27` USD-wei ($1 billion per token); oracle configurations should have much narrower asset-specific bands.

`GovernanceTimelock(proposer, canceller, delay)` should be the bank and oracle governor. Production proposer and canceller must be separate reviewed multisigs; the guardian should be an independently operated emergency multisig. The delay is immutable, 2–30 days. Anyone may execute a matured proposal during its seven-day execution window. The canceller can veto, not execute or replace, proposals. Timelock operation identifiers bind chain ID, executor, target, calldata and salt. All execution sends zero native value. The bank can rotate its guardian only through governance; oracle/timelock role holders are immutable and their multisig signer-management policy must support operational continuity.

Governance can change bounded LTV, liquidation threshold, bonus, close factor, supply/debt caps, interest parameters and oracle feeds. These powers can change a user's liquidation exposure and are trusted, delayed powers. Guardian can freeze the entire bank or one reserve and can disable an oracle feed; only governance can unfreeze or enable it. Governance cannot remove recorded bad debt without actual token recapitalization. A compromised token administrator can still pause/block transfers, alter bridged supply or make collateral worthless; this application cannot eliminate underlying-token risk.

## Funding, custody and zero fees

Treasury or benefactors provide reserve cash through `donateLiquidity(asset, amount)`. **This contribution is irrevocable:** it issues no claim or yield right and has no redemption or administrator recovery path. All borrower interest remains reserve cash, available for subsequent loans. There are no lender liabilities and no treasury extraction path. A future LP product would require a separately reviewed design; depositing into this function must never be presented as earning a redeemable balance.

The application charges zero supply, borrow, repay, withdrawal or protocol liquidation fees (`feeBps = 0`). Variable interest is charged to borrowers, and the liquidation bonus compensates liquidators; neither is a protocol fee. IMD collateral earns no interest. Direct unsolicited token donations create no collateral receipts or reserve claims. Native ETH is not a lending asset: users must use WETH.

The local `ExactToken` adapter accepts standard boolean returns or an empty USDT-style return. Every transfer measures both sender and recipient balances. Transfer fees, sender surcharges, false returns, transfer-time rebases, unexpected callbacks and inexact balance changes revert atomically. All bank mutators share a reentrancy lock. Tokens that rebase between calls remain unsupported: exact transfer checks cannot prevent external changes in actual custody balances. External token pauses, blacklists and bridge interference can block exits or liquidations and must be monitored.

## Debt and rate accounting

Each reserve stores a RAY index (`1e27`), total debt shares, a cached annualized variable rate, the last accrual time, immutable token units, a borrowing cap and realized bad debt. Each account stores its debt shares per reserve. Amounts and caps use each token's native base units, not a universal 18-decimal token unit. Index and rate calculations use full-precision `Math.mulDiv` from pinned vendored OpenZeppelin Math.

For index `I` and shares `S`:

- Reported debt is `ceil(S * I / RAY)`.
- Borrowing `A` units mints `ceil(A * RAY / I)` shares. The post-mint aggregate rounded debt must be within the reserve cap and the whole account must be within LTV. Borrower debt may increase by slightly more than the tokens received because debt rounding favors the reserve.
- A full repayment burns all borrower shares and charges the displayed rounded debt.
- A partial repayment budget `B` burns `floor(B * RAY / I)` shares and charges exactly `oldRoundedDebt - newRoundedDebt`, which cannot exceed `B`. The unused budget stays with the payer. A budget too small to burn a share reverts `Dust`.
- Aggregate reserve debt is rounded once, so the sum of individually rounded account debts can exceed the aggregate by less than one base unit per open account. There is no redeemable LP claim priced against that difference.

Accrual compounds each elapsed second using `RAY + ceil(annualRateRay / secondsPerYear)`. Exponentiation by squaring uses at most 64 rounds, since timestamps are bounded by `uint64`. Permissionless checkpoint frequency therefore cannot materially change fixed-rate interest. Rates are nominal annual rates; displayed APY should reflect compounding rather than equating APR to APY. Rates are updated after cash/debt-changing protocol operations and parameter changes, and are cached between them. A direct unsolicited transfer does not retroactively alter accrued interest. There is no flash loan API.

Utilization is outstanding indexed debt divided by cash plus debt. The variable rate is a two-slope curve about the configured kink. Default experimental settings are base 2%, first slope 8%, second slope 90%, kink 80%, with a hard maximum nominal annual rate of 100%. They are scenario inputs, not evidence that IMD markets can sustain those rates. Caps are bounded to `1e30` base units. The debt index saturates at `1e36`, where additional borrowing fails and repayment/liquidation remain available. This explicit far-future recovery bound prevents arithmetic overflow; interest stops increasing at the ceiling. Cash above `1e30` units is clamped only when computing utilization. Production caps should be orders of magnitude smaller and based on proven liquidation depth.

## Collateral and borrower actions

`supply(amount, onBehalfOf)` mints exactly the IMD received as receipts, subject to the supply cap. Supplying to another account does not enable its collateral. The account owner independently calls `setCollateralEnabled(true)`. Disabling is allowed only after all three debts are zero.

`accountData` values enabled collateral downward and debt upward. It returns total collateral USD, total debt USD, total borrowing capacity, liquidation-threshold USD and health factor, all with 18 USD decimals (HF is also `1e18` scaled). Borrowing capacity is total LTV capacity, not unused headroom: remaining borrowing power is `max(capacity - debt, 0)`. No debt returns `uint256.max` as HF. Price reads fail closed; the frontend must display an unavailable risk view instead of interpreting a failed read as zero debt.

Borrowing and collateral withdrawals with debt require `debtUSD <= collateralUSD * LTV`. This conservative withdrawal boundary preserves the opening buffer rather than allowing withdrawals down to the liquidation threshold. Debt-free withdrawals do not consult the oracle and continue through a global freeze. Supply within its cap, repayments, liquidations and debt-free exits remain possible while frozen. Debt-bearing withdrawals and all new borrowing fail during a global freeze. Reserve freeze blocks new borrowing from that reserve. Supply-cap exhaustion can prevent top-ups; governance must retain rescue headroom and monitor it.

## Liquidation, dust and realized loss

Liquidation is permissionless only when HF is strictly below 1. Between HF 0.95 and 1 the selected debt is limited by the configured close factor (default 50%); below 0.95 up to all selected debt is eligible. The maximum payment is capped by the caller's budget, close-factor limit and collateral USD value divided by `(1 + bonus)`, converted conservatively into the selected debt asset. Repayment share burning uses the same exact-debt-reduction rule as normal repayment. Seizure rounds downward. A caller must provide a deadline and minimum IMD output. `previewLiquidation` exposes the same quote logic; execution state may still change before inclusion.

When a collateral-limited liquidation leaves no more than $0.001 of rounding residue, the final residual collateral is included in the seizure. If economically negligible collateral cannot fund even one debt repayment base unit, `finalizeDust(account)` permits anyone to settle an unhealthy account whose **upward-rounded total collateral valuation** is no greater than $0.001. Valid fresh oracles, outstanding debt and genuine insolvency (`upward-rounded collateral USD < upward-rounded debt USD`) are required. Every outstanding debt reserve must also have zero affordable debt-share repayment; if any ordinary repayment is possible, finalization rejects. This prevents erasing tiny but economically recoverable positions. The caller receives the residual IMD; all remaining debt is written off. There is no arbitrary administrator debt erasure.

Whenever collateral is exhausted, remaining debt across all three reserves is removed from accruing debt shares and recorded as fixed `badDebt` in the respective native debt units. The entire bank and affected reserves freeze. The lost principal and interest are visible, not hidden in a debt-free account. Anyone may recapitalize through `coverBadDebt(asset, amount)`, which requires exact incoming assets and reduces the recorded loss by that amount. Recovery does not automatically unfreeze; governance must separately review and resume operation. Global unfreeze is impossible while any recorded bad debt remains. **Residual availability tradeoff:** even a tiny actual loss triggers this global halt. An adversary can select a tiny already-insolvent position to trigger a halt, requiring recapitalization and a timelocked restart. This favors explicit loss recognition over availability; it is a medium operational/availability limitation and must be accepted before activation. There is no minimum position size, so sub-gas-value positions are also possible.

A liquidity collapse can make liquidation economically unattractive even before numerical dust. No contract can guarantee buyers, keeper gas profitability or token transferability. Oracle outages intentionally block price-dependent liquidations as well as new debt, preserving price integrity at the expense of liquidation liveness. Operators must keep independent oracle and liquidation infrastructure alive, retain funded reserve capital, and freeze new exposure promptly; there is no manual stale-price liquidation bypass.

## Default risk boundaries and operational duties

| Parameter | Inactive experimental default | Hard contract bound |
|---|---:|---:|
| IMD supply cap | 0 | `1e30` base units |
| Each reserve borrow cap | 0 | `1e30` base units |
| Global freeze | true | only governance may unfreeze |
| LTV | 25% | at most 40% |
| Liquidation threshold | 35% | greater than LTV, at most 50% |
| Liquidation bonus | 8% | at most 15% |
| Close factor | 50% | 10–100% |
| Severe HF threshold | 0.95 | fixed |
| Protocol fees | 0% | immutable |

The threshold also satisfies `threshold * (1 + bonus) < 1`. These numerical bounds ensure internal buffer consistency; they do not prove solvency after an abrupt gap, oracle compromise, collateral bridge expansion or failed liquidations. Production activation needs independently sourced IMD pricing, calibrated price bands/heartbeats, market-depth and volatility evidence, concentration/admin acceptance, capital funding, keeper commitments, deployed-byte verification, multisig ownership review, end-to-end production frontend verification and an external audit.

Operations must monitor reserve cash/utilization, pending governance proposals, bridge peers/delegates and ownership, feed age/deviation, custody-versus-receipts, total indexed debt, bad debt, liquidation profitability, and impending cap exhaustion. The frontend must use verified deployment addresses, validate chain ID 1, simulate transactions and request exact approvals (including USDT reset-to-zero handling). Source-level tests and simulated fork deployments do not prove a production release is safe or that the frontend is durably hosted.
