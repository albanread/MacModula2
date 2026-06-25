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
    ] {
        let c = CString::new(fw).unwrap();
        unsafe { dlopen(c.as_ptr(), 2 /*RTLD_NOW*/) };
    }
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

    let mut emitted: Vec<Method> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut skipped = 0u32;
    let mut count: u32 = 0;
    let methods = (rt.copy_methods)(cls, &mut count);
    let method_ptrs: Vec<*mut c_void> =
        (0..count as isize).map(|k| unsafe { *methods.offset(k) }).collect();
    for m in method_ptrs {
        let sel = (rt.method_get_name)(m);
        let sel_name = unsafe { CStr::from_ptr((rt.sel_get_name)(sel)) }.to_string_lossy().into_owned();
        let enc = unsafe { CStr::from_ptr((rt.method_get_types)(m)) }.to_string_lossy().into_owned();
        // skip private / category-injected selectors (the runtime returns every
        // method, including ones other frameworks graft on via categories).
        // Underscores flag private/category conventions; '.' flags property ivars.
        if sel_name.starts_with('_') || sel_name.contains('_') || sel_name.contains('.') {
            continue;
        }
        let toks = tokenize(&enc);
        // toks: [ret, @(self), :(cmd), args...]
        if toks.len() < 3 {
            skipped += 1;
            continue;
        }
        let ret = if toks[0] == "v" { None } else { Some(toks[0].as_str()) };
        let ret_m2 = match ret {
            None => None,
            Some(t) => match m2_type(t) {
                Some(m) => Some(m),
                None => {
                    skipped += 1;
                    continue;
                }
            },
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
        if !ok {
            skipped += 1;
            continue;
        }
        // arity must match the selector's colon count
        if params.len() != sel_name.matches(':').count() {
            skipped += 1;
            continue;
        }
        let mname = method_name(&sel_name);
        if mname.is_empty()
            || M2_KEYWORDS.contains(&mname.as_str())
            || inherited.contains(&mname)        // already declared by an ancestor
            || !seen.insert(mname.clone())
        {
            skipped += 1;
            continue;
        }
        emitted.push(Method { name: mname, selector: sel_name, ret: ret_m2, params });
    }
    emitted.sort_by(|a, b| a.name.cmp(&b.name));

    let mut out = String::new();
    out.push_str(&format!("CLASS {name};\n"));
    // INHERIT must precede any class member (the parser parses it right after the
    // header); the cocoa_class pragma and methods follow.
    if let Some(s) = &super_name {
        out.push_str(&format!("  INHERIT {s};\n"));
    }
    out.push_str(&format!("  <* cocoa_class \"{name}\" *>\n"));
    for m in &emitted {
        let ps: Vec<String> =
            m.params.iter().enumerate().map(|(i, t)| format!("a{i}: {t}")).collect();
        let params = format!(" ({})", ps.join("; "));
        let ret = m.ret.map(|t| format!(": {t}")).unwrap_or_default();
        out.push_str(&format!(
            "  ABSTRACT PROCEDURE {}{}{} <* selector \"{}\" *>;\n",
            m.name, params, ret, m.selector
        ));
    }
    out.push_str(&format!("END {name};\n"));
    out.push_str(&format!("  (* {} own methods; {skipped} skipped *)\n\n", emitted.len()));
    let own_names: HashSet<String> = emitted.iter().map(|m| m.name.clone()).collect();
    (out, own_names)
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
    };

    // Classes to generate: CLI args, or a default curated set.
    let args: Vec<String> = std::env::args().skip(1).collect();
    let classes: Vec<String> = if args.is_empty() {
        ["NSObject", "NSString", "NSArray", "NSMutableArray", "NSDictionary",
         "NSMutableDictionary", "NSNumber", "NSView", "NSWindow", "NSButton",
         "NSColor", "NSApplication"]
            .iter()
            .map(|s| s.to_string())
            .collect()
    } else {
        args
    };

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
