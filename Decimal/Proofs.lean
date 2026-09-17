module

public import Decimal.Basic

public section

namespace Decimal.Model

private theorem digits_count_eq (fuel n : Nat) (h : n < fuel) :
    digits.count fuel n = (Nat.toDigits 10 n).length := by
  induction fuel generalizing n with
  | zero => omega
  | succ fuel ih =>
    rw [digits.count, Nat.toDigits_eq_ite (by decide : 1 < 10)]
    split
    · rfl
    · rename_i hge
      simp only [List.length_append, List.length_singleton]
      rw [ih (n / 10) (by
        have := Nat.div_lt_self (by omega : 0 < n) (by decide : 1 < 10)
        omega)]

/-- The arithmetic digit count agrees with the original string-based definition. -/
theorem digits_eq_length_repr (n : Nat) : digits n = n.repr.length := by
  rw [digits, digits_count_eq (n + 1) n (by omega), Nat.repr_eq_ofList_toDigits]
  simp

/-- Exact division of the coefficient never increments it, in any rounding mode. -/
theorem roundQuotient_exact (mode : Rounding) (s : Bool) (n d : Nat)
    (h : n % d = 0) : roundQuotient mode s n d = n / d := by
  simp [roundQuotient, h]

/-- All rounding modes choose one of the two adjacent integer magnitudes. -/
theorem roundQuotient_bounds (mode : Rounding) (s : Bool) (n d : Nat) :
    n / d ≤ roundQuotient mode s n d ∧ roundQuotient mode s n d ≤ n / d + 1 := by
  cases mode <;> dsimp only [roundQuotient] <;> split <;> omega

theorem roundQuotient_down (s : Bool) (n d : Nat) :
    roundQuotient .down s n d = n / d := by
  simp [roundQuotient]

/-- Within the precision and normal exponent range, finishing is exact and quiet. -/
theorem finish_exact (ctx : Context) (s : Bool) (c : Nat) (e : Int)
    (hc : c ≠ 0) (hp : digits c ≤ ctx.precision)
    (hlo : ctx.etiny ≤ e) (hn : ctx.emin ≤ e + digits c - 1)
    (hhi : e + digits c - 1 ≤ ctx.emax) (hq : e ≤ ctx.maxQuantum) :
    finish ctx s c e = ⟨finite s c e, 0⟩ := by
  have ht : (ctx.etiny - e).toNat = 0 := by omega
  have hp' : ¬ctx.precision < digits c := by omega
  have hn' : ¬e + digits c - 1 < ctx.emin := by omega
  have hhi' : ¬ctx.emax < e + digits c - 1 := by omega
  have hq' : ¬ctx.maxQuantum < e := by omega
  simp [finish, hc, Nat.sub_eq_zero_of_le hp, ht, roundQuotient,
    Nat.mod_one, finishRounded, hp', hn', hhi', hq']

/-- Finite multiplication is commutative, including result representation and flags.
    NaN propagation is intentionally excluded: payload selection is order-sensitive. -/
theorem mul_finite_comm (ctx : Context) (sa sb : Bool) (ca cb : Nat) (ea eb : Int) :
    mul ctx (finite sa ca ea) (finite sb cb eb) =
    mul ctx (finite sb cb eb) (finite sa ca ea) := by
  cases sa <;> cases sb <;>
    simp [mul, finite, propagateNaN, isNaN, Nat.mul_comm, Int.add_comm]

end Decimal.Model

namespace Decimal

/-- Propositional equality reflects representation, not numerical equality. -/
theorem eq_iff_toModel_eq (a b : Decimal) : a = b ↔ a.toModel = b.toModel :=
  ⟨congrArg toModel, ext⟩

-- `decide` constructs kernel-checked proofs here; `native_decide` is not used.
-- Rewrite through public specifications before reducing the reference model.
private theorem modelValue (r : Result Decimal) :
    r.value.toModel = (r.map toModel).value := rfl

example : ((add {} (ofParts false 1 (-1)).value (ofParts false 2 (-1)).value).value).toModel =
    Model.finite false 3 (-1) := by
  simp only [modelValue, add_spec, ofParts_spec]
  decide +kernel

example : ((add {} (ofParts false 130 (-2)).value (ofParts false 120 (-2)).value).value).toModel =
    Model.finite false 250 (-2) := by
  simp only [modelValue, add_spec, ofParts_spec]
  decide +kernel

example : (quantize { precision := 3 } (ofParts false 2345 (-3)).value
    (ofParts false 1 (-2)).value).value.toModel = Model.finite false 234 (-2) := by
  simp only [modelValue, quantize_spec, ofParts_spec]
  decide +kernel

end Decimal
