# IMDBANK research and production admission decision

Research date: **2026-10-06 UTC**. Chain: **Ethereum Mainnet, chain ID 1**. This is a reusable engineering due-diligence record, not a production security certification. Findings below separate onchain facts, indexer observations, and design assumptions. Research informed the decision to keep production exposure disabled. A live website or successful test does not resolve the admission conditions.

## Decision

**Do not admit real-money IMD-backed borrowing yet.** Positive supply/borrow caps and collateral valuation are not justified by the available evidence. Keep initial market caps at zero and opening-risk operations frozen. The blockers are IMD bridge governance concentrated in an externally controlled owner, unreviewed remote bridge/security configuration, no verified suitable IMD/USD oracle, no executable liquidation-depth study, and no historical volatility or beneficial-owner analysis. The local protocol can exercise the full lifecycle with explicit test configurations; those configurations are not production recommendations.

A research snapshot supports identity and integration work, but not safety at a future deployment block. Admission requires the operators and independent reviewers to refresh this record, approve measured parameters, and publish the signed configuration before timelocked activation.

## Reproducible chain snapshot

All successful RPC facts below use block **26,134,012** (`0x18ec5fc`), hash **`0x4c88763379e950dc0c749b6e9f12501f2195d4bbdef406545a1c5f9ffd0ca108`**, timestamp **2026-10-06 14:44:47 UTC**. Four public endpoints returned this block hash. [`evidence/mainnet-block.json`](evidence/mainnet-block.json) records the block header; token evidence retains code and raw `eth_call` results. `code_sha256` hashes the literal hexadecimal result string, not EVM keccak256 bytecode.

`https://eth.blockrazor.xyz` successfully answered chain ID, bytecode, token metadata/balance, and feed calls. BlastAPI also served WETH reads. Other public providers rejected some methods, required keys, rate-limited, or timed out. A successful `eth_blockNumber` alone did **not** prove fork capability: Zan rejected `eth_call`; Flashbots failed token reads. These observations describe this run only. Reproduce with:

```sh
cast block 26134012 --rpc-url https://eth.blockrazor.xyz
cast code 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7 --block 26134012 --rpc-url https://eth.blockrazor.xyz
cast call 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7 'symbol()(string)' --block 26134012 --rpc-url https://eth.blockrazor.xyz
```

Read evidence is not an Ethereum consensus proof. Before launch use independently operated archival nodes, check the finalized block hash, and repeat all dependency verification. No transactions were broadcast during research.

## Aave architecture and licensing

Aave V3's Pool is the user entrypoint for supplying, borrowing, repayment, withdrawal and collateral selection. Reserves account for variable debt through a normalized index; aToken supply claims and variable debt tokens separate underlying custody from user accounting. Our application adopts indexed debt and collateral-health concepts, without claiming Aave deployment compatibility or inherited audit coverage. [Aave Pool documentation](https://aave.com/docs/aave-v3/smart-contracts/pool)

Configuration separates collateral LTV, liquidation threshold/bonus, reserve activation/freeze/pause, caps and borrowing flags. Aave also has features beyond this assignment, including isolation/eMode and flash loans; matching the name “V3” is not a reason to enable them. [Pool Configurator](https://aave.com/docs/aave-v3/smart-contracts/pool-configurator)

Aave distinguishes pool, emergency, risk, listing and bridge privileges through its ACLManager. This project should similarly separate the timelocked parameter authority from a guardian restricted to stopping risk. Production governance should be a reviewed multisig controlling a timelock with an independently held emergency role; a direct owner EOA is inadequate administration for lending. [ACLManager](https://aave.com/docs/aave-v3/smart-contracts/acl-manager)

The license depends on the precise repository and version:

| Code reference | Verified license facts | Decision |
| --- | --- | --- |
| Legacy `aave/aave-v3-core` tag `v1.19.4`, commit `b74526a7bc67a3a117a1963fc871b3eb8cea8435` | BUSL text specifies change to MIT on or before 2023-01-27 | Date has passed, but retain applicable notices for any copied file and check each dependency |
| `aave-dao/aave-v3-origin` at `8305565ae342f1773c42cd2e4593f175fe5968a0` | Current license names Aave v3.7, BUSL additional-use restrictions, MIT change on or before 2027-03-06 | Do not assume permission for a competing production fork in October 2026 |
| Aave Labs interface | Official licensing page lists all rights reserved | Do not copy interface assets/code under an assumed open-source license |

Sources: [pinned legacy license](https://github.com/aave/aave-v3-core/blob/b74526a7bc67a3a117a1963fc871b3eb8cea8435/LICENSE.md), [pinned Origin license](https://github.com/aave-dao/aave-v3-origin/blob/8305565ae342f1773c42cd2e4593f175fe5968a0/LICENSE), [official licensing overview](https://aave.com/docs/resources/code-licensing). The overview still described v3.6 when read, while the current repository license described v3.7; the exact pinned license takes precedence over summaries. License provenance and response hashes are in `evidence/aave-*`. No Aave source is required for this independently written application. Treasury-funded reserves, nontransferable collateral receipts and immutable contracts are intentional differences; this is not a drop-in Aave deployment.

## Asset identities and ERC20 behavior

| Asset | Ethereum address | Onchain name / decimals | Provenance |
| --- | --- | --- | --- |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | Identity.md / 18 | User-supplied address, matching code and metadata at pinned block |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | USD Coin / 6 | [Circle canonical table](https://developers.circle.com/stablecoins/usdc-contract-addresses), live code and metadata |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | Tether USD / 6 | [Tether supported protocols](https://tether.to/en/supported-protocols/), live code and metadata |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | Wrapped Ether / 18 | [Uniswap mainnet list](https://github.com/Uniswap/default-token-list/blob/main/src/tokens/mainnet.json), live code and metadata |

Evidence: [`imd-blockrazor.json`](evidence/imd-blockrazor.json), [`usdc-blockrazor.json`](evidence/usdc-blockrazor.json), [`usdt-onchain.json`](evidence/usdt-onchain.json), [`weth-onchain.json`](evidence/weth-onchain.json). All four addresses had nonempty bytecode and expected symbols. Unsuccessful earlier reads are retained separately, not treated as verification.

USDT transfers may return no Boolean value; Tether expressly documents this integration exception. Use optional-return safe calls and measure exact balances. Its issuer can affect transferability and supply; USDC also introduces issuer/proxy/blacklist/pause risk, documented in [Circle’s FiatToken design](https://github.com/circlefin/stablecoin-evm/blob/master/doc/tokendesign.md). WETH repayment is ERC20 WETH, not an ETH transfer to an arbitrary receiver. Zero protocol fee does not mean zero gas, zero debt interest, or zero liquidator incentive. Users need to see these separately. [Tether integration guidance](https://tether.to/en/supported-protocols/)

Neither a failed `owner()` call nor zero EIP1967 slots proves immutability; USDC uses legacy proxy conventions. Launch verification must inspect the actual deployed proxy and implementation, not just common slot patterns.

## IMD contract and administration

[Sourcify's exact-match record](https://sourcify.dev/server/v2/contract/1/0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7?fields=all) identifies `src/BridgedFP.sol:BridgedFP`, compiler `0.8.26+commit.8a97fa7a`, deployment block **23,501,863**, transaction `0xb2e2587f18b440f2c492d911566cb979d4ec477dd69824d9ac17bdae2608704b`. Its 22,990-byte runtime exactly equaled the pinned RPC runtime. Source hashes and reviewed behavior are retained in [`imd-sourcify.json`](evidence/imd-sourcify.json); the UNLICENSED token source was inspected, not vendored into application code.

The reviewed token inherits standard ERC20 and LayerZero OFT. The token-specific override changes only name/symbol, with owner-controlled setters; historical indexer labels such as FP or VIBE therefore cannot identify today's asset. Normal local transfer code has no custom tax/rebase hook. Cross-chain outgoing transfers burn and verified incoming messages mint. The owner controls trusted peers, delegate and messaging options. This is bridge trust, even though the token runtime itself is not an upgradeable proxy. [LayerZero value-transfer architecture](https://docs.layerzero.network/v2/concepts/value-transfer-implementations)

Pinned reads show:

- `owner()` = `0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7`, with **empty bytecode**. No deployed multisig/timelock controls that account at this snapshot; actual key custody is unknown.
- LayerZero endpoint = `0x1a44076050125825900e736c501f859c50fe728c`.
- Ethereum `totalSupply()` = **4,102,566.979687 IMD**. This is not verified omnichain supply.
- `paused()` reverted; the reviewed IMD ABI has no pause function. A failed probe alone would not establish that fact.

Evidence: [`imd-admin-holders-onchain.json`](evidence/imd-admin-holders-onchain.json). Active peers, remote implementations, delegate, DVNs, executor/library settings, cross-chain supply reconciliation and ownership security were **not fully reviewed**. Owner compromise or misconfiguration could change trusted cross-chain minting paths, undermine scarcity and collapse collateral value. An external governance timelock on IMDBANK cannot neutralize IMD's own owner. Require an explicit bridge-risk review before assigning nonzero collateral value.

## Liquidity, volatility and concentration

The [DEX Screener API snapshot](https://api.dexscreener.com/latest/dex/tokens/0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7), retrieved at 14:46 UTC, returned 30 pairs, including pairs where IMD is the quote asset. They must not all be summed as cash exit liquidity. The largest IMD/native-ETH v4 pool ID was `0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3`: reported price **$12.094**, liquidity **$3,295,639.87**, 24-hour volume **$7,986,506.97**, 5-minute change **-5.38%**, 1-hour **-9.69%**, 24-hour **+20.18%**. An IMD/USDC v3 pool `0x894D4e6d3d2Abc64Fc0de0e4e2Ea63A93BC9c520` reported **$482,303.39** liquidity. These are indexer observations, not audited, same-block executable quotes. [`imd-dexscreener.json`](evidence/imd-dexscreener.json)

Those changes suggest material short-horizon movement; one day's percentages cannot estimate annual volatility, expected shortfall, liquidation horizon losses or manipulation cost. No complete OHLC/trade history was retrieved. Concentrated liquidity can disappear outside its active range; headline TVL and reported volume do not establish liquidator proceeds, independent order flow or wash-trade resistance. A v4 pool ID is bytes32, not an ERC20/pool contract address. Hook logic, positions, withdrawal control, fee changes and concentrated liquidity must be examined. Uniswap describes how historical observations support time-weighted prices; an observable price still needs economic manipulation analysis. [Uniswap oracle concepts](https://developers.uniswap.org/docs/protocols/v3/concepts/price-oracles)

[Blockscout's holder index](https://eth.blockscout.com/api/v2/tokens/0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7/holders) gave a first-page ranking. The selected ten addresses were then read at the pinned block: jointly **56.497%** of Ethereum supply. The first address, labeled `StakedIMD` by the indexer, held **1,751,170.839110946471579962 IMD**, **42.685%** of supply. Another is labeled Uniswap PoolManager, which aggregates pool custody. These are **address/custody concentration measures**, not ten beneficial owners. The ranking's retrieval time differs from the pinned block. Staking beneficiaries, vesting, coordinated wallets, remote holders, LP ownership and insiders remain unknown. The indexer's supply differed slightly from the RPC supply; percentage calculations use the RPC denominator. [`holder evidence`](evidence/imd-admin-holders-onchain.json)

Before admission collect at least 90 days of quality-controlled data if available; otherwise document the shorter history and a stronger probation policy. Reconstruct holders and pool liquidity at a common finalized block. Simulate executable sales of 1%, 5% and 10% of proposed collateral exposure, then LP withdrawals of 50%, 90% and 100%, with gas and liquidation delay. Do not derive a cap as a fixed fraction of reported TVL.

## Oracle selection and protections

Three standard Chainlink reference feeds were found in the [feed catalog](https://reference-data-directory.vercel.app/feeds-mainnet.json) and checked for code, description, decimals and round data at the pinned block. The complete catalog was searched case-insensitively for IMD with **zero matches**; this does not prove that no private, unpublished or other-provider IMD feed exists. [`catalog evidence`](evidence/chainlink-mainnet-catalog.json), [`onchain rounds`](evidence/chainlink-onchain.json)

| Feed | Proxy | Decimals | Catalog heartbeat | Snapshot price / age |
| --- | --- | --- | --- | --- |
| USDC/USD | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` | 8 | 82,800 s | $0.999871 / 72,468 s |
| USDT/USD | `0x3E7d1eAB13ad0104d2750B8863b489D65364e32D` | 8 | 86,400 s | $0.99983342 / 456 s |
| ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` | 8 | 3,600 s | $2,712.08023153 / 1,884 s |

These are deployment candidates, not an approved configuration. Choose each maximum age from its documented update behavior plus an explicit bounded tolerance; a blanket one-hour stale limit would already reject the healthy USDC snapshot. Test new rounds and feed replacement permissions. Chainlink's API supplies signed answer, round identifier and update timestamp; reject nonpositive values, missing/future/stale timestamps, malformed decimals and inconsistent rounds. [Data Feeds API](https://docs.chain.link/data-feeds/api-reference)

No reliable IMD oracle is selected. A spot pool read, indexer HTTP price, arbitrary owner price setter or two wrappers around one manipulated pool is not sufficient security. An independently operated multi-source oracle needs demonstrable source depth, availability, economic attack cost, heartbeat and accountable operations. Chainlink recommends evaluating liquidity, source concentration and extreme events; feed existence alone does not establish fitness. [Selecting quality feeds](https://docs.chain.link/data-feeds/selecting-data-feeds)

The intended fail-closed policy is to block risk-increasing actions on invalid/deviating prices while retaining price-independent repayment and debt-free exit paths. Liquidation should not use a stale “last good” value as though it were current. A circuit breaker may stop wrongful liquidation but create bad debt during an actual price collapse; recovery procedures and independently validated fresh prices are essential. Stablecoin debt is not hardcoded to one dollar: depegs and upside price caps need separate analysis because a capped debt price can understate a borrower's obligation. WETH uses ETH/USD only while its wrap/redemption assumption remains valid.

## Risk assumptions and operational admission requirements

Zero exposure is the only evidence-supported production default. Any nonzero LTV, threshold, liquidation bonus, cap, APR curve, close factor or oracle tolerance used in tests is illustrative. A liquidation incentive is paid to the liquidator for work/risk; it is distinct from the required **0% protocol fee**. Interest accrues to the funded reserve and is also not a fee. This implementation uses explicitly non-redeemable treasury donations for borrowable liquidity; it does not issue interest-bearing, withdrawable reserve supply claims. That is a material difference from Aave, and reserve funders must acknowledge it.

Parameter calibration must satisfy both accounting and economic constraints. At origination, `debtUSD <= collateralUSD * LTV`; liquidation health is `collateralUSD * liquidationThreshold / debtUSD`. LTV must leave room for price changes, interest, delay, execution slippage and incentives. A nominal 5% incentive is useless when gas and slippage exceed proceeds. If collateral becomes worthless or unavailable, liquidators cannot repair solvency; reserve losses require a disclosed loss/backstop policy and sufficiently limited exposure.

Before activating exposure, publish: finalized code/address/implementation hashes; authenticated independent oracle feeds and fallback/recovery policy; token and bridge permissions; measured liquidation-depth and historical stress study; calibrated per-asset/global caps; audited accounting and bad-debt behavior; multisig signers and timelock/guardian responsibilities; funded liquidity and liquidation operators; monitoring/incident drills; completed fork and website wallet flows; external security sign-off and deployment rehearsal. Research did not inspect a production IMDBANK deployment or attest to frontend hosting. The separate validation and deployment records must state exactly which checks ran and which release gates remain open.
