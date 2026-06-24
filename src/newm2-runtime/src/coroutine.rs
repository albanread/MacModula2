//! Coroutine support.
//!
//! Implements the PIM `SYSTEM.NEWPROCESS` / `SYSTEM.TRANSFER` model and the ISO
//! `COROUTINES` interface. Two backends, selected at compile time:
//!
//! * **Windows** — Win32 fibers (`CreateFiber` / `SwitchToFiber`).
//! * **macOS / arm64** — a hand-rolled AArch64 context switch (`nm2_ctx_switch`)
//!   over heap-allocated stacks. This is the native equivalent of a fiber: we
//!   save/restore the AAPCS64 callee-saved registers (x19–x30, sp, d8–d15) and
//!   nothing else, so a `TRANSFER` is a couple of dozen instructions with no
//!   syscall.
//!
//! Both backends expose the same three `nm2_coroutine_*` runtime symbols the
//! compiler lowers `NEWPROCESS` / `TRANSFER` / `COROUTINES.CURRENT` to. A
//! coroutine that runs to completion switches back to the thread's main
//! coroutine rather than terminating the thread, so falling off the end is
//! survivable.

use core::ffi::c_void;

/// The M2 coroutine body: a parameterless procedure.
type CoroutineBody = extern "C-unwind" fn();

// ───────────────────────────── Windows (fibers) ─────────────────────────────
#[cfg(windows)]
mod windows_impl {
    use super::{c_void, CoroutineBody};
    use std::cell::Cell;
    use std::ptr;

    // The fiber entry is `extern "system" fn(*mut c_void)`; CreateFiber/SwitchToFiber
    // live in kernel32.
    unsafe extern "system" {
        fn ConvertThreadToFiber(param: *mut c_void) -> *mut c_void;
        fn CreateFiber(
            stack_size: usize,
            start: extern "system" fn(*mut c_void),
            param: *mut c_void,
        ) -> *mut c_void;
        fn SwitchToFiber(fiber: *mut c_void);
    }

    thread_local! {
        /// The fiber currently running on this thread (the "current coroutine").
        static CURRENT: Cell<*mut c_void> = const { Cell::new(ptr::null_mut()) };
        /// The thread's original (main) fiber, set on first use.
        static MAIN: Cell<*mut c_void> = const { Cell::new(ptr::null_mut()) };
    }

    /// Ensure the calling thread is a fiber and return its main fiber handle.
    /// Idempotent — safe to call before every `NEWPROCESS`.
    fn ensure_main_fiber() -> *mut c_void {
        MAIN.with(|m| {
            let mut h = m.get();
            if h.is_null() {
                h = unsafe { ConvertThreadToFiber(ptr::null_mut()) };
                m.set(h);
                CURRENT.with(|c| c.set(h));
            }
            h
        })
    }

    extern "system" fn fiber_trampoline(param: *mut c_void) {
        // `param` is a boxed coroutine body pointer.
        let body = unsafe { *Box::from_raw(param as *mut CoroutineBody) };
        body();
        // The coroutine returned; hand control back to the main fiber rather than
        // letting the fiber function return (which would end the thread).
        let main = MAIN.with(|m| m.get());
        if !main.is_null() {
            CURRENT.with(|c| c.set(main));
            unsafe { SwitchToFiber(main) };
        }
    }

    pub(super) fn new(body: CoroutineBody, stack_size: usize) -> *mut c_void {
        ensure_main_fiber();
        let boxed = Box::into_raw(Box::new(body)) as *mut c_void;
        let stack = if stack_size == 0 { 64 * 1024 } else { stack_size };
        unsafe { CreateFiber(stack, fiber_trampoline, boxed) }
    }

    pub(super) fn current() -> *mut c_void {
        ensure_main_fiber();
        CURRENT.with(|c| c.get())
    }

    pub(super) fn transfer(from: *mut *mut c_void, to: *mut c_void) {
        ensure_main_fiber();
        let current = CURRENT.with(|c| c.get());
        if !from.is_null() {
            unsafe { *from = current };
        }
        if to.is_null() || to == current {
            return;
        }
        CURRENT.with(|c| c.set(to));
        unsafe { SwitchToFiber(to) };
    }
}

// ─────────────────────────── macOS / arm64 (native) ─────────────────────────
#[cfg(all(not(windows), target_arch = "aarch64"))]
mod aarch64_impl {
    use super::{c_void, CoroutineBody};
    use std::cell::Cell;

    /// Saved AAPCS64 callee-saved state: x19–x28, x29(fp), x30(lr), sp, d8–d15.
    /// Laid out to match the byte offsets used by `nm2_ctx_switch` below.
    ///   regs[0..=11]  = x19,x20,…,x29(fp),x30(lr)
    ///   regs[12]      = sp
    ///   regs[13..=20] = d8,d9,…,d15
    #[repr(C, align(16))]
    struct Ctx {
        regs: [u64; 24],
    }
    impl Ctx {
        const fn zeroed() -> Self {
            Ctx { regs: [0; 24] }
        }
    }

    struct Coroutine {
        ctx: Ctx,
        // Owned stack; `None` for the thread's main coroutine (it runs on the
        // real thread stack). Kept alive for the coroutine's lifetime.
        _stack: Option<Box<[u8]>>,
    }

    thread_local! {
        static CURRENT: Cell<*mut Coroutine> = const { Cell::new(std::ptr::null_mut()) };
        static MAIN: Cell<*mut Coroutine> = const { Cell::new(std::ptr::null_mut()) };
    }

    unsafe extern "C" {
        // Defined in global_asm! below. Saves callee-saved regs into *prev,
        // loads them from *next, and `ret`s into next's saved lr.
        fn nm2_ctx_switch(prev: *mut Ctx, next: *const Ctx);
        // Entry trampoline (asm): calls the body (held in x19), then finish().
        fn nm2_coroutine_trampoline();
    }

    core::arch::global_asm!(
        ".p2align 2",
        ".globl _nm2_ctx_switch",
        "_nm2_ctx_switch:",
        "  stp x19, x20, [x0, #0]",
        "  stp x21, x22, [x0, #16]",
        "  stp x23, x24, [x0, #32]",
        "  stp x25, x26, [x0, #48]",
        "  stp x27, x28, [x0, #64]",
        "  stp x29, x30, [x0, #80]",
        "  mov x9, sp",
        "  str x9, [x0, #96]",
        "  stp d8,  d9,  [x0, #104]",
        "  stp d10, d11, [x0, #120]",
        "  stp d12, d13, [x0, #136]",
        "  stp d14, d15, [x0, #152]",
        "  ldp x19, x20, [x1, #0]",
        "  ldp x21, x22, [x1, #16]",
        "  ldp x23, x24, [x1, #32]",
        "  ldp x25, x26, [x1, #48]",
        "  ldp x27, x28, [x1, #64]",
        "  ldp x29, x30, [x1, #80]",
        "  ldr x9, [x1, #96]",
        "  mov sp, x9",
        "  ldp d8,  d9,  [x1, #104]",
        "  ldp d10, d11, [x1, #120]",
        "  ldp d12, d13, [x1, #136]",
        "  ldp d14, d15, [x1, #152]",
        "  ret",
        ".p2align 2",
        ".globl _nm2_coroutine_trampoline",
        "_nm2_coroutine_trampoline:",
        "  blr x19",                  // call the coroutine body (no args)
        "  bl _nm2_coroutine_finish", // body returned: switch back to main
        "  brk #0",                   // unreachable
    );

    fn ensure_main() -> *mut Coroutine {
        let mut m = MAIN.with(|c| c.get());
        if m.is_null() {
            let co = Box::new(Coroutine { ctx: Ctx::zeroed(), _stack: None });
            m = Box::into_raw(co);
            MAIN.with(|c| c.set(m));
            CURRENT.with(|c| c.set(m));
        }
        m
    }

    /// Called from the asm trampoline when a coroutine body returns: switch back
    /// to the thread's main coroutine. Never returns to its caller.
    #[unsafe(no_mangle)]
    pub extern "C" fn nm2_coroutine_finish() {
        let main = MAIN.with(|c| c.get());
        let cur = CURRENT.with(|c| c.get());
        if main.is_null() || cur.is_null() {
            std::process::abort();
        }
        CURRENT.with(|c| c.set(main));
        // `cur.ctx` is written but never resumed (the coroutine is done).
        unsafe { nm2_ctx_switch(&mut (*cur).ctx, &(*main).ctx) };
    }

    pub(super) fn new(body: CoroutineBody, stack_size: usize) -> *mut c_void {
        ensure_main();
        let size = if stack_size == 0 {
            256 * 1024
        } else {
            stack_size.max(64 * 1024)
        };
        let mut stack = vec![0u8; size].into_boxed_slice();
        let base = stack.as_mut_ptr() as usize;
        // sp grows down from the 16-byte-aligned top of the stack.
        let top = (base + size) & !15usize;

        let mut ctx = Ctx::zeroed();
        ctx.regs[0] = body as usize as u64; // x19 = body fn ptr
        ctx.regs[11] = nm2_coroutine_trampoline as usize as u64; // x30 (lr)
        ctx.regs[12] = top as u64; // sp

        let co = Box::new(Coroutine { ctx, _stack: Some(stack) });
        Box::into_raw(co) as *mut c_void
    }

    pub(super) fn current() -> *mut c_void {
        ensure_main();
        CURRENT.with(|c| c.get()) as *mut c_void
    }

    pub(super) fn transfer(from: *mut *mut c_void, to: *mut c_void) {
        ensure_main();
        let current = CURRENT.with(|c| c.get());
        if !from.is_null() {
            unsafe { *from = current as *mut c_void };
        }
        let to = to as *mut Coroutine;
        if to.is_null() || to == current {
            return;
        }
        CURRENT.with(|c| c.set(to));
        unsafe { nm2_ctx_switch(&mut (*current).ctx, &(*to).ctx) };
    }
}

// ─────────────── other non-Windows arches (unsupported stub) ────────────────
#[cfg(all(not(windows), not(target_arch = "aarch64")))]
mod aarch64_impl {
    use super::{c_void, CoroutineBody};
    pub(super) fn new(_body: CoroutineBody, _stack_size: usize) -> *mut c_void {
        panic!("coroutines are only implemented on Windows and macOS/arm64");
    }
    pub(super) fn current() -> *mut c_void {
        panic!("coroutines are only implemented on Windows and macOS/arm64");
    }
    pub(super) fn transfer(_from: *mut *mut c_void, _to: *mut c_void) {
        panic!("coroutines are only implemented on Windows and macOS/arm64");
    }
}

#[cfg(windows)]
use windows_impl as imp;
#[cfg(not(windows))]
use aarch64_impl as imp;

/// `SYSTEM.NEWPROCESS(body, workspace, size, VAR cor)` — create a coroutine
/// that will run `body`. The PIM workspace pointer is ignored (the runtime
/// manages the stack); `size` is a stack-size hint. Returns an opaque handle
/// the compiler stores into the `cor` PROCESS variable.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_coroutine_new(body: CoroutineBody, stack_size: usize) -> *mut c_void {
    imp::new(body, stack_size)
}

/// `COROUTINES.CURRENT()` — the running coroutine's handle (ISO).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_coroutine_current() -> *mut c_void {
    imp::current()
}

/// `SYSTEM.TRANSFER(VAR from, to)` — suspend the running coroutine, recording
/// its handle in `*from`, and resume `to`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_coroutine_transfer(from: *mut *mut c_void, to: *mut c_void) {
    imp::transfer(from, to)
}
