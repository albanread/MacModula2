//! Module search-path resolution.
//!
//! The search path is a list of directories scanned in order. For a
//! given module name `Foo`, the loader looks for `Foo.def` in each
//! directory and uses the first match. The implementation file is
//! found by:
//!  1. `<same-dir>/Foo.mod`, or
//!  2. the sibling directory where the last `def` path component is
//!     replaced by `mod` (e.g. `isodef/Foo.def` → `isomod/Foo.mod`,
//!     `def/Foo.def` → `mod/Foo.mod`).

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default)]
pub struct SearchPath {
    entries: Vec<PathBuf>,
}

impl SearchPath {
    pub fn new() -> Self {
        Self { entries: Vec::new() }
    }

    pub fn push(&mut self, dir: impl Into<PathBuf>) {
        self.entries.push(dir.into());
    }

    pub fn entries(&self) -> &[PathBuf] {
        &self.entries
    }

    /// Find a module's DEF file by walking the search path. Returns
    /// the first match.
    pub fn find_def(&self, module: &str) -> Option<PathBuf> {
        // A hand-written `<Module>.def` takes precedence GLOBALLY over a
        // generated `<Module>_types.def` (our own Win32 API defs under
        // `library/NewM2`, and the reduced windows_api snapshot) — not just
        // within whichever directory happens to be checked first. Two full
        // passes, not one interleaved pass per directory: the old
        // per-directory interleaving let an EARLIER directory's generated
        // `_types.def` win over a LATER directory's hand-written `.def`,
        // contradicting this very doc comment (and silently using the
        // generated/reduced shape instead of the authoritative one).
        for dir in &self.entries {
            let p = dir.join(format!("{module}.def"));
            if p.is_file() {
                return Some(p);
            }
        }
        for dir in &self.entries {
            let p = dir.join(format!("{module}_types.def"));
            if p.is_file() {
                return Some(p);
            }
        }
        None
    }

    /// Given a DEF path, locate the matching IMPLEMENTATION MODULE
    /// source. Returns None when the body isn't present in the search
    /// tree (e.g. for compiler-provided / runtime-implemented modules).
    pub fn find_impl_for_def(&self, def_path: &Path) -> Option<PathBuf> {
        // Strategy 1: same directory, .mod extension.
        let mut candidate = def_path.to_path_buf();
        candidate.set_extension("mod");
        if candidate.is_file() {
            return Some(candidate);
        }
        // Strategy 2: sibling directory rewriting *def → *mod in the
        // immediate parent name (isodef → isomod, def → mod, …).
        let parent = def_path.parent()?;
        let parent_name = parent.file_name()?.to_str()?;
        if !parent_name.ends_with("def") {
            return None;
        }
        let sibling = format!("{}mod", &parent_name[..parent_name.len() - 3]);
        let basename = def_path.file_stem()?;
        let alt = parent.parent()?.join(&sibling).join(format!(
            "{}.mod",
            basename.to_str()?
        ));
        if alt.is_file() { Some(alt) } else { None }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// A scratch directory removed on drop — avoids a tempfile dependency
    /// just for this one test module.
    struct ScratchDir(PathBuf);
    impl ScratchDir {
        fn new(tag: &str) -> Self {
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let n = COUNTER.fetch_add(1, Ordering::Relaxed);
            let dir = std::env::temp_dir()
                .join(format!("newm2-search-path-test-{tag}-{}-{n}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            ScratchDir(dir)
        }
        fn subdir(&self, name: &str) -> PathBuf {
            let p = self.0.join(name);
            std::fs::create_dir_all(&p).unwrap();
            p
        }
    }
    impl Drop for ScratchDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn hand_written_def_wins_globally_over_a_generated_one_in_an_earlier_dir() {
        // Regression: dirA (earlier on the path) has only a generated
        // Foo_types.def; dirB (later) has the hand-written Foo.def. The
        // doc-commented intent ("a hand-written .def takes precedence") must
        // hold globally, not just within whichever directory is checked
        // first.
        let scratch = ScratchDir::new("precedence");
        let dir_a = scratch.subdir("a");
        let dir_b = scratch.subdir("b");
        std::fs::write(dir_a.join("Foo_types.def"), "(* generated *)").unwrap();
        std::fs::write(dir_b.join("Foo.def"), "(* hand-written *)").unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir_a);
        sp.push(&dir_b);

        let found = sp.find_def("Foo").expect("Foo should resolve");
        assert_eq!(found, dir_b.join("Foo.def"), "the hand-written def must win, from either directory");
    }

    #[test]
    fn generated_def_is_still_used_as_a_fallback_when_no_hand_written_one_exists() {
        let scratch = ScratchDir::new("fallback");
        let dir_a = scratch.subdir("a");
        std::fs::write(dir_a.join("Foo_types.def"), "(* generated *)").unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir_a);

        assert_eq!(sp.find_def("Foo"), Some(dir_a.join("Foo_types.def")));
    }

    #[test]
    fn earlier_directorys_hand_written_def_still_wins_over_a_later_one() {
        // Precedence among directories, for the SAME filename, is still
        // "earlier wins" — only the .def-vs-_types.def priority became global.
        let scratch = ScratchDir::new("dir-order");
        let dir_a = scratch.subdir("a");
        let dir_b = scratch.subdir("b");
        std::fs::write(dir_a.join("Foo.def"), "(* a *)").unwrap();
        std::fs::write(dir_b.join("Foo.def"), "(* b *)").unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir_a);
        sp.push(&dir_b);

        assert_eq!(sp.find_def("Foo"), Some(dir_a.join("Foo.def")));
    }
}
