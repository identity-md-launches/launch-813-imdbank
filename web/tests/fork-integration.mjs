/**
 * Real-token Ethereum fork integration through the frontend's vendored ethers,
 * BrowserProvider (EIP-1193), ABI and amount parser. This is NOT browser automation.
 * Requires an already-running local Anvil fork with chain ID 1, impersonation and
 * compiled Foundry artifacts. No key, environment variable or public write RPC.
 */
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { BrowserProvider, Contract, ContractFactory, MaxUint256, keccak256, parseEther } from '../vendor/ethers-6.15.0.min.js';
import { bankAbi, tokenAbi, oracleAbi } from '../abi.js';
import { canonicalAssets, parseAmount, validateConfig, assertWalletContext, USD } from '../core.js';

process.on('uncaughtException', error => { console.error(JSON.stringify({status:'FAIL',message:error.shortMessage || error.message,code:error.code,details:error.info?.error?.message || error.error?.message || ''})); process.exit(1); });
const endpoint = process.argv[2] || 'http://127.0.0.1:8545';
const url = new URL(endpoint);
if (!['localhost','127.0.0.1','[::1]'].includes(url.hostname) || url.protocol !== 'http:') throw new Error('This destructive fork fixture is restricted to an HTTP loopback Anvil endpoint.');
let id = 0;
async function rpc(method, params=[]) {
  const response = await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:++id,method,params})});
  const json = await response.json();
  if (json.error) throw new Error(`${method}: ${json.error.message}`);
  return json.result;
}
assert.match(await rpc('web3_clientVersion'),/anvil/i,'Requires Anvil, not a public Ethereum node');
assert.equal(BigInt(await rpc('eth_chainId')),1n);
const nodeInfo = await rpc('anvil_nodeInfo');
const startForkBlock = Number(nodeInfo.forkConfig?.forkBlockNumber);
if (!Number.isSafeInteger(startForkBlock) || startForkBlock <= 0) throw new Error('A pinned Ethereum fork is required.');
const forkHeader = await rpc('eth_getBlockByNumber',[`0x${startForkBlock.toString(16)}`,false]);
assert.ok(forkHeader?.hash,'The fork block hash must be available');
const admin = '0x0000000000000000000000000000000000000111';
const guardian = '0x0000000000000000000000000000000000000112';
const borrower = '0x0000000000000000000000000000000000000113';
const liquidator = '0x0000000000000000000000000000000000000114';
let selected = admin;
const injected = {
  async request({method,params=[]}) {
    if (method === 'eth_accounts' || method === 'eth_requestAccounts') return [selected];
    return rpc(method,params);
  },
};
const provider = new BrowserProvider(injected,'any',{cacheTimeout:-1});
provider.pollingInterval=50;
for(const account of [admin,guardian,borrower,liquidator]) {
  await rpc('anvil_impersonateAccount',[account]);
  await rpc('anvil_setBalance',[account,`0x${parseEther('100').toString(16)}`]);
}
const signer = async (account) => {selected=account;return provider.getSigner(account);};
const artifact = name => JSON.parse(fs.readFileSync(new URL(`../../out/${name}.sol/${name}.json`,import.meta.url),'utf8'));
const oracleArtifact = JSON.parse(fs.readFileSync(new URL('../../out/Mocks.sol/MockOracle.json',import.meta.url),'utf8'));
const bankArtifact = artifact('IMDBank');
let receipts = 0;
async function sent(promise) {const tx=await promise;const receipt=await tx.wait(1);assert.equal(receipt.status,1);receipts++;return receipt;}
const deploymentSigner = await signer(admin);
const oracle = await new ContractFactory(oracleArtifact.abi,oracleArtifact.bytecode.object,deploymentSigner).deploy();await oracle.waitForDeployment();
const assets = Object.fromEntries(Object.entries(canonicalAssets).map(([key,value])=>[key,value]));
const bank = await new ContractFactory(bankArtifact.abi,bankArtifact.bytecode.object,deploymentSigner).deploy(admin,guardian,assets.IMD,await oracle.getAddress(),assets.USDC,assets.USDT,assets.WETH);await bank.waitForDeployment();
const bankAddress = await bank.getAddress(), oracleAddress=await oracle.getAddress();
const webBank = new Contract(bankAddress,bankAbi,provider);
const tokens = Object.fromEntries(await Promise.all(Object.entries(assets).map(async ([key,value])=>[key,new Contract(value,tokenAbi,provider)])));
const decimals=Object.fromEntries(await Promise.all(Object.entries(tokens).map(async ([key,token])=>[key,Number(await token.decimals())])));
const amount=(symbol,value)=>parseAmount(value,decimals[symbol]);
for(const symbol of Object.keys(assets)) await sent(oracle.setPrice(assets[symbol],symbol==='WETH'?2000n*USD:USD));
await sent(bank.configureRisk(2500,3500,800,5000,amount('IMD','1000000')));
for(const symbol of ['USDC','USDT','WETH']) await sent(bank.configureReserve(assets[symbol],amount(symbol,'1000000'),10n**27n/50n,10n**27n*8n/100n,10n**27n*90n/100n,8000));

async function transferFromWhale(symbol,recipient,value,candidates) {
  const token=new Contract(assets[symbol],[...tokenAbi,'function transfer(address,uint256) returns(bool)'],provider);
  for(const whale of candidates) {
    if(await token.balanceOf(whale)<value) continue;
    await rpc('anvil_impersonateAccount',[whale]); await rpc('anvil_setBalance',[whale,`0x${parseEther('5').toString(16)}`]);
    await sent(token.connect(await signer(whale)).transfer(recipient,value));
    return whale;
  }
  throw new Error(`None of the pinned candidate ${symbol} holders can fund this fork fixture.`);
}
const stableWhales=['0x55fe002aeff02f77364de339a1292923a15844b8','0xf977814e90da44bfa03b6295a0616a897441acec','0x28c6c06298d514db089934071355e5743bf21d60'];
await sent(bank.setFrozen(false));
const donors={};
donors.IMD=await transferFromWhale('IMD',borrower,amount('IMD','1100'),['0xe54d6571aca515614927f3a70b8957c2b511603c']);
for(const symbol of ['USDC','USDT']) {
  donors[symbol]=await transferFromWhale(symbol,admin,amount(symbol,'20000'),stableWhales);
  await transferFromWhale(symbol,borrower,amount(symbol,'5'),stableWhales);
  await transferFromWhale(symbol,liquidator,amount(symbol,'1000'),stableWhales);
}
const weth=new Contract(assets.WETH,['function deposit() payable','function transfer(address,uint256) returns(bool)'],await signer(admin));
await sent(weth.deposit({value:parseEther('20')}));
await sent(weth.transfer(borrower,amount('WETH','0.01')));

async function approveExact(account,symbol,value) {
  const token=tokens[symbol].connect(await signer(account));
  const allowance=await token.allowance(account,bankAddress);
  if(allowance>0n && allowance<value) await sent(token.approve(bankAddress,0n));
  if(allowance<value) await sent(token.approve(bankAddress,value));
}
async function action(account,name,args) {
  console.error(`Fork action: ${name}`);
  const connection=webBank.connect(await signer(account));
  assertWalletContext({account,chainId:1},{account:(await injected.request({method:'eth_requestAccounts'}))[0],chainId:Number(BigInt(await injected.request({method:'eth_chainId'})))});
  const fn=connection.getFunction(name);
  await fn.staticCall(...args);
  const gas=await fn.estimateGas(...args);
  return sent(fn(...args,{gasLimit:gas+gas/5n}));
}
for(const symbol of ['USDC','USDT','WETH']) {
  const quantity=amount(symbol,symbol==='WETH'?'10':'10000');
  await approveExact(admin,symbol,quantity);await action(admin,'donateLiquidity',[assets[symbol],quantity]);
}
const config={chainId:1,bankAddress,oracleAddress,bankCodeHash:keccak256(await provider.getCode(bankAddress)),oracleCodeHash:keccak256(await provider.getCode(oracleAddress)),transactionConfirmations:1,assets};
validateConfig(config);
assert.equal(await webBank.name(),'IMDBANK');assert.equal(await webBank.symbol(),'IMDBANK');assert.equal(await webBank.feeBps(),0n);
assert.equal((await webBank.collateral()).toLowerCase(),assets.IMD);
assert.equal((await new Contract(oracleAddress,oracleAbi,provider).price(assets.IMD)),USD);
await approveExact(borrower,'IMD',amount('IMD','1000'));
await action(borrower,'supply',[amount('IMD','1000'),borrower]);
await action(borrower,'setCollateralEnabled',[true]);
for(const [symbol,quantity] of [['USDC','100'],['USDT','50'],['WETH','0.005']]) await action(borrower,'borrow',[assets[symbol],amount(symbol,quantity),borrower]);
const initial=await webBank.accountData(borrower);assert.ok(initial.healthFactor>USD);
await assert.rejects(()=>webBank.connect(deploymentSigner).borrow.staticCall(assets.USDC,amount('USDC','1000'),admin),'Uncollateralized actor must be rejected');
const borrowerSigner=await signer(borrower);
await assert.rejects(()=>webBank.connect(borrowerSigner).borrow.staticCall(assets.USDC,amount('USDC','1000'),borrower),'Borrowing beyond LTV must be rejected');
await assert.rejects(()=>webBank.connect(borrowerSigner).setCollateralEnabled.staticCall(false),'Disabling collateral with debt must be rejected');
await approveExact(borrower,'USDC',amount('USDC','1'));await action(borrower,'repay',[assets.USDC,amount('USDC','1'),borrower]);
await action(borrower,'withdraw',[amount('IMD','5'),borrower]);
await sent(oracle.connect(await signer(admin)).setPrice(assets.IMD,USD*3n/10n));
const unhealthy=await webBank.accountData(borrower);assert.ok(unhealthy.healthFactor<USD,'Oracle move must make position liquidatable');
const quote=await webBank.previewLiquidation(borrower,assets.USDC,amount('USDC','50'));
assert.ok(quote.repaid>0n && quote.seized>0n);
await approveExact(liquidator,'USDC',amount('USDC','50'));
const latest=await provider.getBlock('latest');
await assert.rejects(()=>webBank.connect(borrowerSigner).liquidate.staticCall(borrower,assets.USDC,amount('USDC','50'),quote.seized*2n,BigInt(latest.timestamp)+600n),'Unsafe minimum output must be rejected');
const imdBefore=await tokens.IMD.balanceOf(liquidator);
await action(liquidator,'liquidate',[borrower,assets.USDC,amount('USDC','50'),quote.seized*99n/100n,BigInt(latest.timestamp)+600n]);
assert.ok(await tokens.IMD.balanceOf(liquidator)>imdBefore,'Liquidator receives real IMD');
const postLiquidation=await webBank.accountData(borrower);assert.ok(postLiquidation.debtUsd<unhealthy.debtUsd);
await sent(oracle.connect(await signer(admin)).setPrice(assets.IMD,USD));
// Approve exact live debt plus a bounded interest buffer; token transfer is capped by actual debt.
for(const symbol of ['USDC','USDT','WETH']) {
  const debt=await webBank.previewDebt(borrower,assets[symbol]);
  if(debt===0n) continue;
  const ceiling=(debt*1001n+999n)/1000n;
  await approveExact(borrower,symbol,ceiling);await action(borrower,'repay',[assets[symbol],ceiling,borrower]);
  assert.equal(await webBank.previewDebt(borrower,assets[symbol]),0n);
}
await action(borrower,'setCollateralEnabled',[false]);
const remaining=await webBank.collateralBalance(borrower);
await action(borrower,'withdraw',[remaining,borrower]);
assert.equal(await webBank.collateralBalance(borrower),0n);
const final=await webBank.accountData(borrower);assert.equal(final.debtUsd,0n);assert.equal(final.healthFactor,MaxUint256);
const result={
  status:'PASS',browserAutomation:false,publicMainnetTransactions:false,
  description:'Frontend EIP-1193 adapter / BrowserProvider / ABI integration on local Ethereum fork, with real canonical tokens and a mock price oracle.',
  chainId:1,startForkBlock,startForkBlockHash:forkHeader.hash,evmHardfork:nodeInfo.hardFork,finalBlock:await provider.getBlockNumber(),bankAddress,oracleAddress,
  bankSourceSha256:createHash('sha256').update(fs.readFileSync(new URL('../../src/IMDBank.sol',import.meta.url))).digest('hex'),
  bankRuntimeCodeHash:config.bankCodeHash,oracleRuntimeCodeHash:config.oracleCodeHash,
  testGovernance:'Impersonated local test addresses; this is not production multisig governance.',
  successfulReceipts:receipts,tokenDonors:donors,
  checks:['wallet EIP-1193 account connection','chain ID 1','runtime hashes and zero fees','real IMD approve and supply','collateral enablement','USDC, USDT and WETH borrowing','LTV rejection','unsafe collateral disable rejection','partial repayment','withdrawal','oracle-driven health-factor deterioration','liquidation minimum-output rejection','successful liquidation and IMD receipt','full repayment of every asset','final collateral withdrawal','zero remaining debt and collateral'],
};
console.log(JSON.stringify(result,null,2));
await provider.destroy();
