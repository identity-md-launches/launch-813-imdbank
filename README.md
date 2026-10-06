# IMDBANK

Ethereum Mainnet IMD collateral lending implementation with USDC, USDT and WETH variable debt, a guarded two-source oracle, governance timelock, and a wallet-connected static application. Protocol fees are permanently **0%**. The nontransferable collateral receipt ledger's name and symbol are **IMDBANK**.

**Release status: not approved for real funds. No public website or Mainnet protocol deployment has been completed.** The constructors start with zero caps and borrowing frozen. Verified IMD bridge/admin risks, missing approved IMD pricing, incomplete economic calibration and release requirements are documented rather than replaced with invented assumptions. The requested production completion criteria are not all satisfied.

This is an original isolated lending implementation inspired by Aave's accounting concepts, not an Aave fork or an inherited Aave audit. Reserves are funded by **irrevocable donations**, not redeemable lender deposits. Interest stays in reserves. IMDBANK is a receipt ledger, not a newly issued tradable ERC20.

## Build and check without dependency downloads

Foundry and Solidity **0.8.26** must be installed. All Solidity and frontend library dependencies are ordinary vendored files; no submodules or package install is required.

```sh
forge build
forge test
forge fmt --check
node --test web/tests/*.test.mjs
node web/check-abi.mjs
python3 tools/check_bytecode.py
python3 tools/economic_stress.py
```

The default tests are deterministic and need no network, environment variables, FFI, filesystem cheatcodes, wallet secrets or preexisting deployments. Fuzz and stateful invariant settings are in `foundry.toml`. The supplied protected deployment floor is an external check and is not replaced by the project's tests.

Optional real-token Mainnet integration uses a separate profile so offline verification remains complete:

```sh
FOUNDRY_PROFILE=fork forge test --fork-url https://eth.blockrazor.xyz --fork-block-number 26134418 -vv
```

This test requires the pinned block and fails if it is not a valid fork. It uses actual Mainnet token contracts and real Chainlink feed reads, with a deliberately simulated IMD valuation. See [validation](docs/VALIDATION.md) for exactly what was executed and its limitations.

## Application

```sh
python3 -m http.server 8080 --bind 127.0.0.1 --directory web
```

Open `http://127.0.0.1:8080`. All requested screens are present. Injected/EIP-6963 Ethereum wallets can connect; configured deployments support exact approvals, simulation, transactions and receipts. Until `web/config.json` contains reviewed deployed addresses and runtime hashes, transaction submission is disabled. The UI has no fabricated balances or deployment addresses. WalletConnect and real-browser wallet automation remain open requirements.

Deploy `web/` as static HTTPS content following [the hosting and deployment handoff](docs/DEPLOYMENT.md). A local server is **not** a public deployment. No final public HTTPS URL is available from this run.

## Review materials

- [Cited research and admission decision](docs/RESEARCH.md), with timestamped raw evidence.
- [Architecture, accounting and risk limits](docs/ARCHITECTURE.md).
- [Independent contributor security review](docs/SECURITY_REVIEW.md), including fixed findings and residual risks.
- [Validation and economic scenarios](docs/VALIDATION.md).
- [Deployment parameters and operational responsibilities](docs/DEPLOYMENT.md).
- [Frontend implementation and limitations](docs/FRONTEND.md).
- [Vendored dependency provenance](docs/DEPENDENCIES.md).

Application contracts are `src/IMDBank.sol`, `src/RiskOracle.sol`, and `src/GovernanceTimelock.sol`. `script/DeployMainnet.s.sol` is a no-broadcast rehearsal helper taking three explicit, distinct role addresses (governance proposer, timelock veto, emergency guardian); it never reads keys. The launch service should use the three individual application artifacts and supply verified governance configuration.
