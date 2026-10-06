import { BrowserProvider, JsonRpcProvider, Contract, Interface, keccak256, formatUnits, MaxUint256 } from './vendor/ethers-6.15.0.min.js';
import { bankAbi, tokenAbi, oracleAbi } from './abi.js';
import { address, validateConfig, checkTokenMetadata, parseAmount, units, usd, hf, short, projectedPosition, errorText, assertWalletContext, USD, RAY } from './core.js';

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const debtSymbols = ['USDC', 'USDT', 'WETH'];
const symbols = ['IMD', ...debtSymbols];
const wallets = new Map();
const state = { config: null, configError: null, provider: null, wallet: null, account: null, chainId: null, verified: false, bank: null, oracle: null, snapshot: null, busy: false, loading: false, generation: 0, borrower: null, pending: null, history: [], listeners: null };
const escape = (value) => String(value).replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const checksum = (value) => address(value);
const tokenAddress = (symbol) => checksum(state.config.assets[symbol]);
const pct = (value, decimals = 2) => `${units(value, decimals, 2)}%`;
const link = (value) => `<a href="https://etherscan.io/address/${checksum(value)}" target="_blank" rel="noopener noreferrer"><code>${checksum(value)}</code> ↗</a>`;
const safe = async (fn) => { try { return await fn(); } catch { return null; } };
const disableWrites = () => { for (const el of $$('[data-write]')) el.disabled = state.busy || state.loading || !state.verified || !state.account || state.chainId !== 1 || !state.snapshot || el.dataset.blocked === 'true'; };
function showError(error) { $('#error').textContent = errorText(error); $('#error').hidden = false; }
function clearError() { $('#error').hidden = true; }
function status(message, hash) {
  const box = $('#transaction-status'); box.hidden = false; box.replaceChildren();
  const close = document.createElement('button'); close.textContent = '×'; close.className = 'quiet'; close.setAttribute('aria-label', 'Dismiss transaction status'); close.onclick = () => { box.hidden = true; }; box.append(close);
  const body = document.createElement('span'); body.textContent = message; box.append(body);
  if (/^0x[0-9a-fA-F]{64}$/.test(hash || '')) { const anchor = document.createElement('a'); anchor.href = `https://etherscan.io/tx/${hash}`; anchor.target = '_blank'; anchor.rel = 'noopener noreferrer'; anchor.textContent = ' View transaction ↗'; box.append(anchor); }
}
function navigate() {
  const page = location.hash.slice(1) || 'dashboard';
  const allowed = $(`#page-${CSS.escape(page)}`) ? page : 'dashboard';
  for (const section of $$('.page')) section.hidden = section.id !== `page-${allowed}`;
  for (const item of $$('nav a')) { if (item.dataset.page === allowed) item.setAttribute('aria-current', 'page'); else item.removeAttribute('aria-current'); }
  document.title = `${$(`#page-${allowed} h1`).textContent} · IMDBANK`;
}
window.addEventListener('hashchange', navigate);
navigate();

function discoverWallet(detail) {
  if (!detail?.provider || typeof detail.provider.request !== 'function') return;
  const id = detail.info?.uuid || detail.info?.rdns || 'injected';
  wallets.set(id, { provider: detail.provider, name: String(detail.info?.name || 'Ethereum wallet').slice(0, 60) });
  renderWallets();
}
window.addEventListener('eip6963:announceProvider', (event) => discoverWallet(event.detail));
window.dispatchEvent(new Event('eip6963:requestProvider'));
function discoverLegacy() {
  for (const [i, provider] of (window.ethereum?.providers || (window.ethereum ? [window.ethereum] : [])).entries()) {
    if ([...wallets.values()].some((item) => item.provider === provider)) continue;
    const name = provider.isCoinbaseWallet ? 'Coinbase Wallet' : provider.isRabby ? 'Rabby' : provider.isBraveWallet ? 'Brave Wallet' : provider.isMetaMask ? 'MetaMask' : 'Ethereum wallet';
    discoverWallet({ provider, info: { uuid: `legacy-${i}`, name } });
  }
}
function renderWallets() {
  const list = $('#wallet-options'); list.replaceChildren();
  for (const { provider, name } of wallets.values()) { const button = document.createElement('button'); button.textContent = name; button.onclick = () => connect(provider); list.append(button); }
  if (!wallets.size) { const p = document.createElement('p'); p.textContent = 'No Ethereum wallet was detected. Install a wallet extension or open this site inside your mobile wallet.'; list.append(p); }
}
$('#connect').onclick = () => { discoverLegacy(); window.dispatchEvent(new Event('eip6963:requestProvider')); renderWallets(); $('#wallet-dialog').showModal(); };
$('#wallet-close').onclick = () => $('#wallet-dialog').close();
function removeWalletListeners() {
  if (!state.wallet || !state.listeners) return;
  for (const [event, fn] of Object.entries(state.listeners)) state.wallet.removeListener?.(event, fn);
  state.listeners = null;
}
function invalidateSession() { state.generation++; state.verified = false; state.snapshot = null; state.borrower = null; state.borrowerData = null; state.pending = null; $('#review-dialog').close(); disableWrites(); render(); }
async function connect(wallet) {
  clearError();
  try {
    removeWalletListeners(); invalidateSession();
    const accounts = await wallet.request({ method: 'eth_requestAccounts' });
    if (!accounts?.length) throw new Error('No wallet account was selected.');
    state.wallet = wallet; state.account = checksum(accounts[0]);
    state.chainId = Number(BigInt(await wallet.request({ method: 'eth_chainId' })));
    state.provider = new BrowserProvider(wallet, 'any');
    state.listeners = {
      accountsChanged: async (accounts) => { invalidateSession(); state.account = accounts?.[0] ? checksum(accounts[0]) : null; render(); await refresh(); },
      chainChanged: async (chain) => { invalidateSession(); state.chainId = Number(BigInt(chain)); state.provider = new BrowserProvider(wallet, 'any'); render(); await refresh(); },
      disconnect: () => disconnect(),
    };
    for (const [event, fn] of Object.entries(state.listeners)) wallet.on?.(event, fn);
    $('#wallet-dialog').close(); render(); await refresh();
  } catch (error) { showError(error); }
}
function disconnect() {
  removeWalletListeners(); invalidateSession(); state.wallet = null; state.account = null; state.chainId = null;
  state.provider = state.config?.rpcUrl && !state.configError ? new JsonRpcProvider(state.config.rpcUrl, 1) : null;
  render(); void refresh();
}
$('#disconnect').onclick = disconnect;
$('#switch-chain').onclick = async () => { try { await state.wallet?.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x1' }] }); } catch (error) { showError(error); } };
$('#refresh').onclick = () => { clearError(); void refresh(); };

async function verifyDeployment(blockTag) {
  if (state.configError) throw state.configError;
  const network = await state.provider.getNetwork();
  if (network.chainId !== 1n) throw new Error('Connect to Ethereum Mainnet (chain ID 1).');
  const c = state.config;
  const [bankCode, oracleCode] = await Promise.all([state.provider.getCode(c.bankAddress, blockTag), state.provider.getCode(c.oracleAddress, blockTag)]);
  if (bankCode === '0x' || keccak256(bankCode).toLowerCase() !== c.bankCodeHash.toLowerCase()) throw new Error('Lending contract runtime hash does not match the reviewed configuration. Transactions are blocked.');
  if (oracleCode === '0x' || keccak256(oracleCode).toLowerCase() !== c.oracleCodeHash.toLowerCase()) throw new Error('Oracle contract runtime hash does not match the reviewed configuration. Transactions are blocked.');
  state.bank = new Contract(c.bankAddress, bankAbi, state.provider);
  state.oracle = new Contract(c.oracleAddress, oracleAbi, state.provider);
  const read = { blockTag };
  const [collateral, oracle, name, symbol, fee, ...assets] = await Promise.all([state.bank.collateral(read), state.bank.oracle(read), state.bank.name(read), state.bank.symbol(read), state.bank.feeBps(read), ...[0,1,2].map(i => state.bank.assets(i, read))]);
  if (collateral.toLowerCase() !== tokenAddress('IMD').toLowerCase() || oracle.toLowerCase() !== c.oracleAddress.toLowerCase() || name !== 'IMDBANK' || symbol !== 'IMDBANK' || fee !== 0n || assets.some((value, i) => value.toLowerCase() !== tokenAddress(debtSymbols[i]).toLowerCase())) throw new Error('The deployment does not match expected assets, oracle or zero-fee IMDBANK identity.');
}
async function refresh() {
  if (state.loading) return;
  if (!state.provider || state.configError || (state.wallet && state.chainId !== 1)) { state.verified = false; render(); return; }
  state.loading = true; disableWrites();
  const generation = state.generation;
  try {
    const block = await state.provider.getBlock('latest');
    if (!block) throw new Error('The RPC did not return the latest block.');
    const blockTag = block.number;
    await verifyDeployment(blockTag);
    const read = { blockTag };
    const [ltv, threshold, bonus, closeFactor, supplyCap, frozen, governor, guardian, minDebtUsd, lossFreezeUsd] = await Promise.all([
      state.bank.ltvBps(read), state.bank.liquidationThresholdBps(read), state.bank.liquidationBonusBps(read), state.bank.closeFactorBps(read), state.bank.supplyCap(read), state.bank.frozen(read), state.bank.governor(read), state.bank.guardian(read), state.bank.MIN_DEBT_USD(read), state.bank.LOSS_FREEZE_USD(read),
    ]);
    const assets = {};
    await Promise.all(symbols.map(async (symbol) => {
      const token = new Contract(tokenAddress(symbol), tokenAbi, state.provider);
      const [decimals, actualSymbol, price, balance, allowance] = await Promise.all([
        token.decimals(read), token.symbol(read), safe(() => state.oracle.price(tokenAddress(symbol), read)),
        state.account ? token.balanceOf(state.account, read) : null,
        state.account ? token.allowance(state.account, state.config.bankAddress, read) : null,
      ]);
      const immutableUnit = symbol === 'IMD' ? await state.bank.collateralUnit(read) : await state.bank.assetUnit(tokenAddress(symbol),read);
      const metadata = checkTokenMetadata({symbol, observedSymbol:actualSymbol, decimals, accountingUnit:immutableUnit});
      const reserve = symbol !== 'IMD' ? await state.bank.reserveData(tokenAddress(symbol), read) : null;
      const debt = symbol !== 'IMD' && state.account ? await state.bank.previewDebt(state.account, tokenAddress(symbol), read) : null;
      assets[symbol] = { ...metadata, price, balance, allowance, reserve, debt };
    }));
    const account = state.account ? await safe(() => state.bank.accountData(state.account, read)) : null;
    const [supplied, enabled] = state.account ? await Promise.all([state.bank.collateralBalance(state.account, read), state.bank.collateralEnabled(state.account, read)]) : [null, false];
    if (generation !== state.generation) return;
    state.snapshot = { block: block.number, timestamp: block.timestamp, loadedAt: Date.now(), ltv, threshold, bonus, closeFactor, supplyCap, frozen, governor, guardian, minDebtUsd, lossFreezeUsd, assets, account, supplied, enabled };
    state.verified = true;
    render();
  } catch (error) {
    if (generation !== state.generation) return;
    state.verified = false; state.snapshot = null;
    showError(error); render();
  } finally { state.loading = false; disableWrites(); }
}
function render() {
  $('#connect').textContent = state.account ? short(state.account) : 'Connect wallet';
  $('#disconnect').hidden = !state.account;
  $('#switch-chain').hidden = !state.wallet || state.chainId === 1;
  $('#account-full').textContent = state.account || 'Connect your wallet to view your position.';
  const banner = $('#deployment-banner');
  if (state.configError) { banner.textContent = `${errorText(state.configError)} ${state.config?.researchStatus || ''}`; banner.className = 'notice warning'; }
  else if (state.wallet && state.chainId !== 1) { banner.textContent = 'Wrong network. Switch your wallet to Ethereum Mainnet to read and transact.'; banner.className = 'notice danger'; }
  else if (!state.verified) { banner.textContent = 'Deployment verification pending. Connect a wallet or configure a public RPC. Transactions remain disabled.'; banner.className = 'notice warning'; }
  else { banner.textContent = `Configured bank and oracle runtime hashes match on Ethereum at block ${state.snapshot.block}. ${state.snapshot.supplyCap === 0n ? 'Supply cap is zero: this market has not been activated.' : 'Review token, oracle, governance and market risk before depositing.'}`; banner.className = `notice ${state.snapshot.supplyCap === 0n ? 'warning' : ''}`; }
  const s = state.snapshot; const account = s?.account;
  if (s) { const changed = symbols.filter(symbol => s.assets[symbol].metadataWarning).map(symbol => `${symbol} currently reports symbol ${s.assets[symbol].actualSymbol} at ${tokenAddress(symbol)}`); if (changed.length) { banner.textContent += ` TOKEN METADATA WARNING: ${changed.join('; ')}. Recheck issuer changes; repayments and exits remain available.`; banner.className = 'notice warning'; } }
  $('#data-state').textContent = s ? `Read at Ethereum block ${s.block.toLocaleString()} · ${new Date(s.timestamp * 1000).toUTCString()} · refresh every 15 seconds` : 'Blockchain state has not been loaded.';
  const available = account ? (account.borrowCapacityUsd > account.debtUsd ? account.borrowCapacityUsd - account.debtUsd : 0n) : null;
  const metrics = { collateral: usd(account?.collateralUsd), debt: usd(account?.debtUsd), health: hf(account?.healthFactor), available: usd(available), imd: s ? units(s.supplied, s.assets.IMD.decimals) : '—' };
  for (const el of $$('[data-metric]')) { el.textContent = metrics[el.dataset.metric]; el.classList.toggle('danger-text', el.dataset.metric === 'health' && account?.healthFactor < USD); }
  $('#collateral-status').textContent = s && state.account ? `Collateral is ${s.enabled ? 'enabled' : 'disabled'}. Supplied: ${units(s.supplied, s.assets.IMD.decimals)} IMD.` : 'Connect a wallet to view collateral status.';
  $('#toggle-collateral').textContent = s?.enabled ? 'Disable collateral' : 'Enable collateral';
  $('#supplied-balance').textContent = `Supplied IMD: ${s ? units(s.supplied, s.assets.IMD.decimals) : '—'}`;
  for (const el of $$('[data-balance]')) el.textContent = `Wallet balance: ${s ? units(s.assets[el.dataset.balance].balance, s.assets[el.dataset.balance].decimals) : '—'} ${el.dataset.balance}`;
  renderMarkets(); renderPosition(); renderRisk(); renderAddresses(); renderAnalytics(); updateQuotes(); disableWrites();
}
function renderMarkets() {
  const s = state.snapshot;
  const rows = debtSymbols.map(symbol => {
    const a = s?.assets[symbol]; const r = a?.reserve;
    return `<tr><td><span class="asset"><span class="coin">${symbol === 'WETH' ? 'Ξ' : '$'}</span>${symbol}</span><small>${symbol === 'WETH' ? 'Wrapped Ether' : 'USD stablecoin'}</small></td><td>${r ? `${units(r.rateRay * 100n, 27, 2)}%` : '—'}<small>Variable APR</small></td><td>${r ? units(r.cash, a.decimals, 3) : '—'} ${symbol}</td><td>${r ? units(r.totalDebt, a.decimals, 3) : '—'} ${symbol}</td><td>${a ? usd(a.price) : '—'}</td><td><span class="badge ${!r || r.frozen || s.frozen || r.cap === 0n ? 'bad' : ''}">${!r ? 'Not loaded' : r.frozen || s.frozen ? 'Frozen' : r.cap === 0n ? 'Cap zero' : 'Active'}</span></td><td><a href="#borrow">Borrow ↗</a></td></tr>`;
  }).join('');
  for (const el of $$('[data-markets]')) el.innerHTML = `<table><thead><tr><th>Asset</th><th>Borrow rate</th><th>Available liquidity</th><th>Outstanding debt</th><th>Oracle price</th><th>Status</th><th></th></tr></thead><tbody>${rows}</tbody></table>`;
}
function renderPosition() {
  const s = state.snapshot;
  if (!s || !state.account) { $('#debt-table').textContent = 'Connect your wallet to load individual debts.'; $('#allowances').textContent = 'No verified account loaded.'; return; }
  $('#debt-table').innerHTML = `<table><thead><tr><th>Debt asset</th><th>Wallet balance</th><th>Accrued debt</th><th>Debt value</th><th></th></tr></thead><tbody>${debtSymbols.map(symbol => { const a = s.assets[symbol]; return `<tr><td>${symbol}</td><td>${units(a.balance,a.decimals)}</td><td>${units(a.debt,a.decimals)}</td><td>${a.price == null ? 'Unavailable' : usd(a.debt * a.price / 10n ** BigInt(a.decimals))}</td><td><a href="#repay">Repay ↗</a></td></tr>`; }).join('')}</tbody></table>`;
  $('#allowances').replaceChildren();
  for (const symbol of symbols) {
    const a = s.assets[symbol]; const row = document.createElement('div'); row.className = 'allowance-row';
    const label = document.createElement('span'); label.textContent = `${symbol}: ${units(a.allowance, a.decimals)} approved`; row.append(label);
    const button = document.createElement('button'); button.textContent = 'Revoke'; button.dataset.write = ''; button.disabled = a.allowance === 0n; button.dataset.blocked = String(a.allowance === 0n); button.onclick = () => review({ action: 'revoke', symbol, amount: 0n }); row.append(button); $('#allowances').append(row);
  }
}
function renderRisk() {
  const s = state.snapshot;
  $('#risk-deployment').textContent = state.verified ? `Runtime hashes matched at block ${s.block}. This does not establish production readiness. ${state.config.researchStatus}` : 'No deployment is currently verified. Production activation remains blocked.';
  const rows = s ? [ ['Loan-to-value limit', pct(s.ltv)], ['Liquidation threshold', pct(s.threshold)], ['Liquidation bonus', pct(s.bonus)], ['Close factor', pct(s.closeFactor)], ['IMD supply cap', `${units(s.supplyCap, s.assets.IMD.decimals)} IMD`], ['Minimum debt per asset', usd(s.minDebtUsd)], ['Loss halt threshold per reserve', usd(s.lossFreezeUsd)], ['Global risk freeze', s.frozen ? 'Active' : 'Inactive'], ['IMD oracle', s.assets.IMD.price == null ? 'Unavailable / rejected by oracle' : usd(s.assets.IMD.price)], ['Guardian', short(s.guardian)], ['Governor', short(s.governor)] ] : [['Status','Awaiting verified deployment']];
  $('#risk-parameters').innerHTML = rows.map(([name,value]) => `<div><dt>${escape(name)}</dt><dd>${escape(value)}</dd></div>`).join('');
  $('#liquidation-risk').innerHTML = (s ? rows.slice(1,4) : rows).map(([name,value]) => `<div><dt>${escape(name)}</dt><dd>${escape(value)}</dd></div>`).join('');
}
function renderAddresses() {
  if (!state.config) return;
  const entries = [['IMDBANK lending contract',state.config.bankAddress], ['Protected price oracle',state.config.oracleAddress], ...symbols.map(symbol=>[`${symbol} token`,state.config.assets?.[symbol]])];
  if (state.snapshot) entries.push(['Governor',state.snapshot.governor], ['Guardian',state.snapshot.guardian]);
  $('#addresses-list').innerHTML = entries.map(([name,value]) => `<div class="address-row"><strong>${escape(name)}</strong>${value && /^0x[0-9a-fA-F]{40}$/.test(value) ? link(value) : '<code>Not deployed / not configured</code>'}<small>${value ? state.verified ? name.includes('token') ? 'Address and metadata checked at the displayed block; admin and implementation risks remain.' : 'Read from configured deployment. Review source and administrator security independently.' : 'Configured address only; chain verification has not completed.' : 'No address will be invented or inferred.'}</small></div>`).join('') + `<div class="address-row"><strong>Configured lending runtime hash</strong><code>${escape(state.config.bankCodeHash || 'Not configured')}</code><strong>Configured oracle runtime hash</strong><code>${escape(state.config.oracleCodeHash || 'Not configured')}</code></div>`;
}
function renderAnalytics() {
  const s = state.snapshot;
  if (!s) { $('#analytics-table').textContent = 'No verified blockchain snapshot available.'; return; }
  $('#analytics-table').innerHTML = `<table><thead><tr><th>Asset</th><th>Utilization</th><th>Debt cap</th><th>Bad debt</th><th>Borrow index</th></tr></thead><tbody>${debtSymbols.map(symbol => { const a = s.assets[symbol], r = a.reserve; const u = r.cash + r.totalDebt === 0n ? 0n : r.totalDebt * 10000n / (r.cash + r.totalDebt); return `<tr><td>${symbol}</td><td>${pct(u)}<div class="chart-track"><progress max="10000" value="${u}" aria-label="${symbol} utilization"></progress></div></td><td>${units(r.cap,a.decimals)} ${symbol}</td><td>${units(r.badDebt,a.decimals)} ${symbol}</td><td>${units(r.index,27,12)}</td></tr>`; }).join('')}</tbody></table>`;
}
function actionSymbol(form) { return form.elements.asset?.value || 'IMD'; }
function updateQuotes() {
  const s = state.snapshot;
  for (const form of $$('[data-action]')) {
    const output = $(`[data-quote="${form.dataset.action}"]`);
    if (!s || !state.account) { output.textContent = 'Connect a wallet to a verified deployment to preview your position.'; continue; }
    const symbol = actionSymbol(form), a = s.assets[symbol];
    if (form.dataset.action === 'repay') $('#repay-debt').textContent = `Debt: ${units(a.debt,a.decimals)} ${symbol} · Wallet: ${units(a.balance,a.decimals)} ${symbol}`;
    if (!form.elements.amount.value) { output.textContent = 'Enter an amount to preview your position.'; continue; }
    try {
      const amount = parseAmount(form.elements.amount.value, a.decimals);
      if (!s.account || a.price == null) { output.textContent = 'Oracle valuation unavailable. Repayments remain available subject to contract simulation; risk-increasing actions fail closed.'; continue; }
      const projected = projectedPosition({collateralUsd:s.account.collateralUsd,debtUsd:s.account.debtUsd,liquidationBps:s.threshold,ltvBps:s.ltv,action:form.dataset.action,amount,decimals:a.decimals,price:a.price,enabled:s.enabled,assetDebt:a.debt});
      const limit = projected?.exceedsCapacity ? ` Projected debt ${usd(projected.debtUsd)} exceeds the loan-to-value borrowing limit ${usd(projected.capacityUsd)}; the contract will reject this action.` : '';
      output.textContent = `Projected health factor: ${hf(projected?.health)} · Oracle value: ${usd(amount * a.price / 10n ** BigInt(a.decimals))}.${limit} Estimate excludes price movement, accrued interest after this block, rounding dust and other pending transactions. The contract rechecks at execution.`;
      output.classList.toggle('danger-text', projected != null && (projected.health < USD || projected.exceedsCapacity));
    } catch (error) { output.textContent = errorText(error); }
  }
}
for (const form of $$('[data-action]')) {
  form.addEventListener('input', updateQuotes);
  form.addEventListener('submit', (event) => { event.preventDefault(); try { const symbol = actionSymbol(form); const amount = parseAmount(form.elements.amount.value, state.snapshot?.assets[symbol].decimals); review({ action: form.dataset.action, symbol, amount }); } catch (error) { showError(error); } });
}
$('#repay-fill').onclick = () => {
  const form = $('#repay-form'), symbol = actionSymbol(form), a = state.snapshot?.assets[symbol];
  if (!a?.debt) return;
  const buffered = (a.debt * 1001n + 999n) / 1000n;
  form.elements.amount.value = formatUnits(buffered > a.balance ? a.balance : buffered, a.decimals); updateQuotes();
};
$('#toggle-collateral').onclick = () => review({ action: 'collateral', enabled: !state.snapshot?.enabled, symbol: 'IMD', amount: 0n });
$('#donate-form').onsubmit = (event) => { event.preventDefault(); try { const form = event.currentTarget, symbol = actionSymbol(form); if (!form.elements.ack.checked) throw new Error('Acknowledge that reserve funding is non-redeemable.'); review({ action: 'donate', symbol, amount: parseAmount(form.elements.amount.value, state.snapshot?.assets[symbol].decimals) }); } catch (error) { showError(error); } };
$('#lookup-form').onsubmit = async (event) => { event.preventDefault(); clearError(); try {
  if (!state.verified) throw new Error('A verified protocol connection is required.');
  const borrower = checksum(event.currentTarget.elements.account.value.trim());
  const blockTag = await state.provider.getBlockNumber();
  const [data, collateral] = await Promise.all([state.bank.accountData(borrower,{blockTag}),state.bank.collateralBalance(borrower,{blockTag})]);
  state.borrower = borrower; state.borrowerData = data; $('#finalize-dust').dataset.blocked = String(!(data.healthFactor < USD && data.collateralUsd <= 10n ** 15n && data.collateralUsd < data.debtUsd)); disableWrites();
  $('#liquidation-account').textContent = `${borrower} · Block ${blockTag} · Health factor ${hf(data.healthFactor)} · Debt ${usd(data.debtUsd)} · IMD collateral ${units(collateral,state.snapshot.assets.IMD.decimals)}. ${data.healthFactor < USD ? 'Unhealthy; preview exact repayment and collateral at review.' : 'Not eligible for liquidation at this block.'}`;
} catch (error) { state.borrower = null; $('#liquidation-account').textContent = errorText(error); showError(error); } };
$('#lookup-form input').addEventListener('input', () => { state.borrower = null; state.borrowerData = null; $('#finalize-dust').dataset.blocked='true'; disableWrites(); });
$('#finalize-dust').onclick = () => { if (!state.borrower || !state.borrowerData) return showError(new Error('Inspect the borrower account first.')); review({action:'dust', symbol:'IMD', amount:0n, borrower:state.borrower, collateralUsd:state.borrowerData.collateralUsd}); };
$('#liquidate-form').onsubmit = async (event) => { event.preventDefault(); clearError(); try {
  if (!state.borrower) throw new Error('Inspect the borrower account first.');
  const form = event.currentTarget, symbol = actionSymbol(form);
  const amount = parseAmount(form.elements.amount.value, state.snapshot?.assets[symbol].decimals);
  const minimum = parseAmount(form.elements.minimum.value, state.snapshot?.assets.IMD.decimals);
  const quote = await state.bank.previewLiquidation(state.borrower,tokenAddress(symbol),amount);
  if (quote.seized < minimum || quote.repaid === 0n) throw new Error('The quoted liquidation does not meet your minimum output or has no repayable debt.');
  review({ action: 'liquidate', symbol, amount, minimum, borrower: state.borrower, quote });
} catch (error) { showError(error); } };
function review(request) {
  clearError();
  try {
    if (!state.verified || !state.account || state.chainId !== 1 || !state.snapshot) throw new Error('Connect an Ethereum Mainnet wallet to a verified deployment first.');
    if (state.busy || state.loading) throw new Error('Wait for the current request to finish.');
    const s = state.snapshot, a = s.assets[request.symbol];
    if (request.action === 'supply' && s.supplyCap === 0n) throw new Error('The IMD supply cap is zero. This market is not activated.');
    if (request.action === 'borrow' && (s.frozen || a.reserve.frozen || a.reserve.cap === 0n)) throw new Error('Borrowing is disabled by a freeze or zero reserve cap.');
    if (request.action === 'borrow' && request.amount > a.reserve.cash) throw new Error('The reserve has insufficient available liquidity.');
    if (request.action === 'withdraw' && request.amount > s.supplied) throw new Error('Withdrawal exceeds your supplied IMD.');
    if (['supply','donate'].includes(request.action) && request.amount > a.balance) throw new Error('Amount exceeds your wallet token balance.');
    if (request.action === 'repay' && a.debt === 0n) throw new Error('There is no debt to repay in this asset.');
    state.pending = { ...request, context: { account: state.account, chainId: state.chainId }, generation: state.generation };
    const rows = [['Action',request.action === 'collateral' ? `${request.enabled ? 'Enable' : 'Disable'} collateral` : request.action],['Network','Ethereum Mainnet · Chain ID 1'],['Account',state.account],['Contract / approval spender',state.config.bankAddress]];
    if (!['collateral','revoke','dust'].includes(request.action)) rows.push(['Amount / spending ceiling',`${formatUnits(request.amount,a.decimals)} ${request.symbol}`]);
    if (request.action === 'dust') rows.push(['Borrower',request.borrower],['Residual collateral value',`${formatUnits(request.collateralUsd,18)} USD`],['Effect','Receive residual IMD; write off unpaid debt and freeze affected lending. Collateral must be worth at most $0.001, less than the debt, and unable to fund any ordinary liquidation. The contract checks these conditions during simulation.']);
    if (request.action === 'revoke') rows.push(['Approval',`Set ${request.symbol} allowance to zero`]);
    if (request.action === 'liquidate') rows.push(['Borrower',request.borrower],['Quoted repayment',`${formatUnits(request.quote.repaid,a.decimals)} ${request.symbol}`],['Quoted IMD received',`${formatUnits(request.quote.seized,s.assets.IMD.decimals)} IMD`],['Minimum IMD received',`${formatUnits(request.minimum,s.assets.IMD.decimals)} IMD`]);
    if (request.action === 'donate') rows.push(['Withdrawal claim','NONE. This donation cannot be withdrawn.']);
    if (s.account && a.price != null && ['supply','borrow','repay','withdraw'].includes(request.action)) {
      const projected = projectedPosition({collateralUsd:s.account.collateralUsd,debtUsd:s.account.debtUsd,liquidationBps:s.threshold,ltvBps:s.ltv,action:request.action,amount:request.amount,decimals:a.decimals,price:a.price,enabled:s.enabled,assetDebt:a.debt});
      if (projected.exceedsCapacity) throw new Error(`This action would leave ${usd(projected.debtUsd)} of debt above the loan-to-value borrowing limit of ${usd(projected.capacityUsd)}. The contract rejects it. Refresh if prices or balances changed.`);
      rows.push(['Estimated resulting health factor', hf(projected.health)], ['Remaining borrowing limit after action', projected.capacityUsd == null ? 'Unavailable' : usd(projected.capacityUsd > projected.debtUsd ? projected.capacityUsd - projected.debtUsd : 0n)]);
    }
    $('#review-details').innerHTML = `<dl>${rows.map(([k,v])=>`<dt>${escape(k)}</dt><dd>${escape(v)}</dd>`).join('')}</dl>`;
    $('#review-ack').checked = false; $('#review-submit').disabled = true; $('#review-dialog').showModal();
  } catch (error) { showError(error); }
}
$('#review-ack').onchange = () => { $('#review-submit').disabled = !$('#review-ack').checked; };
$('#review-close').onclick = () => { state.pending = null; $('#review-dialog').close(); };
async function assertContext(request) {
  if (request.generation !== state.generation || !state.wallet) throw new Error('Wallet context changed. Review the action again.');
  const [accounts, chain] = await Promise.all([state.wallet.request({method:'eth_accounts'}), state.wallet.request({method:'eth_chainId'})]);
  assertWalletContext(request.context,{account:accounts[0],chainId:Number(BigInt(chain))});
}
async function waitForTransaction(tx, label) {
  status(`${label}: submitted. Waiting for ${state.config.transactionConfirmations} confirmation(s).`,tx.hash);
  let receipt;
  try { receipt = await tx.wait(state.config.transactionConfirmations); }
  catch (error) { if (error.code === 'TRANSACTION_REPLACED' && !error.cancelled && error.reason === 'repriced' && error.receipt) receipt = error.receipt; else throw error; }
  if (!receipt || receipt.status !== 1) throw new Error(`${label} failed on chain. Check the transaction receipt before retrying.`);
  state.history.unshift({label,hash:receipt.hash,block:receipt.blockNumber});
  $('#history').innerHTML = state.history.map(item=>`<div class="history-item"><strong>${escape(item.label)}</strong> · confirmed in block ${item.block}<br><a href="https://etherscan.io/tx/${item.hash}" target="_blank" rel="noopener noreferrer">${short(item.hash)} ↗</a></div>`).join('');
  return receipt;
}
async function approve(request, signer, amount) {
  await assertContext(request);
  const iface = new Interface(tokenAbi);
  const tx = {to:tokenAddress(request.symbol),data:iface.encodeFunctionData('approve',[state.config.bankAddress,amount]),from:request.context.account};
  // USDT and other ERC20 tokens may return no data; decode only when data is present.
  const returned = await state.provider.call(tx);
  if (returned !== '0x') { const result = iface.decodeFunctionResult('approve',returned); if (!result[0]) throw new Error('The token rejected the approval.'); }
  const gas = await state.provider.estimateGas(tx);
  await assertContext(request);
  status(`Approve ${request.symbol}: confirm ${formatUnits(amount,state.snapshot.assets[request.symbol].decimals)} in your wallet.`);
  const sent = await signer.sendTransaction({...tx,gasLimit:gas + gas / 5n});
  await waitForTransaction(sent,amount === 0n ? `Revoke ${request.symbol} allowance` : `Approve ${request.symbol}`);
}
async function ensureAllowance(request, signer) {
  const token = new Contract(tokenAddress(request.symbol),tokenAbi,state.provider);
  const allowance = await token.allowance(request.context.account,state.config.bankAddress);
  if (allowance >= request.amount) return;
  // Reset nonzero allowance before replacing it; needed by USDT and safe for other supported assets.
  if (allowance > 0n) await approve(request,signer,0n);
  await approve(request,signer,request.amount);
}
$('#review-submit').onclick = async () => {
  const request = state.pending;
  if (!request || !$('#review-ack').checked || state.busy) return;
  state.pending = null; $('#review-dialog').close(); state.busy = true; disableWrites(); clearError();
  try {
    await assertContext(request);
    await verifyDeployment('latest');
    const signer = await state.provider.getSigner(request.context.account);
    if (request.action === 'revoke') { await approve(request,signer,0n); status(`${request.symbol} allowance revoked.`); return; }
    if (['supply','repay','liquidate','donate'].includes(request.action)) await ensureAllowance(request,signer);
    await assertContext(request);
    const bank = state.bank.connect(signer);
    let method, args;
    if (request.action === 'supply') { method='supply'; args=[request.amount,request.context.account]; }
    if (request.action === 'withdraw') { method='withdraw'; args=[request.amount,request.context.account]; }
    if (request.action === 'borrow') { method='borrow'; args=[tokenAddress(request.symbol),request.amount,request.context.account]; }
    if (request.action === 'repay') { method='repay'; args=[tokenAddress(request.symbol),request.amount,request.context.account]; }
    if (request.action === 'collateral') { method='setCollateralEnabled'; args=[request.enabled]; }
    if (request.action === 'dust') { method='finalizeDust'; args=[request.borrower]; }
    if (request.action === 'donate') { method='donateLiquidity'; args=[tokenAddress(request.symbol),request.amount]; }
    if (request.action === 'liquidate') {
      const block = await state.provider.getBlock('latest');
      method='liquidate'; args=[request.borrower,tokenAddress(request.symbol),request.amount,request.minimum,BigInt(block.timestamp)+600n];
    }
    if (!method) throw new Error('Unsupported action.');
    status('Simulating against the latest contract state…');
    const fn = bank.getFunction(method);
    await fn.staticCall(...args);
    const gas = await fn.estimateGas(...args);
    await assertContext(request);
    status('Simulation passed. Review and confirm the protocol transaction in your wallet.');
    const transaction = await fn(...args,{gasLimit:gas+gas/5n});
    const receipt = await waitForTransaction(transaction,request.action);
    status(`${request.action} confirmed in block ${receipt.blockNumber}. Refreshing your on-chain position.`,receipt.hash);
  } catch (error) { showError(error); status(`Action stopped: ${errorText(error)} If an approval already confirmed, it remains active and can be revoked from My position.`); }
  finally { state.busy = false; await refresh(); disableWrites(); }
};

async function start() {
  try {
    const response = await fetch('./config.json',{cache:'no-store'});
    if (!response.ok) throw new Error('Deployment configuration could not be loaded.');
    state.config = await response.json();
    try { validateConfig(state.config); } catch (error) { state.configError = error; }
    if (state.config.rpcUrl && !state.configError) state.provider = new JsonRpcProvider(state.config.rpcUrl,1);
    render();
    await refresh();
  } catch (error) { state.configError = error; showError(error); render(); }
  discoverLegacy();
  setInterval(() => { if (!document.hidden && !state.busy) void refresh(); },15000);
}
void start();
