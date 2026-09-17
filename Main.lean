module

import Decimal

public def main : IO Unit :=
  do
    let ctx : Decimal.Context := { precision := 28 }
    let a := (Decimal.parse "1.30").value
    let b := (Decimal.parse "1.20").value
    let sum := Decimal.add ctx a b
    IO.println s!"{a} + {b} = {sum.value}"
    let third := Decimal.div ctx (Decimal.ofInt 1).value (Decimal.ofInt 3).value
    IO.println s!"1 / 3 = {third.value}; flags = {Decimal.Flags.names third.flags}"
