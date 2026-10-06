# Contributor test coverage

This addition tests the existing immutable contracts. It changes no application source,
configuration, frontend, dependency, or deployment artifact. All test dependencies are already
vendored. The default test run needs neither network access nor environment mutation.

## Suites and properties

| File | Additional coverage |
| --- | --- |
| `AccountingEdges.t.sol` | Invalid amounts, recipients and reserves; cumulative caps and interest; unsolicited collateral; exact LTV, health-factor and close-factor boundaries; third-party repayment; prospective rate changes; kink/full utilization; index saturation and exit; atomic rollback of repayment and liquidation; partial recapitalization; repayment conservation and repeated tiny borrow/repay cycles across both token precisions. |
| `ThreeReserveInvariants.t.sol` | Three funded actors with starting debt in every reserve; random supply on behalf, borrowing to another recipient, partial/full repayment, withdrawal, direct/protocol donations, time, price changes, liquidation, dust finalization, freezes, collateral toggles and recapitalization. |
| `OracleIntegrationEdges.t.sol` | Real `RiskOracle` wired to `IMDBank`, with synthetic external aggregators. Independent heartbeat boundaries, malformed round metadata, extreme signed answers, price bands, replacement/enable rollback, source outages, cross-reserve debt valuation, depegs, decimals 0–18, and deviation boundaries. |
| `GovernanceEdges.t.sol` | Delay/grace boundaries, expiry and cancellation followed by a fresh delay, failed-target retry, nested execution, complete operation-domain binding, constructor failure paths, every bank risk-control authority, guardian rotation, and reserve freeze isolation. |
| `TokenBoundaryEdges.t.sol` | Every bank mutator's reentrancy guard, callbacks on inbound/outbound transfers, false/short/extra/noncanonical returns, empty returns, sender surcharges/refunds, receiver taxes/bonuses, issuer pause, and transaction rollback of claims, balances and allowances. |
| `OptionalMainnet.t.sol` | Opt-in fork extension at the existing suite's pinned block 26,134,012, using deployment asset constants: interest-bearing repayment across three assets, unsafe-action rejection, exit, collateral exhaustion and actual-token recapitalization. Missing RPC skips the suite at setup. |

The six contributor stateless fuzz tests each run 1,000 cases through inline configuration.
The new invariant campaign runs 256 sequences of 96 calls with `fail-on-revert = true`.
Expected protocol rejections are checked by selector; unexpected errors and harness assertions
fail the run. No arbitrary revert is silently swallowed in the handler.

The handler tracks independent ledgers from successful external flows:

- IMD claims equal supplied tokens minus withdrawals and seized collateral, per actor.
- Actual IMD custody equals those claims plus unsolicited IMD donations.
- Each reserve's actual cash equals its starting cash, plus donations, repayments and
  recapitalizations, minus disbursed borrowing.
- Recorded bad debt equals unpaid account debt on collateral exhaustion, minus actual
  recapitalization. Unpaid debt in other reserves is included.
- The sum of individual debts can exceed rounded aggregate debt by at most two native
  token units for three actors; indices never decrease when time advances.
- Successful borrowing/withdrawal respects LTV; a successful repayment reduces debt by
  exactly the actual payment. Liquidation execution matches an unchanged preview and charges
  no more than the submitted budget.
- Material cumulative losses latch a reserve halt at writeoff time; partial cover or a later price
  change cannot clear it. Recorded losses at or below $1 need not halt lending. An independent
  ghost ledger tracks the expected halt through writeoffs and recapitalization and checks both
  the contract's halt flag and required freezes. Disabled or exhausted collateral leaves no active
  user debt. After each random sequence, full repayment and debt-free withdrawal must unwind
  every remaining claim, including when frozen or after extreme price changes.

Starting supply and debt are asserted nonzero. A deterministic handler exercise separately
reaches liquidation, dust writeoff, recapitalization, repayment and withdrawal so the important
transitions do not depend exclusively on random discovery.

## Revision for the accepted second-round repairs

This revision preserves the existing suites and updates the expectations affected by R2-01,
R2-02 and R2-03. The initial build exposed an outdated eleven-field oracle getter destructure;
after correcting it, the baseline run exposed three stale expectations (two-sided price bands,
opening tiny debts, and the invariant handler rejecting `MinimumDebt`). Those are test
compatibility issues with the accepted repairs, not new contract defects.

- Oracle integration now checks the added pause field, failed-enable rollback, agreed collateral
  crashes below the configured floor and debt spikes above the ceiling. Real bank liquidations
  must remain possible in both adverse price directions. A guardian-pause scenario checks the
  exact expiry, stale observations at expiry, fresh observations restoring liquidation while the
  bank is frozen, and failure to extend the pause by repeating it or rotating the guardian.
- A new 1,000-case property checks the minimum debt at differing reserve prices and precisions,
  atomic rejection one native unit below the boundary, one-unit top-ups, repayment-created dust,
  and reopening only when the resulting debt satisfies the minimum. A unit test prevents another
  account or reserve from satisfying that minimum. Repeated tiny borrow/repay cycles retain an
  admitted position while exercising one-unit rounding and end with a full repayment/no-profit check.
- The existing random handler still generates sub-minimum amounts, checks the specific rejection
  and verifies rollback. Its loss model distinguishes non-halting dust from a material-loss halt.
  A deterministic sequence accumulates $0.50, another $0.50, then one USDC base unit of loss;
  it verifies the strict threshold, failed restart after partial cover, and full recapitalization.

## Running

```sh
forge build
forge test
```

For the optional fork tests, set `IMDBANK_TEST_MAINNET_RPC_URL` in the invoking process using an
archive-capable Ethereum RPC, then run:

```sh
forge test --match-contract OptionalMainnetTest -vv
```

The RPC value is never committed or set by a test. An explicitly supplied but unusable endpoint
fails, rather than being treated as a successful fork run.

Final local verification: `forge build` succeeded with compiler lint warnings; `forge test`
completed with **101 passed, 0 failed, 1 skipped** on Foundry 1.8.3. The optional fork suite's setup
is the single skip because no RPC is configured. The three-reserve invariant completed
**256 runs / 24,576 calls / 0 handler reverts**. `forge fmt` and `git diff --check` also passed.
Build outputs and caches were redirected into `test/scratch/` to keep generated files inside the
assignment's write scope; no source, configuration or dependency changes are required for the
default commands above.

## Scope and limitations

Local token/feed prices and balances are synthetic scenarios, not verified IMD market data or
production risk calibration. The stateful campaign permits authorized freezes/recovery but does
not model arbitrary governance reconfiguration, external rebases between transfers, token issuer
confiscation, or a trustworthy live IMD oracle. Unit tests cover additional authorization,
configuration, transfer and oracle failure paths. A correct accounting invariant cannot establish
executable market depth or profitable keeper operation.

The fork extension uses the accepted integration fixture's pinned block/holder and explicit mock
IMD valuation. It is not browser/wallet E2E validation. This contributor run has no configured fork RPC, so live
fork execution remains unverified. Public website hosting, deployment, static analyzers beyond
Foundry's compiler/lint checks, and the production release blockers already recorded in the
project's security documentation are outside this bounded test contribution.

No new reproducible contract defect was found by this addition. Passing these tests is not a
production security sign-off.
