import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { Interface, MaxUint256 } from '../vendor/ethers-6.15.0.min.js';
import { bankAbi } from '../abi.js';
import { validateConfig, canonicalAssets, parseAmount, units, projectedHealth, errorText, assertWalletContext, USD } from '../core.js';

const validConfig = () => ({chainId:1,bankAddress:'0x1111111111111111111111111111111111111111',oracleAddress:'0x2222222222222222222222222222222222222222',bankCodeHash:`0x${'ab'.repeat(32)}`,oracleCodeHash:`0x${'cd'.repeat(32)}`,transactionConfirmations:2,assets:{...canonicalAssets}});

test('deployment defaults fail closed until real addresses and hashes are supplied', () => {
  const config = JSON.parse(fs.readFileSync(new URL('../config.json', import.meta.url)));
  assert.throws(()=>validateConfig(config),/not configured/);
  assert.equal(config.chainId,1);
  assert.equal(config.bankAddress,null);
  assert.equal(config.deploymentStatus,'NOT_DEPLOYED');
});
test('rejects wrong chain, swapped assets, zero addresses and missing runtime hashes', () => {
  assert.doesNotThrow(()=>validateConfig(validConfig()));
  const cases = [c=>c.chainId=31337,c=>c.assets.USDC=c.assets.USDT,c=>c.bankAddress=`0x${'0'.repeat(40)}`,c=>c.bankCodeHash=null,c=>c.oracleCodeHash=`0x${'0'.repeat(64)}`,c=>c.transactionConfirmations=0,c=>c.rpcUrl='http://untrusted.example'];
  for(const mutate of cases) {const config=validConfig();mutate(config);assert.throws(()=>validateConfig(config));}
});
test('fixed-point amounts retain 18 decimal precision and never use floating point', () => {
  assert.equal(parseAmount('123456789012345678.123456789012345678',18),123456789012345678123456789012345678n);
  assert.equal(parseAmount('0.000001',6),1n);
  assert.equal(parseAmount('1.123456',6),1123456n);
  assert.equal(units(123456789123456789123456789n,18,18),'123,456,789.123456789123456789');
});
test('rejects unsafe, zero, nondecimal, overprecision and overflow inputs', () => {
  for(const value of ['0','0.000000','-1','1e18','1,000','NaN','Infinity','.1','01','1.','0x10','1.0000001']) assert.throws(()=>parseAmount(value,6));
  assert.throws(()=>parseAmount((MaxUint256+1n).toString(),0));
  assert.throws(()=>parseAmount('1',19));
});
test('health projection tracks supply, borrow, repay and collateral withdrawal', () => {
  const base={collateralUsd:1000n*USD,debtUsd:100n*USD,liquidationBps:3500n,decimals:18,price:USD,enabled:true};
  assert.equal(projectedHealth({...base,action:'supply',amount:100n*USD}),385n*USD/100n);
  assert.equal(projectedHealth({...base,action:'borrow',amount:100n*USD}),175n*USD/100n);
  assert.equal(projectedHealth({...base,action:'withdraw',amount:500n*USD}),175n*USD/100n);
  assert.equal(projectedHealth({...base,action:'repay',amount:100n*USD}),MaxUint256);
  assert.equal(projectedHealth({...base,action:'repay',amount:1000n*USD}),MaxUint256);
  assert.equal(projectedHealth({...base,action:'supply',amount:100n*USD,enabled:false}),35n*USD/10n);
  assert.equal(projectedHealth({...base,action:'borrow',amount:100n*USD,price:null}),null);
});
test('projection values added debt up and released collateral up', () => {
  const base={collateralUsd:100n*USD,debtUsd:30n*USD,liquidationBps:3500n,decimals:18,price:USD+1n,enabled:true};
  const expected=base.collateralUsd*3500n*USD/10000n/(base.debtUsd+2n);
  assert.equal(projectedHealth({...base,action:'borrow',amount:1n}),expected);
});
test('wallet account and chain must match reviewed action', () => {
  const expected={account:'0x1111111111111111111111111111111111111111',chainId:1};
  assert.doesNotThrow(()=>assertWalletContext(expected,{...expected}));
  assert.throws(()=>assertWalletContext(expected,{...expected,chainId:31337}),/Mainnet/);
  assert.throws(()=>assertWalletContext(expected,{...expected,account:'0x2222222222222222222222222222222222222222'}),/account changed/);
  assert.throws(()=>assertWalletContext(expected,{...expected,account:null}),/account changed/);
});
test('wallet rejection, reverts and token failures have bounded readable messages', () => {
  assert.match(errorText({code:4001}),/rejected/);
  assert.match(errorText({code:'INSUFFICIENT_FUNDS'}),/gas/);
  assert.match(errorText({revert:{name:'UnsafePosition'}}),/borrowing limit/);
  assert.match(errorText({revert:{name:'CapExceeded'}}),/cap/);
  assert.ok(errorText({message:'x'.repeat(2000)}).length<=500);
});
test('ABI transaction encoding carries exact amount, recipient and liquidation slippage', () => {
  const abi=new Interface(bankAbi),asset=canonicalAssets.USDC,user='0x1111111111111111111111111111111111111111';
  const encoded=abi.encodeFunctionData('borrow',[asset,123456789n,user]);
  const decoded=abi.decodeFunctionData('borrow',encoded);
  assert.equal(decoded.amount,123456789n);assert.equal(decoded.to.toLowerCase(),user);
  const liquidation=abi.decodeFunctionData('liquidate',abi.encodeFunctionData('liquidate',[user,asset,1n,2n,3n]));
  assert.equal(liquidation.maxRepay,1n);assert.equal(liquidation.minCollateralOut,2n);assert.equal(liquidation.deadline,3n);
});
test('HTML exposes every requested screen, no remote scripts and clear launch gate', () => {
  const html=fs.readFileSync(new URL('../index.html',import.meta.url),'utf8');
  for(const screen of ['dashboard','markets','supply','borrow','repay','withdraw','position','liquidations','analytics','risk','addresses']) assert.match(html,new RegExp(`id="page-${screen}"`));
  assert.doesNotMatch(html,/<script[^>]+src="https?:/);
  assert.match(html,/Production activation is blocked/);
});

test('projection flags borrow and withdrawal above the loan-to-value capacity the contract enforces', async () => {
  const {projectedPosition}=await import('../core.js');
  const base={collateralUsd:10000n*USD,debtUsd:0n,liquidationBps:3500n,ltvBps:2500n,decimals:6,price:USD,enabled:true};
  const borrow=projectedPosition({...base,action:'borrow',amount:3000n*10n**6n});
  assert.equal(borrow.health,10000n*USD*3500n/10000n*USD/(3000n*USD));
  assert.equal(borrow.capacityUsd,2500n*USD);
  assert.equal(borrow.exceedsCapacity,true);
  assert.equal(projectedPosition({...base,action:'borrow',amount:2500n*10n**6n}).exceedsCapacity,false);
  const withdraw=projectedPosition({...base,debtUsd:2500n*USD,decimals:18,price:10n*USD,action:'withdraw',amount:USD});
  assert.equal(withdraw.exceedsCapacity,true);
  assert.ok(withdraw.health>USD);
  assert.equal(projectedPosition({...base,debtUsd:2500n*USD,decimals:18,price:10n*USD,action:'supply',amount:1n}).exceedsCapacity,false);
  assert.equal(projectedPosition({...base,debtUsd:2500n*USD,decimals:18,price:10n*USD,action:'withdraw',amount:1n}).exceedsCapacity,true);
  assert.equal(projectedPosition({...base,debtUsd:3000n*USD,action:'repay',amount:1n}).exceedsCapacity,false);
  assert.equal(projectedPosition({...base,action:'withdraw',amount:USD}).exceedsCapacity,false);
  assert.equal(projectedPosition({...base,ltvBps:undefined,action:'borrow',amount:3000n*10n**6n}).capacityUsd,null);
  assert.match(errorText({revert:{name:'MinimumDebt'}}),/at least \$1/);
});

test('repayment preview caps the spending ceiling to debt in that asset', () => {
  const value=projectedHealth({collateralUsd:10000n*USD,debtUsd:1100n*USD,liquidationBps:3500n,action:'repay',amount:10000n*USD,assetDebt:100n*USD,decimals:18,price:USD,enabled:true});
  assert.equal(value,35n*USD/10n);
});

test('mutable token symbol warns without blocking repayment while decimal drift is rejected', async () => {
  const {checkTokenMetadata}=await import('../core.js');
  assert.equal(checkTokenMetadata({symbol:'IMD',observedSymbol:'IMD',decimals:18n,accountingUnit:10n**18n}).metadataWarning,false);
  const changed=checkTokenMetadata({symbol:'IMD',observedSymbol:'RENAMED',decimals:18n,accountingUnit:10n**18n});
  assert.equal(changed.metadataWarning,true);assert.equal(changed.actualSymbol,'RENAMED');assert.equal(changed.decimals,18);
  assert.doesNotThrow(()=>checkTokenMetadata({symbol:'USDT',observedSymbol:'NEW USDT',decimals:6n,accountingUnit:10n**6n}));
  assert.throws(()=>checkTokenMetadata({symbol:'IMD',observedSymbol:'IMD',decimals:6n,accountingUnit:10n**18n}),/accounting unit/);
  assert.throws(()=>checkTokenMetadata({symbol:'USDC',observedSymbol:'USDC',decimals:18n,accountingUnit:10n**18n}),/accounting unit/);
});
