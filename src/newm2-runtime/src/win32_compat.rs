//! macOS-native shims for the handful of Win32 primitives that the Modula-2
//! *runtime library* layer (`library/winrtmod`) calls directly.
//!
//! These are not an emulation of Win32 — they are thin, native re-expressions
//! of the same contract on top of the POSIX/Darwin facility that fits:
//! `VirtualAlloc`/`VirtualFree` become `mmap`/`munmap`. The JIT and AOT paths
//! resolve the imported Win32 names (e.g. `VirtualAlloc`) to these functions on
//! macOS, exactly as they resolve them to `kernel32.dll` exports on Windows.
//!
//! As the macOS runtime grows a proper native module layer (`macrtmod`), the
//! library will call native primitives instead and these compatibility shims
//! will shrink to nothing.

#![cfg(not(windows))]

use core::ffi::c_void;
use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::OnceLock;

// Darwin mmap constants (arm64).
const PROT_READ: i32 = 0x1;
const PROT_WRITE: i32 = 0x2;
const MAP_PRIVATE: i32 = 0x0002;
const MAP_ANON: i32 = 0x1000; // MAP_ANONYMOUS on Darwin
const MAP_FAILED: *mut c_void = usize::MAX as *mut c_void; // (void*)-1

unsafe extern "C" {
    fn mmap(
        addr: *mut c_void,
        len: usize,
        prot: i32,
        flags: i32,
        fd: i32,
        offset: i64,
    ) -> *mut c_void;
    fn munmap(addr: *mut c_void, len: usize) -> i32;
}

/// Tracks `base -> length` for every live mapping so `VirtualFree` (which, like
/// `MEM_RELEASE`, is not given a length) can `munmap` the exact region.
fn regions() -> &'static Mutex<HashMap<usize, usize>> {
    static R: OnceLock<Mutex<HashMap<usize, usize>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

/// `VirtualAlloc(lpAddress, dwSize, flAllocationType, flProtect)` — Win32
/// contract, mmap implementation. We honor the common reserve+commit /
/// read-write case the runtime heap uses and ignore the (NULL) hint address.
#[unsafe(no_mangle)]
pub extern "C" fn nm2_win32_VirtualAlloc(
    _lp_address: *mut c_void,
    dw_size: usize,
    _fl_allocation_type: u32,
    _fl_protect: u32,
) -> *mut c_void {
    if dw_size == 0 {
        return std::ptr::null_mut();
    }
    let p = unsafe {
        mmap(
            std::ptr::null_mut(),
            dw_size,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANON,
            -1,
            0,
        )
    };
    if p == MAP_FAILED || p.is_null() {
        return std::ptr::null_mut();
    }
    regions().lock().unwrap().insert(p as usize, dw_size);
    p
}

/// `VirtualFree(lpAddress, dwSize, dwFreeType)` — returns nonzero on success.
#[unsafe(no_mangle)]
pub extern "C" fn nm2_win32_VirtualFree(
    lp_address: *mut c_void,
    _dw_size: usize,
    _dw_free_type: u32,
) -> i32 {
    let len = regions().lock().unwrap().remove(&(lp_address as usize));
    match len {
        Some(len) => {
            let rc = unsafe { munmap(lp_address, len) };
            if rc == 0 { 1 } else { 0 }
        }
        None => 0,
    }
}

/// Resolve a Win32 import name to one of the native shims above. Returns the
/// function address for the JIT/AOT external binder, or `None` if we don't
/// (yet) provide that symbol on macOS.
pub fn resolve(name: &str) -> Option<*const ()> {
    match name {
        "VirtualAlloc" => Some(nm2_win32_VirtualAlloc as *const ()),
        "VirtualFree" => Some(nm2_win32_VirtualFree as *const ()),
        _ => None,
    }
}
