module

public import Decimal

/-! Public API checks. The integration test copies this file into a separate
    package, where it must work without access to Decimal's private scopes. -/

namespace Decimal.ModuleTests

public theorem context_exposed (ctx : Context) :
    ctx.etiny = ctx.emin - ctx.precision + 1 := rfl

public theorem traps_exposed (ctx : Context) (r : Result Nat) :
    r.check ctx = if r.flags &&& ctx.traps == 0 then .ok r.value else .error r.flags := rfl

public theorem classification_exposed (a : Decimal) :
    a.isFinite = a.toModel.isFinite := rfl

public theorem equality_instance_exposed (a b : Decimal) :
    (a == b) = numericEq a b := rfl

public theorem default_instance_exposed :
    (default : Decimal) = (ofInt 0).value := rfl

public theorem add_value_spec (ctx : Context) (a b : Decimal) :
    (add ctx a b).value.toModel = (Model.add ctx a.toModel b.toModel).value :=
  congrArg Result.value (add_spec ctx a b)

public theorem add_flags_spec (ctx : Context) (a b : Decimal) :
    (add ctx a b).flags = (Model.add ctx a.toModel b.toModel).flags :=
  congrArg Result.flags (add_spec ctx a b)

public theorem ext_attribute {a b : Decimal} (h : a.toModel = b.toModel) : a = b := by
  ext
  exact h

public theorem simp_attribute (a : Decimal) : a.copyNegate.copyNegate = a := by
  simp

public theorem rounding_bounds (mode : Rounding) (s : Bool) (n d : Nat) :
    n / d ≤ Model.roundQuotient mode s n d ∧ Model.roundQuotient mode s n d ≤ n / d + 1 :=
  Model.roundQuotient_bounds mode s n d

private theorem modelValue (r : Result Decimal) :
    r.value.toModel = (r.map toModel).value := rfl

private theorem result_ext {a b : Result Model}
    (hv : a.value = b.value) (hf : a.flags = b.flags) : a = b := by
  cases a
  cases b
  cases hv
  cases hf
  rfl

public theorem exact_tenths :
    (add {} (ofParts false 1 (-1)).value (ofParts false 2 (-1)).value).map toModel =
      ⟨Model.finite false 3 (-1), 0⟩ := by
  simp only [add_spec, modelValue, ofParts_spec]
  apply result_ext <;> decide +kernel

public theorem rounding_with_signals :
    (quantize { precision := 3 } (ofParts false 2345 (-3)).value
      (ofParts false 1 (-2)).value).map toModel =
      ⟨Model.finite false 234 (-2), Flags.inexact ||| Flags.rounded⟩ := by
  simp only [quantize_spec, modelValue, ofParts_spec]
  apply result_ext <;> decide +kernel

end Decimal.ModuleTests
