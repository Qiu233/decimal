module

-- Contexts, signal bits, and result handling are part of the logical interface.
@[expose] public section

namespace Decimal

/-- The eight rounding modes supported by Python's `decimal`. -/
inductive Rounding where
  | halfEven | halfUp | halfDown | up | down | ceiling | floor | zeroFiveUp
  deriving Repr, BEq, DecidableEq, Inhabited

/-- Public signal bits, independent of libmpdec's ABI. Invalid-operation conditions
    (including invalid contexts and malformed input) are grouped together. -/
abbrev Flags := UInt32

namespace Flags
def invalidOperation : Flags := 1
def divisionByZero : Flags := 2
def overflow : Flags := 4
def underflow : Flags := 8
def subnormal : Flags := 16
def inexact : Flags := 32
def rounded : Flags := 64
def clamped : Flags := 128

def contains (flags signal : Flags) : Bool := flags &&& signal != 0

def names (flags : Flags) : List String :=
  [(invalidOperation, "InvalidOperation"), (divisionByZero, "DivisionByZero"),
   (overflow, "Overflow"), (underflow, "Underflow"), (subnormal, "Subnormal"),
   (inexact, "Inexact"), (rounded, "Rounded"), (clamped, "Clamped")].filterMap
    fun (bit, name) => if contains flags bit then some name else none
end Flags

/-- Bounds of supported 64-bit libmpdec builds. Precision is variable, not fixed
    at machine-word size; available memory is the practical limit. -/
def maxPrecision : Nat := 999999999999999999
def maxExponent : Int := 999999999999999999
def minExponent : Int := -1999999999999999997

/-- Immutable arithmetic context. Operations report flags; `Result.check` applies traps.
    No process-global or thread-local mutable context is used. -/
structure Context where
  precision : Nat := 28
  emax : Int := 999999
  emin : Int := -999999
  rounding : Rounding := .halfEven
  clamp : Bool := false
  traps : Flags := 7
  deriving Repr, BEq, Inhabited

namespace Context
def isValid (ctx : Context) : Bool :=
  0 < ctx.precision && ctx.precision ≤ maxPrecision &&
  0 ≤ ctx.emax && ctx.emax ≤ maxExponent &&
  -maxExponent ≤ ctx.emin && ctx.emin ≤ 0

def etiny (ctx : Context) : Int := ctx.emin - ctx.precision + 1
def etop (ctx : Context) : Int := ctx.emax - ctx.precision + 1
def maxQuantum (ctx : Context) : Int := if ctx.clamp then ctx.etop else ctx.emax
end Context

/-- A value and the signals raised by this operation (not cumulative flags). -/
structure Result (α : Type) where
  value : α
  flags : Flags := 0
  deriving Repr, BEq

namespace Result
def map (f : α → β) (r : Result α) : Result β := ⟨f r.value, r.flags⟩

/-- Apply the caller's traps. The error retains all signals raised by the operation. -/
def check (ctx : Context) (r : Result α) : Except Flags α :=
  if r.flags &&& ctx.traps == 0 then .ok r.value else .error r.flags

/-- Accumulate sticky flags even when a trap fires. -/
def record (ctx : Context) (previous : Flags) (r : Result α) : Except Flags α × Flags :=
  (r.check ctx, previous ||| r.flags)
end Result

end Decimal
