//! The BOX: the bodies of the `SWI` definition module (library/boxdef/SWI.def),
//! RISC OS SWIs from Modula-2 with registers in and out. See
//! design/BOX_PORT.md, section 5.
//!
//! A SWI is always called in its X form (the module's hook); `Call` turns
//! an error into an ISO exception whose source is SWI's own and whose number
//! and message are the error block's, `XCall` hands back the block. Strings
//! cross as Latin-1: CHAR is a 16-bit cell here, RISC OS's characters are
//! bytes. A string made for a SWI (`Str`) is in the run's dynamic area, so
//! it is a RISC OS address; it is freed with the area when the run ends.

use crate::rosbox;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;

pub type Regs = [u32; 10];

static FLAGS: AtomicU32 = AtomicU32::new(0);
static SOURCE: AtomicU64 = AtomicU64::new(0);
static NUMBERS: Mutex<Option<HashMap<String, u32>>> = Mutex::new(None);

/// SWI's exception source (made at its first use).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_swi_source() -> u64 {
    let s = SOURCE.load(Ordering::Relaxed);
    if s != 0 {
        return s;
    }
    let n = crate::exceptions::nm2_alloc_exception_source();
    match SOURCE.compare_exchange(0, n, Ordering::Relaxed, Ordering::Relaxed) {
        Ok(_) => n,
        Err(old) => old,
    }
}

fn raise(number: u32, text: &str) -> ! {
    let mut w: Vec<u16> = text.encode_utf16().collect();
    w.push(0);
    unsafe { crate::exceptions::nm2_raise(nm2_swi_source(), number as u64, w.as_ptr(), (w.len() - 1) as u64) }
}

/// An open ARRAY OF CHAR (wide cells, `high` its HIGH) up to its NUL, as
/// Latin-1 bytes.
unsafe fn latin1(p: *const u16, high: u64) -> Vec<u8> {
    let mut v = Vec::new();
    if p.is_null() {
        return v;
    }
    for i in 0..=high as usize {
        let c = unsafe { *p.add(i) };
        if c == 0 {
            break;
        }
        v.push(if c < 256 { c as u8 } else { b'?' });
    }
    v
}

fn number_of(name: &str) -> Option<u32> {
    let mut g = NUMBERS.lock().unwrap();
    let m = g.get_or_insert_with(HashMap::new);
    if let Some(&n) = m.get(name) {
        return Some(n);
    }
    let n = rosbox::swi_number(name)?;
    m.insert(name.to_string(), n);
    Some(n)
}

fn call(swi: u32, r: *mut Regs) -> u32 {
    let regs = unsafe { &mut *r };
    match rosbox::swi(swi, regs) {
        Ok(f) => {
            FLAGS.store(f, Ordering::Relaxed);
            0
        }
        Err(e) => {
            FLAGS.store(1, Ordering::Relaxed);
            if e == 0 { u32::MAX } else { e }
        }
    }
}

fn raise_error(e: u32) -> ! {
    if e == u32::MAX {
        raise(0, "SWI: no SWI handler (not in the box)");
    }
    raise(rosbox::error_number(e), &rosbox::error_text(e))
}

/// `SWI.Call(swi, r)`: raises on an error.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_swi_call(swi: u32, r: *mut Regs) {
    let e = call(swi, r);
    if e != 0 {
        raise_error(e);
    }
}

/// `SWI.XCall(swi, r)`: the error block's address, or 0 (NIL).
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_swi_xcall(swi: u32, r: *mut Regs) -> usize {
    let e = call(swi, r);
    if e == u32::MAX { 0 } else { e as usize }
}

unsafe fn named(name: *const u16, high: u64) -> u32 {
    let n = String::from_utf8_lossy(&unsafe { latin1(name, high) }).into_owned();
    match number_of(&n) {
        Some(x) => x,
        None => raise(0x1E6, &format!("SWI name not known: {n}")),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_swi_call_name(name: *const u16, high: u64, r: *mut Regs) {
    let n = unsafe { named(name, high) };
    unsafe { nm2_swi_call(n, r) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_swi_xcall_name(name: *const u16, high: u64, r: *mut Regs) -> usize {
    let n = unsafe { named(name, high) };
    unsafe { nm2_swi_xcall(n, r) }
}

/// `SWI.Number(name)`: OS_SWINumberFromString; raises if it is not known.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_swi_number(name: *const u16, high: u64) -> u32 {
    unsafe { named(name, high) }
}

/// N Z C V of the last call, as bits 3-0.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_swi_flags() -> u32 {
    FLAGS.load(Ordering::Relaxed)
}

/// `SWI.Addr(a)`: a as a RISC OS address; raises if it is not one (above
/// 4 GB: /init's own memory, which RISC OS cannot see).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_swi_addr(a: usize) -> u32 {
    if a > u32::MAX as usize {
        raise(0x1E4, &format!("SWI.Addr: &{a:X} is not a RISC OS address (copy it with SWI.Str or put it in NEW'd memory)"));
    }
    a as u32
}

/// `SWI.Str(s)`: a 0-terminated Latin-1 copy of s in the dynamic area.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_swi_str(s: *const u16, high: u64) -> u32 {
    let b = unsafe { latin1(s, high) };
    let p = rosbox::arena_alloc(b.len() + 1, 4);
    if p.is_null() {
        raise(0x101, "SWI.Str: no memory in the dynamic area");
    }
    unsafe {
        std::ptr::copy_nonoverlapping(b.as_ptr(), p, b.len());
        *p.add(b.len()) = 0;
    }
    nm2_swi_addr(p as usize)
}

/// `SWI.GetStr(a, s)`: the control-terminated string at RISC OS address a.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_swi_get_str(a: u32, dst: *mut u16, high: u64) {
    if dst.is_null() {
        return;
    }
    let mut i = 0usize;
    if a != 0 {
        let p = a as usize as *const u8;
        while (i as u64) <= high {
            let c = unsafe { *p.add(i) };
            if c < 32 {
                break;
            }
            unsafe { *dst.add(i) = c as u16 };
            i += 1;
        }
    }
    if (i as u64) <= high {
        unsafe { *dst.add(i) = 0 };
    }
}

#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_swi_error_number(e: usize) -> u32 {
    rosbox::error_number(e as u32)
}

#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_swi_error_text(e: usize, dst: *mut u16, high: u64) {
    if e == 0 {
        if !dst.is_null() {
            unsafe { *dst = 0 };
        }
        return;
    }
    unsafe { nm2_swi_get_str(e as u32 + 4, dst, high) }
}
