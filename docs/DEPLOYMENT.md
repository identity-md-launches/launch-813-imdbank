# Deployment handoff and operation

## Current status

**Public HTTPS URL: not deployed / unavailable. Mainnet application addresses: not deployed.** No wallet keys were read and no transactions were broadcast to a public chain. All state-changing integration activity used local Foundry or Anvil fork state. Hosting access, final role addresses and a confirmed deployment address set have not been supplied. A public website deployment must still be performed and verified; local serving and integration tests do not meet that criterion.

The public frontend remains intentionally unconfigured. Do not copy temporary fork addresses into production. Do not deploy a live-money market until the [research admission conditions](RESEARCH.md) and independent external security review have been met.

## Explicit constructor parameters

Deploy three nonpayable, immutable applications, in order:

| Application | Constructor parameters |
| --- | --- |
| `GovernanceTimelock` | `governanceMultisig`, `vetoMultisig`, `172800` |
| `RiskOracle` | deployed timelock, `emergencyMultisig` |
| `IMDBank` | deployed timelock, `emergencyMultisig`, IMD, deployed oracle, USDC, USDT, WETH |

Three roles must be distinct and nonzero: the governance proposer, the timelock veto (canceller) and the emergency guardian of the bank and oracle. **The veto multisig must not be the emergency multisig.** A key holding both could pause a feed or freeze the bank and then cancel every governance operation that would reverse it or rotate it, turning an emergency action into a permanent state; the rehearsal helper rejects that wiring. The rehearsal helper requires code at all three multisig addresses, but code presence does not prove a valid Safe configuration. The network owner must provide the real addresses and independently inspect signer sets, thresholds, modules, guards, fallback handlers, recovery policy and signer separation. Suggested starting governance policy is a reviewed 3-of-5 governance Safe, a distinct 2-of-3 emergency Safe and a distinct veto Safe (for example a security council); these are operational suggestions, not configured facts. The factory must never receive governance implicitly through `msg.sender`.

Canonical chain ID is **1**. Token arguments:

| Asset | Address | Decimals |
| --- | --- | --- |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | 18 |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | 6 |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | 18 |

Addresses and code/metadata were researched at block 26,134,012; refresh them at a finalized deployment block. IMD symbol/name are mutable, so compare canonical address, source, code and units rather than treating its display label as immutable identity.

`script/DeployMainnet.s.sol:deploy(governanceMultisig, vetoMultisig, emergencyMultisig)` rehearses this explicit configuration without reading environment variables or broadcasting, and checks that the oracle's guardian pause is at least the timelock delay. `test/DeploymentRehearsal.t.sol` verifies constructor role handoff and delayed governance under an offline token fixture. It does not certify a real Safe or deploy anything publicly. A deployment manifest with invented role addresses would be misleading; the final launch manifest must be produced from the confirmed network-owner configuration and the three reviewed artifacts.

Initial constructor state is intentionally complete and inactive: zero supply/borrow caps, global freeze, no configured prices. There are no initializers, proxies, delegatecalls, native ETH deposits, protocol fee setters or administrator withdrawal paths. Compile with the pinned compiler and `bytecode_hash = "none"`.

## Activation gates and parameter record

1. Complete IMD remote peer/DVN/delegate/admin analysis, finalized supply/holder reconciliation and executable liquidation-depth study. Publish volatility and liquidity-collapse assumptions. Zero caps remain the justified production choice until these are resolved.
2. Select two genuinely independent USD sources for each asset. Distinct addresses alone are insufficient. No suitable IMD/USD pair has been approved. Record feed addresses, operator independence, units, heartbeats, max ages, price bands and deviation bounds. The dispatcher permits ages up to 48 hours: configure each feed's maximum age as its heartbeat plus a grace margin (for example 86,400 s + 3,600 s for the catalogued USDT/USD and USDC/USD feeds, 3,600 s + 900 s for ETH/USD), never exactly the heartbeat, because the heartbeat round lands after the heartbeat elapses. Bounds are one-directional: `maxPrice` caps collateral feeds, `minPrice` floors debt feeds (`0` = no floor); a collateral crash or debt spike is priced as reported rather than rejected.
3. Verify governance and guardian configuration, proposer/canceller/guardian separation and the immutable two-day delay. Every feed/risk/cap change must be scheduled with its exact target, calldata and salt. Anyone may execute after readiness and within seven days, so a scheduled risk-parameter cut takes effect at a block chosen by whoever executes it and can be followed by a liquidation in the same transaction; publish scheduled changes to borrowers as soon as they are scheduled. Veto or proposer may cancel. A failed execution rolls back. Timelock role addresses are immutable; the bank and oracle guardians can be rotated only by governance; Safe signer rotation must preserve addresses.
4. Derive and publish caps, LTV/threshold, bonus, close factor and rate curves from stress evidence. The example 25% LTV/35% threshold/8% bonus and 2%+8%+90% rate curve are testing assumptions, **not** approved market parameters.
5. Fund reserve liquidity only with explicitly irrevocable risk capital. `donateLiquidity` issues no redemption or yield claim; neither operators nor donors can withdraw it. Interest remains in the bank. Reserve cash can be lost through bad debt.
6. Verify all deployed source and immutable runtime bytes; confirm no forbidden opcodes and size limits. Runtime hashes must include deployed immutable substitutions, not zero-placeholder artifact bytes. Conduct an independent external audit and replay the final exact configuration on a fork.
7. Only then schedule feed configuration, bounded caps and unfreeze. Monitor the timelock throughout the delay. Abort via guardian if any assumption changes.

The launch service must separately estimate deployment gas with actual constructor dependencies and its CREATE2/factory process. This project rehearses constructor behavior and checks runtime/initcode sizes; it does not claim the network's protected deployment test or gas ceiling was independently passed.

## Static HTTPS hosting

`web/` is self-contained. Copy its files to a reviewed static host; it needs no runtime build, CDN, package installation, server secrets or API backend. A host that supports the included `_headers` file can apply its policy; other hosts must configure equivalent HTTPS, CSP, nosniff and framing restrictions. Public RPC HTTP access must be HTTPS. Wallet requests use the selected wallet provider.

Populate `web/config.json` with the real bank/oracle addresses, their EVM keccak256 runtime hashes, chain ID 1, the four canonical tokens, an approved optional public read RPC and receipt confirmation count. Review this as a security-sensitive release: an attacker who can rewrite both addresses and hashes can redirect users. Obtain and retain release hashes independently of the website.

Publish over HTTPS with domain control and rollback capability. Check that HTML, config, JS, CSS and the vendored module return correct MIME types, that no source is fetched from third-party CDNs, and that the configuration is not stale-cached. Run actual desktop/mobile wallet QA, account/network-switch rejection, approval resets, replaced/rejected transaction handling and onchain receipt reconciliation. WalletConnect requires its own reviewed vendored connector and project configuration; it is not currently implemented. Report the final HTTPS URL and evidence from an independent public fetch only after this succeeds.

## Operator responsibilities and incidents

| Role | Responsibilities and permitted action |
| --- | --- |
| Governance multisig | Review source/risk/feeds; schedule parameter/cap/guardian changes; unfreeze only after investigation and recapitalization; answer every guardian feed pause within its window with a permanent disable, a reconfiguration or a re-enable |
| Veto multisig | Cancel pending timelock proposals; holds no pause, freeze, unfreeze or parameter power; must be a different key set from the emergency multisig |
| Emergency multisig | Freeze new borrowing globally or by reserve; pause a suspect oracle feed once for the guardian pause window (two days by default) until governance decides; cannot unfreeze, re-enable, change prices, cancel proposals or seize user funds |
| Risk/bridge monitors | Watch IMD owner, peers, delegate, messaging security, supply, custody concentration, liquidity ranges and executable exit depth |
| Oracle operators | Maintain independent sources, round timestamps and recovery evidence; alert on age/deviation/band failures; never substitute an unreviewed manual price |
| Liquidators | Maintain funding and allowances, simulate, use min-out/deadline, cover gas/MEV, observe correct debt and collateral units |
| Capital backstop | Fund irrevocable liquidity and any explicitly accepted `coverBadDebt`; no redemption rights arise |
| Web operator | Control domain/releases, protect deployment config, observe RPC freshness and wallet flows, publish accurate incident status |

On suspect pricing/bridge changes, the guardian freezes new risk and can pause a feed. A guardian feed pause expires after the guardian pause window and cannot be repeated for that feed until governance re-enables or reconfigures it, so governance must schedule its decision immediately: if the feed is genuinely broken, schedule a governance `setEnabled(asset, false)` (indefinite) or a reconfiguration before the pause lapses. Repayment and debt-free withdrawal remain oracle-independent. Oracle outages block liquidation too, so investigate promptly; stale-price forced liquidation is not available. Normal top-ups are subject to the supply cap, requiring rescue headroom in the approved cap design; a debt-free depositor can occupy that headroom, so monitor cap utilization and keep the cap well above expected custody.

Recorded bad debt above $1 per reserve (valued when recorded) halts the reserve and the bank until the reserve's loss is covered in full; recapitalize using exact `coverBadDebt` transfers, investigate the cause and timelock any restart. Losses of at most $1 are recorded, visible in `reserveData` and coverable by anyone, but do not halt lending; the $1 minimum debt per account and reserve prevents the one-unit positions that previously made such micro-losses manufacturable at will. Monitor recorded dust losses as an early signal.

Underlying asset pause/blacklist/rebase or bridge failure can block transfers despite correct bank code. Do not promise guaranteed exit liquidity. Contract logic is immutable: a discovered code defect requires freeze, a reviewed migration/new deployment and user-controlled recovery where possible, not an undisclosed upgrade or administrator sweep.
