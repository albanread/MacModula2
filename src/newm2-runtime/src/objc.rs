//! macOS Objective-C runtime bridge.
//!
//! The native equivalent of the Windows build's COM layer. Where Windows
//! dispatches through `@ordinal`-checked vtables, macOS frameworks (AppKit,
//! Foundation, …) dispatch through Objective-C message sends. This module gives
//! Modula-2 the primitives that underpin every message send:
//!
//!   * `objc_getClass(name)`      — look up a class by name
//!   * `sel_registerName(name)`   — intern a selector
//!   * `objc_msgSend`             — send a message; M2 takes its address and
//!                                  calls it through a typed PROCEDURE so each
//!                                  call site carries its own ABI signature
//!                                  (exactly how COM call through a vtable slot).
//!
//! Everything is resolved through `dlsym` at runtime so the host (driver / JIT)
//! gains no static link dependency on libobjc; `bootstrap()` `dlopen`s the
//! umbrella frameworks first so the classes and exports are present.
//!
//! Class and selector names are ASCII C strings, but `ARRAY OF CHAR` is UTF-16
//! on this toolchain, so the two name-taking entry points transcode at the
//! boundary. They take the open-array ABI `(ptr, high)` and read up to the
//! first NUL.

#![cfg(not(windows))]

use core::ffi::c_void;
use std::ffi::CString;
use std::sync::OnceLock;

const RTLD_DEFAULT: *mut c_void = (-2isize) as *mut c_void;
const RTLD_NOW: i32 = 0x2;

unsafe extern "C" {
    fn dlopen(path: *const i8, mode: i32) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const i8) -> *mut c_void;
}

/// Map the umbrella frameworks into the process so libobjc, the `NS*` classes,
/// and the AppKit/Foundation/CoreGraphics exports resolve via
/// `dlsym(RTLD_DEFAULT, …)`. Idempotent; runs once.
pub fn bootstrap() {
    static ONCE: OnceLock<()> = OnceLock::new();
    ONCE.get_or_init(|| {
        for path in [
            "/System/Library/Frameworks/Cocoa.framework/Cocoa",
            "/System/Library/Frameworks/AppKit.framework/AppKit",
            "/System/Library/Frameworks/Foundation.framework/Foundation",
            "/usr/lib/libobjc.A.dylib",
        ] {
            if let Ok(c) = CString::new(path) {
                unsafe { dlopen(c.as_ptr(), RTLD_NOW) };
            }
        }
    });
}

/// Resolve a symbol by name across everything loaded into the process — the
/// macOS analogue of the Windows build's DLL-probing external resolver. After
/// `bootstrap()`, every libSystem / libobjc / framework C entry point
/// (`objc_msgSend`, `CGColorCreate`, `CFRelease`, …) resolves here.
pub fn dlsym_default(name: &str) -> Option<*const ()> {
    bootstrap();
    let c = CString::new(name).ok()?;
    let p = unsafe { dlsym(RTLD_DEFAULT, c.as_ptr()) };
    if p.is_null() { None } else { Some(p as *const ()) }
}

fn sym_or_null(name: &str) -> *mut c_void {
    dlsym_default(name).map(|p| p as *mut c_void).unwrap_or(std::ptr::null_mut())
}

/// UTF-16 open array `(ptr, high)` → UTF-8 C string, stopping at the first NUL.
fn wide_to_cstring(ptr: *const u16, high: u64) -> Option<CString> {
    if ptr.is_null() {
        return None;
    }
    // `high` is HIGH(arr) = len-1; allow a generous bound and stop at NUL.
    let cap = (high as usize).saturating_add(1).min(4096);
    let units = unsafe { std::slice::from_raw_parts(ptr, cap) };
    let end = units.iter().position(|&u| u == 0).unwrap_or(units.len());
    let s = String::from_utf16_lossy(&units[..end]);
    CString::new(s).ok()
}

/// `ObjC.GetClass(name)` — look up an Objective-C class by (wide) name.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_objc_get_class(name: *const u16, high: u64) -> *mut c_void {
    let Some(c) = wide_to_cstring(name, high) else {
        return std::ptr::null_mut();
    };
    let f = sym_or_null("objc_getClass");
    if f.is_null() {
        return std::ptr::null_mut();
    }
    let f: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(f) };
    f(c.as_ptr())
}

/// `ObjC.Selector(name)` — intern a selector from a (wide) name.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_objc_sel(name: *const u16, high: u64) -> *mut c_void {
    let Some(c) = wide_to_cstring(name, high) else {
        return std::ptr::null_mut();
    };
    let f = sym_or_null("sel_registerName");
    if f.is_null() {
        return std::ptr::null_mut();
    }
    let f: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(f) };
    f(c.as_ptr())
}

/// `ObjC.MsgSendPtr()` — the address of `objc_msgSend`, which M2 casts to a
/// typed PROCEDURE and calls indirectly (per-call-site ABI).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_objc_msgsend_ptr() -> *mut c_void {
    sym_or_null("objc_msgSend")
}

/// `ObjC.NSString(s)` — build an autoreleased `NSString*` from a (wide) M2
/// string via `+[NSString stringWithUTF8String:]`. Returns an `id`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_objc_nsstring(name: *const u16, high: u64) -> *mut c_void {
    let Some(c) = wide_to_cstring(name, high) else {
        return std::ptr::null_mut();
    };
    let get_class = sym_or_null("objc_getClass");
    let reg_sel = sym_or_null("sel_registerName");
    let msg_send = sym_or_null("objc_msgSend");
    if get_class.is_null() || reg_sel.is_null() || msg_send.is_null() {
        return std::ptr::null_mut();
    }
    let get_class: extern "C" fn(*const i8) -> *mut c_void =
        unsafe { std::mem::transmute(get_class) };
    let reg_sel: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(reg_sel) };
    let send: extern "C" fn(*mut c_void, *mut c_void, *const i8) -> *mut c_void =
        unsafe { std::mem::transmute(msg_send) };

    let cls = get_class(c"NSString".as_ptr());
    let sel = reg_sel(c"stringWithUTF8String:".as_ptr());
    if cls.is_null() || sel.is_null() {
        return std::ptr::null_mut();
    }
    send(cls, sel, c.as_ptr())
}

/// `ObjC.Pump(seconds)` — run the Core Foundation run loop in the default mode
/// for `seconds`, so a window appears and events are processed without blocking
/// forever (the native, bounded substitute for `[NSApp run]` in a demo/test).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_objc_pump(seconds: f64) {
    bootstrap();
    // kCFRunLoopDefaultMode is a CFStringRef* data export.
    let mode_var = sym_or_null("kCFRunLoopDefaultMode") as *const *const c_void;
    let run_fn = sym_or_null("CFRunLoopRunInMode");
    if mode_var.is_null() || run_fn.is_null() {
        return;
    }
    let mode = unsafe { *mode_var };
    // CFRunLoopRunInMode(mode: CFStringRef, seconds: f64, returnAfterSourceHandled: bool) -> i32
    let run: extern "C" fn(*const c_void, f64, u8) -> i32 = unsafe { std::mem::transmute(run_fn) };
    let _ = run(mode, seconds, 0);
}
