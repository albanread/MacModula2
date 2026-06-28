//! The Cocoa selector database (extension 3) — data that drives typed Objective-C
//! message sends and selector validation. Two interchangeable backends behind one
//! interface:
//!
//!   * the shared **SQLite mirror** `cocoa_data/cocoa.sqlite` (preferred) — selectors
//!     are resolved lazily from `rt_methods`, reducing each raw `@encode` to a return
//!     kind with the shared layout parser. Pointed to by `$MACM2_COCOA_DB`, or a
//!     `cocoa.sqlite` sitting next to the JSON.
//!   * the legacy **line-parsed JSON** `cocoa-selectors.json` (fallback) — loaded
//!     whole into a map; used when no SQLite mirror is present.
//!
//! Return kinds: @ id/ptr · : SEL · i int · u uint · d real · B bool · v void ·
//! N/P/S/R the named geometry structs · `{…}` a synthesizable struct descriptor.

use crate::sqlite::Sqlite;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Debug, Clone)]
pub struct SelSig {
    pub ret: String,
    pub argc: usize,
}

#[derive(Default)]
pub struct CocoaDb {
    /// Eager map (JSON backend); empty when the SQLite backend is active.
    pub selectors: HashMap<String, SelSig>,
    pub classes: HashSet<String>,
    backend: Option<Sqlite>,
    /// Memoizes lazy SQLite lookups (only the selectors a compile actually touches).
    cache: Mutex<HashMap<String, Option<SelSig>>>,
}

impl CocoaDb {
    /// Load the database: prefer the SQLite mirror, else the JSON at `json_path`.
    /// A missing/unreadable source yields an empty database (sends fall back to an
    /// `id` result, the pre-extension-3 behaviour) so non-Cocoa builds are unaffected.
    pub fn load(json_path: &Path) -> CocoaDb {
        if let Some(p) = sqlite_path(json_path) {
            if let Some(db) = Self::load_sqlite(&p) {
                return db;
            }
        }
        Self::load_json(json_path)
    }

    fn load_sqlite(path: &Path) -> Option<CocoaDb> {
        let conn = Sqlite::open(path)?;
        let classes: HashSet<String> =
            conn.query_all("SELECT name FROM rt_classes").into_iter().collect();
        if classes.is_empty() {
            return None; // wrong schema / empty file — fall back to JSON
        }
        Some(CocoaDb {
            selectors: HashMap::new(),
            classes,
            backend: Some(conn),
            cache: Mutex::new(HashMap::new()),
        })
    }

    fn load_json(path: &Path) -> CocoaDb {
        let mut db = CocoaDb::default();
        let Ok(text) = std::fs::read_to_string(path) else {
            return db;
        };
        for line in text.lines() {
            let t = line.trim();
            if t.starts_with("\"classes\":") {
                for (i, seg) in t.split('"').enumerate() {
                    if i >= 3 && i % 2 == 1 {
                        db.classes.insert(seg.to_string());
                    }
                }
                continue;
            }
            if let Some((sel, sig)) = parse_selector_line(t) {
                db.selectors.insert(sel, sig);
            }
        }
        db
    }

    pub fn lookup(&self, selector: &str) -> Option<SelSig> {
        if let Some(be) = &self.backend {
            if let Some(hit) = self.cache.lock().unwrap().get(selector) {
                return hit.clone();
            }
            let sig = backend_lookup(be, selector);
            self.cache.lock().unwrap().insert(selector.to_string(), sig.clone());
            return sig;
        }
        self.selectors.get(selector).cloned()
    }

    pub fn is_empty(&self) -> bool {
        self.backend.is_none() && self.selectors.is_empty()
    }
}

/// Where to find the SQLite mirror: `$MACM2_COCOA_DB`, else a `cocoa.sqlite`
/// sitting beside the JSON.
fn sqlite_path(json_path: &Path) -> Option<PathBuf> {
    if let Ok(p) = std::env::var("MACM2_COCOA_DB") {
        let pb = PathBuf::from(p);
        if pb.exists() {
            return Some(pb);
        }
    }
    let sibling = json_path.with_file_name("cocoa.sqlite");
    sibling.exists().then_some(sibling)
}

/// Resolve one selector against `rt_methods`: take its most common raw encoding and
/// reduce it to a return kind. Argument count comes from the selector's colons.
fn backend_lookup(be: &Sqlite, selector: &str) -> Option<SelSig> {
    // The *most common* encoding across the classes that declare this selector.
    // A plain LIMIT 1 (arbitrary row) is faster but mis-resolves selectors whose
    // first-stored class is atypical — it regressed the IDE. The cost is moot: a
    // build issues only tens of these (lazy + cached), ~ms total, dwarfed by codegen.
    let enc = be.query_one(
        "SELECT encoding FROM rt_methods WHERE selector=?1 \
         GROUP BY encoding ORDER BY count(*) DESC LIMIT 1",
        Some(selector),
    )?;
    Some(SelSig { ret: reduce_ret(&enc), argc: selector.matches(':').count() })
}

/// Reduce a raw method `@encode` to the database's return-kind string, matching the
/// generator's mapping: scalars → kind chars, named geometry → N/P/S/R, other
/// structs → their raw encoding descriptor (which sema synthesizes a record from).
fn reduce_ret(encoding: &str) -> String {
    use newm2_cocoa_encoding as enc;
    match enc::parse(encoding) {
        enc::Ty::Scalar(s) => scalar_kind(s).to_string(),
        enc::Ty::Pointer => "@".to_string(),
        enc::Ty::Struct { name, .. } => geometry(name.as_deref())
            .map(str::to_string)
            .or_else(|| leading_brace(encoding))
            .unwrap_or_else(|| "{".to_string()),
        _ => {
            if encoding.starts_with('v') {
                "v".to_string()
            } else {
                "@".to_string()
            }
        }
    }
}

fn scalar_kind(s: newm2_cocoa_encoding::Scalar) -> &'static str {
    use newm2_cocoa_encoding::Scalar::*;
    match s {
        I8 | I16 | I32 | I64 => "i",
        U8 | U16 | U32 | U64 => "u",
        F32 | F64 => "d",
        Bool => "B",
        Ptr => "@",
    }
}

fn geometry(name: Option<&str>) -> Option<&'static str> {
    Some(match name? {
        "CGRect" | "NSRect" => "R",
        "CGPoint" | "NSPoint" => "P",
        "CGSize" | "NSSize" => "S",
        "NSRange" | "_NSRange" => "N",
        _ => return None,
    })
}

/// The leading balanced `{…}` group of a method encoding — the return struct's own
/// encoding (drops the trailing offset digits + argument tokens).
fn leading_brace(s: &str) -> Option<String> {
    let b = s.as_bytes();
    if b.first() != Some(&b'{') {
        return None;
    }
    let mut depth = 0;
    for (i, &c) in b.iter().enumerate() {
        match c {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(s[..=i].to_string());
                }
            }
            _ => {}
        }
    }
    None
}

/// Parse one JSON selector entry: `"sel": {"ret": "R", "args": ["x", …]}`.
fn parse_selector_line(t: &str) -> Option<(String, SelSig)> {
    let rest = t.strip_prefix('"')?;
    const MID: &str = "\": {\"ret\": \"";
    let q = rest.find(MID)?;
    let sel = rest[..q].to_string();
    let after = &rest[q + MID.len()..];
    let rq = after.find('"')?;
    let ret = after[..rq].to_string();
    let argc = match after.find("\"args\": [") {
        Some(ai) => {
            let arr = &after[ai + "\"args\": [".len()..];
            let end = arr.find(']').unwrap_or(0);
            arr[..end].matches('"').count() / 2
        }
        None => 0,
    };
    Some((sel, SelSig { ret, argc }))
}
