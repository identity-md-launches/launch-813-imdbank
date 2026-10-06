# Validation record

Date: 2026-10-06 UTC. Compiler: Solidity **0.8.26**, optimizer 200 runs, Cancun target, metadata bytecode hash disabled. Foundry: **1.8.3**. Verification below records observed local results, not independent deployment authorization or a production audit certificate.

## Executed checks

| Check | Observed result | Evidence / scope |
| --- | --- | --- |
| `forge build` | Pass | [`forge-build.txt`](evidence/forge-build.txt); compiler heuristic lint warnings remain and are triaged in the security review |
| `forge test` | 47 passed, 0 failed, 0 skipped | Independent contributor run at the default 512 fuzz runs, [`independent-review-checks.json`](evidence/independent-review-checks.json) |
| `forge test --fuzz-runs 10000` | 47 passed, 0 failed, 0 skipped | [`forge-tests.txt`](evidence/forge-tests.txt); 10,000 cases per fuzz function |
| Stateful invariants | 128 runs, 8,192 handler calls, all three invariants pass | Collateral conservation, exact reserve cash flow and aggregate debt rounding; handler catches expected unsafe-action reverts |
| `forge fmt --check` | Pass | [`forge-fmt.txt`](evidence/forge-fmt.txt), empty successful output |
| Mainnet fork tests | 3 passed, 0 failed, 0 skipped | [`mainnet-fork-tests.txt`](evidence/mainnet-fork-tests.txt), pinned block 26,134,012 |
| Frontend EIP-1193 fork integration | Pass, 46 confirmed receipts | [`frontend-fork.json`](evidence/frontend-fork.json), real canonical tokens, vendored frontend ABI/provider/parser, local Anvil only |
| Frontend unit tests | 12 passed | [`frontend-unit-tests.txt`](evidence/frontend-unit-tests.txt); finite fixed-point amounts, configuration gates, wallet context, projections, calldata, mutable token metadata and required screens |
| Frontend ABI compatibility | Pass | `node web/tests/abi-compatibility.mjs`, exact functions/outputs/mutability against compiler artifacts |
| Deployment-byte inspection | Pass for all three application artifacts | [`bytecode-check.txt`](evidence/bytecode-check.txt); size bounds and no forbidden opcodes under the supplied PUSH-aware scanning rule |
| Economic scenarios | 80 cases executed; 49 show shortfall | [`economic-stress.csv`](evidence/economic-stress.csv); deliberately hypothetical assumptions, not an IMD historical backtest |
| Independent contributor adversarial review | Nine regression/edge tests pass | [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md), three contract findings and one frontend finding repaired; one Medium availability issue remains |

The current Foundry version groups the three stateful invariants as one reported test item, hence its total differs from simply counting function declarations. Stateful handlers use three actors and exercise supply, borrow, repay, withdrawal, donations, time passage and price-shock liquidation. Invalid actions are expected; conservation is checked after each sequence. Neither fuzz counts nor invariant passes establish completeness of state exploration.

## Mainnet and frontend integration boundaries

The fork starts from Ethereum block **26,134,012**, hash **`0x4c88763379e950dc0c749b6e9f12501f2195d4bbdef406545a1c5f9ffd0ca108`**. Public reads used the endpoint recorded in [research](RESEARCH.md). Each fork test requires chain ID 1, that block number, nonempty canonical token code, expected decimals and IMD symbol at the historical snapshot; it fails if these requirements are absent. No test silently substitutes local token mocks for the canonical addresses.

Foundry tests supply real IMD obtained from a pinned holder under impersonation, use canonical USDC/USDT/WETH transfers (including USDT's nonstandard return), execute all three borrows, reject unsafe actions, repay, withdraw, liquidate and verify bad debt/custody. Reserve funding for this fixture uses local `deal` state changes; this does not assert issuer permissions or transferable production balances. Separate tests inspect actual Chainlink USD rounds at the same block.

The frontend integration fixture instead funds from real token holders on the local fork and wraps ETH into canonical WETH. It connects through an EIP-1193 adapter and the browser-provider implementation bundled in the website. It executes exact approval, supply, enable collateral, all three borrow paths, partial/full repayment, withdrawal, invalid LTV and collateral-disable rejection, an oracle shock, rejected liquidation minimum output, successful liquidation, and final zero debt/collateral. It refuses non-loopback URLs and requires Anvil. No key is read or public-chain transaction sent.

The **final-source frontend replay passed at block 26,134,156**, with block hash, final source SHA256, actual fixture runtime hash and EVM hardfork recorded in `frontend-fork.json`. A previous successful frontend run started from block 26,134,012; that result is preserved in `frontend-fork-initial.json`. During a later replay the public RPC no longer served newly requested state at that original block (`fork-rpc-limitation.json`). This is an archival availability limit, not a silently skipped test. The replay was explicitly repinned and completed against the final source; durable replay of the original snapshot requires a working archival provider.

**Both lifecycle fixtures use an explicitly mocked IMD valuation**, because no production IMD oracle is approved. The real Chainlink round test does not prove that an independent dual-source oracle configuration exists for all four assets. The frontend harness is **not** browser automation: it does not load the page in a real wallet extension, click DOM controls, verify mobile/keyboard layout, test WalletConnect, or exercise a hosted public website. Those requested release criteria remain unmet.

Replay the integration without exposing an unlocked fork node publicly:

```sh
anvil --fork-url https://eth.blockrazor.xyz --fork-block-number 26134156 --chain-id 1 --accounts 0 --auto-impersonate --silent
node web/tests/fork-integration.mjs http://127.0.0.1:8545
```

The mock oracle artifact is compiled by `forge test`. This script mutates only local test state. Fork replay requires upstream historical state access; the default build, unit/fuzz/invariant tests, bytecode checks and frontend unit checks work without network access or package downloads.

## Attack and failure coverage

- Oracle zero/negative/stale/future/missing/inconsistent rounds, feed-decimal changes, divergent sources, price bands, stale-configuration rollback and guardian disable/unfreeze restrictions.
- USDC/USDT six-decimal versus WETH/IMD eighteen-decimal accounting; exact receive/send checks; optional-return, false-return and taxed tokens; callback reentrancy; unexpected external token confiscation.
- Borrowing and partial/full repayment rounding, multi-reserve interest and health factors, repeated supply/withdrawal conservation, indexed debt aggregation, direct donations and cached interest, checkpoint-frequency attack regression.
- Flash-funded supply/borrow/withdraw sequence rejection. The bank offers no flash-loan entrypoint. This test does not prove an external flash loan cannot manipulate a future selected oracle source.
- Price gap and WETH appreciation, stablecoin debt repricing, insufficient cash, cap reductions, health/close-factor eligibility, liquidation deadlines/minimum output, multi-reserve loss recognition and recapitalization.
- Extreme positive-but-near-zero collateral prices, unsafe dust finalization, recoverable small positions, atomic rollback on failed finalization transfers, and the retained tiny-real-loss global-halt risk.
- Guardian/governor separation, delayed execution, cancellation, replay/domain separation, failed execution rollback, constructor role handoff, wrong-chain and invalid governance deployment rejection.
- A liquidation gas budget assertion below 1,000,000 gas under the local fixture; fixed three-reserve loops and at most 64 exponentiation steps. No claim is made about worst-case gas through arbitrarily upgraded underlying token/feed code or profitable liquidation under real gas spikes.

Economic stress assumes 100 IMD at $10, $250 initial debt, 35% threshold, 8% liquidation bonus, price drops from 0–95%, execution haircuts from 0–90%, and debt-value multipliers from 0.8–2. These 80 combinations illustrate gap/depeg/depth risk. Forty-nine cases have shortfall after the incentive; even a low starting LTV cannot guarantee solvency when collateral liquidity collapses. There is no fitted probability distribution or claim that the sampled inputs predict IMD outcomes. Production parameter calibration remains open.

## Static analysis and independent review

Compiler static heuristics and manual code review ran. No installed Slither or Mythril executable was available, and neither was run or represented as passing. The vendored arithmetic library is pinned. All application runtimes fit EIP-170: IMDBank **12,360 bytes**, RiskOracle **4,266 bytes**, GovernanceTimelock **1,934 bytes**. The supplied protected harness also scans unreachable runtime data; a pooled event topic originally contained a forbidden byte, so the event was renamed to the equivalent `FrozenStateChanged`, and the same PUSH-aware scan now passes. No forbidden executing opcode was introduced.

The independent contributor reviewed code and wrote reproductions separately from its implementation owner. Research/risk/audit, protocol architecture/Solidity, frontend/Web3/QA/integration, and root oracle/governance/testing/economic/deployment work were handled in separate cooperating workstreams. They are agent contributors, not an accredited external audit firm. No established Critical or High code exploit remained within the bounded reviewed scope. Medium M-05 and major release dependencies remain open, and this statement must not be marketed as production audit clearance.

Missing validation includes long-duration production-like soak tests, historical IMD market calibration and manipulation-cost measurements, complete LayerZero remote configuration review, actual browser/extension/mobile E2E, public hosting verification, WalletConnect, live independent IMD oracle integration, final multisig/constructor parameters, network factory rehearsal with its exact signed deployment manifest, and external auditor signoff. The project is a useful locally checked implementation and handoff, **not a completed production launch**.
