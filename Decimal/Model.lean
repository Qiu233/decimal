module

public import Decimal.Context

-- Downstream proofs may unfold the complete reference semantics.
@[expose] public section

namespace Decimal

inductive Kind where
  | finite | infinity | quietNaN | signalingNaN
  deriving Repr, BEq, ReflBEq, LawfulBEq, DecidableEq, Inhabited

/-- Logical representation. A finite value denotes the signed coefficient times
    `10^exponent`. Zero signs and trailing zeroes are significant in representation.
    A NaN's coefficient is its payload. -/
structure Model where
  kind : Kind := .finite
  negative : Bool := false
  coefficient : Nat := 0
  exponent : Int := 0
  deriving Repr, BEq, DecidableEq, Inhabited

namespace Model

def finite (negative : Bool) (coefficient : Nat) (exponent : Int) : Model :=
  ⟨.finite, negative, coefficient, exponent⟩
def infinity (negative : Bool) : Model := ⟨.infinity, negative, 0, 0⟩
def nan : Model := ⟨.quietNaN, false, 0, 0⟩
def invalid : Result Model := ⟨nan, Flags.invalidOperation⟩
def isFinite (a : Model) : Bool := a.kind == .finite
def isNaN (a : Model) : Bool := a.kind == .quietNaN || a.kind == .signalingNaN
def isZero (a : Model) : Bool := a.isFinite && a.coefficient == 0

/-- Decimal digit count, including one digit for zero. Arithmetic keeps this
    reducible in downstream proofs; `Nat.repr` has an unexposed definition. -/
def digits (n : Nat) : Nat := count (n + 1) n
where
  count : Nat → Nat → Nat
    | 0, _ => 0
    | fuel + 1, n => if n < 10 then 1 else count fuel (n / 10) + 1

def adjusted (a : Model) : Int := a.exponent + digits a.coefficient - 1
def copyNegate (a : Model) : Model := { a with negative := !a.negative }
def copyAbs (a : Model) : Model := { a with negative := false }

def ofParts (negative : Bool) (coefficient : Nat) (exponent : Int) : Result Model :=
  if digits coefficient > maxPrecision || exponent < minExponent || exponent > maxExponent ||
     (coefficient != 0 && exponent + digits coefficient - 1 > maxExponent) then invalid
  else ⟨finite negative coefficient exponent, 0⟩

def ofInt (n : Int) : Result Model := ofParts (n < 0) n.natAbs 0

/-- Exact rational interpretation, absent for infinities and NaNs. -/
def toRat? (a : Model) : Option Rat :=
  if a.isFinite then
    let c : Rat := Rat.ofInt (if a.negative then -(a.coefficient : Int) else a.coefficient)
    some (if a.exponent ≥ 0 then c * Rat.ofInt (10 ^ a.exponent.toNat)
          else c / Rat.ofInt (10 ^ (-a.exponent).toNat))
  else none

/-- Round a rational magnitude using integer quotient and remainder. -/
def roundQuotient (mode : Rounding) (negative : Bool) (n d : Nat) : Nat :=
  let q := n / d
  let r := n % d
  let increment := r != 0 && match mode with
    | .down => false
    | .up => true
    | .ceiling => !negative
    | .floor => negative
    | .halfUp => 2 * r ≥ d
    | .halfDown => 2 * r > d
    | .halfEven => 2 * r > d || (2 * r == d && q % 2 == 1)
    | .zeroFiveUp => q % 10 == 0 || q % 10 == 5
  q + if increment then 1 else 0

def overflowToInfinity (mode : Rounding) (negative : Bool) : Bool :=
  match mode with
  | .down | .zeroFiveUp => false
  | .ceiling => !negative
  | .floor => negative
  | _ => true

/-- Finish a single rounding, including exponent limits, without double rounding. -/
def finishRounded (ctx : Context) (negative : Bool) (coefficient : Nat)
    (exponent : Int) (flags : Flags) (tiny : Bool) : Result Model := Id.run do
  let mut c := coefficient
  let mut e := exponent
  let mut f := flags
  if digits c > ctx.precision then
    c := c / 10
    e := e + 1
  if c != 0 && e + digits c - 1 > ctx.emax then
    let v := if overflowToInfinity ctx.rounding negative then infinity negative
      else finite negative (10 ^ ctx.precision - 1) ctx.etop
    return ⟨v, Flags.overflow ||| Flags.inexact ||| Flags.rounded⟩
  if tiny then
    f := f ||| Flags.subnormal
    if Flags.contains f Flags.inexact then f := f ||| Flags.underflow
    if c == 0 then f := f ||| Flags.clamped
  if e > ctx.maxQuantum then
    c := c * 10 ^ (e - ctx.maxQuantum).toNat
    e := ctx.maxQuantum
    f := f ||| Flags.clamped
  return ⟨finite negative c e, f⟩

def finish (ctx : Context) (negative : Bool) (coefficient : Nat)
    (exponent : Int) : Result Model :=
  if coefficient == 0 then
    let e := max ctx.etiny (min ctx.maxQuantum exponent)
    ⟨finite negative 0 e, if e == exponent then 0 else Flags.clamped⟩
  else
    let shift := max (digits coefficient - ctx.precision) (ctx.etiny - exponent).toNat
    let divisor := 10 ^ shift
    let f := (if shift > 0 then Flags.rounded else 0) |||
      (if coefficient % divisor != 0 then Flags.inexact else 0)
    finishRounded ctx negative (roundQuotient ctx.rounding negative coefficient divisor)
      (exponent + shift) f (exponent + digits coefficient - 1 < ctx.emin)

def quietNaN (ctx : Context) (a : Model) : Result Model :=
  let p := ctx.precision - if ctx.clamp then 1 else 0
  ⟨⟨.quietNaN, a.negative, a.coefficient % 10 ^ p, 0⟩,
   if a.kind == .signalingNaN then Flags.invalidOperation else 0⟩

def propagateNaN (ctx : Context) (a b : Model) : Option (Result Model) :=
  if a.kind == .signalingNaN then some (quietNaN ctx a)
  else if b.kind == .signalingNaN then some (quietNaN ctx b)
  else if a.isNaN then some (quietNaN ctx a)
  else if b.isNaN then some (quietNaN ctx b)
  else none

def apply (ctx : Context) (a : Model) : Result Model :=
  if !ctx.isValid then invalid
  else if a.isNaN then quietNaN ctx a
  else if a.kind == .infinity then ⟨a, 0⟩
  else finish ctx (a.negative && (!a.isZero || ctx.rounding == .floor)) a.coefficient a.exponent

def addFinite (ctx : Context) (a b : Model) : Result Model :=
  let e := min a.exponent b.exponent
  let ca : Int := a.coefficient * 10 ^ (a.exponent - e).toNat
  let cb : Int := b.coefficient * 10 ^ (b.exponent - e).toNat
  let sum := (if a.negative then -ca else ca) + (if b.negative then -cb else cb)
  let sign := if sum == 0 then
      if a.negative == b.negative then a.negative else ctx.rounding == .floor
    else sum < 0
  finish ctx sign sum.natAbs e

def add (ctx : Context) (a b : Model) : Result Model :=
  if !ctx.isValid then invalid
  else if let some r := propagateNaN ctx a b then r
  else if a.kind == .infinity then
    if b.kind == .infinity && a.negative != b.negative then invalid else ⟨a, 0⟩
  else if b.kind == .infinity then ⟨b, 0⟩
  else addFinite ctx a b

def sub (ctx : Context) (a b : Model) : Result Model :=
  if !ctx.isValid then invalid
  else if let some r := propagateNaN ctx a b then r
  else add ctx a b.copyNegate

def mul (ctx : Context) (a b : Model) : Result Model :=
  if !ctx.isValid then invalid
  else if let some r := propagateNaN ctx a b then r
  else
    let sign := a.negative != b.negative
    if a.kind == .infinity || b.kind == .infinity then
      if a.isZero || b.isZero then invalid else ⟨infinity sign, 0⟩
    else finish ctx sign (a.coefficient * b.coefficient) (a.exponent + b.exponent)

/-- Remove trailing zeroes up to the preferred exponent of exact division. -/
def stripZeroes : Nat → Nat → Int → Int → Nat × Int
  | 0, c, e, _ => (c, e)
  | fuel + 1, c, e, limit =>
    if c != 0 && c % 10 == 0 && e < limit then stripZeroes fuel (c / 10) (e + 1) limit
    else (c, e)

def divFinite (ctx : Context) (a b : Model) : Result Model :=
  let sign := a.negative != b.negative
  let preferred := a.exponent - b.exponent
  if a.coefficient == 0 then finish ctx sign 0 preferred
  else
    let k : Int := (digits a.coefficient : Int) - digits b.coefficient
    let below := if k ≥ 0 then a.coefficient < b.coefficient * 10 ^ k.toNat
      else a.coefficient * 10 ^ (-k).toNat < b.coefficient
    let k := if below then k - 1 else k
    let e := max ctx.etiny (preferred + k - ctx.precision + 1)
    let scale := preferred - e
    let n := a.coefficient * 10 ^ scale.toNat
    let d := b.coefficient * 10 ^ (-scale).toNat
    let rem := n % d
    let q := roundQuotient ctx.rounding sign n d
    let (q, e') := if rem == 0 then stripZeroes (digits q) q e preferred else (q, e)
    let flags := (if rem != 0 then Flags.inexact ||| Flags.rounded
                  else if e > preferred then Flags.rounded else 0)
    finishRounded ctx sign q e' flags (preferred + k < ctx.emin)

def div (ctx : Context) (a b : Model) : Result Model :=
  if !ctx.isValid then invalid
  else if let some r := propagateNaN ctx a b then r
  else
    let sign := a.negative != b.negative
    if a.kind == .infinity then
      if b.kind == .infinity then invalid else ⟨infinity sign, 0⟩
    else if b.kind == .infinity then ⟨finite sign 0 ctx.etiny, Flags.clamped⟩
    else if b.isZero then
      if a.isZero then invalid else ⟨infinity sign, Flags.divisionByZero⟩
    else divFinite ctx a b

/-- Quantize to the second operand's exponent. Never signals Underflow. -/
def quantize (ctx : Context) (a b : Model) : Result Model :=
  if !ctx.isValid then invalid
  else if let some r := propagateNaN ctx a b then r
  else if a.kind == .infinity || b.kind == .infinity then
    if a.kind == .infinity && b.kind == .infinity then ⟨a, 0⟩ else invalid
  else if b.exponent < ctx.etiny || b.exponent > ctx.emax then invalid
  else if a.isZero then finish ctx a.negative 0 b.exponent
  else
    let shift := a.exponent - b.exponent
    if (digits a.coefficient : Int) + shift > ctx.precision then invalid
    else
      let divisor := 10 ^ (-shift).toNat
      let c := roundQuotient ctx.rounding a.negative (a.coefficient * 10 ^ shift.toNat) divisor
      if digits c > ctx.precision || b.exponent + digits c - 1 > ctx.emax then invalid
      else
        let r := finish ctx a.negative c b.exponent
        ⟨r.value, r.flags ||| (if shift < 0 then Flags.rounded else 0) |||
          (if a.coefficient % divisor != 0 then Flags.inexact else 0)⟩

def numericEq (a b : Model) : Bool :=
  if a.isNaN || b.isNaN then false
  else if a.kind == .infinity || b.kind == .infinity then
    a.kind == b.kind && a.negative == b.negative
  else if a.isZero && b.isZero then true
  else if a.negative != b.negative then false
  else
    let e := min a.exponent b.exponent
    a.coefficient * 10 ^ (a.exponent - e).toNat == b.coefficient * 10 ^ (b.exponent - e).toNat

def toScientific (a : Model) : String :=
  let sign := if a.negative then "-" else ""
  sign ++ match a.kind with
  | .infinity => "Infinity"
  | .quietNaN | .signalingNaN =>
    (if a.kind == .quietNaN then "NaN" else "sNaN") ++
      (if a.coefficient == 0 then "" else toString a.coefficient)
  | .finite =>
    let ds := (toString a.coefficient).toList
    let adj := a.adjusted
    if a.exponent ≤ 0 && adj ≥ -6 then
      let point := (ds.length : Int) + a.exponent
      if point > 0 then
        String.ofList (ds.take point.toNat) ++
          (if a.exponent == 0 then "" else "." ++ String.ofList (ds.drop point.toNat))
      else "0." ++ String.ofList (List.replicate (-point).toNat '0' ++ ds)
    else
      String.ofList (ds.take 1) ++
        (if ds.length > 1 then "." ++ String.ofList (ds.drop 1) else "") ++
        "E" ++ (if adj ≥ 0 then "+" else "") ++ toString adj

def asciiSpace (c : Char) : Bool := c == ' ' || c == '\t' || c == '\n' ||
  c == '\r' || c.toNat == 11 || c.toNat == 12

/-- Exact ASCII Python-style conversion: outer whitespace, underscores,
    case-insensitive specials and signed exponents. Unicode digits are excluded. -/
def parse (text : String) : Result Model := Id.run do
  if text.toList.any (fun c => c.toNat > 127 || c.toNat == 0) then return invalid
  let cs := text.toList.dropWhile asciiSpace
  let cs := (cs.reverse.dropWhile asciiSpace).reverse.filter (· != '_')
  let negative := cs.head? == some '-'
  let cs := if negative || cs.head? == some '+' then cs.drop 1 else cs
  let s := (String.ofList cs).toLower
  if s == "inf" || s == "infinity" then return ⟨infinity negative, 0⟩
  if s.startsWith "nan" || s.startsWith "snan" then
    let signaling := s.startsWith "snan"
    let payload := s.toList.drop (if signaling then 4 else 3)
    if !payload.all Char.isDigit then return invalid
    let c := (String.ofList payload).toNat?.getD 0
    if digits c > maxPrecision then return invalid
    return ⟨⟨if signaling then .signalingNaN else .quietNaN, negative, c, 0⟩, 0⟩
  let pieces := s.splitOn "e"
  let (mantissa, exponent) ← match pieces with
    | [m] => pure (m, (0 : Int))
    | [m, e] =>
      let es := e.toList
      let neg := es.head? == some '-'
      let es := if neg || es.head? == some '+' then es.drop 1 else es
      match (String.ofList es).toNat? with
      | some n => pure (m, if neg then -(n : Int) else n)
      | none => return invalid
    | _ => return invalid
  let (allDigits, fractional) ← match mantissa.splitOn "." with
    | [whole] => pure (whole, 0)
    | [whole, frac] => pure (whole ++ frac, frac.length)
    | _ => return invalid
  match allDigits.toNat? with
  | none => return invalid
  | some c => return ofParts negative c (exponent - fractional)

end Model
end Decimal
