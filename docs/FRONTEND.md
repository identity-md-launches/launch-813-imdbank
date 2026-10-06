# IMDBANK application and integration handoff

The application is implemented in `web/`. It is a static, responsive browser application with real contract transaction execution, not a balance mockup. Dashboard, Markets, Supply IMD, Borrow, Repay, Withdraw, My Position, Liquidations, Analytics, Risk Information and Contract Addresses are implemented. Native ES modules and vendored ethers 6.15.0 keep every runtime dependency in ordinary repository files. React/Next.js were not needed for this bounded, offline-verifiable delivery.

## Deployment status

**No public HTTPS deployment is established by these files. No production bank address is configured.** The checked-in configuration intentionally has null bank and oracle addresses and hashes. The site can render and discover/connect a wallet, but cannot transact until a deployer supplies and reviews the real deployment configuration. A running static website alone would not remove the market's zero-cap and research launch gates.

Research has verified IMD bytecode and its LayerZero OFT identity at block 26134012. IMD governance/bridge control, executable liquidation liquidity, concentration and an approved production oracle still need the decisions recorded in the research and risk documents. Configuring a price from a mock, the market spot price, or an unreviewed deployment is not an acceptable production handoff.

The task environment did not supply a hosting account, authenticated deployment channel, domain, or completed production contract deployment. The root handoff must state any subsequent verified public URL; no URL is invented here.

## Run and test offline

From the repository root:

```sh
python3 -m http.server 8080 --bind 127.0.0.1 --directory web
node --test web/tests/*.test.mjs
forge build
node web/tests/abi-compatibility.mjs
```

Open `http://127.0.0.1:8080`. Node is needed for checks and Python for this optional local server; the hosted app needs neither at runtime. No package installation or CDN is required. Do not serve repository root, compiler artifacts, or other repository contents as the website.

The unit suite covers fixed-point amounts, malformed/overflow values, default deployment lockout, chain/address/hash configuration, wallet account and chain changes, health-factor projections, the loan-to-value capacity check on borrow and withdrawal projections, multiple-asset repayment ceilings, ABI encoding, readable errors, and screen presence. The ABI compatibility checker compares frontend function selectors, return types, and mutability against compiled Foundry outputs. The successful fork evidence is preserved in `docs/evidence/frontend-fork.json`; it records 46 confirmed fixture/action receipts and final zero borrower debt and collateral.

## Wallets and state

- EIP-6963 discovery and legacy EIP-1193 injection support MetaMask, Coinbase Wallet, Rabby, Brave, and compatible desktop or in-wallet mobile browsers. This is protocol-level support; each branded wallet still needs release QA. There is no WalletConnect QR connector. No WalletConnect project identifier was supplied and no remote connector is silently loaded.
- Account and chain listeners invalidate snapshots, pending reviews and transaction eligibility. Writes are restricted to chain ID 1 and the reviewed account is checked again before approval and before the protocol transaction.
- With no public RPC, chain reads use the connected wallet. An optional reviewed HTTPS `rpcUrl` permits public market reads without a wallet. There is no API key in this repository.
- All market/account reads use the same block tag. Balances, debt, collateral status, indexed rates, reserve liquidity, caps, bad debt and health factor come from the blockchain. The page refreshes every 15 seconds while visible and after transaction receipts.
- Borrowing power is the current LTV-based debt capacity minus current debt. Available borrowing remains subject to individual reserve caps and liquidity. Displayed APR is the contract's annual variable rate, not a promised yield or constant APY.
- Oracle failures make valuation unavailable. Repayment, approvals, and debt-free exits can remain accessible if the contract permits them; the interface never replaces a missing price with one dollar or a last-good guessed price.
- IMD and stablecoin symbol metadata can be changed by administrators. A symbol mismatch raises an explicit warning with the configured address and observed symbol; it does not trap users by disabling debt repayment. Token decimals must still match the bank's immutable accounting unit. The addresses are fixed by the chain configuration.

## Transaction safety

Every action has a review screen containing chain, account, contract/spender, asset and spending ceiling. The user acknowledges the review before wallet requests. Amounts use BigInt fixed-point parsing throughout; JavaScript floating-point numbers are never used for token amounts, prices, interest indices or debt.

Approvals use the requested finite amount. A nonzero inadequate allowance is reset to zero before increasing it, including USDT. Approval simulation accepts empty return data and rejects an explicit false return. The contract's exact-transfer checks are still authoritative for token behavior. If an approval succeeds and the next step fails or is rejected, the UI explicitly warns that the allowance remains and offers per-asset revocation in My Position.

The protocol action is simulated with `eth_call` and estimated before submission. Ethereum may change between simulation and inclusion, so simulation is not a guarantee. Pending status includes an Etherscan transaction link. Receipt status must indicate success after the configured number of confirmations. A repriced transaction is accepted only with its confirmed receipt; cancellation/replacement asks the user to refresh and reassess. Confirmed transactions appear in session analytics. No off-chain balance is added optimistically.

Projections for borrowing and withdrawal apply the same two rules the contract enforces: the health factor uses the liquidation threshold, and the loan-to-value capacity (`ltvBps`) bounds the debt that a borrow or debt-bearing withdrawal may leave. A projection whose debt exceeds the projected capacity is shown in the danger style with the limit, and the review dialog refuses it with the real rejection boundary instead of letting a "safe-looking" health factor reach a failing simulation. The review also shows the remaining borrowing limit after the action. The contract's `MinimumDebt` rejection (debt per asset below $1 after a borrow) is translated into a readable message, and the minimum debt and loss-halt thresholds are read from the contract on the Risk Information screen.

Repayment accepts a maximum spending ceiling and the contract charges only actual debt reduction. The full-debt button fills current debt plus a 0.1% bounded interest buffer, capped to the wallet balance. Health projections cap repayment to debt in the selected asset, avoiding an overstatement when the user enters a ceiling larger than that asset's debt. Projections are labeled estimates and exclude subsequent interest, price changes and exact share rounding; on-chain simulation and execution remain authoritative.

Liquidation requires an inspected borrower, maximum repayment, positive minimum IMD output and a ten-minute block-timestamp deadline. The UI reads `previewLiquidation` and displays quoted repayment and seized collateral before review. The caller's minimum output is enforced on-chain. The lending contract also supports `finalizeDust(address)` for unhealthy collateral at or below $0.001 that is worth less than the debt and cannot fund any ordinary liquidation. Its advanced control requires an inspected borrower; contract simulation remains authoritative for eligibility. The review states that unpaid debt is written off and affected lending freezes. See contract/operator documentation before invoking it.

Reserve funding is exposed only as an explicitly acknowledged **non-redeemable donation**. It does not imply deposits, LP shares, withdrawal rights or yield. This matches the treasury-funded reserve architecture.

## Runtime verification and public hosting

To prepare a real deployment, the authorized deployer must:

1. Complete research/risk approval, independent audit, operational readiness and production contract deployment. Keep caps at zero while these are incomplete.
2. Independently review the finalized addresses, constructor parameters and deployed runtime bytecode including immutable values. Record the keccak256 runtime hash for the bank and oracle. An untrusted RPC reporting its own hash is not an independent attestation.
3. Update `web/config.json` with actual `bankAddress`, `bankCodeHash`, `oracleAddress`, `oracleCodeHash`, deployment block and optional HTTPS read RPC. Preserve chain ID 1 and canonical asset addresses. Keep status/research text accurate. Configuration values are public and must never contain a wallet key or secret RPC credential.
4. The app verifies bytecode hashes, contract name/symbol, zero protocol fee, oracle address, collateral address, three reserve addresses, token code-backed reads, and immutable accounting units before enabling writes. Compare governor and guardian addresses with the reviewed multisig and timelock configuration separately.
5. Publish the contents of `web/` on an authenticated static HTTPS host. Cloudflare Pages and Netlify recognize the supplied `_headers`; other hosts must implement equivalent response headers. Configure a no-store policy for `config.json`, no-cache for HTML, HTTPS, anti-framing and content security policy headers. No build command or SPA path rewrite is necessary because navigation uses hashes.
6. Remove local RPC connect exceptions from both the HTML policy and host `_headers` for production. Configure the public RPC origin more narrowly if used. An RPC endpoint must allow browser-origin requests and have operational limits suitable for the app.
7. Verify the final public HTTPS URL from an independent network, response headers, every route, keyboard/mobile layout, wallet chooser, wrong-network behavior, on-chain address verification and transaction receipts. Record that URL and verification evidence in the deployment handoff.

The UI's “runtime hash matched” statement is deliberately narrower than verified source or safe deployment. It does not attest proxy-token implementation safety, multisig threshold, timelock policy, price-source security or economic liquidity. Explorer links are provided for independent inspection.

## Fork integration and remaining release QA

`web/tests/fork-integration.mjs` uses the exact vendored ethers module, EIP-1193 adapter, `BrowserProvider`, frontend ABI and amount parser against local Anvil. It refuses non-loopback endpoints and requires the node identify itself as Anvil with chain ID 1. It imports compiled bank/mock-oracle artifacts, deploys local fixtures, impersonates test administrators and real token holders, supplies real IMD, funds reserves with real USDC/USDT and deposited WETH, exercises the three borrow paths, simulates unsafe actions, repays and withdraws, changes an explicitly mocked oracle, liquidates and verifies final zero debt/collateral.

After starting a pinned Ethereum fork, run:

```sh
node web/tests/fork-integration.mjs http://127.0.0.1:8545
```

This requires the fork node's upstream archive/RPC access for uncached state. The default unit and Foundry verification checks do not require that network access. The fixture mutates only the local fork and uses Anvil impersonation; it reads no keys or environment variables. It prints a JSON evidence summary and does not write local fixture addresses into the production configuration.

The replay against the revised contracts passed with 46 receipts at fork block 26,134,418, recorded in `docs/evidence/frontend-fork.json`; the first-round replay at block 26,134,156 is kept as `frontend-fork-round1.json`. The public RPC stopped serving some uncached state at the earlier block 26,134,012 during a subsequent replay; that limitation and the earlier successful run are preserved separately. The harness now reads and records the actual Anvil fork block/hash rather than assuming a hardcoded snapshot. Use a durable archival RPC to reproduce old snapshots reliably.

**The EIP-1193 integration is not a browser E2E run.** No browser binary or installed extension was available during this frontend work. Release still requires a real browser test of wallet discovery/account changes, input and review controls, approval rejection, transaction replacement, page recovery after reload, mobile and accessibility behavior, and complete hosted-site-to-contract flow. A mock oracle demonstrates integration paths, not a reliable production IMD oracle. Public hosting, real wallet-brand QA, a WalletConnect connector if required, and independent production security approval remain explicitly open until separately evidenced.
