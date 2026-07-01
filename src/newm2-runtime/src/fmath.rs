//! Floating-point primitives backing the ISO `LowReal` / `LowLong`
//! modules: `frexp`, `ldexp`, `modf` and a few related helpers that
//! don't map to a single LLVM intrinsic.
//!
//! All operate on `f64`. The Modula-2 `LowReal` port (`REAL` = f32 in
//! NewM2) widens to LONGREAL on the M2 side before calling these.

/// `frexp(x)` — split `x` into a normalized fraction `m` in `[0.5, 1.0)`
/// (or 0 for x=0) and a power-of-two exponent `e` such that `x = m * 2^e`.
/// `0`, `±inf`, and NaN return `(x, 0)`. Bound to `NM2.Math.Frexp`.
///
/// `out_exp` is `*mut i64` to match Modula-2 `INTEGER` (NewM2 = 8 bytes).
/// A narrower i32 would leave the upper four bytes uninitialised, which
/// in the M2 caller reads back as random garbage. (We learned that one
/// the hard way — `exponent(8.0)` came back as `777389080580` instead
/// of `4` before this fix.)
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_math_frexp(
    x: f64,
    out_exp: *mut i64,
) -> f64 {
    if out_exp.is_null() {
        return x;
    }
    if x == 0.0 || !x.is_finite() {
        unsafe { *out_exp = 0 };
        return x;
    }
    let bits = x.to_bits();
    let raw_exp = ((bits >> 52) & 0x7FF) as i64;
    if raw_exp == 0 {
        // Subnormal — normalise by repeatedly doubling. Simpler than
        // a bit-counting variant for code we'll rarely hit at runtime.
        let mut m = x;
        let mut e: i64 = 0;
        while m.abs() < 0.5 {
            m *= 2.0;
            e -= 1;
        }
        unsafe { *out_exp = e };
        return m;
    }
    // Normal: set the biased exponent to 1022 so the implicit-leading-1
    // mantissa renders the fraction in `[0.5, 1.0)`.
    let new_bits = (bits & !(0x7FFu64 << 52)) | (1022u64 << 52);
    let fraction = f64::from_bits((bits & (1u64 << 63)) | (new_bits & !(1u64 << 63)));
    unsafe { *out_exp = raw_exp - 1022 };
    fraction
}

/// `ldexp(x, n)` — `x * 2^n`. `n` is `i64` to match Modula-2 INTEGER.
/// Bound to `NM2.Math.Ldexp`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_ldexp(x: f64, n: i64) -> f64 {
    if x == 0.0 || !x.is_finite() {
        return x;
    }
    // `x * 2^n` computed as a single `2^n` value then multiplied overflowed
    // (or flushed to 0) whenever |n| alone was large even though the TRUE
    // product x*2^n was a perfectly ordinary finite (possibly subnormal)
    // f64 — e.g. ldexp(1e-300, 1024): 2^1024 alone is +inf, but the real
    // product is ~1.8e8. Scale in bounded chunks instead, each individually
    // within f64's normal exponent range, so no intermediate step can
    // overflow/underflow when the final result wouldn't.
    //
    // A double's exponent spans at most [-1074, 1023] (subnormal floor to
    // normal ceiling), so any n outside roughly that same span makes the
    // result unconditionally 0 or ±inf regardless of x — clamp there first
    // so an adversarial |n| can't turn this into an unbounded loop.
    let n = n.clamp(-2200, 2200);
    const STEP: i32 = 1000; // safely inside f64's normal exponent range
    let mut r = x;
    let mut remaining = n;
    while remaining > STEP as i64 {
        r *= (2.0f64).powi(STEP);
        remaining -= STEP as i64;
    }
    while remaining < -(STEP as i64) {
        r *= (2.0f64).powi(-STEP);
        remaining += STEP as i64;
    }
    r * (2.0f64).powi(remaining as i32)
}

/// `modf(x)` — split `x` into integer and fractional parts. Both share
/// `x`'s sign. Returns the fractional part; integer part is written to
/// `*out_int`. Bound to `NM2.Math.Modf`.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_math_modf(
    x: f64,
    out_int: *mut f64,
) -> f64 {
    if out_int.is_null() {
        return x;
    }
    if !x.is_finite() {
        unsafe { *out_int = x };
        return if x.is_nan() { x } else { x.copysign(0.0) };
    }
    let ipart = x.trunc();
    unsafe { *out_int = ipart };
    x - ipart
}

// ── Transcendental / power primitives (NM2Math.*) ────────────────────────────
//
// REAL and LONGREAL are both `f64` in this build, so each function backs both
// the plain (REAL) and the `L`-prefixed (LONGREAL) NM2Math procedure. Bound by
// name in newm2-llvm; the ISO RealMath / LongMath bodies call them qualified.

macro_rules! math1 {
    ($name:ident, $method:ident) => {
        #[unsafe(no_mangle)]
        pub extern "C-unwind" fn $name(x: f64) -> f64 {
            x.$method()
        }
    };
}

math1!(nm2_math_sin, sin);
math1!(nm2_math_cos, cos);
math1!(nm2_math_tan, tan);
math1!(nm2_math_arcsin, asin);
math1!(nm2_math_arccos, acos);
math1!(nm2_math_arctan, atan);
math1!(nm2_math_exp, exp);
math1!(nm2_math_ln, ln);
math1!(nm2_math_lg, log2);
math1!(nm2_math_sqrt, sqrt);
math1!(nm2_math_sinh, sinh);
math1!(nm2_math_cosh, cosh);
math1!(nm2_math_tanh, tanh);
math1!(nm2_math_arcsinh, asinh);
math1!(nm2_math_arccosh, acosh);
math1!(nm2_math_arctanh, atanh);
math1!(nm2_math_floor, floor);

/// `arctan2(y, x)` — the angle of the point (x, y).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_arctan2(y: f64, x: f64) -> f64 {
    y.atan2(x)
}

/// `pow(base, exponent)` — `base ** exponent`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_pow(base: f64, exponent: f64) -> f64 {
    base.powf(exponent)
}

/// `truncToInt(x)` — truncate towards zero to a signed INTEGER.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_trunc_to_int(x: f64) -> i64 {
    x.trunc() as i64
}

/// `truncToCard(x)` — truncate towards zero to a CARDINAL.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_trunc_to_card(x: f64) -> u64 {
    x.trunc() as u64
}

// ── Extended unary primitives ────────────────────────────────────────────────

math1!(nm2_math_ceil, ceil); // smallest integer >= x
math1!(nm2_math_round, round); // nearest integer, halves away from zero
math1!(nm2_math_trunc, trunc); // integer part as REAL (towards zero)
math1!(nm2_math_log10, log10); // base-10 logarithm
math1!(nm2_math_exp2, exp2); // 2 ** x
math1!(nm2_math_cbrt, cbrt); // cube root (defined for x < 0)
math1!(nm2_math_expm1, exp_m1); // exp(x) - 1, accurate near 0
math1!(nm2_math_log1p, ln_1p); // ln(1 + x), accurate near 0
math1!(nm2_math_degrees, to_degrees); // radians -> degrees
math1!(nm2_math_radians, to_radians); // degrees -> radians

/// `sign(x)` — -1, 0, or +1. Unlike `f64::signum`, `sign(±0) = 0`; `sign(NaN) = NaN`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_sign(x: f64) -> f64 {
    if x.is_nan() {
        x
    } else if x == 0.0 {
        0.0
    } else {
        x.signum()
    }
}

// ── Extended binary primitives ───────────────────────────────────────────────

macro_rules! math2 {
    ($name:ident, $method:ident) => {
        #[unsafe(no_mangle)]
        pub extern "C-unwind" fn $name(x: f64, y: f64) -> f64 {
            x.$method(y)
        }
    };
}

math2!(nm2_math_hypot, hypot); // sqrt(x*x + y*y) without overflow
math2!(nm2_math_copysign, copysign); // magnitude of x with the sign of y
math2!(nm2_math_min, min); // IEEE minimum (NaN-skipping)
math2!(nm2_math_max, max); // IEEE maximum (NaN-skipping)
math2!(nm2_math_log, log); // log(x, base) = log_base(x)

/// `fmod(x, y)` — floating remainder of x/y, with the sign of x (C `fmod`).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_fmod(x: f64, y: f64) -> f64 {
    x % y
}

#[cfg(test)]
mod ldexp_tests {
    use super::*;

    #[test]
    fn matches_plain_multiply_for_ordinary_values() {
        assert_eq!(nm2_math_ldexp(1.5, 4), 1.5 * 16.0);
        assert_eq!(nm2_math_ldexp(3.0, -2), 3.0 * 0.25);
        assert_eq!(nm2_math_ldexp(0.0, 100), 0.0);
    }

    #[test]
    fn tiny_x_large_n_stays_finite_when_the_true_product_is() {
        // Regression: 2^1024 alone is +inf, but 1e-300 * 2^1024 is an
        // ordinary finite value (~1.8e8) — the old single-step powi(1024)
        // computed +inf * 1e-300 = +inf, a wrong non-finite result for a
        // perfectly representable input.
        let r = nm2_math_ldexp(1e-300, 1024);
        assert!(r.is_finite(), "expected a finite result, got {r}");
        let expected = 1e-300 * 2f64.powi(1024 - 997) * 2f64.powi(997); // split reference calc, avoids the same overflow in the test
        assert!((r - expected).abs() / expected < 1e-9, "r={r} expected≈{expected}");
    }

    #[test]
    fn huge_n_saturates_to_zero_or_infinity_without_hanging() {
        // Genuinely out-of-range exponents must still resolve (not loop
        // forever) to the mathematically correct saturated result.
        assert_eq!(nm2_math_ldexp(1.0, i64::MAX), f64::INFINITY);
        assert_eq!(nm2_math_ldexp(1.0, i64::MIN + 1), 0.0);
        assert_eq!(nm2_math_ldexp(-1.0, i64::MAX), f64::NEG_INFINITY);
    }

    #[test]
    fn non_finite_and_zero_pass_through() {
        assert!(nm2_math_ldexp(f64::NAN, 5).is_nan());
        assert_eq!(nm2_math_ldexp(f64::INFINITY, -5), f64::INFINITY);
        assert_eq!(nm2_math_ldexp(0.0, 5), 0.0);
    }
}
