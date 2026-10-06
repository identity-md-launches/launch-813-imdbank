#!/usr/bin/env python3
"""Check actual optimized deployed bytecode, skipping PUSH data as the supplied floor does."""
import json
from pathlib import Path


def check(name):
    artifact = json.loads(Path(f'out/{name}.sol/{name}.json').read_text())
    code = bytes.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    init = bytes.fromhex(artifact['bytecode']['object'].removeprefix('0x'))
    assert 0 < len(code) <= 24576, (name, 'runtime size', len(code))
    assert len(init) + 32 * 7 <= 49152, (name, 'initcode limit')
    i = 0
    while i < len(code):
        op = code[i]
        assert op not in (0xF2, 0xF4, 0xFF), (name, 'forbidden opcode', hex(op), i)
        i += op - 0x5F + 1 if 0x60 <= op <= 0x7F else 1
    print(f'{name}: {len(code)} runtime bytes; no DELEGATECALL, CALLCODE or SELFDESTRUCT')


for contract in ('IMDBank', 'RiskOracle', 'GovernanceTimelock'):
    check(contract)
