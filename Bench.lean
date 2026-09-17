module

import Decimal

open Decimal

private def nativeLoop (ctx : Context) (a b : Decimal) (n : Nat) : Decimal := Id.run do
  let mut acc := a
  for _ in [:n] do acc := (Decimal.mul ctx acc b).value
  return acc

private def modelLoop (ctx : Context) (a b : Model) (n : Nat) : Model := Id.run do
  let mut acc := a
  for _ in [:n] do acc := (Model.mul ctx acc b).value
  return acc

public def main (args : List String) : IO Unit := do
  let n := (args.head?.bind String.toNat?).getD 20000
  let p := (args[1]?.bind String.toNat?).getD 100
  let ctx : Context := { precision := p }
  let a := (Decimal.parse ("1." ++ String.ofList (List.replicate p '2'))).value
  let b := (Decimal.parse "1.0000001").value
  let ma := a.toModel
  let mb := b.toModel
  let nativeSink ← IO.mkRef a
  let modelSink ← IO.mkRef ma
  let start ← IO.monoMsNow
  nativeSink.set (nativeLoop ctx a b n)
  IO.println s!"libmpdec: {n} multiplications at precision {p}: {(← IO.monoMsNow) - start} ms"
  let start ← IO.monoMsNow
  modelSink.set (modelLoop ctx ma mb n)
  IO.println s!"Lean model: {n} multiplications at precision {p}: {(← IO.monoMsNow) - start} ms"
  let result ← nativeSink.get
  let expected ← modelSink.get
  unless result.toModel == expected do throw (IO.userError "benchmark results differ")
  IO.println s!"Result: {result}"
