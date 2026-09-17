#!/usr/bin/env python3
"""Compare native libmpdec, the executable Lean model, and Python decimal.

No third-party Python packages or network access are needed.
Build decimalOracle first, then run this file from the repository root.
"""

import argparse
import decimal as D
import os
import random
import subprocess
from pathlib import Path

MODES = [D.ROUND_HALF_EVEN, D.ROUND_HALF_UP, D.ROUND_HALF_DOWN, D.ROUND_UP,
         D.ROUND_DOWN, D.ROUND_CEILING, D.ROUND_FLOOR, D.ROUND_05UP]
SIGNALS = [D.InvalidOperation, D.DivisionByZero, D.Overflow, D.Underflow,
           D.Subnormal, D.Inexact, D.Rounded, D.Clamped]
OPS = {"apply": "plus", "add": "add", "sub": "subtract", "mul": "multiply",
       "div": "divide", "quantize": "quantize"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oracle", type=Path,
                        default=Path(".lake/build/bin/decimalOracle" + (".exe" if os.name == "nt" else "")))
    parser.add_argument("--cases", type=int, default=3000)
    args = parser.parse_args()
    rng = random.Random(20260917)
    cases = []

    def add(op, a, b="0", p=9, emin=-9, emax=9, mode=0, clamp=0):
        cases.append((op, p, emin, emax, mode, clamp, a, b))

    parsing = ["", ".", "-", "+", "1.2.3", "1e", "1e+", "--1", "1 2", "0x10",
               "NaN", "sNaN", "-NaN0030", "-sNaN002", "Inf", "+INFINITY", "iNf",
               "nAn", "sNaN12345", "nan0", "NaN1.2", "NaN+1", "Inf0", "_1_2.3_0_",
               "  +1.20e+3  ", "0.000000", "-0.0000000", "00.00100", ".5", "5.",
               "1E+999999999999999999", "1E-1999999999999999997",
               "10E+999999999999999999", "0E+1000000000000000000",
               "0E-1999999999999999998", "1e999999999999999999999999999",
               "1e-999999999999999999999999999", "9" * 5000]
    for s in parsing:
        add("parse", s)

    special = ["0", "-0.00", "0E+20", "-0E-20", "1", "-1", "Infinity",
               "-Infinity", "NaN", "-NaN12345", "sNaN", "-sNaN67890"]
    for mode in range(8):
        for a in special:
            for b in special:
                for op in OPS:
                    add(op, a, b, p=3, emin=-3, emax=3, mode=mode, clamp=mode % 2)
        for a in ["0.00009995", "-0.00009995", "0.00000001", "-0.00000001",
                  "9999", "-9999", "9.999", "-9.999", "1000.00", "2500", "3500"]:
            for op in OPS:
                for b in ["1", "3", "0.0001", "1E+2"]:
                    add(op, a, b, p=3, emin=-3, emax=3, mode=mode, clamp=mode % 2)

    def operand():
        if rng.randrange(20) == 0:
            return rng.choice(special)
        size = rng.randrange(1, 51)
        digits = "".join(str(rng.randrange(10)) for _ in range(size))
        return rng.choice(["", "-"]) + digits + "E" + str(rng.randrange(-80, 81))

    for _ in range(args.cases):
        a, b = operand(), operand()
        p = rng.choice([1, 2, 3, 9, 28, 50, 100])
        emin, emax = -rng.randrange(0, 61), rng.randrange(0, 61)
        mode, clamp = rng.randrange(8), rng.randrange(2)
        for op in OPS:
            add(op, a, b, p, emin, emax, mode, clamp)

    wire = "".join("|".join(map(str, c)) + "\n" for c in cases)
    proc = subprocess.run([str(args.oracle.resolve())], input=wire, text=True, encoding="utf-8",
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    lines = proc.stdout.splitlines()
    assert len(lines) == len(cases), (len(lines), len(cases), proc.stderr)
    failures = []
    for case, line in zip(cases, lines):
        op, p, emin, emax, mode, clamp, a, b = case
        ctx = D.Context(prec=p, Emin=emin, Emax=emax, rounding=MODES[mode], clamp=clamp)
        ctx.clear_traps()
        if op == "parse":
            expected = D.Decimal(a, context=ctx)
        else:
            da, db = D.Decimal(a), D.Decimal(b)
            expected = getattr(ctx, OPS[op])(da) if op == "apply" else getattr(ctx, OPS[op])(da, db)
        flags = sum(1 << i for i, s in enumerate(SIGNALS) if ctx.flags[s])
        native, nf, spec, sf, agrees = line.split("|")
        if (native, int(nf)) != (str(expected), flags) or (native, nf) != (spec, sf) or agrees != "true":
            failures.append((case, line, (str(expected), flags)))
    for case, actual, expected in failures[:20]:
        print("CASE:", case)
        print("NATIVE|FLAGS|MODEL|FLAGS|REPRESENTATION:", actual)
        print("PYTHON:", expected)
    if failures:
        raise SystemExit(f"{len(failures)} / {len(cases)} cases failed")
    print(f"{len(cases)} cases passed: native = Lean model = Python decimal "
          f"(libmpdec {D.__libmpdec_version__}, all 8 rounding modes)")


if __name__ == "__main__":
    main()
