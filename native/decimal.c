#include <lean/lean.h>
#include <mpdecimal.h>
#include <stdatomic.h>
#include <string.h>

#if !defined(MPD_CONFIG_64) || MPD_VERSION_HEX < 0x02050000
#error "decimal requires 64-bit libmpdec >= 2.5.0"
#endif

/* All Decimal arguments are borrowed. Every result owns a fresh, immutable
   mpd_t. No operand is mutated and no global libmpdec settings are changed. */
static _Atomic(lean_external_class *) decimal_class = NULL;
static atomic_flag class_lock = ATOMIC_FLAG_INIT;

static void finalize(void *p) { mpd_del((mpd_t *)p); }
static void foreach(void *p, b_lean_obj_arg f) { (void)p; (void)f; }

static lean_external_class *get_class(void) {
    lean_external_class *c = atomic_load_explicit(&decimal_class, memory_order_acquire);
    if (c != NULL) return c;
    while (atomic_flag_test_and_set_explicit(&class_lock, memory_order_acquire)) { }
    c = atomic_load_explicit(&decimal_class, memory_order_relaxed);
    if (c == NULL) {
        c = lean_register_external_class(finalize, foreach);
        atomic_store_explicit(&decimal_class, c, memory_order_release);
    }
    atomic_flag_clear_explicit(&class_lock, memory_order_release);
    return c;
}

static const mpd_t *decimal(b_lean_obj_arg a) {
    return (const mpd_t *)lean_get_external_data(a);
}

static mpd_t *new_decimal(void) {
    mpd_t *a = mpd_qnew();
    if (a == NULL) lean_internal_panic_out_of_memory();
    return a;
}

static lean_obj_res wrap(mpd_t *a) { return lean_alloc_external(get_class(), a); }

static void check_memory(uint32_t status) {
    if (status & MPD_Malloc_error) lean_internal_panic_out_of_memory();
}

static uint32_t signals(uint32_t s) {
    check_memory(s);
    return ((s & MPD_IEEE_Invalid_operation) ? 1u : 0u) |
           ((s & MPD_Division_by_zero) ? 2u : 0u) |
           ((s & MPD_Overflow) ? 4u : 0u) |
           ((s & MPD_Underflow) ? 8u : 0u) |
           ((s & MPD_Subnormal) ? 16u : 0u) |
           ((s & MPD_Inexact) ? 32u : 0u) |
           ((s & MPD_Rounded) ? 64u : 0u) |
           ((s & MPD_Clamped) ? 128u : 0u);
}

/* Result has one object field followed by UInt32. Model has two object fields
   (coefficient, exponent), then Kind and Bool. Context has three object fields
   (precision, emax, emin), then UInt32 traps, Rounding, Bool clamp.
   These layouts are covered by native/model differential tests. */
static lean_obj_res result(mpd_t *a, uint32_t status) {
    uint32_t flags = signals(status);
    lean_object *r = lean_alloc_ctor(0, 1, sizeof(uint32_t));
    lean_ctor_set(r, 0, wrap(a));
    lean_ctor_set_uint32(r, sizeof(void *), flags);
    return r;
}

static lean_obj_res invalid(void) {
    mpd_t *a = new_decimal();
    mpd_setspecial(a, MPD_POS, MPD_NAN);
    return result(a, MPD_Invalid_operation);
}

static int context(mpd_context_t *ctx, b_lean_obj_arg obj) {
    lean_object *p = lean_ctor_get(obj, 0);
    lean_object *emax = lean_ctor_get(obj, 1);
    lean_object *emin = lean_ctor_get(obj, 2);
    /* Check arbitrary-size Lean integers before converting them to C integers. */
    if (!lean_nat_lt(lean_box(0), p) ||
        !lean_nat_le(p, lean_uint64_to_nat(MPD_MAX_PREC)) ||
        !lean_int_le(lean_int_to_int(0), emax) ||
        !lean_int_le(emax, lean_int64_to_int(MPD_MAX_EMAX)) ||
        !lean_int_le(lean_int64_to_int(MPD_MIN_EMIN), emin) ||
        !lean_int_le(emin, lean_int_to_int(0))) return 0;
    static const int rounding[] = {
        MPD_ROUND_HALF_EVEN, MPD_ROUND_HALF_UP, MPD_ROUND_HALF_DOWN,
        MPD_ROUND_UP, MPD_ROUND_DOWN, MPD_ROUND_CEILING, MPD_ROUND_FLOOR,
        MPD_ROUND_05UP
    };
    mpd_maxcontext(ctx);
    ctx->prec = (mpd_ssize_t)lean_uint64_of_nat(p);
    ctx->emax = (int64_t)lean_int64_of_int(emax);
    ctx->emin = (int64_t)lean_int64_of_int(emin);
    ctx->round = rounding[lean_ctor_get_uint8(obj, 3 * sizeof(void *) + 4)];
    ctx->clamp = lean_ctor_get_uint8(obj, 3 * sizeof(void *) + 5);
    ctx->traps = 0;
    return 1;
}

/* Core Lean conversion symbols (the Lean ABI is pinned by lean-toolchain).
   Use core symbols so this library has no load-time dependency on Decimal.Basic.
   Nat.reprFast consumes its argument; Int.repr borrows it. */
extern lean_obj_res l_Nat_reprFast(lean_obj_arg);
extern lean_obj_res l_Int_repr(b_lean_obj_arg);

LEAN_EXPORT lean_obj_res lean_decimal_of_parts(uint8_t negative,
        b_lean_obj_arg coefficient, b_lean_obj_arg exponent) {
    if (lean_int_lt(exponent, lean_int64_to_int(MPD_MIN_ETINY)) ||
        lean_int_lt(lean_int64_to_int(MPD_MAX_EMAX), exponent)) return invalid();
    lean_inc(coefficient);
    lean_object *cs = l_Nat_reprFast(coefficient);
    lean_object *es = l_Int_repr(exponent);
    size_t cn = lean_string_size(cs) - 1, en = lean_string_size(es) - 1;
    if (cn > SIZE_MAX - en - 3) lean_internal_panic_out_of_memory();
    char *text = malloc(cn + en + 3);
    if (text == NULL) lean_internal_panic_out_of_memory();
    char *p = text;
    if (negative) *p++ = '-';
    memcpy(p, lean_string_cstr(cs), cn); p += cn;
    *p++ = 'E';
    memcpy(p, lean_string_cstr(es), en + 1);
    mpd_t *a = new_decimal();
    uint32_t status = 0;
    mpd_qset_string_exact(a, text, &status);
    free(text);
    lean_dec(cs);
    lean_dec(es);
    return result(a, status);
}

LEAN_EXPORT lean_obj_res lean_decimal_of_int(b_lean_obj_arg n) {
    lean_object *s = l_Int_repr(n);
    mpd_t *a = new_decimal();
    uint32_t status = 0;
    mpd_qset_string_exact(a, lean_string_cstr(s), &status);
    lean_dec(s);
    return result(a, status);
}

static int ascii_space(unsigned char c) {
    return c == ' ' || (c >= 9 && c <= 13);
}

LEAN_EXPORT lean_obj_res lean_decimal_parse(b_lean_obj_arg input) {
    const unsigned char *s = (const unsigned char *)lean_string_cstr(input);
    size_t start = 0, end = lean_string_size(input) - 1;
    while (start < end && ascii_space(s[start])) start++;
    while (end > start && ascii_space(s[end - 1])) end--;
    char *text = malloc(end - start + 1);
    if (text == NULL) lean_internal_panic_out_of_memory();
    size_t n = 0;
    for (size_t i = start; i < end; i++) {
        if (s[i] == 0 || s[i] > 127) { free(text); return invalid(); }
        if (s[i] != '_') text[n++] = (char)s[i];
    }
    text[n] = 0;
    mpd_t *a = new_decimal();
    uint32_t status = 0;
    mpd_qset_string_exact(a, text, &status);
    free(text);
    return result(a, status);
}

LEAN_EXPORT lean_obj_res lean_decimal_to_string(b_lean_obj_arg a) {
    char *s = mpd_to_sci(decimal(a), 1);
    if (s == NULL) lean_internal_panic_out_of_memory();
    lean_object *r = lean_mk_string(s);
    mpd_free(s);
    return r;
}

LEAN_EXPORT lean_obj_res lean_decimal_to_model(b_lean_obj_arg obj) {
    const mpd_t *a = decimal(obj);
    uint8_t kind = mpd_isfinite(a) ? 0 : mpd_isinfinite(a) ? 1 : mpd_issnan(a) ? 3 : 2;
    lean_object *coefficient = lean_box(0);
    if (!mpd_isinfinite(a) && a->len > 0) {
        /* Read-only view, with no exponent or sign, to export the coefficient. */
        mpd_t view = *a;
        view.flags = MPD_STATIC | MPD_STATIC_DATA;
        view.exp = 0;
        char *s = mpd_to_sci(&view, 1);
        if (s == NULL) lean_internal_panic_out_of_memory();
        coefficient = lean_cstr_to_nat(s);
        mpd_free(s);
    }
    lean_object *r = lean_alloc_ctor(0, 2, 2);
    lean_ctor_set(r, 0, coefficient);
    lean_ctor_set(r, 1, lean_int64_to_int(mpd_isfinite(a) ? a->exp : 0));
    lean_ctor_set_uint8(r, 2 * sizeof(void *), kind);
    lean_ctor_set_uint8(r, 2 * sizeof(void *) + 1, mpd_isnegative(a) != 0);
    return r;
}

LEAN_EXPORT uint8_t lean_decimal_is_finite(b_lean_obj_arg a) { return mpd_isfinite(decimal(a)) != 0; }
LEAN_EXPORT uint8_t lean_decimal_is_nan(b_lean_obj_arg a) { return mpd_isnan(decimal(a)) != 0; }
LEAN_EXPORT uint8_t lean_decimal_is_zero(b_lean_obj_arg a) { return mpd_iszero(decimal(a)) != 0; }
LEAN_EXPORT uint8_t lean_decimal_is_signed(b_lean_obj_arg a) { return mpd_isnegative(decimal(a)) != 0; }

LEAN_EXPORT uint8_t lean_decimal_numeric_eq(b_lean_obj_arg a, b_lean_obj_arg b) {
    if (mpd_isnan(decimal(a)) || mpd_isnan(decimal(b))) return 0;
    uint32_t status = 0;
    return mpd_qcmp(decimal(a), decimal(b), &status) == 0;
}

LEAN_EXPORT uint8_t lean_decimal_same_representation(b_lean_obj_arg a, b_lean_obj_arg b) {
    return mpd_cmp_total(decimal(a), decimal(b)) == 0;
}

LEAN_EXPORT lean_obj_res lean_decimal_copy_negate(b_lean_obj_arg a) {
    mpd_t *r = new_decimal();
    uint32_t status = 0;
    mpd_qcopy_negate(r, decimal(a), &status);
    check_memory(status);
    return wrap(r);
}

LEAN_EXPORT lean_obj_res lean_decimal_copy_abs(b_lean_obj_arg a) {
    mpd_t *r = new_decimal();
    uint32_t status = 0;
    mpd_qcopy_abs(r, decimal(a), &status);
    check_memory(status);
    return wrap(r);
}

LEAN_EXPORT lean_obj_res lean_decimal_apply(b_lean_obj_arg c, b_lean_obj_arg a) {
    mpd_context_t ctx;
    if (!context(&ctx, c)) return invalid();
    mpd_t *r = new_decimal();
    uint32_t status = 0;
    mpd_qplus(r, decimal(a), &ctx, &status);
    return result(r, status);
}

#define BINARY(name, operation) \
    LEAN_EXPORT lean_obj_res name(b_lean_obj_arg c, b_lean_obj_arg a, b_lean_obj_arg b) { \
        mpd_context_t ctx; \
        if (!context(&ctx, c)) return invalid(); \
        mpd_t *r = new_decimal(); \
        uint32_t status = 0; \
        operation(r, decimal(a), decimal(b), &ctx, &status); \
        return result(r, status); \
    }

BINARY(lean_decimal_add, mpd_qadd)
BINARY(lean_decimal_sub, mpd_qsub)
BINARY(lean_decimal_mul, mpd_qmul)
BINARY(lean_decimal_div, mpd_qdiv)
BINARY(lean_decimal_quantize, mpd_qquantize)
