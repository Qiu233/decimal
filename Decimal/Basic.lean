module

public import Decimal.Model

public section

/-- An immutable decimal. The kernel sees a `Model`; compiled code owns an
    external libmpdec object. All executable access goes through the FFI API.
    The private constructor prevents accidentally constructing a Lean object
    where the native API expects an external object. Definitions that access
    this representation stay unexposed; the specification theorems below
    export their logical behavior without exporting the constructor. -/
structure Decimal where
  private mk ::
  private model : Decimal.Model

namespace Decimal

/-- Materialize the logical representation. Linear in the coefficient size;
    arithmetic does not perform this conversion. -/
@[extern "lean_decimal_to_model"]
def toModel (a : @& Decimal) : Model := a.model

/-- Exact, context-independent construction, preserving the exponent and zero sign. -/
@[extern "lean_decimal_of_parts"]
def ofParts (negative : Bool) (coefficient : @& Nat) (exponent : @& Int) : Result Decimal :=
  (Model.ofParts negative coefficient exponent).map mk

@[extern "lean_decimal_of_int"]
def ofInt (n : @& Int) : Result Decimal := (Model.ofInt n).map mk

/-- Exact ASCII conversion; malformed or unrepresentable input signals InvalidOperation. -/
@[extern "lean_decimal_parse"]
def parse (text : @& String) : Result Decimal := (Model.parse text).map mk

@[expose] def fromString (text : String) : Except Flags Decimal := (parse text).check {}

@[expose, extern "lean_decimal_to_string"]
def toScientific (a : @& Decimal) : String := a.toModel.toScientific

@[extern "lean_decimal_copy_negate"]
def copyNegate (a : @& Decimal) : Decimal := mk a.toModel.copyNegate

@[extern "lean_decimal_copy_abs"]
def copyAbs (a : @& Decimal) : Decimal := mk a.toModel.copyAbs

@[expose, extern "lean_decimal_is_finite"]
def isFinite (a : @& Decimal) : Bool := a.toModel.isFinite

@[expose, extern "lean_decimal_is_nan"]
def isNaN (a : @& Decimal) : Bool := a.toModel.isNaN

@[expose, extern "lean_decimal_is_zero"]
def isZero (a : @& Decimal) : Bool := a.toModel.isZero

@[expose, extern "lean_decimal_is_signed"]
def isSigned (a : @& Decimal) : Bool := a.toModel.negative

/-- Quiet numerical equality. All NaNs compare false, including to themselves. -/
@[expose, extern "lean_decimal_numeric_eq"]
def numericEq (a b : @& Decimal) : Bool := Model.numericEq a.toModel b.toModel

/-- Representation equality distinguishes quantum, signed zero, and NaN payloads. -/
@[expose, extern "lean_decimal_same_representation"]
def sameRepresentation (a b : @& Decimal) : Bool := a.toModel == b.toModel

/-- Unary plus: round to context, with Python's handling of zero signs. -/
@[extern "lean_decimal_apply"]
def apply (ctx : @& Context) (a : @& Decimal) : Result Decimal :=
  (Model.apply ctx a.toModel).map mk

@[extern "lean_decimal_add"]
def add (ctx : @& Context) (a b : @& Decimal) : Result Decimal :=
  (Model.add ctx a.toModel b.toModel).map mk

@[extern "lean_decimal_sub"]
def sub (ctx : @& Context) (a b : @& Decimal) : Result Decimal :=
  (Model.sub ctx a.toModel b.toModel).map mk

@[extern "lean_decimal_mul"]
def mul (ctx : @& Context) (a b : @& Decimal) : Result Decimal :=
  (Model.mul ctx a.toModel b.toModel).map mk

@[extern "lean_decimal_div"]
def div (ctx : @& Context) (a b : @& Decimal) : Result Decimal :=
  (Model.div ctx a.toModel b.toModel).map mk

@[extern "lean_decimal_quantize"]
def quantize (ctx : @& Context) (a quantum : @& Decimal) : Result Decimal :=
  (Model.quantize ctx a.toModel quantum.toModel).map mk

instance : Inhabited Decimal := ⟨(ofInt 0).value⟩
instance : ToString Decimal := ⟨toScientific⟩
instance : Repr Decimal := ⟨fun a _ => repr a.toScientific⟩
instance : BEq Decimal := ⟨numericEq⟩

/-- Rational interpretation is intended for specifications, not hot arithmetic paths. -/
@[expose] def toRat? (a : Decimal) : Option Rat := a.toModel.toRat?

@[ext] theorem ext {a b : Decimal} (h : a.toModel = b.toModel) : a = b := by
  cases a
  cases b
  cases h
  rfl

theorem toModel_injective : Function.Injective toModel := fun _ _ => ext

/-- These are kernel-level specification theorems, not proofs about the C code.
    Use `by rfl` rather than `:= rfl`: the equations cross the private
    representation boundary and must not receive the inferred `defeq` attribute. -/
@[simp] theorem parse_spec (text : String) :
    (parse text).map toModel = Model.parse text := by rfl

@[simp] theorem ofParts_spec (s : Bool) (c : Nat) (e : Int) :
    (ofParts s c e).map toModel = Model.ofParts s c e := by rfl

@[simp] theorem ofInt_spec (n : Int) :
    (ofInt n).map toModel = Model.ofInt n := by rfl

@[simp] theorem apply_spec (ctx : Context) (a : Decimal) :
    (apply ctx a).map toModel = Model.apply ctx a.toModel := by rfl

@[simp] theorem add_spec (ctx : Context) (a b : Decimal) :
    (add ctx a b).map toModel = Model.add ctx a.toModel b.toModel := by rfl

@[simp] theorem sub_spec (ctx : Context) (a b : Decimal) :
    (sub ctx a b).map toModel = Model.sub ctx a.toModel b.toModel := by rfl

@[simp] theorem mul_spec (ctx : Context) (a b : Decimal) :
    (mul ctx a b).map toModel = Model.mul ctx a.toModel b.toModel := by rfl

@[simp] theorem div_spec (ctx : Context) (a b : Decimal) :
    (div ctx a b).map toModel = Model.div ctx a.toModel b.toModel := by rfl

@[simp] theorem quantize_spec (ctx : Context) (a b : Decimal) :
    (quantize ctx a b).map toModel = Model.quantize ctx a.toModel b.toModel := by rfl

@[simp] theorem copyNegate_toModel (a : Decimal) :
    a.copyNegate.toModel = a.toModel.copyNegate := by rfl

@[simp] theorem copyAbs_toModel (a : Decimal) :
    a.copyAbs.toModel = a.toModel.copyAbs := by rfl

@[simp] theorem copyNegate_copyNegate (a : Decimal) : a.copyNegate.copyNegate = a := by
  apply ext
  simp [Model.copyNegate]

@[simp] theorem copyAbs_copyAbs (a : Decimal) : a.copyAbs.copyAbs = a.copyAbs := by
  apply ext
  simp [Model.copyAbs]

end Decimal
