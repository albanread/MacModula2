//! The BOX (64-bit RISC OS over Linux; design/BOX_PORT.md): the runtime's
//! way out to RISC OS. The runtime is linked into the box's `/init`, so it
//! must never touch the process's own stdin/stdout or exit it: the module
//! that runs programs (rosgd `modules/modula2`) gives hooks, and the
//! terminal, file and SWI paths of the runtime go through them.
//!
//! Escape: the module sets the stop flag (from its write/read/SWI hooks);
//! the runtime looks at it after each hook call and ends the program as
//! `HALT` does, so FINALLY parts and module finalizers still run.

use std::ffi::{c_char, c_int, c_void, CStr};
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};

/// The hooks, as `m2_box.h` declares them.
#[repr(C)]
pub struct Hooks {
    /// Bytes for the VDU (Latin-1; "\n" is a new line).
    pub write: Option<unsafe extern "C" fn(*const u8, usize)>,
    /// A line of input (no terminator) into buf: its length, or -1 at the
    /// end of the input (Escape).
    pub read: Option<unsafe extern "C" fn(*mut u8, usize) -> isize>,
    /// SWI `number` (the X form) with r[0..9] in and out; *flags gets
    /// N Z C V as bits 3-0. An error: its number in *errnum and its block's
    /// address returned; else 0.
    pub swi: Option<unsafe extern "C" fn(u32, *mut u32, *mut u32, *mut u32) -> u32>,
    /// A SWI's number from its name: 0 if known, else -1.
    pub swi_number: Option<unsafe extern "C" fn(*const c_char, *mut u32) -> c_int>,
    /// A RISC OS file's bytes (malloc'd, freed with libc free) or NULL.
    pub file_load: Option<unsafe extern "C" fn(*const c_char, *mut usize) -> *mut u8>,
    /// 0 nothing, 1 a file, 2 a directory (OS_File 17's object type).
    pub file_kind: Option<unsafe extern "C" fn(*const c_char) -> c_int>,
    /// Memory in the arena (RISC OS addresses), for the program's data:
    /// grows the run's dynamic area by n bytes and returns the old end, or
    /// 0 when it cannot. The area is made at the first call and removed
    /// by the module when the run ends.
    pub arena_grow: Option<unsafe extern "C" fn(usize) -> usize>,
}

static HOOKS: AtomicPtr<Hooks> = AtomicPtr::new(std::ptr::null_mut());
static STOP: AtomicBool = AtomicBool::new(false);

pub fn set_hooks(h: *const Hooks) {
    HOOKS.store(h as *mut Hooks, Ordering::SeqCst);
}

pub fn hooks() -> Option<&'static Hooks> {
    let p = HOOKS.load(Ordering::SeqCst);
    if p.is_null() { None } else { Some(unsafe { &*p }) }
}

/// Escape was seen: the program ends at the next hook call.
pub fn request_stop() {
    STOP.store(true, Ordering::SeqCst);
}

pub fn clear_stop() {
    STOP.store(false, Ordering::SeqCst);
}

/// Ends the program (as HALT does) if Escape was seen.
pub fn check_stop() {
    if STOP.swap(false, Ordering::SeqCst) {
        crate::termination::nm2_halt(17);
    }
}

/// UTF-8 text to the VDU as Latin-1 (a character above 255 is "?").
pub fn write_str(s: &str) {
    let Some(w) = hooks().and_then(|h| h.write) else { return };
    let bytes: Vec<u8> = s.chars().map(|c| if (c as u32) < 256 { c as u32 as u8 } else { b'?' }).collect();
    unsafe { w(bytes.as_ptr(), bytes.len()) };
    check_stop();
}

pub fn write_bytes(b: &[u8]) {
    if let Some(w) = hooks().and_then(|h| h.write) {
        unsafe { w(b.as_ptr(), b.len()) };
    }
    check_stop();
}

/// A line of input with its "\n", or None at the end of the input.
pub fn read_line() -> Option<Vec<u8>> {
    let r = hooks().and_then(|h| h.read)?;
    let mut buf = vec![0u8; 1024];
    let n = unsafe { r(buf.as_mut_ptr(), buf.len()) };
    check_stop();
    if n < 0 {
        return None;
    }
    buf.truncate(n as usize);
    buf.push(b'\n');
    Some(buf)
}

/// Calls a SWI (always the X form). Ok(flags) or Err(error block address).
pub fn swi(number: u32, r: &mut [u32; 10]) -> Result<u32, u32> {
    let Some(f) = hooks().and_then(|h| h.swi) else { return Err(0) };
    let mut flags = 0u32;
    let mut errnum = 0u32;
    let e = unsafe { f(number, r.as_mut_ptr(), &mut flags, &mut errnum) };
    check_stop();
    if flags & 1 != 0 { Err(e) } else { Ok(flags) }
}

pub fn swi_number(name: &str) -> Option<u32> {
    let f = hooks().and_then(|h| h.swi_number)?;
    let c = std::ffi::CString::new(name).ok()?;
    let mut n = 0u32;
    (unsafe { f(c.as_ptr(), &mut n) } == 0).then_some(n)
}

pub fn file_load(name: &str) -> Option<Vec<u8>> {
    let f = hooks().and_then(|h| h.file_load)?;
    let c = std::ffi::CString::new(name).ok()?;
    let mut n = 0usize;
    let p = unsafe { f(c.as_ptr(), &mut n) };
    if p.is_null() {
        return None;
    }
    let v = unsafe { std::slice::from_raw_parts(p, n) }.to_vec();
    unsafe { libc::free(p as *mut c_void) };
    Some(v)
}

pub fn file_kind(name: &str) -> i32 {
    let Some(f) = hooks().and_then(|h| h.file_kind) else { return 0 };
    let Ok(c) = std::ffi::CString::new(name) else { return 0 };
    unsafe { f(c.as_ptr()) }
}

/// The text of a RISC OS error block at `e` (a RISC OS address).
pub fn error_text(e: u32) -> String {
    if e == 0 {
        return "no SWI handler".into();
    }
    let p = (e as usize + 4) as *const c_char;
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

pub fn error_number(e: u32) -> u32 {
    if e == 0 { 0 } else { unsafe { *(e as usize as *const u32) } }
}

// ── The program's data in the arena ──────────────────────────────────────
//
// dlmalloc over the run's dynamic area: NEW, Storage.ALLOCATE and the JIT's
// data sections get RISC OS addresses, so the program can hand them to
// SWIs. The area only grows during a run; `arena_reset` forgets it when the
// module has removed it.

struct ArenaSys;

unsafe impl dlmalloc::Allocator for ArenaSys {
    fn alloc(&self, size: usize) -> (*mut u8, usize, u32) {
        let Some(g) = hooks().and_then(|h| h.arena_grow) else { return (std::ptr::null_mut(), 0, 0) };
        let size = (size + 0xFFFF) & !0xFFFF;
        let base = unsafe { g(size) };
        if base == 0 { (std::ptr::null_mut(), 0, 0) } else { (base as *mut u8, size, 0) }
    }
    fn remap(&self, _: *mut u8, _: usize, _: usize, _: bool) -> *mut u8 {
        std::ptr::null_mut()
    }
    fn free_part(&self, _: *mut u8, _: usize, _: usize) -> bool {
        false
    }
    fn free(&self, _: *mut u8, _: usize) -> bool {
        false
    }
    fn can_release_part(&self, _: u32) -> bool {
        false
    }
    fn allocates_zeros(&self) -> bool {
        false
    }
    fn page_size(&self) -> usize {
        4096
    }
}

static ARENA: std::sync::Mutex<Option<dlmalloc::Dlmalloc<ArenaSys>>> = std::sync::Mutex::new(None);

/// `n` bytes aligned to `align` in the arena, or null.
pub fn arena_alloc(n: usize, align: usize) -> *mut u8 {
    let mut g = ARENA.lock().unwrap();
    let d = g.get_or_insert_with(|| dlmalloc::Dlmalloc::new_with_allocator(ArenaSys));
    unsafe { d.malloc(n.max(1), align.max(16)) }
}

pub fn arena_free(p: *mut u8, n: usize, align: usize) {
    if p.is_null() {
        return;
    }
    let mut g = ARENA.lock().unwrap();
    if let Some(d) = g.as_mut() {
        unsafe { d.free(p, n.max(1), align.max(16)) };
    }
}

/// Whether the arena allocator is in use (a hook to grow it is set).
pub fn arena_on() -> bool {
    hooks().and_then(|h| h.arena_grow).is_some()
}

/// The run is over and its dynamic area gone: forget the allocator's state.
pub fn arena_reset() {
    let mut g = ARENA.lock().unwrap();
    if let Some(d) = g.take() {
        std::mem::forget(d); // its memory was the area's
    }
}
