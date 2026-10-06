# Independent contributor adversarial review

Review date: 2026-10-06. Reviewer: separate research/security contributor agent, independent of the protocol implementation agent. This is a bounded contributor review, **not an external audit firm certification and not approval to accept funds**. Scope: `src/IMDBank.sol`, `src/lib/ExactToken.sol`, `src/RiskOracle.sol`, `src/GovernanceTimelock.sol`, unit fixtures and selected frontend transaction paths. Tests/research findings were reported to the implementation owner and repaired locally where indicated.

## Findings and reproduction record

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| M-01 | Medium | Permissionless interest checkpoint frequency changed borrower cost and liquidation eligibility | Repaired; regression passes |
| M-02 | Medium | Collateral below the debt token's smallest unit could not liquidate or finalize, leaving losses unrecognized | Repaired with guarded dust finalization; regressions pass |
| M-03 | Medium, frontend availability | IMD owner metadata changes disabled every website transaction, including repayment/exit | Repaired in source; browser metadata-mutation coverage remains a QA item |
| M-04 | Medium, availability | Dust finalization wrote off fully recoverable small positions and triggered global freeze | Repaired; rejection and ordinary recovery regressions pass |
| M-05 | Medium, residual availability | A genuine one-base-unit loss globally halts new borrowing | Open, explicit safety-first policy; quantified by regression |

No Critical or High code exploit was established during the reviewed scope at this snapshot. That statement is narrower than a claim of production safety. The residual Medium availability limitation and the release blockers below prevent a production-ready conclusion.

### M-01: caller-selected interest compounding

Initial `_previewIndex` computed `index * (1 + APR * elapsed / YEAR)`; every public `accrue` checkpoint persisted the result. For equal elapsed time at fixed 100% APR, one annual call produced 2x principal while 365 daily calls produced about 2.7146x. With 1,000 IMD at $10, $1,500 USDC debt and 35% liquidation threshold, the annual branch remained healthy while the daily branch became liquidatable. An unrelated caller could choose the branch.

Repair: fixed per-second compounded factor using bounded exponentiation by squaring, conservative rounding and an index ceiling. `testAudit_checkpointFrequencyCannotMateriallyChangeBorrowerDebt` compares both paths with a one-base-unit debt tolerance and negligible health-factor tolerance. Both now have the same economic result. This comparison fixes cached APR so utilization changes cannot obscure the issue. The single test's 365 operations are a harness stress loop, not the gas cost of one production action.

### M-02: worthless residual collateral blocked insolvency handling

Initial state: 1,000 IMD collateral, 1,500 USDC debt. Set the valid positive test oracle value to one wei of USD per IMD. `_liquidationQuote` rounded covered USDC below one native unit and reverted `Dust`; collateral never reached zero, `_writeOff` was unreachable, `badDebt` stayed zero and reserves remained active.

Repair: `finalizeDust(account)` requires debt, fresh valid prices, unhealthy health factor and a conservative rounded-up collateral value no greater than the dust threshold. It finalizes collateral custody, records losses, freezes risk and transfers the residual collateral atomically. Independent regressions cover extreme collapse, healthy positions, valuable collateral, broken oracle and a taxed outgoing IMD transfer. The last case proves a failed token movement rolls back the writeoff and freeze. M-04 separately reviews whether this admission rule is sufficiently narrow.

### M-03: mutable token symbol blocked repayments

Research established that IMD's token owner can call `updateSymbol`. The initial frontend required `symbol() === "IMD"` during each refresh, clearing `state.verified` and disabling all actions when the comparison failed. A metadata change therefore denied website access to repayment and withdrawal even when canonical address, bytecode and token decimals were unchanged.

Expected behavior: immutable configured address/code and accounting decimals determine transaction safety; changed display metadata must produce a visible warning and retain verified repayment/exit paths. Other token assumptions and runtime verification remain enforced. Source verification confirmed `actualSymbol` is retained as a visible warning and no longer rejects refresh; immutable bank accounting units are checked against live decimals. A real browser metadata-mutation case remains an explicit QA coverage limitation.

### M-04: small solvent accounts could manufacture a writeoff

Concrete reproduction in the first `finalizeDust` implementation:

1. Supply `1e14` IMD at $10: collateral value $0.001.
2. Borrow 200 USDC base units: debt $0.0002.
3. Lower IMD to $5: collateral value $0.0005 and health factor 0.875.
4. `previewLiquidation` permits full 200-unit repayment, proving all debt is recoverable with the configured bonus.
5. `finalizeDust` instead gives all collateral to its caller, writes off 200 units and globally freezes borrowing.

The monetary amount is tiny, but restarting borrowing requires governance action. An attacker can accumulate small positions and repeat during price moves. Require actual inability to liquidate, prevent needless loss, and explicitly address microscopic losses as a denial-of-service vector. Repair: require conservatively rounded collateral value below total debt, then check all three reserves and reject finalization whenever an affordable ordinary repayment can burn debt shares. `testAudit_smallRecoverablePositionCannotTriggerGlobalFreeze` now proves finalization rejects and ordinary liquidation clears debt. `testAudit_insolventButPartlyRecoverableDustMustLiquidateFirst` prevents premature writeoff of an insolvent but still partly repayable position.

### M-05: genuine microscopic losses still stop all lending

This remaining behavior is explicitly retained to prioritize recognition of any insolvency over availability. Supply `4e11` IMD at $10 and borrow one USDC native unit ($0.000001). A move to $2.40 values the collateral at $0.00000096, too little to repay even one unit including bonus. Finalization correctly records one unit of loss and freezes the entire bank. The economic loss is genuine, but the global outage can cost much more than the loss; repeated tiny positions can prolong it. `testAudit_actualTinyLossTriggersGlobalSafetyHalt` quantifies the behavior. Operators need loss monitoring, recapitalization and timelock response procedures; minimum economical position sizes or a separately reviewed dust-loss policy remain possible future mitigations. This item is not represented as resolved.

## Reviewed security properties and remaining assumptions

**Accounting and rounding.** Borrow shares round upward; partial repayment burns only affordable shares and charges the exact reduction in displayed debt. Integer bounds, indexed growth, fixed three-reserve loops and full-precision multiplication were checked. Aggregate debt can differ by rounding dust from summed separately rounded accounts; no withdrawable reserve share claims exist in this treasury-funded design. Direct token donations do not grant collateral credit or withdrawal rights.

**ERC20 and reentrancy.** Every bank mutation uses a shared reentrancy guard. ExactToken accepts absent return data, rejects false/malformed returns, and checks both sender and receiver deltas. Callback, transfer-tax and output-failure tests verify atomicity. These checks cannot make an arbitrary lying token safe; constructors/production manifests must pin the researched assets. Later blacklisting, fee activation, rebase or bridge failure remains a liquidity/availability dependency risk. Treasury liquidity donations are deliberately non-redeemable and must never be marketed as yield-bearing deposits.

**Oracles.** Two distinct addresses are required, but economic source independence cannot be proved by address inequality. Nonpositive values, stale/future/missing timestamps, inconsistent rounds, decimal drift, bounds and excessive disagreement reject. Collateral chooses the lower accepted price; debt chooses the higher. Configuration that fails validation rolls back. The same manipulated market behind both feeds can defeat agreement checks, and authorized governance can choose bad feeds. Therefore source independence and appropriate heartbeat settings remain explicit admission conditions. No source is automatically safe because it implements the aggregator interface.

**Liquidations/economics.** Health factor, close-factor threshold, conservative collateral conversion, minimum output and deadlines were reviewed. Repeated tiny liquidations, collateral exhaustion, price gaps, exhausted cash and stablecoin debt appreciation require continued fuzz/invariant coverage. A valid oracle can report a price at which no liquidator can sell collateral; arithmetic correctness does not ensure liquidation profitability. Invalid feeds stop liquidations while repayment and debt-free withdrawal remain possible. That tradeoff needs an incident playbook and funded loss backstop.

**Administration.** RiskOracle and GovernanceTimelock expose no observed unauthenticated parameter path. Timelock IDs include chain, timelock address, target, calldata hash and salt; execution marks state before the call, rejects reentry, rolls back on failure, and expires after its grace period. Proposer/canceller roles and immutable delay are checked. Timelock proposer and guardian must actually be independent reviewed multisigs in production; address constructor arguments do not establish this. Irrecoverably lost immutable role keys are an operational migration risk. Authorized parameter changes can make existing positions liquidatable; delay, monitoring and user notice are essential.

**Upgrades.** These application contracts are immutable and have no intended proxy upgrade route. Upstream token and feed contracts can have independent administrators and upgrades. Verify runtime/dependencies at a finalized launch block and monitor external implementations afterward. Contract-size/forbidden-opcode checks are deployment policy checks, not vulnerability analysis.

**Frontend.** Canonical asset addresses, bank/oracle runtime hashes, chain ID, account changes, spender review, exact-size approvals, allowance reset, preflight simulation, receipt status and liquidation minimum output/deadline were inspected. EIP-6963/injected-wallet support is distinct from WalletConnect QR/session support. A local fork browser adapter validates its own transaction path; it does not validate every real wallet extension or hardware signing flow. Public configuration is unset by default and must never display invented production addresses.

## Verification evidence and limitations

Independent command: `forge test --match-contract IndependentAuditTest -vv`. After M-01/M-02/M-04 repairs: **9 passed, 0 failed**. One case quantifies the retained M-05 safety-halt limitation; passing it does not mean the availability limitation disappeared. Tests use no environment variables or network. A subsequent full `forge test` run completed with **47 passed, 0 failed**, including 512-run fuzz cases and 128 invariant runs / 8,192 handler calls. `forge build` and the bytecode policy checker passed. [`independent-review-checks.json`](evidence/independent-review-checks.json) records the reviewed compiler runtime templates and exact limits; later integration changes require revalidation.

The integration owner ran compiler lint and `tools/check_bytecode.py`, which validates deployed sizes and excludes forbidden opcodes while skipping PUSH data. Slither and Mythril were unavailable and **were not run**. Manual review, compiler lint, a bytecode policy check and economic simulations do not substitute for those named analyzers. Likewise, a mainnet fork using mock prices proves token/accounting integration, not a trustworthy live IMD oracle. The overall test/fork/browser report is maintained separately by the integration owner.

## Compiler-lint triage

`forge build` completed with heuristic warnings. Manual triage: the timelock sets its execution guard and completion state before its external call; the bank similarly guards all mutation paths. Events after guarded interactions do not establish a reentry bypass. Calls/validation inside reserve loops are bounded to exactly three assets, and timestamp comparisons intentionally enforce deadlines, freshness and timelock delays. Oracle signed-to-unsigned conversions follow a strict positive-answer check and bounded normalization. Constructor token validation requires code and supported decimals, including rejecting the zero address. Test timestamp warnings concern Foundry warp instrumentation, not deployment logic; explicit captured timestamps are used for the independent checkpoint comparison. This triage does not suppress or claim elimination of all linter output.

## Release blockers, distinct from code findings

- No admitted independent IMD oracle or proven source/manipulation-cost study.
- IMD bridge owner has empty code at the research block; active remote peers, DVNs, libraries, custody and cross-chain supply remain unreviewed.
- No same-block executable liquidation-depth study, historical stress distribution or beneficial-holder analysis sufficient to calibrate nonzero caps.
- No external real-money security sign-off, operational multisig/timelock handoff, insurance/backstop funding or incident rehearsal established by this review.
- Public hosting, production deployment addresses, real wallet matrix and all website-to-fork acceptance paths require explicit evidence from deployment/QA.

Production caps must remain zero until these conditions are resolved. A claim that this repository is fully production-ready would exceed the evidence.
