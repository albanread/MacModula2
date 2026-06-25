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

/// `ObjC.Highlight(textview)` — syntax-color an NSTextView's content using the
/// NewM2 lexer: keywords, string/char literals, numbers, pragmas, and comments
/// each get a colour. Re-runnable. Byte offsets map to NSString (UTF-16) indices
/// directly for ASCII source (the common case for M2).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_ide_highlight(textview: *mut c_void) {
    bootstrap();
    if textview.is_null() {
        return;
    }
    let msg = sym_or_null("objc_msgSend");
    let reg = sym_or_null("sel_registerName");
    let getcls = sym_or_null("objc_getClass");
    if msg.is_null() || reg.is_null() || getcls.is_null() {
        return;
    }
    let reg: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(reg) };
    let getcls: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(getcls) };
    let send0: extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
        unsafe { std::mem::transmute(msg) };
    let send_str: extern "C" fn(*mut c_void, *mut c_void) -> *const i8 =
        unsafe { std::mem::transmute(msg) };
    let add_attr: extern "C" fn(*mut c_void, *mut c_void, *mut c_void, *mut c_void, u64, u64) =
        unsafe { std::mem::transmute(msg) };

    let s = send0(textview, reg(c"string".as_ptr()));
    if s.is_null() {
        return;
    }
    let utf8 = send_str(s, reg(c"UTF8String".as_ptr()));
    if utf8.is_null() {
        return;
    }
    let src = unsafe { CStr::from_ptr(utf8) }.to_string_lossy().into_owned();

    let storage = send0(textview, reg(c"textStorage".as_ptr()));
    if storage.is_null() {
        return;
    }
    let fg_var = sym_or_null("NSForegroundColorAttributeName") as *const *mut c_void;
    if fg_var.is_null() {
        return;
    }
    let fg = unsafe { *fg_var };

    let nscolor = getcls(c"NSColor".as_ptr());
    let color = |name: &CStr| -> *mut c_void { send0(nscolor, reg(name.as_ptr())) };
    let c_default = color(c"textColor");
    let c_keyword = color(c"systemBlueColor");
    let c_string = color(c"systemRedColor");
    let c_number = color(c"systemPurpleColor");
    let c_pragma = color(c"systemTealColor");
    let c_comment = color(c"systemGreenColor");

    let add_sel = reg(c"addAttribute:value:range:".as_ptr());
    let utf16_len = src.encode_utf16().count() as u64;
    add_attr(storage, add_sel, fg, c_default, 0, utf16_len);

    let apply = |start: usize, end: usize, col: *mut c_void| {
        if col.is_null() || end <= start {
            return;
        }
        add_attr(storage, add_sel, fg, col, start as u64, (end - start) as u64);
    };

    // Comments (the lexer strips them): scan (* ... *) with nesting.
    let bytes = src.as_bytes();
    let mut i = 0usize;
    while i + 1 < bytes.len() {
        if bytes[i] == b'(' && bytes[i + 1] == b'*' {
            let start = i;
            let mut depth = 1usize;
            i += 2;
            while i + 1 < bytes.len() && depth > 0 {
                if bytes[i] == b'(' && bytes[i + 1] == b'*' {
                    depth += 1;
                    i += 2;
                } else if bytes[i] == b'*' && bytes[i + 1] == b')' {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            apply(start, i, c_comment);
        } else {
            i += 1;
        }
    }

    if let Ok(tokens) = newm2_lexer::tokenize(&src) {
        for t in &tokens {
            use newm2_lexer::TokenKind::*;
            let col = match &t.kind {
                Keyword(_) => c_keyword,
                String(_) | Char(_) => c_string,
                Integer(_) | Real(_) => c_number,
                Pragma(_) => c_pragma,
                _ => std::ptr::null_mut(),
            };
            apply(t.span.start.offset, t.span.end.offset, col);
        }
    }
}

/// Shared body for the open/save panels: run the panel modally and, on OK, copy
/// the chosen path into `dest`. `save` selects NSSavePanel vs NSOpenPanel.
/// Returns 1 if a path was chosen, 0 otherwise.
fn run_file_panel(save: bool, dest: *mut u16, dest_high: u64) -> i64 {
    bootstrap();
    let msg = sym_or_null("objc_msgSend");
    let reg = sym_or_null("sel_registerName");
    let getcls = sym_or_null("objc_getClass");
    if msg.is_null() || reg.is_null() || getcls.is_null() {
        return 0;
    }
    let reg: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(reg) };
    let getcls: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(getcls) };
    let s0: extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
        unsafe { std::mem::transmute(msg) };
    let s_i64: extern "C" fn(*mut c_void, *mut c_void) -> i64 = unsafe { std::mem::transmute(msg) };
    let s_str: extern "C" fn(*mut c_void, *mut c_void) -> *const i8 =
        unsafe { std::mem::transmute(msg) };
    let cls = if save {
        getcls(c"NSSavePanel".as_ptr())
    } else {
        getcls(c"NSOpenPanel".as_ptr())
    };
    let panel = s0(cls, reg(if save { c"savePanel".as_ptr() } else { c"openPanel".as_ptr() }));
    if panel.is_null() {
        return 0;
    }
    // NSModalResponseOK == 1
    let resp = s_i64(panel, reg(c"runModal".as_ptr()));
    if resp != 1 {
        return 0;
    }
    let url = s0(panel, reg(c"URL".as_ptr()));
    if url.is_null() {
        return 0;
    }
    let nspath = s0(url, reg(c"path".as_ptr()));
    if nspath.is_null() {
        return 0;
    }
    let utf8 = s_str(nspath, reg(c"UTF8String".as_ptr()));
    if utf8.is_null() {
        return 0;
    }
    let text = unsafe { CStr::from_ptr(utf8) }.to_string_lossy().into_owned();
    // write into dest (wide, NUL-terminated)
    let cap = (dest_high as usize).saturating_add(1);
    if !dest.is_null() && cap > 0 {
        let units: Vec<u16> = text.encode_utf16().collect();
        let n = units.len().min(cap - 1);
        for (i, &u) in units.iter().take(n).enumerate() {
            unsafe { *dest.add(i) = u };
        }
        unsafe { *dest.add(n) = 0 };
    }
    1
}

/// `ObjC.OpenPanel(VAR path)` — show an Open dialog; returns 1 and fills `path`
/// if the user chose a file, 0 if cancelled.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_cocoa_open_panel(dest: *mut u16, dest_high: u64) -> i64 {
    run_file_panel(false, dest, dest_high)
}

/// `ObjC.SavePanel(VAR path)` — show a Save dialog; returns 1 and fills `path`
/// if the user chose a destination, 0 if cancelled.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_cocoa_save_panel(dest: *mut u16, dest_high: u64) -> i64 {
    run_file_panel(true, dest, dest_high)
}

/// `ObjC.RunApp()` — install a minimal main menu (so Cmd-Q quits), activate the
/// app, and run the AppKit event loop until the user quits. This is the real,
/// interactive desktop run (blocking), as opposed to the bounded `Pump`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_cocoa_run_app() {
    bootstrap();
    let msg = sym_or_null("objc_msgSend");
    let reg = sym_or_null("sel_registerName");
    let getcls = sym_or_null("objc_getClass");
    if msg.is_null() || reg.is_null() || getcls.is_null() {
        return;
    }
    let reg: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(reg) };
    let getcls: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(getcls) };
    let s0: extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
        unsafe { std::mem::transmute(msg) };
    let s1: extern "C" fn(*mut c_void, *mut c_void, *mut c_void) -> *mut c_void =
        unsafe { std::mem::transmute(msg) };
    let s1b: extern "C" fn(*mut c_void, *mut c_void, bool) -> *mut c_void =
        unsafe { std::mem::transmute(msg) };
    let s3: extern "C" fn(
        *mut c_void,
        *mut c_void,
        *mut c_void,
        *mut c_void,
        *mut c_void,
    ) -> *mut c_void = unsafe { std::mem::transmute(msg) };
    let sel = |n: &CStr| reg(n.as_ptr());
    let nsstr = |s: &str| -> *mut c_void {
        match CString::new(s) {
            Ok(c) => nm2_objc_nsstring_via(getcls, reg, msg, c.as_ptr()),
            Err(_) => std::ptr::null_mut(),
        }
    };
    let alloc_init = |cls_name: &CStr| -> *mut c_void {
        let cls = getcls(cls_name.as_ptr());
        s0(s0(cls, sel(c"alloc")), sel(c"init"))
    };

    let app = s0(getcls(c"NSApplication".as_ptr()), sel(c"sharedApplication"));
    let _ = s1(app, sel(c"setActivationPolicy:"), 0 as *mut c_void); // Regular

    // Minimal main menu: one app menu containing Quit (Cmd-Q -> terminate:).
    let main_menu = alloc_init(c"NSMenu");
    let app_item = alloc_init(c"NSMenuItem");
    let _ = s1(main_menu, sel(c"addItem:"), app_item);
    let app_menu = alloc_init(c"NSMenu");
    let _ = s1(app_item, sel(c"setSubmenu:"), app_menu);
    let quit = s0(getcls(c"NSMenuItem".as_ptr()), sel(c"alloc"));
    // initWithTitle:(NSString) action:(SEL) keyEquivalent:(NSString)
    let quit = s3(
        quit,
        sel(c"initWithTitle:action:keyEquivalent:"),
        nsstr("Quit"),
        sel(c"terminate:"),
        nsstr("q"),
    );
    let _ = s1(app_menu, sel(c"addItem:"), quit);
    let _ = s1(app, sel(c"setMainMenu:"), main_menu);

    let _ = s1b(app, sel(c"activateIgnoringOtherApps:"), true);
    let _ = s0(app, sel(c"run"));
}

// Internal: build an NSString from a UTF-8 C pointer using already-resolved fns.
fn nm2_objc_nsstring_via(
    getcls: extern "C" fn(*const i8) -> *mut c_void,
    reg: extern "C" fn(*const i8) -> *mut c_void,
    msg: *mut c_void,
    utf8: *const i8,
) -> *mut c_void {
    let send: extern "C" fn(*mut c_void, *mut c_void, *const i8) -> *mut c_void =
        unsafe { std::mem::transmute(msg) };
    let cls = getcls(c"NSString".as_ptr());
    send(cls, reg(c"stringWithUTF8String:".as_ptr()), utf8)
}

/// `ObjC.MarkErrors(textview, output)` — parse compiler diagnostics of the form
/// `name:LINE: error: …` (or `warning:`) out of `output`, and give those lines a
/// pale-red background in the editor. Clears any previous marks first. Returns
/// the number of error lines marked.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_ide_mark_errors(
    textview: *mut c_void,
    out_ptr: *const u16,
    out_high: u64,
) -> i64 {
    bootstrap();
    if textview.is_null() {
        return 0;
    }
    let msg = sym_or_null("objc_msgSend");
    let reg = sym_or_null("sel_registerName");
    let getcls = sym_or_null("objc_getClass");
    if msg.is_null() || reg.is_null() || getcls.is_null() {
        return 0;
    }
    let reg: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(reg) };
    let getcls: extern "C" fn(*const i8) -> *mut c_void = unsafe { std::mem::transmute(getcls) };
    let send0: extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void =
        unsafe { std::mem::transmute(msg) };
    let send_str: extern "C" fn(*mut c_void, *mut c_void) -> *const i8 =
        unsafe { std::mem::transmute(msg) };
    let send_color: extern "C" fn(*mut c_void, *mut c_void, f64, f64, f64, f64) -> *mut c_void =
        unsafe { std::mem::transmute(msg) };
    let add_attr: extern "C" fn(*mut c_void, *mut c_void, *mut c_void, *mut c_void, u64, u64) =
        unsafe { std::mem::transmute(msg) };
    let rem_attr: extern "C" fn(*mut c_void, *mut c_void, *mut c_void, u64, u64) =
        unsafe { std::mem::transmute(msg) };

    // editor text + line offsets (ASCII: byte offset == UTF-16 index)
    let s = send0(textview, reg(c"string".as_ptr()));
    if s.is_null() {
        return 0;
    }
    let utf8 = send_str(s, reg(c"UTF8String".as_ptr()));
    if utf8.is_null() {
        return 0;
    }
    let src = unsafe { CStr::from_ptr(utf8) }.to_string_lossy().into_owned();
    let mut line_start: Vec<usize> = vec![0];
    for (i, b) in src.bytes().enumerate() {
        if b == b'\n' {
            line_start.push(i + 1);
        }
    }

    let storage = send0(textview, reg(c"textStorage".as_ptr()));
    if storage.is_null() {
        return 0;
    }
    let bg_var = sym_or_null("NSBackgroundColorAttributeName") as *const *mut c_void;
    if bg_var.is_null() {
        return 0;
    }
    let bg = unsafe { *bg_var };
    let total = src.encode_utf16().count() as u64;
    // clear previous marks
    rem_attr(storage, reg(c"removeAttribute:range:".as_ptr()), bg, 0, total);

    let nscolor = getcls(c"NSColor".as_ptr());
    let pale_red = send_color(
        nscolor,
        reg(c"colorWithCalibratedRed:green:blue:alpha:".as_ptr()),
        1.0,
        0.80,
        0.80,
        1.0,
    );

    // parse diagnostics for line numbers
    let out = {
        if out_ptr.is_null() {
            String::new()
        } else {
            let cap = (out_high as usize).saturating_add(1);
            let units = unsafe { std::slice::from_raw_parts(out_ptr, cap) };
            let end = units.iter().position(|&u| u == 0).unwrap_or(units.len());
            String::from_utf16_lossy(&units[..end])
        }
    };
    let add_sel = reg(c"addAttribute:value:range:".as_ptr());
    let mut count = 0i64;
    for line in out.lines() {
        if !(line.contains("error") || line.contains("warning")) {
            continue;
        }
        // `name:LINE: sev: message` → field 1 is the line number
        let Some(num) = line.split(':').nth(1).and_then(|f| f.trim().parse::<usize>().ok()) else {
            continue;
        };
        if num == 0 || num > line_start.len() {
            continue;
        }
        let start = line_start[num - 1];
        let end = if num < line_start.len() {
            line_start[num]
        } else {
            src.len()
        };
        add_attr(storage, add_sel, bg, pale_red, start as u64, (end - start) as u64);
        count += 1;
    }
    count
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
