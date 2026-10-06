#!/usr/bin/env python3
"""Deterministic stress scenarios, NOT a calibrated IMD price/liquidity model."""
import csv
from decimal import Decimal as D
from pathlib import Path


def scenario(price_drop, execution_haircut, debt_multiplier):
    collateral = D(100)
    initial_price = D(10)
    loan = D(250)
    threshold = D('0.35')
    bonus = D('1.08')
    oracle_value = collateral * initial_price * (1 - price_drop)
    debt = loan * debt_multiplier
    realizable = oracle_value * (1 - execution_haircut)
    return {
        'price_drop': price_drop,
        'execution_haircut': execution_haircut,
        'debt_multiplier': debt_multiplier,
        'health_factor': oracle_value * threshold / debt,
        'debt_usd': debt,
        'oracle_collateral_usd': oracle_value,
        'realizable_usd': realizable,
        'shortfall_usd': max(D(0), debt - realizable / bonus),
    }


def main():
    cases = [scenario(D(p), D(s), D(d))
             for p in ('0', '.3', '.5', '.75', '.95')
             for s in ('0', '.1', '.5', '.9')
             for d in ('.8', '1', '1.2', '2')]
    target = Path('docs/evidence/economic-stress.csv')
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open('w') as output:
        writer = csv.DictWriter(output, fieldnames=cases[0].keys())
        writer.writeheader()
        writer.writerows(cases)
    # Sanity checks: no adverse move => solvent; gap/doubled debt => loss; depth matters.
    assert scenario(D(0), D(0), D(1))['shortfall_usd'] == 0
    assert scenario(D('.95'), D(0), D(1))['shortfall_usd'] > 0
    assert scenario(D(0), D('.9'), D(1))['shortfall_usd'] > 0
    assert scenario(D('.5'), D('.1'), D(2))['shortfall_usd'] > 0
    print(f'{len(cases)} scenarios written; {sum(c["shortfall_usd"] > 0 for c in cases)} exhibit shortfall.')


if __name__ == '__main__':
    main()
