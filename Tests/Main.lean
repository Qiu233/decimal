module

import Decimal

open Decimal

private def check (ok : Bool) (message : String) : IO Unit :=
  unless ok do throw (IO.userError message)

private def checkResult (actual : Result Decimal) (expected : Result Model)
    (label : String) : IO Unit := do
  check (actual.value.toModel == expected.value && actual.flags == expected.flags)
    s!"{label}: got {actual.value} / {actual.flags}, expected {expected.value.toScientific} / {expected.flags}"

private def runTests : IO Unit := do
  for text in ["0", "-0.00", ".5", "5.", "123E+5", "1.234500", "1e-7",
      "-Infinity", "-sNaN123", "nan000", "  _+12_3.0_  ", "", ".", "1e+",
      "1\x00junk", "١٢", "１２", "1\n2", "\t-1.20\r\n"] do
    checkResult (Decimal.parse text) (Model.parse text) s!"parse {repr text}"
  for sign in [false, true] do
    for c in [0, 1, 100, 10^80 + 123456789] do
      for e in [-999999999999999999, -7, 0, 100, 999999999999999999,
          -1999999999999999997, -1999999999999999998, 2^100] do
        checkResult (Decimal.ofParts sign c e) (Model.ofParts sign c e) "ofParts"
  for n in [0, 1, -1, 2^200, -(2^200), 10^1000 + 7] do
    checkResult (Decimal.ofInt n) (Model.ofInt n) "ofInt"
  let a := (Decimal.parse "1.00").value
  let b := (Decimal.parse "1").value
  let z := (Decimal.parse "-0.00").value
  let n := (Decimal.parse "-sNaN12").value
  check (a == b) "numeric equality must ignore trailing zeroes"
  check (!a.sameRepresentation b) "representation must retain trailing zeroes"
  check (z == (Decimal.parse "0").value) "signed zero equality"
  check (z.isFinite && z.isZero && z.isSigned && !z.isNaN) "zero classification"
  check (n.isNaN && n.isSigned && !n.isFinite && !n.isZero && !(n == n)) "NaN classification"
  check (a.copyNegate.copyNegate.sameRepresentation a) "negation round trip"
  check (n.copyAbs.toScientific == "sNaN12") "copyAbs must not signal or quiet sNaN"
  let saved := a.toScientific
  let _ := Decimal.add {} a b
  check (a.toScientific == saved) "borrowed operands must be immutable"
  let badContexts : List Context := [{ precision := 0 }, { precision := 2^130 },
    { emax := -1 }, { emin := 1 }, { emax := 2^100 }, { emin := -(2^100) }]
  for ctx in badContexts do
    for op in [Decimal.add, Decimal.sub, Decimal.mul, Decimal.div, Decimal.quantize] do
      checkResult (op ctx a b) Model.invalid "invalid context"
    checkResult (Decimal.apply ctx a) Model.invalid "invalid unary context"
  let third := Decimal.div {} b (Decimal.ofInt 3).value
  check (third.flags == Flags.inexact ||| Flags.rounded) "inexact division flags"
  let (trapped, sticky) := third.record { traps := Flags.inexact } Flags.clamped
  check (trapped matches .error _) "trap must return Except.error"
  check (sticky == Flags.inexact ||| Flags.rounded ||| Flags.clamped) "sticky flags survive traps"
  let zeroDivision := Decimal.div {} b z
  check (zeroDivision.check {} matches .error _) "default division-by-zero trap"
  -- Huge exponent gaps exercise the native algorithm without expanding 10^gap in Lean.
  let huge := (Decimal.parse "1e999999").value
  let tiny := (Decimal.parse "1e-999999").value
  check ((Decimal.add {} huge tiny).flags == Flags.inexact ||| Flags.rounded) "large exponent gap"
  -- Concurrent reads of the same native objects, with independent contexts and results.
  let tasks ← (List.range 8).mapM fun i => IO.asTask do
    let ctx : Context := { precision := i + 1 }
    let mut acc := a
    for _ in [:2000] do acc := (Decimal.add ctx acc b).value
    check (a.toScientific == "1.00" && b.toScientific == "1") "concurrent operand mutation"
    checkResult (Decimal.div ctx a b) (Model.div ctx a.toModel b.toModel) "concurrent result"
  for task in tasks do
    match ← IO.wait task with
    | .ok _ => pure ()
    | .error e => throw e
  IO.println "Native API, construction, contexts, traps, aliasing and concurrency tests passed."

public def main : IO Unit := runTests
