import { getAddress, parseUnits, formatUnits, MaxUint256 } from './vendor/ethers-6.15.0.min.js';
export const USD = 10n ** 18n;
export const RAY = 10n ** 27n;
export const canonicalAssets = Object.freeze({
  IMD: '0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7',
  USDC: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
  USDT: '0xdac17f958d2ee523a2206206994597c13d831ec7',
  WETH: '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2',
});
export function address(value) {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value)) throw new Error('A valid Ethereum address is required.');
  return getAddress(value.toLowerCase());
}
export function validateConfig(config) {
  if (config.chainId !== 1) throw new Error('Only Ethereum Mainnet (chain ID 1) is supported.');
  for (const [symbol, expected] of Object.entries(canonicalAssets)) {
    if (config.assets?.[symbol]?.toLowerCase() !== expected) throw new Error(`Unexpected ${symbol} address in deployment configuration.`);
  }
  if (!config.bankAddress || !config.oracleAddress) throw new Error('Protocol deployment is not configured. Transactions are unavailable.');
  config.bankAddress = address(config.bankAddress);
  config.oracleAddress = address(config.oracleAddress);
  if (config.bankAddress === '0x0000000000000000000000000000000000000000' || config.oracleAddress === '0x0000000000000000000000000000000000000000') throw new Error('Zero deployment addresses are forbidden.');
  for (const key of ['bankCodeHash', 'oracleCodeHash']) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(config[key] ?? '') || /^0x0+$/.test(config[key])) throw new Error(`A verified ${key} is required.`);
  }
  if (!Number.isInteger(config.transactionConfirmations) || config.transactionConfirmations < 1 || config.transactionConfirmations > 64) throw new Error('Transaction confirmations must be between 1 and 64.');
  if (config.rpcUrl && !/^https:\/\//.test(config.rpcUrl) && !/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/?$/.test(config.rpcUrl)) throw new Error('Public RPC connections must use HTTPS.');
  return config;
}
export function checkTokenMetadata({ symbol, observedSymbol, decimals, accountingUnit }) {
  if (!Object.hasOwn(canonicalAssets, symbol)) throw new Error('Unsupported configured token.');
  const count = Number(decimals);
  const expected = symbol === 'WETH' ? 18 : symbol === 'IMD' ? null : 6;
  if (!Number.isInteger(count) || count < 0 || count > 18 || (expected !== null && count !== expected) || accountingUnit !== 10n ** BigInt(count)) throw new Error(`${symbol} decimals do not match the lending contract's accounting unit.`);
  // Token administrators can change symbol metadata without changing accounting.
  // Report that drift; never prevent debt repayment merely because of a new label.
  return { decimals: count, actualSymbol: String(observedSymbol), metadataWarning: observedSymbol !== symbol };
}
export function parseAmount(value, decimals) {
  if (typeof value !== 'string' || !/^(0|[1-9]\d*)(\.\d+)?$/.test(value.trim())) throw new Error('Enter a positive decimal amount, without exponents or separators.');
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 18) throw new Error('Unsupported token decimals.');
  const cleaned = value.trim();
  if ((cleaned.split('.')[1]?.length ?? 0) > decimals) throw new Error(`This token supports at most ${decimals} decimal places.`);
  const result = parseUnits(cleaned, decimals);
  if (result <= 0n || result > MaxUint256) throw new Error('Amount must be positive and within the token limit.');
  return result;
}
export function units(value, decimals = 18, places = 6) {
  if (value === null || value === undefined) return '—';
  const parts = formatUnits(value, decimals).split('.');
  const fraction = (parts[1] ?? '').slice(0, places).replace(/0+$/, '');
  return `${parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',')}${fraction ? `.${fraction}` : ''}`;
}
export function usd(value) { return value == null ? 'Unavailable' : `$${units(value, 18, 2)}`; }
export function hf(value) { return value == null ? 'Unavailable' : value === MaxUint256 ? 'No debt' : units(value, 18, 3); }
export function short(value) { return value ? `${value.slice(0, 6)}…${value.slice(-4)}` : 'Not deployed'; }
export function ceilDiv(a, b) { if (b <= 0n) throw new Error('Invalid denominator.'); return (a + b - 1n) / b; }
export function projectedPosition({ collateralUsd, debtUsd, liquidationBps, ltvBps, action, amount, decimals, price, enabled, assetDebt }) {
  if (price == null) return null;
  let c = collateralUsd; let d = debtUsd;
  if (action === 'repay' && assetDebt != null && amount > assetDebt) amount = assetDebt;
  const deltaDown = amount * price / (10n ** BigInt(decimals));
  const deltaUp = ceilDiv(amount * price, 10n ** BigInt(decimals));
  if (action === 'supply' && enabled) c += deltaDown;
  if (action === 'withdraw') c = c > deltaUp ? c - deltaUp : 0n;
  if (action === 'borrow') d += deltaUp;
  if (action === 'repay') d = d > deltaDown ? d - deltaDown : 0n;
  const health = d === 0n ? MaxUint256 : c * liquidationBps / 10000n * USD / d;
  // The contract rejects borrowing and debt-bearing withdrawals above the loan-to-value capacity,
  // which is stricter than the liquidation threshold used by the health factor.
  const capacityUsd = ltvBps == null ? null : c * ltvBps / 10000n;
  const exceedsCapacity = capacityUsd != null && d > 0n && (action === 'borrow' || action === 'withdraw') && d > capacityUsd;
  return { collateralUsd: c, debtUsd: d, health, capacityUsd, exceedsCapacity };
}
export function projectedHealth(input) { const projected = projectedPosition(input); return projected == null ? null : projected.health; }
export function errorText(error) {
  if (error?.code === 4001 || error?.code === 'ACTION_REJECTED') return 'You rejected the wallet request. No transaction was sent by this step.';
  if (error?.code === 'INSUFFICIENT_FUNDS') return 'Insufficient ETH for network gas.';
  if (error?.code === 'NETWORK_ERROR') return 'The wallet network changed. Reconnect on Ethereum Mainnet and try again.';
  if (error?.code === 'TRANSACTION_REPLACED') return error.cancelled ? 'The transaction was cancelled or replaced. Refresh your position before retrying.' : 'The transaction was replaced. Refresh to check its final state.';
  const reason = error?.revert?.name || error?.reason || error?.shortMessage || error?.message || 'The request could not be completed.';
  const messages = { Unauthorized: 'This action requires a governance role your wallet does not hold.', Frozen: 'This action is disabled by an emergency freeze or unresolved bad debt.', CapExceeded: 'This action exceeds an on-chain supply or borrowing cap.', InsufficientLiquidity: 'The reserve does not have enough available liquidity.', UnsafePosition: 'This action would leave the account above its allowed borrowing limit.', HealthyPosition: 'This account is healthy and cannot be liquidated.', InvalidPrice: 'The price oracle is unavailable, stale or outside its safety bounds.', Dust: 'This amount is too small after debt-share rounding.', Expired: 'The liquidation deadline expired. Review a fresh quote.', Slippage: 'The liquidation would return less IMD than your chosen minimum.', InvalidAmount: 'The contract rejected this amount.', OutstandingBadDebt: 'Unresolved bad debt prevents this risk setting from being changed.', MinimumDebt: 'Your debt in this asset must be at least $1 after borrowing. Borrow more or nothing.' };
  if (messages[reason]) return messages[reason];
  if (/user rejected|user denied/i.test(reason)) return 'You rejected the wallet request.';
  if (/missing revert data|execution reverted/i.test(reason)) return 'The contract rejected this action. Check caps, oracle freshness, liquidity, allowance and your health factor. No action was submitted if simulation failed.';
  return String(reason).slice(0, 500);
}
export function assertWalletContext(expected, actual) {
  if (actual.chainId !== 1 || expected.chainId !== actual.chainId) throw new Error('Switch your wallet to Ethereum Mainnet before continuing.');
  if (!actual.account || expected.account.toLowerCase() !== actual.account.toLowerCase()) throw new Error('The selected wallet account changed. Review the action again.');
}
