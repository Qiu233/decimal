module

import Decimal

open Decimal

private def rounding (n : Nat) : Rounding :=
  match n with
  | 1 => .halfUp | 2 => .halfDown | 3 => .up | 4 => .down
  | 5 => .ceiling | 6 => .floor | 7 => .zeroFiveUp | _ => .halfEven

/-- Simple line protocol used by the independent Python differential test. -/
private def evaluate (line : String) : Except String String := do
  let [op, p, emin, emax, mode, clamp, sa, sb] := line.trimAscii.copy.splitOn "|"
    | throw "expected op|precision|emin|emax|rounding|clamp|a|b"
  let some p := p.toNat? | throw "precision"
  let some emin := emin.toInt? | throw "emin"
  let some emax := emax.toInt? | throw "emax"
  let ctx : Context := {
    precision := p, emin, emax, rounding := rounding mode.toNat!
    clamp := clamp == "1", traps := 0 }
  let a := (Decimal.parse sa).value
  let b := (Decimal.parse sb).value
  let ma := (Model.parse sa).value
  let mb := (Model.parse sb).value
  let (native, spec) ← match op with
    | "parse" => pure (Decimal.parse sa, Model.parse sa)
    | "apply" => pure (Decimal.apply ctx a, Model.apply ctx ma)
    | "add" => pure (Decimal.add ctx a b, Model.add ctx ma mb)
    | "sub" => pure (Decimal.sub ctx a b, Model.sub ctx ma mb)
    | "mul" => pure (Decimal.mul ctx a b, Model.mul ctx ma mb)
    | "div" => pure (Decimal.div ctx a b, Model.div ctx ma mb)
    | "quantize" => pure (Decimal.quantize ctx a b, Model.quantize ctx ma mb)
    | _ => throw "unknown operation"
  let agrees := native.value.toModel == spec.value
  return s!"{native.value}|{native.flags}|{spec.value.toScientific}|{spec.flags}|{agrees}"

public def main : IO Unit := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  repeat
    let line ← input.getLine
    if line.isEmpty then break
    match evaluate line with
    | .ok result => output.putStrLn result
    | .error err => throw (IO.userError err)
