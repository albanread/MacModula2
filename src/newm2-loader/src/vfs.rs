//! Where the loader's files come from. Normally the host's file system;
//! a host that has another (the BOX: a program's own modules are found
//! through RISC OS, design/BOX_PORT.md) installs hooks that answer for
//! the paths they own.

use std::path::Path;
use std::sync::RwLock;

/// `is_file` and `read` for the paths a hook owns: `None` hands the path
/// back to the host's file system.
pub struct Hooks {
    pub is_file: fn(&Path) -> Option<bool>,
    pub read: fn(&Path) -> Option<std::io::Result<Vec<u8>>>,
}

static HOOKS: RwLock<Option<Hooks>> = RwLock::new(None);

pub fn set_hooks(h: Option<Hooks>) {
    *HOOKS.write().unwrap() = h;
}

pub fn is_file(p: &Path) -> bool {
    if let Some(h) = HOOKS.read().unwrap().as_ref() {
        if let Some(r) = (h.is_file)(p) {
            return r;
        }
    }
    p.is_file()
}

pub fn read(p: &Path) -> std::io::Result<Vec<u8>> {
    if let Some(h) = HOOKS.read().unwrap().as_ref() {
        if let Some(r) = (h.read)(p) {
            return r;
        }
    }
    std::fs::read(p)
}
