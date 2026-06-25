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
use std::ffi::CStr;
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

/// `ObjC.GetString(nsstr, VAR dest)` — copy an `NSString`'s text into a (wide)
/// M2 `ARRAY OF CHAR`, NUL-terminated. Returns the number of code units written.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_objc_nsstring_to_wide(
    nsstr: *mut c_void,
    dest: *mut u16,
    dest_high: u64,
) -> u64 {
    if nsstr.is_null() || dest.is_null() {
        return 0;
    }
    let msg = sym_or_null("objc_msgSend");
    let reg = sym_or_null("sel_registerName");
    if msg.is_null() || reg.is_null() {
        return 0;
    }
    let reg: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(reg) };
    let send: extern "C" fn(*mut c_void, *mut c_void) -> *const i8 =
        unsafe { std::mem::transmute(msg) };
    let utf8 = send(nsstr, reg(c"UTF8String".as_ptr()));
    if utf8.is_null() {
        return 0;
    }
    let text = unsafe { CStr::from_ptr(utf8) }.to_string_lossy().into_owned();

    let cap = (dest_high as usize).saturating_add(1); // capacity in u16 units
    if cap == 0 {
        return 0;
    }
    let units: Vec<u16> = text.encode_utf16().collect();
    let n = units.len().min(cap - 1);
    for (i, &u) in units.iter().take(n).enumerate() {
        unsafe { *dest.add(i) = u };
    }
    unsafe { *dest.add(n) = 0 };
    n as u64
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

/// `ObjC.AllocateClass(super, name)` — begin defining a new Objective-C class
/// (`objc_allocateClassPair`). Add methods, then `RegisterClass`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_objc_allocate_class(
    superclass: *mut c_void,
    name: *const u16,
    high: u64,
) -> *mut c_void {
    bootstrap();
    let Some(c) = wide_to_cstring(name, high) else {
        return std::ptr::null_mut();
    };
    let f = sym_or_null("objc_allocateClassPair");
    if f.is_null() {
        return std::ptr::null_mut();
    }
    let f: extern "C" fn(*mut c_void, *const i8, usize) -> *mut c_void =
        unsafe { std::mem::transmute(f) };
    f(superclass, c.as_ptr(), 0)
}

/// `ObjC.AddMethod(cls, sel, imp, typeEncoding)` — install a method whose
/// implementation is `imp` (a plain C-ABI function — a module-level Modula-2
/// procedure works directly, since an Obj-C IMP is `ret (*)(id self, SEL _cmd, …)`).
/// `typeEncoding` is the Obj-C type string, e.g. "v@:@" for `-(void)act:(id)x`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_objc_add_method(
    cls: *mut c_void,
    sel: *mut c_void,
    imp: *mut c_void,
    types: *const u16,
    high: u64,
) -> i32 {
    let Some(c) = wide_to_cstring(types, high) else {
        return 0;
    };
    let f = sym_or_null("class_addMethod");
    if f.is_null() {
        return 0;
    }
    let f: extern "C" fn(*mut c_void, *mut c_void, *mut c_void, *const i8) -> i8 =
        unsafe { std::mem::transmute(f) };
    f(cls, sel, imp, c.as_ptr()) as i32
}

/// `ObjC.RegisterClass(cls)` — finalize a class begun with `AllocateClass`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_objc_register_class(cls: *mut c_void) {
    let f = sym_or_null("objc_registerClassPair");
    if f.is_null() {
        return;
    }
    let f: extern "C" fn(*mut c_void) = unsafe { std::mem::transmute(f) };
    f(cls);
}

/// An `NSRect` / `CGRect` — four CGFloat (f64) passed in v0–v3 on arm64.
#[repr(C)]
#[derive(Clone, Copy)]
struct NsRect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

/// `ObjC.SnapshotView(view, path)` — render an `NSView` (and its subviews)
/// offscreen into a bitmap and write it as a PNG. This works without a window
/// server (`cacheDisplayInRect:` draws into a CGBitmapContext), so a Cocoa UI
/// can be captured headlessly — the native way to *see* the UI. Returns nonzero
/// on success.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_cocoa_snapshot_view(
    view: *mut c_void,
    path: *const u16,
    path_high: u64,
) -> i32 {
    bootstrap();
    if view.is_null() {
        return 0;
    }
    let msg = sym_or_null("objc_msgSend");
    let reg = sym_or_null("sel_registerName");
    if msg.is_null() || reg.is_null() {
        return 0;
    }
    let sel = |s: &std::ffi::CStr| -> *mut c_void {
        let f: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(reg) };
        f(s.as_ptr())
    };

    // [view bounds] -> NSRect (struct return, x8-indirect on arm64).
    let send_rect_ret: extern "C" fn(*mut c_void, *mut c_void) -> NsRect =
        unsafe { std::mem::transmute(msg) };
    let bounds = send_rect_ret(view, sel(c"bounds"));
    if bounds.w < 1.0 || bounds.h < 1.0 {
        return 0;
    }

    // rep = [view bitmapImageRepForCachingDisplayInRect: bounds]
    let send_rect_arg: extern "C" fn(*mut c_void, *mut c_void, NsRect) -> *mut c_void =
        unsafe { std::mem::transmute(msg) };
    let rep = send_rect_arg(view, sel(c"bitmapImageRepForCachingDisplayInRect:"), bounds);
    if rep.is_null() {
        return 0;
    }

    // [view cacheDisplayInRect: bounds toBitmapImageRep: rep]
    let send_rect_rep: extern "C" fn(*mut c_void, *mut c_void, NsRect, *mut c_void) =
        unsafe { std::mem::transmute(msg) };
    send_rect_rep(view, sel(c"cacheDisplayInRect:toBitmapImageRep:"), bounds, rep);

    // data = [rep representationUsingType: NSBitmapImageFileTypePNG(4) properties: nil]
    let send_png: extern "C" fn(*mut c_void, *mut c_void, u64, *mut c_void) -> *mut c_void =
        unsafe { std::mem::transmute(msg) };
    let data = send_png(rep, sel(c"representationUsingType:properties:"), 4, std::ptr::null_mut());
    if data.is_null() {
        return 0;
    }

    // [data writeToFile: <NSString path> atomically: NO]
    let path_str = nm2_objc_nsstring(path, path_high);
    if path_str.is_null() {
        return 0;
    }
    let send_write: extern "C" fn(*mut c_void, *mut c_void, *mut c_void, bool) -> bool =
        unsafe { std::mem::transmute(msg) };
    let ok = send_write(data, sel(c"writeToFile:atomically:"), path_str, false);
    if ok { 1 } else { 0 }
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
