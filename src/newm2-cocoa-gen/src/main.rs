//! cocoa-gen — the macOS analogue of winapi-gen.
//!
//! Reads the **Objective-C runtime itself** (the authoritative, complete source:
//! `class_copyMethodList` gives every method's selector + type encoding for a
//! loaded class) and emits MacM2 EXTERNAL class declarations
//! (`<* cocoa_class "NSView" *>` + ABSTRACT methods with pinned selectors) so a
//! Cocoa class can be used from typed Modula-2. See docs/macm2-runtime.md and
//! docs/design/cocoa-classes.md.
//!
//! v1: instance methods with object/scalar signatures; methods whose encoding
//! involves structs, blocks, varargs, or pointers-to-struct are skipped (listed
//! in a trailing comment count). Run on macOS arm64.

use std::collections::HashSet;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};

// Prototype: recursive encoding parser + layout tree + tier classifier.
mod encoding;

unsafe extern "C" {
    fn dlopen(path: *const c_char, mode: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, sym: *const c_char) -> *mut c_void;
}

// objc runtime function pointers, resolved at startup.
struct Rt {
    get_class: extern "C" fn(*const c_char) -> *mut c_void,
    copy_methods: extern "C" fn(*mut c_void, *mut u32) -> *mut *mut c_void,
    method_get_name: extern "C" fn(*mut c_void) -> *mut c_void,
    method_get_types: extern "C" fn(*mut c_void) -> *const c_char,
    sel_get_name: extern "C" fn(*mut c_void) -> *const c_char,
    superclass: extern "C" fn(*mut c_void) -> *mut c_void,
    class_get_name: extern "C" fn(*mut c_void) -> *const c_char,
    object_get_class: extern "C" fn(*mut c_void) -> *mut c_void,
}

fn sym(name: &str) -> *mut c_void {
    let c = CString::new(name).unwrap();
    // RTLD_DEFAULT = -2 on macOS.
    let p = unsafe { dlsym(-2isize as *mut c_void, c.as_ptr()) };
    assert!(!p.is_null(), "symbol not found: {name}");
    p
}

fn load_frameworks() {
    for fw in [
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/Frameworks/AppKit.framework/AppKit",
        "/System/Library/Frameworks/AVFoundation.framework/AVFoundation",
    ] {
        let c = CString::new(fw).unwrap();
        unsafe { dlopen(c.as_ptr(), 2 /*RTLD_NOW*/) };
    }
}

/// Normalize an Obj-C type-encoding token to a single-letter *kind* the compiler
/// maps to an M2 type: @=id/ptr  :=SEL  i=signed-int  u=unsigned-int  d=real
/// B=bool  v=void  {=struct(unsupported)  ?=other. Keeps the selector DB
/// language-neutral; the compiler owns the kind->TypeId mapping (data-driven).
/// A single scalar encoding -> kind, or None for anything non-scalar.
fn scalar_kind(tok: &str) -> Option<&'static str> {
    Some(match tok {
        "@" | "#" | "*" => "@",
        "q" | "l" | "i" | "s" => "i",
        "Q" | "L" | "I" | "S" => "u",
        "d" | "f" => "d",
        "B" | "c" | "C" => "B",
        _ => return None,
    })
}

/// Flatten a struct encoding `{Name=field…}` to the in-order sequence of its
/// scalar field kinds (recursing through nested structs), e.g. `{_NSRange=QQ}` ->
/// "uu", `{CGRect={CGPoint=dd}{CGSize=dd}}` -> "dddd". Returns None if any field
/// is unsupported (array/union/etc.) so the compiler falls back to `id`. A field
/// pointer counts as `@`. The struct's ABI follows from this field sequence, so
/// the compiler can synthesize a matching record.
fn flatten_struct(tok: &str) -> Option<String> {
    let eq = tok.find('=')?;
    if tok.len() < 2 {
        return None;
    }
    let inner = &tok[eq + 1..tok.len() - 1]; // strip the trailing '}'
    let mut out = String::new();
    for ft in tokenize(inner) {
        if ft.starts_with('{') {
            out.push_str(&flatten_struct(&ft)?);
        } else if ft.starts_with('^') {
            out.push('@'); // pointer field
        } else if ft.starts_with('[') || ft.starts_with('(') {
            return None; // array / union field — unsupported
        } else {
            out.push_str(scalar_kind(&ft)?);
        }
    }
    (!out.is_empty()).then_some(out)
}

/// The struct tag name in `{Name=…}` (or `{Name…}`), or None if anonymous (`?`)
/// or not a plain identifier.
fn struct_name(tok: &str) -> Option<String> {
    let n: String = tok[1..].chars().take_while(|&c| c != '=' && c != '}').collect();
    if n.is_empty() || !n.chars().all(|c| c.is_alphanumeric() || c == '_') {
        return None;
    }
    Some(n)
}

/// True when we synthesize a record for this struct shape: any flat scalar struct
/// of reasonable size. The compiler picks the return ABI from the record type —
/// registers (x0/x1 or v0–v3) for ≤16-byte / HFA structs, sret (x8) for larger —
/// so both are reliable. The size cap just rejects pathologically large structs.
fn synthesizable_struct(fields: &str) -> bool {
    let size: usize = fields.chars().map(|c| if c == 'B' { 1 } else { 8 }).sum();
    size <= 256
}

/// Read an attribute `name='…'` / `name="…"` from an XML line.
fn xml_attr(line: &str, name: &str) -> Option<String> {
    let key = format!("{name}=");
    let p = line.find(&key)? + key.len();
    let q = line.as_bytes().get(p).copied()? as char; // ' or "
    let rest = &line[p + 1..];
    let end = rest.find(q)?;
    Some(rest[..end].to_string())
}

/// Parse a *named* struct encoding `{EncName="f1"k1"f2"k2…}` (from BridgeSupport's
/// type64) into (encoding-name, [(field-name, kind)]). Returns None for a struct
/// with a non-scalar field (nested struct / pointer / array) — those keep
/// positional fields. Kinds reuse scalar_kind.
fn parse_named_struct(enc: &str) -> Option<(String, Vec<(String, String)>)> {
    let s = enc.strip_prefix('{')?.strip_suffix('}')?;
    let eq = s.find('=')?;
    let encname = s[..eq].to_string();
    let body = s[eq + 1..].as_bytes();
    let mut i = 0;
    let mut fields = Vec::new();
    while i < body.len() {
        if body[i] != b'"' {
            return None; // expected a field name
        }
        i += 1;
        let start = i;
        while i < body.len() && body[i] != b'"' {
            i += 1;
        }
        let fname = String::from_utf8_lossy(&body[start..i]).into_owned();
        i += 1; // closing quote
        let c = *body.get(i)? as char;
        let kind = scalar_kind(&c.to_string())?; // nested/pointer/array -> None
        fields.push((fname, kind.to_string()));
        i += 1;
    }
    (!fields.is_empty()).then_some((encname, fields))
}

/// Load Cocoa struct field names from the system BridgeSupport metadata (the
/// runtime method encodings omit them). Maps encoding-name -> [(field, kind)] for
/// flat all-scalar structs; nested structs (e.g. CGRect) are left to the
/// hand-written geometry records.
fn load_bridgesupport() -> std::collections::HashMap<String, Vec<(String, String)>> {
    let mut out = std::collections::HashMap::new();
    for fw in ["Foundation", "AppKit", "CoreGraphics", "QuartzCore", "CoreImage"] {
        let path = format!(
            "/System/Library/Frameworks/{fw}.framework/Resources/BridgeSupport/{fw}.bridgesupport"
        );
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        for line in text.lines() {
            let l = line.trim();
            if !l.starts_with("<struct ") {
                continue;
            }
            let Some(enc) = xml_attr(l, "type64").or_else(|| xml_attr(l, "type")) else {
                continue;
            };
            let enc = enc.replace("&quot;", "\"");
            if let Some((encname, fields)) = parse_named_struct(&enc) {
                out.entry(encname).or_insert(fields);
            }
        }
    }
    out
}

type BridgeStructs = std::collections::HashMap<String, Vec<(String, String)>>;

/// Normalize an encoding token to a return/argument *kind*. Named geometry structs
/// keep their short tags (R/N/P/S — the compiler maps them to ObjC.NSRect/…);
/// any other struct becomes a synthesizable descriptor `{<field kinds>}` (or `{`
/// when it can't be flattened).
fn kind_of(tok: &str, bs: &BridgeStructs) -> String {
    if tok.starts_with('^') {
        return "@".to_string(); // pointer
    }
    if tok.starts_with('{') {
        if tok.starts_with("{CGRect") || tok.starts_with("{NSRect") {
            return "R".to_string();
        }
        if tok.starts_with("{CGPoint") || tok.starts_with("{NSPoint") {
            return "P".to_string();
        }
        if tok.starts_with("{CGSize") || tok.starts_with("{NSSize") {
            return "S".to_string();
        }
        if tok.starts_with("{_NSRange") || tok.starts_with("{NSRange") {
            return "N".to_string();
        }
        // Other named structs: synthesize any reasonable flat struct (the compiler
        // picks register vs sret return from the record type). Prefer real field names from BridgeSupport ("{Name|f1:k1|f2:k2}"); fall
        // back to positional fields ("{Name:fieldkinds}").
        return match (struct_name(tok), flatten_struct(tok)) {
            (Some(n), Some(f)) if synthesizable_struct(&f) => match bs.get(&n) {
                Some(named) => {
                    let parts: Vec<String> =
                        named.iter().map(|(fld, k)| format!("{fld}:{k}")).collect();
                    format!("{{{n}|{}}}", parts.join("|"))
                }
                None => format!("{{{n}:{f}}}"),
            },
            _ => "{".to_string(), // anonymous / sret / unsupported -> id
        };
    }
    if tok.starts_with('[') || tok.starts_with('(') {
        return "{".to_string(); // array / union
    }
    match tok {
        "@" | "#" | "*" => "@",
        ":" => ":",
        "q" | "l" | "i" | "s" => "i",
        "Q" | "L" | "I" | "S" => "u",
        "d" | "f" => "d",
        "B" | "c" | "C" => "B",
        "v" => "v",
        _ => "?",
    }
    .to_string()
}

/// Collect `selector -> (ret-kind, arg-kinds)` for one class, flagging any
/// selector whose signature disagrees across classes as ambiguous (dropped).
fn collect_selectors(
    rt: &Rt,
    cls: *mut c_void,
    out: &mut std::collections::HashMap<String, (String, Vec<String>)>,
    ambiguous: &mut HashSet<String>,
    bs: &BridgeStructs,
) {
    let mut count: u32 = 0;
    let methods = (rt.copy_methods)(cls, &mut count);
    if methods.is_null() {
        return;
    }
    for k in 0..count as isize {
        let m = unsafe { *methods.offset(k) };
        let sel = (rt.method_get_name)(m);
        let sel_name =
            unsafe { CStr::from_ptr((rt.sel_get_name)(sel)) }.to_string_lossy().into_owned();
        if sel_name.starts_with('_') {
            continue;
        }
        let enc =
            unsafe { CStr::from_ptr((rt.method_get_types)(m)) }.to_string_lossy().into_owned();
        let toks = tokenize(&enc);
        if toks.len() < 3 {
            continue; // need at least ret, self(@), _cmd(:)
        }
        let ret = kind_of(&toks[0], bs);
        let args: Vec<String> = toks[3..].iter().map(|t| kind_of(t, bs)).collect();
        if args.len() != sel_name.matches(':').count() {
            continue; // encoding/arity disagreement — skip
        }
        match out.get(&sel_name) {
            Some((r, a)) if *r == ret && *a == args => {} // consistent, keep
            Some(_) => {
                ambiguous.insert(sel_name); // conflicting signatures across classes
            }
            None => {
                out.insert(sel_name, (ret, args));
            }
        }
    }
}

/// Emit the selector database (JSON) to stdout: `{classes, selectors}`. Walks
/// each requested class and its superclass chain (so inherited selectors are
/// included) plus the metaclass (class methods).
fn emit_json(rt: &Rt, classes: &[String], bs: &BridgeStructs) {
    let mut sels: std::collections::HashMap<String, (String, Vec<String>)> =
        std::collections::HashMap::new();
    let mut ambiguous: HashSet<String> = HashSet::new();
    let mut class_names: Vec<String> = Vec::new();
    let mut seen_cls: HashSet<String> = HashSet::new();
    for c in classes {
        let mut cur = (rt.get_class)(CString::new(c.as_str()).unwrap().as_ptr());
        while !cur.is_null() {
            let n =
                unsafe { CStr::from_ptr((rt.class_get_name)(cur)) }.to_string_lossy().into_owned();
            if seen_cls.insert(n.clone()) {
                class_names.push(n);
                collect_selectors(rt, cur, &mut sels, &mut ambiguous, bs);
                let meta = (rt.object_get_class)(cur);
                collect_selectors(rt, meta, &mut sels, &mut ambiguous, bs);
            }
            cur = (rt.superclass)(cur);
        }
    }
    for a in &ambiguous {
        sels.remove(a);
    }
    let mut keys: Vec<&String> = sels.keys().collect();
    keys.sort();
    class_names.sort();
    println!("{{");
    println!(
        "  \"note\": \"generated by newm2-cocoa-gen (COCOA_GEN_JSON=1). kinds: @=id :=SEL i=int u=uint d=real B=bool v=void {{=struct ?=other\","
    );
    let cls_list =
        class_names.iter().map(|c| format!("\"{c}\"")).collect::<Vec<_>>().join(", ");
    println!("  \"classes\": [{cls_list}],");
    println!("  \"selectors\": {{");
    for (i, k) in keys.iter().enumerate() {
        let (r, a) = &sels[*k];
        let args = a.iter().map(|x| format!("\"{x}\"")).collect::<Vec<_>>().join(", ");
        let comma = if i + 1 < keys.len() { "," } else { "" };
        println!("    \"{k}\": {{\"ret\": \"{r}\", \"args\": [{args}]}}{comma}");
    }
    println!("  }}");
    println!("}}");
}

/// Tokenize an Obj-C type encoding into type tokens, discarding qualifiers,
/// digits (sizes/offsets), and whitespace. A struct/array/union/pointer becomes
/// a single token so callers can detect "unsupported".
fn tokenize(enc: &str) -> Vec<String> {
    let b = enc.as_bytes();
    let mut i = 0;
    let mut out = Vec::new();
    while i < b.len() {
        let c = b[i] as char;
        match c {
            '0'..='9' | ' ' => i += 1,
            // type qualifiers (const, in, out, …): skip, keep the base type.
            'r' | 'n' | 'N' | 'o' | 'O' | 'R' | 'V' => i += 1,
            '{' | '[' | '(' => {
                // read a balanced group as one token (unsupported aggregate).
                let (open, close) = match c {
                    '{' => ('{', '}'),
                    '[' => ('[', ']'),
                    _ => ('(', ')'),
                };
                let mut depth = 0;
                let start = i;
                while i < b.len() {
                    let ch = b[i] as char;
                    if ch == open {
                        depth += 1;
                    } else if ch == close {
                        depth -= 1;
                        if depth == 0 {
                            i += 1;
                            break;
                        }
                    }
                    i += 1;
                }
                out.push(enc[start..i].to_string());
            }
            '^' => {
                // pointer to next type — take "^" + the following base char.
                let mut tok = String::from("^");
                i += 1;
                if i < b.len() {
                    tok.push(b[i] as char);
                    i += 1;
                }
                out.push(tok);
            }
            _ => {
                out.push(c.to_string());
                i += 1;
            }
        }
    }
    out
}

/// Map a type token to an M2 type, or None if unsupported.
fn m2_type(tok: &str) -> Option<&'static str> {
    Some(match tok {
        "@" => "ObjC.Id",
        "#" => "ObjC.Id", // Class
        ":" => "ObjC.SEL",
        "q" | "l" | "i" | "s" => "INTEGER",
        "Q" | "L" | "I" | "S" => "CARDINAL",
        "d" | "f" => "REAL",
        "B" | "c" | "C" => "BOOLEAN",
        "*" => "ObjC.Id", // char* — pass as a pointer
        _ => return None, // structs, blocks(?), pointers-to-struct, void* etc.
    })
}

/// Turn a selector into an M2 method name: capitalize each keyword and join.
/// `addObject:` -> `AddObject`, `setObject:forKey:` -> `SetObjectForKey`.
fn method_name(sel: &str) -> String {
    let mut s = String::new();
    for part in sel.split(':') {
        if part.is_empty() {
            continue;
        }
        let mut chars = part.chars();
        if let Some(f) = chars.next() {
            s.extend(f.to_uppercase());
            s.push_str(chars.as_str());
        }
    }
    s
}

const M2_KEYWORDS: &[&str] = &[
    "And", "Array", "Begin", "By", "Case", "Const", "Div", "Do", "Else", "Elsif", "End", "Exit",
    "For", "From", "If", "Import", "In", "Loop", "Mod", "Module", "Not", "Of", "Or", "Pointer",
    "Procedure", "Qualified", "Record", "Repeat", "Return", "Set", "Then", "To", "Type", "Until",
    "Var", "While", "With",
];

struct Method {
    name: String,
    selector: String,
    ret: Option<&'static str>,
    params: Vec<&'static str>,
}

/// Emit one class with **only its own** methods, `INHERIT`ing its superclass
/// when that superclass is also being emitted (`known`). Inherited methods come
/// from the chain, so the module stays small and matches Cocoa's structure.
fn gen_class(
    rt: &Rt,
    cls: *mut c_void,
    name: &str,
    known: &HashSet<String>,
    inherited: &HashSet<String>,
) -> (String, HashSet<String>) {
    let super_cls = (rt.superclass)(cls);
    let super_name = if super_cls.is_null() {
        None
    } else {
        let n = unsafe { CStr::from_ptr((rt.class_get_name)(super_cls)) }
            .to_string_lossy()
            .into_owned();
        known.contains(&n).then_some(n)
    };

    let mut seen: HashSet<String> = HashSet::new();
    // Instance methods (on the class); class methods (on the metaclass).
    let (mut instance, sk1) = collect_methods(rt, cls, &mut seen, inherited);
    let metaclass = (rt.object_get_class)(cls);
    let (mut classm, sk2) = collect_methods(rt, metaclass, &mut seen, inherited);
    instance.sort_by(|a, b| a.name.cmp(&b.name));
    classm.sort_by(|a, b| a.name.cmp(&b.name));

    let render = |m: &Method, kw: &str| -> String {
        let ps: Vec<String> =
            m.params.iter().enumerate().map(|(i, t)| format!("a{i}: {t}")).collect();
        let params = format!(" ({})", ps.join("; "));
        let ret = m.ret.map(|t| format!(": {t}")).unwrap_or_default();
        format!("  ABSTRACT {kw} {}{}{} <* selector \"{}\" *>;\n", m.name, params, ret, m.selector)
    };

    let mut out = String::new();
    out.push_str(&format!("CLASS {name};\n"));
    // INHERIT must precede any class member (the parser parses it right after the
    // header); the cocoa_class pragma and methods follow.
    if let Some(s) = &super_name {
        out.push_str(&format!("  INHERIT {s};\n"));
    }
    out.push_str(&format!("  <* cocoa_class \"{name}\" *>\n"));
    for m in &classm {
        out.push_str(&render(m, "CLASS PROCEDURE"));
    }
    for m in &instance {
        out.push_str(&render(m, "PROCEDURE"));
    }
    out.push_str(&format!("END {name};\n"));
    out.push_str(&format!(
        "  (* {} instance + {} class methods; {} skipped *)\n\n",
        instance.len(),
        classm.len(),
        sk1 + sk2
    ));
    let own_names: HashSet<String> =
        instance.iter().chain(classm.iter()).map(|m| m.name.clone()).collect();
    (out, own_names)
}

/// Process a class's `class_copyMethodList`, mapping selectors+encodings to M2
/// methods, filtering unsupported/category/keyword/dup ones. `seen` dedups
/// within the (class, metaclass) pair; `inherited` skips ancestor methods.
fn collect_methods(
    rt: &Rt,
    cls: *mut c_void,
    seen: &mut HashSet<String>,
    inherited: &HashSet<String>,
) -> (Vec<Method>, u32) {
    let mut out = Vec::new();
    let mut skipped = 0u32;
    let mut count: u32 = 0;
    let methods = (rt.copy_methods)(cls, &mut count);
    for k in 0..count as isize {
        let m = unsafe { *methods.offset(k) };
        let sel = (rt.method_get_name)(m);
        let sel_name =
            unsafe { CStr::from_ptr((rt.sel_get_name)(sel)) }.to_string_lossy().into_owned();
        let enc =
            unsafe { CStr::from_ptr((rt.method_get_types)(m)) }.to_string_lossy().into_owned();
        if sel_name.starts_with('_') || sel_name.contains('_') || sel_name.contains('.') {
            continue;
        }
        let toks = tokenize(&enc);
        if toks.len() < 3 {
            skipped += 1;
            continue;
        }
        let ret_m2 = match (toks[0] == "v").then_some(None).unwrap_or_else(|| Some(m2_type(&toks[0]))) {
            None => None,             // void
            Some(Some(m)) => Some(m), // mapped return
            Some(None) => {
                skipped += 1;
                continue;
            }
        };
        let mut params = Vec::new();
        let mut ok = true;
        for t in &toks[3..] {
            match m2_type(t) {
                Some(m) => params.push(m),
                None => {
                    ok = false;
                    break;
                }
            }
        }
        if !ok || params.len() != sel_name.matches(':').count() {
            skipped += 1;
            continue;
        }
        let mname = method_name(&sel_name);
        if mname.is_empty()
            || M2_KEYWORDS.contains(&mname.as_str())
            || inherited.contains(&mname)
            || !seen.insert(mname.clone())
        {
            skipped += 1;
            continue;
        }
        out.push(Method { name: mname, selector: sel_name, ret: ret_m2, params });
    }
    (out, skipped)
}

fn main() {
    load_frameworks();
    let rt = Rt {
        get_class: unsafe { std::mem::transmute(sym("objc_getClass")) },
        copy_methods: unsafe { std::mem::transmute(sym("class_copyMethodList")) },
        method_get_name: unsafe { std::mem::transmute(sym("method_getName")) },
        method_get_types: unsafe { std::mem::transmute(sym("method_getTypeEncoding")) },
        sel_get_name: unsafe { std::mem::transmute(sym("sel_getName")) },
        superclass: unsafe { std::mem::transmute(sym("class_getSuperclass")) },
        class_get_name: unsafe { std::mem::transmute(sym("class_getName")) },
        object_get_class: unsafe { std::mem::transmute(sym("object_getClass")) },
    };

    // Classes to generate: CLI args, or a default curated set.
    let args: Vec<String> = std::env::args().skip(1).collect();
    let classes: Vec<String> = if args.is_empty() {
        ["NSObject", "NSString", "NSMutableString", "NSArray", "NSMutableArray",
         "NSDictionary", "NSMutableDictionary", "NSNumber", "NSValue", "NSData",
         "NSDate", "NSURL", "NSError", "NSNotification",
         "NSView", "NSWindow", "NSButton", "NSColor", "NSFont", "NSApplication",
         "NSResponder", "NSControl", "NSTextField", "NSText", "NSTextView",
         "NSTextStorage", "NSScrollView", "NSSplitView", "NSTabView", "NSTabViewItem",
         "NSMenu", "NSMenuItem", "NSRulerView", "NSSearchField", "NSEvent",
         "NSSound", "NSAffineTransform", "AVMIDIPlayer"]
            .iter()
            .map(|s| s.to_string())
            .collect()
    } else {
        args
    };

    // Selector-database mode (data for the compiler's typed sends + validation).
    if std::env::var("COCOA_GEN_JSON").is_ok() {
        let bs = load_bridgesupport();
        emit_json(&rt, &classes, &bs);
        return;
    }

    let module = std::env::var("COCOA_GEN_MODULE").unwrap_or_else(|_| "CocoaNS".to_string());

    // Closure over the inheritance chains: each requested class drags in its
    // superclasses, so INHERIT has a target. Order base-first by chain depth.
    let mut chain_of = |start: &str| -> Vec<(String, *mut c_void, usize)> {
        let c0 = (rt.get_class)(CString::new(start).unwrap().as_ptr());
        if c0.is_null() {
            eprintln!("cocoa-gen: class not found: {start}");
            return Vec::new();
        }
        let mut v = Vec::new();
        let mut cur = c0;
        let mut depth_from_self = 0usize;
        while !cur.is_null() {
            let n =
                unsafe { CStr::from_ptr((rt.class_get_name)(cur)) }.to_string_lossy().into_owned();
            v.push((n, cur, depth_from_self));
            cur = (rt.superclass)(cur);
            depth_from_self += 1;
        }
        v
    };

    let mut by_name: std::collections::HashMap<String, (*mut c_void, usize)> =
        std::collections::HashMap::new();
    for c in &classes {
        let chain = chain_of(c);
        let n = chain.len();
        for (i, (name, cls, _)) in chain.into_iter().enumerate() {
            // depth-from-root = (chain length - 1 - index-from-self)
            let depth = n - 1 - i;
            by_name.entry(name).or_insert((cls, depth));
        }
    }
    let known: HashSet<String> = by_name.keys().cloned().collect();
    let mut ordered: Vec<(String, *mut c_void, usize)> =
        by_name.into_iter().map(|(k, (c, d))| (k, c, d)).collect();
    ordered.sort_by(|a, b| a.2.cmp(&b.2).then(a.0.cmp(&b.0))); // base-first, then name

    println!("DEFINITION MODULE {module};   (* generated by newm2-cocoa-gen — do not edit *)");
    println!("(* EXTERNAL declarations of AppKit/Foundation classes for typed M2 use. *)");
    println!("IMPORT ObjC;\n");
    // Cumulative method set per class (own ∪ ancestors), so a derived class never
    // re-declares an inherited method. Base-first order guarantees the
    // superclass's set is ready first.
    let mut cumulative: std::collections::HashMap<String, HashSet<String>> =
        std::collections::HashMap::new();
    for (name, cls, _) in &ordered {
        let super_cls = (rt.superclass)(*cls);
        let inherited = if super_cls.is_null() {
            HashSet::new()
        } else {
            let sn = unsafe { CStr::from_ptr((rt.class_get_name)(super_cls)) }
                .to_string_lossy()
                .into_owned();
            cumulative.get(&sn).cloned().unwrap_or_default()
        };
        let (decl, own) = gen_class(&rt, *cls, name, &known, &inherited);
        print!("{decl}");
        let mut cum = inherited;
        cum.extend(own);
        cumulative.insert(name.clone(), cum);
    }
    println!("END {module}.");
}
