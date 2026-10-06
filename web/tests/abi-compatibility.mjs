import fs from 'node:fs';
import assert from 'node:assert/strict';
import { Interface } from '../vendor/ethers-6.15.0.min.js';
import { bankAbi, oracleAbi } from '../abi.js';
const cases=[['IMDBank',bankAbi],['RiskOracle',oracleAbi]];
let checked=0;
for(const [name,abi] of cases) {
  const artifact=JSON.parse(fs.readFileSync(new URL(`../../out/${name}.sol/${name}.json`,import.meta.url),'utf8'));
  const actual=new Interface(artifact.abi),frontend=new Interface(abi);
  for(const fragment of frontend.fragments) {
    if(fragment.type!=='function') continue;
    const deployed=actual.getFunction(fragment.format('sighash'));
    assert.ok(deployed,`${name}.${fragment.name} is absent from compiled ABI`);
    assert.equal(deployed.selector,fragment.selector);
    assert.deepEqual(deployed.outputs.map(value=>value.type),fragment.outputs.map(value=>value.type),`${name}.${fragment.name} output types differ`);
    assert.equal(deployed.stateMutability,fragment.stateMutability,`${name}.${fragment.name} mutability differs`);
    checked++;
  }
}
console.log(`PASS: ${checked} frontend function signatures match compiled Foundry artifacts.`);
