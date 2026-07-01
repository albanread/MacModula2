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

    /// Fiber stacks aren't introspectable this way (CreateFiber/SwitchToFiber
    /// give no access to a fiber's own stack bounds) — not implemented for the
    /// Windows backend; the GC falls back to the OS-thread stack bounds.
    pub(super) fn current_stack_range() -> Option<(usize, usize)> {
        None
    }

    /// No explicit free implemented for the fiber backend (Windows manages
    /// fiber lifetime itself; `DeleteFiber` would be the equivalent).
    pub(super) fn free(_handle: *mut c_void) {}
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
        // Owned guarded stack; `None` for the thread's main coroutine (it runs
        // on the real thread stack). Kept alive for the coroutine's lifetime;
        // munmap'd on drop.
        _stack: Option<GuardedStack>,
        /// [base, top) of the usable (non-guard) stack region; `_stack` is
        /// `None` for the main coroutine, so these are 0 there — the GC falls
        /// back to the OS-thread bounds in that case (see `current_stack_range`).
        stack_base: usize,
        stack_top: usize,
    }

    thread_local! {
        static CURRENT: Cell<*mut Coroutine> = const { Cell::new(std::ptr::null_mut()) };
        static MAIN: Cell<*mut Coroutine> = const { Cell::new(std::ptr::null_mut()) };
        /// Every coroutine created on this thread that hasn't been freed yet
        /// (`nm2_coroutine_new` pushes, `nm2_coroutine_free` removes). Lets a
        /// long-running program reclaim finished coroutines instead of leaking
        /// their stack forever (a coroutine is otherwise handed out as a bare
        /// `Box::into_raw` pointer with no other owner).
        static LIVE: std::cell::RefCell<Vec<*mut Coroutine>> = const { std::cell::RefCell::new(Vec::new()) };
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
            let co = Box::new(Coroutine {
                ctx: Ctx::zeroed(),
                _stack: None,
                stack_base: 0,
                stack_top: 0,
            });
            m = Box::into_raw(co);
            MAIN.with(|c| c.set(m));
            CURRENT.with(|c| c.set(m));
        }
        m
    }

    fn page_size() -> usize {
        let p = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        if p > 0 { p as usize } else { 16384 }
    }

    /// A coroutine's stack, backed by an anonymous mmap with a `PROT_NONE`
    /// guard page immediately below the usable region (the stack grows down
    /// from `top`). Without this a plain heap `Vec<u8>` had no overflow
    /// protection at all: exceeding it silently walked into whatever heap
    /// allocation happened to sit adjacent, corrupting it, instead of faulting.
    struct GuardedStack {
        mmap_base: usize,
        mmap_len: usize,
    }
    impl Drop for GuardedStack {
        fn drop(&mut self) {
            unsafe { libc::munmap(self.mmap_base as *mut c_void, self.mmap_len) };
        }
    }
    fn alloc_guarded_stack(usable_size: usize) -> (GuardedStack, usize, usize) {
        let page = page_size();
        let usable = usable_size.div_ceil(page) * page;
        let total = page + usable; // one guard page below the usable region

        let mmap_base = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                total,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANON,
                -1,
                0,
            )
        };
        assert!(mmap_base != libc::MAP_FAILED, "nm2_coroutine_new: mmap failed for a {total}-byte stack");
        let rc = unsafe { libc::mprotect(mmap_base, page, libc::PROT_NONE) };
        if rc != 0 {
            unsafe { libc::munmap(mmap_base, total) };
            panic!("nm2_coroutine_new: mprotect(PROT_NONE) failed for the guard page");
        }

        let base = mmap_base as usize + page; // usable region starts after the guard page
        let top = (base + usable) & !15usize; // sp grows down from the 16-byte-aligned top
        (GuardedStack { mmap_base: mmap_base as usize, mmap_len: total }, base, top)
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
        let (guarded, base, top) = alloc_guarded_stack(size);

        let mut ctx = Ctx::zeroed();
        ctx.regs[0] = body as usize as u64; // x19 = body fn ptr
        ctx.regs[11] = nm2_coroutine_trampoline as usize as u64; // x30 (lr)
        ctx.regs[12] = top as u64; // sp

        let co = Box::new(Coroutine { ctx, _stack: Some(guarded), stack_base: base, stack_top: top });
        let ptr = Box::into_raw(co);
        LIVE.with(|l| l.borrow_mut().push(ptr));
        ptr as *mut c_void
    }

    pub(super) fn current() -> *mut c_void {
        ensure_main();
        CURRENT.with(|c| c.get()) as *mut c_void
    }

    /// The currently-running coroutine's own [base, top) stack range, or
    /// `None` when running on the thread's main coroutine (i.e. the real OS
    /// thread stack — use the OS-thread bounds instead in that case). Lets the
    /// GC scan the coroutine's OWN stack instead of the wrong (OS-thread)
    /// range when a collection is triggered from inside a running coroutine.
    pub(super) fn current_stack_range() -> Option<(usize, usize)> {
        let cur = CURRENT.with(|c| c.get());
        let main = MAIN.with(|c| c.get());
        if cur.is_null() || cur == main {
            return None;
        }
        let co = unsafe { &*cur };
        Some((co.stack_base, co.stack_top))
    }

    /// Free a finished, non-running coroutine's stack + handle. Refuses to
    /// free the main or currently-running coroutine (that would pull the
    /// stack out from under whoever is executing on it), and is a no-op for a
    /// handle this thread never created / already freed.
    pub(super) fn free(handle: *mut c_void) {
        let ptr = handle as *mut Coroutine;
        if ptr.is_null() {
            return;
        }
        let main = MAIN.with(|c| c.get());
        let current = CURRENT.with(|c| c.get());
        if ptr == main || ptr == current {
            return;
        }
        let was_live = LIVE.with(|l| {
            let mut v = l.borrow_mut();
            if let Some(i) = v.iter().position(|&p| p == ptr) {
                v.remove(i);
                true
            } else {
                false
            }
        });
        if was_live {
            drop(unsafe { Box::from_raw(ptr) });
        }
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
    pub(super) fn current_stack_range() -> Option<(usize, usize)> {
        None
    }
    pub(super) fn free(_handle: *mut c_void) {}
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

/// Free a finished coroutine's stack + handle (not part of ISO/PIM — an
/// explicit reclaim API so a program that creates many coroutines over its
/// lifetime, e.g. one per request, doesn't leak a stack per coroutine
/// forever). A no-op if `handle` is the main or currently-running coroutine,
/// or already freed.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_coroutine_free(handle: *mut c_void) {
    imp::free(handle)
}

/// The currently-running coroutine's own stack range, or `None` when running
/// on the thread's main coroutine (the real OS thread stack). Crate-internal:
/// lets the GC's conservative stack scan use the coroutine's OWN bounds
/// instead of the enclosing OS thread's when a collection is triggered from
/// inside a running coroutine (otherwise it would scan the wrong — and
/// potentially unmapped — address range).
pub(crate) fn current_stack_range() -> Option<(usize, usize)> {
    imp::current_stack_range()
}

#[cfg(all(test, not(windows), target_arch = "aarch64"))]
mod tests {
    use super::*;

    extern "C-unwind" fn noop_body() {}

    #[test]
    fn current_stack_range_is_none_on_main_and_some_inside_a_coroutine() {
        assert!(current_stack_range().is_none(), "main coroutine must report None");

        extern "C-unwind" fn check_body() {
            let r = current_stack_range();
            assert!(r.is_some(), "must report Some((base, top)) while running inside a coroutine");
            let (base, top) = r.unwrap();
            assert!(base < top, "base must be below top");
            assert!(top - base >= 64 * 1024, "range must cover at least the requested stack size");
            // The real stack pointer right now must fall inside the reported
            // range — this is the exact property the GC scan fix depends on.
            let sp_now = &base as *const usize as usize;
            assert!(sp_now >= base && sp_now < top, "current sp {sp_now:#x} not in [{base:#x}, {top:#x})");
        }

        let mut from: *mut c_void = std::ptr::null_mut();
        let co = nm2_coroutine_new(check_body, 64 * 1024);
        nm2_coroutine_transfer(&mut from as *mut _, co);
        assert!(current_stack_range().is_none(), "must be back to None after returning to main");
        nm2_coroutine_free(co);
    }

    #[test]
    fn free_reclaims_a_finished_coroutine_and_refuses_live_ones() {
        let co = nm2_coroutine_new(noop_body, 64 * 1024);

        // Refuses to free the main / currently-running coroutine.
        let main_handle = nm2_coroutine_current();
        nm2_coroutine_free(main_handle); // must be a no-op, not a crash
        assert_eq!(nm2_coroutine_current(), main_handle, "main coroutine must survive a free() attempt");

        // A never-run, finished-by-fiat coroutine can be freed.
        nm2_coroutine_free(co);
        // Freeing the same (now-reclaimed) handle again must be a safe no-op,
        // not a double-free.
        nm2_coroutine_free(co);
    }

    /// Deliberately overflows a coroutine's guarded stack and asserts the
    /// process dies from the guard page (SIGSEGV/SIGBUS) instead of silently
    /// corrupting whatever heap memory used to sit below the old plain-Vec
    /// stack. Guard-page faults are fatal by design, so this must run as a
    /// subprocess: the outer test re-execs this test binary selecting only
    /// the `__overflow_child` test below and checks how the child died.
    #[test]
    fn stack_overflow_faults_instead_of_silently_corrupting_memory() {
        let exe = std::env::current_exe().expect("current_exe");
        let status = std::process::Command::new(exe)
            .args(["--exact", "coroutine::tests::__overflow_child", "--nocapture"])
            .env("NM2_COROUTINE_OVERFLOW_CHILD", "1")
            .status()
            .expect("failed to spawn child test process");
        assert!(!status.success(), "child should have crashed from the guard page, not exited cleanly");
        use std::os::unix::process::ExitStatusExt;
        let sig = status.signal();
        assert!(
            sig == Some(libc::SIGSEGV) || sig == Some(libc::SIGBUS),
            "expected the child to die from SIGSEGV/SIGBUS (the guard page), got {status:?}"
        );
    }

    #[test]
    fn __overflow_child() {
        if std::env::var_os("NM2_COROUTINE_OVERFLOW_CHILD").is_none() {
            return; // only does anything when deliberately spawned as the child above
        }

        extern "C-unwind" fn overflow_body() {
            #[inline(never)]
            fn recurse(pad: [u8; 4096]) -> u8 {
                let pad = std::hint::black_box(pad);
                // Non-tail: the recursive call's result feeds into a use after
                // the call, so the compiler cannot turn this into a loop.
                pad[0].wrapping_add(recurse(pad))
            }
            std::hint::black_box(recurse([1u8; 4096]));
        }

        let mut from: *mut c_void = std::ptr::null_mut();
        let co = nm2_coroutine_new(overflow_body, 64 * 1024);
        nm2_coroutine_transfer(&mut from as *mut _, co);
        // Only reachable if the overflow somehow didn't fault — a genuine
        // test failure, distinct from the expected signal death.
        eprintln!("ERROR: coroutine overflow did not fault the guard page");
        std::process::exit(111);
    }
}
