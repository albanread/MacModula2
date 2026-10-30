//! `dlopen` and `dlsym` for a static musl program (the BOX's /init).
//! From NewCL-BOX (src/ncl-llvm/src/static_dl.rs), where it was found.
//!
//! MCJIT opens the program itself (`dlopen(NULL)`) when an engine is
//! made, and looks up any symbol a module needs that was not bound with
//! `LLVMAddGlobalMapping` through `dlsym`.  musl's static libc has only
//! weak stubs for these, which fail ("Dynamic loading not supported"),
//! so a static engine could make no engine at all.  These strong
//! definitions take their place: the program's handle is a token, and
//! `dlsym` answers from a table of the C library and compiler-rt
//! routines LLVM's code generator calls on its own (block moves, the
//! maths library, 128-bit division).  A name not in the table is
//! reported on stderr once, so a gap shows itself.

#![allow(non_upper_case_globals)]

use std::ffi::{c_char, c_int, c_void, CStr};

/// The program's handle: any non-null value will do.
static PROGRAM: u8 = 0;

#[unsafe(no_mangle)]
pub extern "C" fn dlopen(file: *const c_char, _mode: c_int) -> *mut c_void {
    if file.is_null() {
        &PROGRAM as *const u8 as *mut c_void
    } else {
        std::ptr::null_mut()
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dlclose(_handle: *mut c_void) -> c_int {
    0
}

unsafe extern "C" {
    fn memcpy(d: *mut c_void, s: *const c_void, n: usize) -> *mut c_void;
    fn memmove(d: *mut c_void, s: *const c_void, n: usize) -> *mut c_void;
    fn memset(d: *mut c_void, c: c_int, n: usize) -> *mut c_void;
    fn memcmp(a: *const c_void, b: *const c_void, n: usize) -> c_int;
    fn bcmp(a: *const c_void, b: *const c_void, n: usize) -> c_int;
    fn malloc(n: usize) -> *mut c_void;
    fn free(p: *mut c_void);
    fn abort() -> !;
    fn fmod(a: f64, b: f64) -> f64;
    fn fmodf(a: f32, b: f32) -> f32;
    fn pow(a: f64, b: f64) -> f64;
    fn powf(a: f32, b: f32) -> f32;
    fn exp(a: f64) -> f64;
    fn exp2(a: f64) -> f64;
    fn log(a: f64) -> f64;
    fn log2(a: f64) -> f64;
    fn log10(a: f64) -> f64;
    fn sin(a: f64) -> f64;
    fn cos(a: f64) -> f64;
    fn tan(a: f64) -> f64;
    fn sqrt(a: f64) -> f64;
    fn floor(a: f64) -> f64;
    fn ceil(a: f64) -> f64;
    fn round(a: f64) -> f64;
    fn trunc(a: f64) -> f64;
    fn rint(a: f64) -> f64;
    fn nearbyint(a: f64) -> f64;
    fn fma(a: f64, b: f64, c: f64) -> f64;
    fn fmin(a: f64, b: f64) -> f64;
    fn fmax(a: f64, b: f64) -> f64;
    fn __divti3(a: i128, b: i128) -> i128;
    fn __udivti3(a: u128, b: u128) -> u128;
    fn __modti3(a: i128, b: i128) -> i128;
    fn __umodti3(a: u128, b: u128) -> u128;
    // The unwinder's (libunwind, from zig): RTDyldMemoryManager hands each
    // module's .eh_frame to it, so panics unwind through JIT'd frames.
    fn __register_frame(fde: *const c_void);
    fn __deregister_frame(fde: *const c_void);
}

fn lookup(name: &[u8]) -> *mut c_void {
    macro_rules! table {
        ($($f:ident),* $(,)?) => {
            match name {
                $(n if n == stringify!($f).as_bytes() => $f as *const () as *mut c_void,)*
                _ => std::ptr::null_mut(),
            }
        };
    }
    table!(
        memcpy, memmove, memset, memcmp, bcmp, malloc, free, abort, fmod, fmodf, pow, powf,
        exp, exp2, log, log2, log10, sin, cos, tan, sqrt, floor, ceil, round, trunc, rint,
        nearbyint, fma, fmin, fmax, __divti3, __udivti3, __modti3, __umodti3,
    );
    match name {
        b"__register_frame" => register_eh_frame_section as *const () as *mut c_void,
        b"__deregister_frame" => deregister_eh_frame_section as *const () as *mut c_void,
        _ => std::ptr::null_mut(),
    }
}

/// Calls `f` on each FDE of the .eh_frame section at `section`.  LLVM
/// hands libgcc's `__register_frame` a whole section (on Linux, which is
/// libgcc's convention); LLVM's libunwind, the one zig links, takes one
/// FDE at a time (Apple's).  A record is a 32-bit length (0xffffffff: a
/// 64-bit length follows) and a 32-bit CIE pointer, 0 in a CIE; a zero
/// length ends the section.
unsafe fn each_fde(section: *const u8, f: unsafe extern "C" fn(*const c_void)) {
    let mut p = section;
    loop {
        let len = unsafe { (p as *const u32).read_unaligned() } as u64;
        if len == 0 {
            break;
        }
        let (len, body) = if len == 0xffff_ffff {
            (unsafe { (p.add(4) as *const u64).read_unaligned() }, unsafe { p.add(12) })
        } else {
            (len, unsafe { p.add(4) })
        };
        let cie_ptr = unsafe { (body as *const u32).read_unaligned() };
        if cie_ptr != 0 {
            unsafe { f(p as *const c_void) };
        }
        p = unsafe { body.add(len as usize) };
    }
}

extern "C" fn register_eh_frame_section(section: *const c_void) {
    unsafe { each_fde(section as *const u8, __register_frame) }
}

extern "C" fn deregister_eh_frame_section(section: *const c_void) {
    unsafe { each_fde(section as *const u8, __deregister_frame) }
}

/// Whether `dlsym` answers for `name` (the JIT's check before it makes code).
pub fn offers(name: &str) -> bool {
    !lookup(name.as_bytes()).is_null()
}

/// The address of a C routine `dlsym` offers, for an EXTERNAL procedure.
pub fn address(name: &str) -> Option<*const ()> {
    let p = lookup(name.as_bytes());
    (!p.is_null()).then_some(p as *const ())
}

#[unsafe(no_mangle)]
pub extern "C" fn dlsym(_handle: *mut c_void, name: *const c_char) -> *mut c_void {
    if name.is_null() {
        return std::ptr::null_mut();
    }
    let n = unsafe { CStr::from_ptr(name) }.to_bytes();
    let p = lookup(n);
    if p.is_null() {
        eprintln!("Modula-2: the JIT asked for {}, which this static program does not offer",
            String::from_utf8_lossy(n));
    }
    p
}

/// inkwell refers to LLVM's interpreter (which the box's LLVM set does not
/// have) for an engine kind this program never makes.
#[unsafe(no_mangle)]
pub extern "C" fn LLVMLinkInInterpreter() {}
