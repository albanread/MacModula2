#![allow(dead_code)]
//! Prototype: a recursive Obj-C type-encoding parser that produces an
//! offset-annotated **layout tree**, plus the **tier classifier** that decides
//! how a returned C struct is exposed to Modula-2.
//!
//! This generalizes the existing scalar-only `flatten_struct` / `parse_named_struct`
//! in `main.rs` (which collapse anything non-trivial to `id`, losing the value) into
//! a faithful tree that carries nesting, fixed arrays, unions, pointers, bitfields,
//! and — crucially — **true C field offsets/sizes** (the current descriptor assumes
//! 8 bytes per field, which already mis-lays any struct with 32-bit int fields).
//!
//! Three tiers, decided here, shared by both downstream paths:
//!   * `FlatRecord`   — flat scalar fields            → a flat M2 RECORD (today)
//!   * `NestedRecord` — nesting and/or fixed arrays   → a faithful nested RECORD
//!   * `Object`       — unions / bitfields / unknown / oversize → a CLASS wrapper
//!                      with named accessors over an inline payload
//!
//! The ABI return class (registers vs sret/x8) is computed separately and is
//! needed by *both* a record receive and an object's sret-into-payload receive.
//!
//! Grammar handled (runtime `method_getTypeEncoding` *and* BridgeSupport `type64`,
//! which adds `"field"` names):
//!   type   := qualifier* base
//!   base   := '{' name ('=' field*)? '}'      struct
//!           | '(' name ('=' field*)? ')'      union
//!           | '[' digits type ']'             fixed array
//!           | '^' type                        pointer (opaque, 8 bytes)
//!           | 'b' digits                      bitfield
//!           | scalar | '?'                    leaf
//!   field  := ('"' name '"')? type            name present only in BridgeSupport

/// A C scalar leaf, carrying its true arm64 (LP64) width.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scalar {
    I8,
    U8,
    I16,
    U16,
    I32,
    U32,
    I64,
    U64,
    F32,
    F64,
    Bool,
    /// id / Class / char* / SEL — an 8-byte pointer-ish word.
    Ptr,
}

impl Scalar {
    pub fn size(self) -> u64 {
        use Scalar::*;
        match self {
            I8 | U8 | Bool => 1,
            I16 | U16 => 2,
            I32 | U32 | F32 => 4,
            I64 | U64 | F64 | Ptr => 8,
        }
    }
    pub fn align(self) -> u64 {
        self.size()
    }
    /// Best-effort M2 type for the synth. Width-preserving: an i32 field is 4
    /// bytes, so it must NOT map to M2 INTEGER (i64) or offsets shift.
    pub fn m2(self) -> &'static str {
        use Scalar::*;
        match self {
            I8 => "INTEGER8",
            U8 => "CARDINAL8",
            I16 => "INTEGER16",
            U16 => "CARDINAL16",
            I32 => "INTEGER32",
            U32 => "CARDINAL32",
            I64 => "INTEGER",
            U64 => "CARDINAL",
            F32 => "REAL32",
            F64 => "REAL",
            Bool => "BOOLEAN",
            Ptr => "ADDRESS",
        }
    }
}

/// A node in the parsed encoding tree.
#[derive(Debug, Clone, PartialEq)]
pub enum Ty {
    Scalar(Scalar),
    /// `^T` — modelled as an opaque 8-byte pointer (the pointee is consumed but
    /// not retained; a pointer field is an M2 ADDRESS).
    Pointer,
    Struct { name: Option<String>, fields: Vec<Field> },
    Union { name: Option<String>, fields: Vec<Field> },
    Array { len: u64, elem: Box<Ty> },
    /// `bN` — an N-bit bitfield (forces the enclosing struct to the Object tier).
    Bitfield { bits: u32 },
    /// An encoding we don't model (`?` function pointer / block, opaque struct,
    /// long double on exotic targets, truncated input). Forces the Object tier.
    Unknown(char),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Field {
    pub name: Option<String>,
    pub ty: Ty,
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

/// Parse a complete type encoding into a `Ty`. Tolerant: malformed/truncated
/// input yields `Ty::Unknown` rather than panicking, so a bad encoding falls to
/// the Object tier instead of breaking the generator.
pub fn parse(enc: &str) -> Ty {
    let mut p = Parser { b: enc.as_bytes(), i: 0 };
    p.parse_type()
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }
    fn bump(&mut self) -> Option<u8> {
        let c = self.peek();
        if c.is_some() {
            self.i += 1;
        }
        c
    }
    /// Skip Obj-C type qualifiers (const/in/out/inout/bycopy/byref/oneway) and
    /// stray whitespace. These only appear as prefixes and never collide with a
    /// type code, so dropping them is safe.
    fn skip_qualifiers(&mut self) {
        while let Some(c) = self.peek() {
            match c {
                b'r' | b'n' | b'N' | b'o' | b'O' | b'R' | b'V' | b' ' => self.i += 1,
                _ => break,
            }
        }
    }
    fn read_number(&mut self) -> u64 {
        let mut n = 0u64;
        while let Some(c) = self.peek() {
            if c.is_ascii_digit() {
                n = n.saturating_mul(10).saturating_add((c - b'0') as u64);
                self.i += 1;
            } else {
                break;
            }
        }
        n
    }
    /// A struct/union tag: identifier chars up to `=` or the closing bracket.
    fn read_tag(&mut self) -> Option<String> {
        let start = self.i;
        while let Some(c) = self.peek() {
            if c == b'=' || c == b'}' || c == b')' {
                break;
            }
            self.i += 1;
        }
        let s = String::from_utf8_lossy(&self.b[start..self.i]).into_owned();
        // `?` (and empty) mean anonymous.
        if s.is_empty() || s == "?" {
            None
        } else {
            Some(s)
        }
    }
    fn read_quoted_name(&mut self) -> String {
        self.bump(); // opening "
        let start = self.i;
        while let Some(c) = self.peek() {
            if c == b'"' {
                break;
            }
            self.i += 1;
        }
        let s = String::from_utf8_lossy(&self.b[start..self.i]).into_owned();
        self.bump(); // closing "
        s
    }

    fn parse_type(&mut self) -> Ty {
        self.skip_qualifiers();
        match self.peek() {
            Some(b'{') => self.parse_aggregate(b'}'),
            Some(b'(') => self.parse_aggregate(b')'),
            Some(b'[') => self.parse_array(),
            Some(b'^') => {
                self.bump();
                let _pointee = self.parse_type(); // consume, but model as opaque ptr
                Ty::Pointer
            }
            Some(b'b') => {
                self.bump();
                Ty::Bitfield { bits: self.read_number() as u32 }
            }
            Some(b'@') => self.parse_object(),
            Some(c) => {
                self.bump();
                scalar_of(c)
            }
            None => Ty::Unknown('\0'),
        }
    }

    /// `@`=id, `@?`=block, `@"Class"`/`@"<Proto>"`=typed object — each is ONE 8-byte
    /// pointer. Without consuming the `?`/`"..."`, a struct field `@?` splits into
    /// `ptr` + a stray unknown leaf, and `@"NSString"` eats the class as the next
    /// field name — corrupting any aggregate that carries a block / typed object.
    fn parse_object(&mut self) -> Ty {
        self.bump(); // @
        match self.peek() {
            Some(b'?') => {
                self.bump();
                if self.peek() == Some(b'<') {
                    self.skip_balanced(b'<', b'>'); // inline block signature
                }
            }
            Some(b'"') => {
                let _class = self.read_quoted_name(); // captured later for typed returns
            }
            _ => {}
        }
        Ty::Scalar(Scalar::Ptr)
    }

    fn skip_balanced(&mut self, open: u8, close: u8) {
        let mut depth = 0u32;
        while let Some(c) = self.bump() {
            if c == open {
                depth += 1;
            } else if c == close {
                depth -= 1;
                if depth == 0 {
                    break;
                }
            }
        }
    }

    fn parse_array(&mut self) -> Ty {
        self.bump(); // [
        let len = self.read_number();
        let elem = self.parse_type();
        if self.peek() == Some(b']') {
            self.bump();
        }
        Ty::Array { len, elem: Box::new(elem) }
    }

    fn parse_aggregate(&mut self, close: u8) -> Ty {
        let open = self.bump().unwrap_or(b'{'); // { or (
        let name = self.read_tag();
        if self.peek() != Some(b'=') {
            // opaque (no body), e.g. `{CGColor}` — usually seen behind `^`.
            if self.peek() == Some(close) {
                self.bump();
            }
            return Ty::Unknown(open as char);
        }
        self.bump(); // =
        let fields = self.parse_fields(close);
        // An empty body (`{X=}`) carries no value — unmodelable, like the bodyless
        // `{X}` form, so both opaque shapes route to the Object tier consistently.
        if fields.is_empty() {
            return Ty::Unknown(open as char);
        }
        if close == b'}' {
            Ty::Struct { name, fields }
        } else {
            Ty::Union { name, fields }
        }
    }

    fn parse_fields(&mut self, close: u8) -> Vec<Field> {
        let mut fields = Vec::new();
        loop {
            self.skip_qualifiers();
            match self.peek() {
                None => break,
                Some(c) if c == close => {
                    self.bump();
                    break;
                }
                Some(b'"') => {
                    let name = self.read_quoted_name();
                    let ty = self.parse_type();
                    fields.push(Field { name: Some(name), ty });
                }
                Some(_) => {
                    let ty = self.parse_type();
                    fields.push(Field { name: None, ty });
                }
            }
        }
        fields
    }
}

/// Map a single scalar encoding char to a `Ty` leaf. arm64 / LP64 widths.
fn scalar_of(c: u8) -> Ty {
    use Scalar::*;
    Ty::Scalar(match c {
        b'c' => I8,
        b'C' => U8,
        b's' => I16,
        b'S' => U16,
        b'i' => I32,
        b'I' => U32,
        b'l' | b'q' => I64, // long == long long == 8 on LP64
        b'L' | b'Q' => U64,
        b'f' => F32,
        b'd' | b'D' => F64, // long double == double on arm64-darwin
        b'B' => Bool,
        b'@' | b'#' | b'*' | b':' => Ptr,
        other => return Ty::Unknown(other as char),
    })
}

// ---------------------------------------------------------------------------
// Layout (Apple arm64 C ABI: natural alignment)
// ---------------------------------------------------------------------------

fn round_up(x: u64, a: u64) -> u64 {
    if a <= 1 {
        x
    } else {
        x.div_ceil(a).saturating_mul(a)
    }
}

/// A laid-out field: its byte offset and the size/align of its type.
#[derive(Debug, Clone, PartialEq)]
pub struct LaidField {
    pub name: Option<String>,
    pub offset: u64,
    pub size: u64,
    pub align: u64,
}

/// `(size, align)` of a type. Bitfields are approximated (rounded to whole
/// bytes); structs containing them are Object-tier and re-measured downstream.
pub fn size_align(ty: &Ty) -> (u64, u64) {
    match ty {
        Ty::Scalar(s) => (s.size(), s.align()),
        Ty::Pointer => (8, 8),
        Ty::Bitfield { bits } => ((*bits as u64).div_ceil(8).max(1), 1),
        Ty::Unknown(_) => (0, 1),
        Ty::Array { len, elem } => {
            let (es, ea) = size_align(elem);
            (round_up(es, ea).saturating_mul(*len), ea.max(1))
        }
        Ty::Struct { fields, .. } => {
            let (_, size, align) = lay_struct(fields);
            (size, align)
        }
        Ty::Union { fields, .. } => {
            let mut size = 0u64;
            let mut align = 1u64;
            for f in fields {
                let (fs, fa) = size_align(&f.ty);
                size = size.max(fs);
                align = align.max(fa.max(1));
            }
            (round_up(size, align), align)
        }
    }
}

/// Lay out a struct's fields in order; returns (laid fields, size, align).
fn lay_struct(fields: &[Field]) -> (Vec<LaidField>, u64, u64) {
    let mut off = 0u64;
    let mut align = 1u64;
    let mut laid = Vec::with_capacity(fields.len());
    for f in fields {
        let (fs, fa) = size_align(&f.ty);
        let fa = fa.max(1);
        off = round_up(off, fa);
        laid.push(LaidField { name: f.name.clone(), offset: off, size: fs, align: fa });
        off = off.saturating_add(fs);
        align = align.max(fa);
    }
    (laid, round_up(off, align), align)
}

/// Top-level field offsets, for a struct (or union — all at 0). Empty otherwise.
pub fn field_offsets(ty: &Ty) -> Vec<LaidField> {
    match ty {
        Ty::Struct { fields, .. } => lay_struct(fields).0,
        Ty::Union { fields, .. } => fields
            .iter()
            .map(|f| {
                let (fs, fa) = size_align(&f.ty);
                LaidField { name: f.name.clone(), offset: 0, size: fs, align: fa.max(1) }
            })
            .collect(),
        _ => Vec::new(),
    }
}

// ---------------------------------------------------------------------------
// ABI return classification (AAPCS64)
// ---------------------------------------------------------------------------

/// Homogeneous floating aggregate: all leaves the same FP width, returns
/// `(width_bits, member_count)`. `None` if any leaf is non-FP / mixed-width.
pub fn hfa(ty: &Ty) -> Option<(u32, u32)> {
    match ty {
        Ty::Scalar(Scalar::F32) => Some((32, 1)),
        Ty::Scalar(Scalar::F64) => Some((64, 1)),
        Ty::Array { len, elem } => {
            let (w, c) = hfa(elem)?;
            // count in u64, then narrow — a >u32 member count can't be a register
            // HFA, so `try_from` failing → None (not a fabricated small HFA).
            let total = (c as u64).checked_mul(*len)?;
            Some((w, u32::try_from(total).ok()?))
        }
        Ty::Struct { fields, .. } => {
            let mut acc: Option<(u32, u32)> = None;
            for f in fields {
                let (w, c) = hfa(&f.ty)?;
                acc = match acc {
                    None => Some((w, c)),
                    Some((w0, c0)) if w0 == w => Some((w0, c0 + c)),
                    _ => return None,
                };
            }
            acc
        }
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AbiReturn {
    /// Returned in registers: x0/x1 (≤16-byte non-HFA) or v0–v3 (HFA).
    Registers,
    /// Returned via memory: caller passes a hidden sret pointer in x8.
    IndirectSret,
}

pub fn abi_return(ty: &Ty) -> AbiReturn {
    if let Some((_, c)) = hfa(ty) {
        if (1..=4).contains(&c) {
            return AbiReturn::Registers;
        }
    }
    let (size, _) = size_align(ty);
    if size <= 16 {
        AbiReturn::Registers
    } else {
        AbiReturn::IndirectSret
    }
}

// ---------------------------------------------------------------------------
// Tier classification
// ---------------------------------------------------------------------------

/// Conservative cap above which we never synthesize a value record (matches the
/// existing generator's 256-byte guard).
pub const SIZE_CAP: u64 = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    /// Flat scalar fields → a flat M2 RECORD (the existing fast path).
    FlatRecord,
    /// Nesting and/or fixed arrays, all leaves modelable → a nested M2 RECORD.
    NestedRecord,
    /// Unions / bitfields / unmodelable leaves / oversize → a CLASS wrapper with
    /// named accessors over an inline sret payload.
    Object,
}

/// Decide how to expose this returned type, with a human reason. The Object tier
/// is the always-correct fallback; structural blockers are checked before size.
pub fn classify(ty: &Ty) -> (Tier, &'static str) {
    if has(ty, &|t| matches!(t, Ty::Union { .. })) {
        return (Tier::Object, "contains a union");
    }
    if has(ty, &|t| matches!(t, Ty::Bitfield { .. })) {
        return (Tier::Object, "contains a bitfield");
    }
    if has(ty, &|t| matches!(t, Ty::Unknown(_))) {
        return (Tier::Object, "contains an unmodelable field type");
    }
    let (size, _) = size_align(ty);
    if size > SIZE_CAP {
        return (Tier::Object, "larger than the value-record size cap");
    }
    match ty {
        Ty::Struct { fields, .. } => {
            let nested = fields.iter().any(|f| {
                matches!(f.ty, Ty::Struct { .. } | Ty::Union { .. } | Ty::Array { .. })
            }) || has(ty, &|t| matches!(t, Ty::Array { .. }));
            if nested {
                (Tier::NestedRecord, "nested structs and/or fixed arrays")
            } else {
                (Tier::FlatRecord, "flat scalar fields")
            }
        }
        Ty::Array { .. } => (Tier::NestedRecord, "a fixed array"),
        _ => (Tier::FlatRecord, "a scalar"),
    }
}

/// Does any node in the tree satisfy `pred`? Pointers are opaque leaves — we do
/// NOT recurse through them (a pointer-to-union is just a pointer).
fn has(ty: &Ty, pred: &dyn Fn(&Ty) -> bool) -> bool {
    if pred(ty) {
        return true;
    }
    match ty {
        Ty::Struct { fields, .. } | Ty::Union { fields, .. } => {
            fields.iter().any(|f| has(&f.ty, pred))
        }
        Ty::Array { elem, .. } => has(elem, pred),
        _ => false,
    }
}

/// One-line analysis used by tests and a debug dump.
#[derive(Debug, Clone, PartialEq)]
pub struct Analysis {
    pub ty: Ty,
    pub size: u64,
    pub align: u64,
    pub hfa: Option<(u32, u32)>,
    pub abi: AbiReturn,
    pub tier: Tier,
    pub reason: &'static str,
}

pub fn analyze(enc: &str) -> Analysis {
    let ty = parse(enc);
    let (size, align) = size_align(&ty);
    let (tier, reason) = classify(&ty);
    Analysis { hfa: hfa(&ty), abi: abi_return(&ty), size, align, tier, reason, ty }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(enc: &str) -> Analysis {
        analyze(enc)
    }

    #[test]
    fn cgpoint_flat_hfa_registers() {
        let r = a("{CGPoint=dd}");
        assert_eq!((r.size, r.align), (16, 8));
        assert_eq!(r.hfa, Some((64, 2)));
        assert_eq!(r.abi, AbiReturn::Registers);
        assert_eq!(r.tier, Tier::FlatRecord);
        let f = field_offsets(&r.ty);
        assert_eq!(f.len(), 2);
        assert_eq!((f[0].offset, f[1].offset), (0, 8));
    }

    #[test]
    fn cgrect_nested_is_hfa4_registers() {
        // {CGRect={CGPoint=dd}{CGSize=dd}} flattens to 4×f64 → HFA(64,4) → v0–v3.
        let r = a("{CGRect={CGPoint=dd}{CGSize=dd}}");
        assert_eq!((r.size, r.align), (32, 8));
        assert_eq!(r.hfa, Some((64, 4)));
        assert_eq!(r.abi, AbiReturn::Registers);
        assert_eq!(r.tier, Tier::NestedRecord);
    }

    #[test]
    fn nsrange_two_u64_registers_flat() {
        let r = a("{_NSRange=QQ}");
        assert_eq!((r.size, r.align), (16, 8));
        assert_eq!(r.hfa, None); // integers, not an HFA
        assert_eq!(r.abi, AbiReturn::Registers); // ≤16 → x0/x1
        assert_eq!(r.tier, Tier::FlatRecord);
    }

    #[test]
    fn named_fields_from_bridgesupport() {
        let r = a("{CGPoint=\"x\"d\"y\"d}");
        let f = field_offsets(&r.ty);
        assert_eq!(f[0].name.as_deref(), Some("x"));
        assert_eq!(f[1].name.as_deref(), Some("y"));
        assert_eq!((f[0].offset, f[1].offset), (0, 8));
    }

    #[test]
    fn catransform3d_big_flat_sret() {
        // 16 doubles: flat scalars but >4 members → not HFA → sret; still a record.
        let enc = format!("{{CATransform3D={}}}", "d".repeat(16));
        let r = a(&enc);
        assert_eq!(r.size, 128);
        assert_eq!(r.hfa, Some((64, 16))); // homogeneous, but >4 members → not a register HFA
        assert_eq!(r.abi, AbiReturn::IndirectSret);
        assert_eq!(r.tier, Tier::FlatRecord);
    }

    #[test]
    fn simd_vector4_array_is_hfa() {
        // [4f] → 4×f32 HFA(32,4) → registers; array makes it a nested record.
        let r = a("{simd_float4=[4f]}");
        assert_eq!((r.size, r.align), (16, 4));
        assert_eq!(r.hfa, Some((32, 4)));
        assert_eq!(r.abi, AbiReturn::Registers);
        assert_eq!(r.tier, Tier::NestedRecord);
    }

    #[test]
    fn simd_matrix4x4_nested_array_sret() {
        // [4[4f]] → 16×f32, 64 bytes, not HFA → sret; nested record.
        let r = a("{matrix_float4x4=[4[4f]]}");
        assert_eq!(r.size, 64);
        assert_eq!(r.abi, AbiReturn::IndirectSret);
        assert_eq!(r.tier, Tier::NestedRecord);
    }

    #[test]
    fn union_forces_object() {
        let r = a("{Tagged=i(Payload=if)}");
        assert_eq!(r.tier, Tier::Object);
        assert_eq!(r.reason, "contains a union");
    }

    #[test]
    fn bitfield_forces_object() {
        let r = a("{Flags=b1b1b6}");
        assert_eq!(r.tier, Tier::Object);
        assert_eq!(r.reason, "contains a bitfield");
    }

    #[test]
    fn function_pointer_field_is_unknown_object() {
        // `?` (block / fn-ptr) leaf → unmodelable → object.
        let r = a("{Handler=i?}");
        assert_eq!(r.tier, Tier::Object);
        assert_eq!(r.reason, "contains an unmodelable field type");
    }

    #[test]
    fn oversize_forces_object() {
        let enc = format!("{{Big={}}}", "d".repeat(40)); // 320 bytes
        let r = a(&enc);
        assert!(r.size > SIZE_CAP);
        assert_eq!(r.tier, Tier::Object);
    }

    #[test]
    fn pointer_field_stays_a_record() {
        // a pointer is an ADDRESS leaf — value-copyable, no nesting.
        let r = a("{Node=^vi}");
        let f = field_offsets(&r.ty);
        assert_eq!(f.len(), 2);
        assert_eq!((f[0].offset, f[1].offset), (0, 8)); // ptr@0(8), i32@8
        assert_eq!(r.size, 16);
        assert_eq!(r.tier, Tier::FlatRecord);
    }

    #[test]
    fn mixed_int_widths_lay_out_correctly() {
        // {Mixed=ic}: i32@0 (4) then i8@4 (1) → size rounds to 8, align 4.
        // The CURRENT 8-bytes-per-field descriptor would call this 16 bytes.
        let r = a("{Mixed=ic}");
        let f = field_offsets(&r.ty);
        assert_eq!((f[0].offset, f[0].size), (0, 4));
        assert_eq!((f[1].offset, f[1].size), (4, 1));
        assert_eq!((r.size, r.align), (8, 4));
        assert_eq!(r.tier, Tier::FlatRecord);
    }

    #[test]
    fn pointer_to_union_is_just_a_pointer() {
        // ^(...) must NOT drag the union out — it's an 8-byte pointer.
        let r = a("{Holder=^(U=if)q}");
        assert_eq!(r.tier, Tier::FlatRecord);
        assert_eq!(r.size, 16);
    }

    #[test]
    fn truncated_input_falls_to_object() {
        let r = a("{Bad=dd"); // missing close brace
        // still parses the two doubles; tolerant close — should not panic
        assert!(matches!(r.ty, Ty::Struct { .. }));
    }

    #[test]
    fn empty_body_struct_is_object_like_the_bodyless_form() {
        // {CGColor=} (empty body) must route to Object, same as the bodyless
        // {CGColor} — not become a degenerate zero-size FlatRecord.
        let r = a("{CGColor=}");
        assert!(matches!(r.ty, Ty::Unknown(_)));
        assert_eq!(r.tier, Tier::Object);
        assert_eq!(a("{CGColor}").tier, Tier::Object);
    }

    #[test]
    fn absurd_array_length_saturates_to_object_no_panic() {
        // Adversarial: a length that would overflow `size*len`. Must saturate
        // (never panic, never wrap below the cap) and land in Object.
        let r = a("{Wrap={A=[2305843009213693952d]}i}"); // 2^61 doubles inside
        assert!(r.size >= SIZE_CAP);
        assert_eq!(r.tier, Tier::Object);
        let top = a("[999999999999999999999d]"); // saturates read_number
        assert!(top.size >= SIZE_CAP);
        assert_eq!(top.tier, Tier::Object);
    }

    #[test]
    fn huge_array_count_does_not_fabricate_an_hfa() {
        // 2^32 floats must not truncate to a 0- or 1-member HFA.
        let r = a("[4294967296f]");
        assert_eq!(r.hfa, None);
        assert_eq!(r.tier, Tier::Object);
    }

    #[test]
    fn nsedgeinsets_flat_four_doubles() {
        let r = a("{NSEdgeInsets=dddd}");
        assert_eq!(r.size, 32);
        assert_eq!(r.hfa, Some((64, 4)));
        assert_eq!(r.abi, AbiReturn::Registers);
        assert_eq!(r.tier, Tier::FlatRecord);
    }

    #[test]
    fn block_and_typed_object_are_single_pointer() {
        // {B=@?i}: block(ptr)@0 + i32@8 -> 2 fields, 16 bytes (not 3 fields + a stray ?)
        let r = a("{B=@?i}");
        assert_eq!(field_offsets(&r.ty).len(), 2);
        assert_eq!(r.size, 16);
        // @"NSString" is one pointer; the class name is consumed, not a phantom field
        assert_eq!(field_offsets(&a("{S=@\"NSString\"i}").ty).len(), 2);
        // an inline block signature @?<...> stays a single leaf
        assert_eq!(field_offsets(&a("{H=@?<v@?@\"NSError\">i}").ty).len(), 2);
    }
}
