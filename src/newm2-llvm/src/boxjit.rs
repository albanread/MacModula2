//! The BOX's JIT (design/BOX_PORT.md, section 3): MCJIT, because the box's
//! LLVM (the NCL library set) has no ORC JIT. One linked module per run;
//! the large code model, so that calls and data references reach the
//! runtime in `/init` from mmap'd code wherever it lies; every runtime name
//! bound by address; code in mmap'd pages, data (the program's globals) in
//! the run's dynamic area so that `ADR` of a global is a RISC OS address.
//!
//! The engine lives until the run ends (`box_end_run`), when it is disposed
//! of: that deregisters the code's `.eh_frame` from the unwinder and the
//! memory manager unmaps the code.

use super::*;
use llvm_sys::execution_engine::{
    LLVMCreateMCJITCompilerForModule, LLVMCreateSimpleMCJITMemoryManager, LLVMDisposeExecutionEngine,
    LLVMExecutionEngineRef, LLVMInitializeMCJITCompilerOptions, LLVMMCJITCompilerOptions,
};
use std::collections::HashSet;
use std::ffi::{c_char, c_void};
use std::sync::Mutex;
use std::time::Instant;

/// The run's engine (an LLVMExecutionEngineRef) and context, as integers so
/// that the static is Send; 0 when no run holds one.
static ENGINE: Mutex<(usize, usize)> = Mutex::new((0, 0));

/// `*Modula2 -d`: the JIT's sections and entry points are written out.
pub static BOX_DEBUG: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn debug(s: String) {
    if BOX_DEBUG.load(std::sync::atomic::Ordering::Relaxed) {
        newm2_runtime::rosbox::write_str(&s);
    }
}

fn section_name(p: *const c_char) -> String {
    if p.is_null() { String::new() } else { unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned() }
}

// ── The memory manager ───────────────────────────────────────────────────

struct Mm {
    /// mmap'd code: (address, length)
    code: Vec<(usize, usize)>,
}

unsafe extern "C" {
    fn mmap(a: *mut c_void, n: usize, prot: i32, flags: i32, fd: i32, off: i64) -> *mut c_void;
    fn munmap(a: *mut c_void, n: usize) -> i32;
    fn mprotect(a: *mut c_void, n: usize, prot: i32) -> i32;
    fn __clear_cache(start: *mut c_char, end: *mut c_char);
}
const PROT_READ: i32 = 1;
const PROT_WRITE: i32 = 2;
const PROT_EXEC: i32 = 4;
const MAP_PRIVATE: i32 = 2;
const MAP_ANONYMOUS: i32 = 0x20;

/// Pages for code. MCJIT's AArch64 code is position-independent and reaches
/// its data (in the arena, below 4 GB) by ADRP, +-4 GB from the code: so the
/// code goes just above 4 GB, where the kernel gives the address asked for
/// if it is free. Elsewhere only if it must (no arena: a host test).
const NEAR: usize = 0x1_0000_0000;
const FAR: usize = 0x1_7000_0000;
static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(NEAR);

fn code_pages(len: usize) -> *mut c_void {
    let mut at = NEXT.load(std::sync::atomic::Ordering::Relaxed);
    while at + len < FAR {
        let p = unsafe { mmap(at as *mut c_void, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) };
        if p as isize == -1 {
            break;
        }
        if p as usize == at {
            NEXT.store((at + len + 0xFFFF) & !0xFFFF, std::sync::atomic::Ordering::Relaxed);
            return p;
        }
        unsafe { munmap(p, len) };
        at += 0x100_0000;
    }
    if newm2_runtime::rosbox::arena_on() {
        return std::ptr::null_mut();
    }
    let p = unsafe { mmap(std::ptr::null_mut(), len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) };
    if p as isize == -1 { std::ptr::null_mut() } else { p }
}

/// The run is over: the code pages are given back, so the next run's start
/// again just above 4 GB.
fn code_pages_reset() {
    NEXT.store(NEAR, std::sync::atomic::Ordering::Relaxed);
}

extern "C" fn alloc_code(opaque: *mut c_void, size: usize, align: u32, _id: u32, _name: *const c_char) -> *mut u8 {
    let mm = unsafe { &mut *(opaque as *mut Mm) };
    let len = (size.max(1) + align.max(16) as usize + 0xFFF) & !0xFFF;
    let p = code_pages(len);
    if p.is_null() {
        return std::ptr::null_mut();
    }
    mm.code.push((p as usize, len));
    debug(format!("JIT code {} at &{:X} ({} bytes)\n", section_name(_name), p as usize, size));
    p as *mut u8
}

extern "C" fn alloc_data(opaque: *mut c_void, size: usize, align: u32, _id: u32, _name: *const c_char, _ro: i32) -> *mut u8 {
    let _ = opaque;
    let align = align.max(16) as usize;
    if newm2_runtime::rosbox::arena_on() {
        let p = newm2_runtime::rosbox::arena_alloc(size.max(1), align);
        if !p.is_null() {
            unsafe { std::ptr::write_bytes(p, 0, size) };
        }
        debug(format!("JIT data {} at &{:X} ({} bytes)\n", section_name(_name), p as usize, size));
        return p;
    }
    // No arena (a host test): ordinary memory, kept for the process's life
    let layout = std::alloc::Layout::from_size_align(size.max(1), align).unwrap();
    unsafe { std::alloc::alloc_zeroed(layout) }
}

extern "C" fn finalize(opaque: *mut c_void, _err: *mut *mut c_char) -> i32 {
    let mm = unsafe { &mut *(opaque as *mut Mm) };
    for &(p, n) in &mm.code {
        unsafe {
            __clear_cache(p as *mut c_char, (p + n) as *mut c_char);
            mprotect(p as *mut c_void, n, PROT_READ | PROT_EXEC);
        }
    }
    0
}

extern "C" fn destroy(opaque: *mut c_void) {
    let mm = unsafe { Box::from_raw(opaque as *mut Mm) };
    for &(p, n) in &mm.code {
        unsafe { munmap(p as *mut c_void, n) };
    }
}

// ── A run ────────────────────────────────────────────────────────────────

fn target_machine(opt: u32) -> Result<TargetMachine, String> {
    let triple = TargetMachine::get_default_triple();
    let target = Target::from_triple(&triple).map_err(|e| format!("Target::from_triple: {e}"))?;
    target
        .create_target_machine(&triple, "generic", "", opt_level(opt), RelocMode::Static, CodeModel::Large)
        .ok_or_else(|| "create_target_machine failed".to_string())
}

/// `*Modula2 -c`: the whole back end, no run.
pub fn compile_modules_box(irs: &[&IrModule], sema: &SemaResult, opts: CodegenOptions) -> Result<(), String> {
    codegen::init_llvm();
    let ctx = Context::create();
    let module = emit_linked_module(&ctx, irs, sema, opts)?;
    module.verify().map_err(|e| format!("LLVM verify: {e}"))?;
    let tm = target_machine(opts.opt_level)?;
    optimize_module(&module, &tm, opts.opt_level)?;
    tm.write_to_memory_buffer(&module, FileType::Object).map_err(|e| format!("code generation: {e}"))?;
    Ok(())
}

/// Compiles and runs the modules (dependency order, the program last):
/// HALT's code, or the reason it could not run or stopped. `compiled` is
/// told the compile time (ms) before the program starts.
pub fn run_modules_box(
    irs: &[&IrModule],
    sema: &SemaResult,
    opts: CodegenOptions,
    compiled: &dyn Fn(u128),
    t0: Instant,
) -> Result<i32, String> {
    box_end_run();
    codegen::init_llvm();
    let ctx = Box::new(Context::create());
    let module = emit_linked_module(&ctx, irs, sema, opts)?;
    module.verify().map_err(|e| format!("LLVM verify: {e}"))?;
    let tm = target_machine(opts.opt_level)?;
    optimize_module(&module, &tm, opts.opt_level)?;

    let mut jo: LLVMMCJITCompilerOptions = unsafe { std::mem::zeroed() };
    unsafe { LLVMInitializeMCJITCompilerOptions(&mut jo, std::mem::size_of::<LLVMMCJITCompilerOptions>()) };
    jo.OptLevel = opts.opt_level.min(3);
    jo.CodeModel = llvm_sys::target_machine::LLVMCodeModel::LLVMCodeModelLarge;
    let mm = Box::into_raw(Box::new(Mm { code: Vec::new() })) as *mut c_void;
    jo.MCJMM = unsafe { LLVMCreateSimpleMCJITMemoryManager(mm, alloc_code, alloc_data, finalize, Some(destroy)) };

    let mut engine: LLVMExecutionEngineRef = std::ptr::null_mut();
    let mut err: *mut c_char = std::ptr::null_mut();
    let mref = module.as_mut_ptr();
    let rc = unsafe {
        LLVMCreateMCJITCompilerForModule(&mut engine, mref, &mut jo, std::mem::size_of::<LLVMMCJITCompilerOptions>(), &mut err)
    };
    if rc != 0 || engine.is_null() {
        let msg = if err.is_null() {
            "no engine".to_string()
        } else {
            let s = unsafe { CStr::from_ptr(err) }.to_string_lossy().into_owned();
            unsafe { llvm_sys::core::LLVMDisposeMessage(err) };
            s
        };
        return Err(format!("Modula-2: the JIT could not be made: {msg}"));
    }
    // The engine owns the module now: forget inkwell's handle on it
    std::mem::forget(module);
    let module = unsafe { Module::new(mref) };
    *ENGINE.lock().unwrap() = (engine as usize, Box::into_raw(ctx) as usize);

    // Every name the module declares and does not define must be bound
    // (RuntimeDyld would abort /init on a missing one)
    let mut bound: HashSet<String> = HashSet::new();
    {
        let mut binder = |name: &str, addr: *const ()| {
            bind_function_address(engine, &module, name, addr);
            bound.insert(name.to_string());
        };
        for_each_runtime_binding(&module, opts, &mut binder);
        for_each_external_binding(irs, &mut binder);
    }
    let mut missing = Vec::new();
    let mut f = module.get_first_function();
    while let Some(func) = f {
        let name = func.get_name().to_string_lossy().into_owned();
        if func.count_basic_blocks() == 0
            && !name.starts_with("llvm.")
            && !bound.contains(&name)
            && !unsafe { llvm_sys::core::LLVMGetFirstUse(func.as_value_ref()) }.is_null()
            && !crate::static_dl::offers(&name)
        {
            missing.push(name);
        }
        f = func.get_next_function();
    }
    std::mem::forget(module);
    if !missing.is_empty() {
        return Err(format!("Modula-2: the box's runtime has no {}", missing.join(", ")));
    }

    let lookup = |name: &str| -> u64 {
        use llvm_sys::execution_engine::{LLVMGetFunctionAddress, LLVMGetGlobalValueAddress};
        let Ok(c) = std::ffi::CString::new(name) else { return 0 };
        let a = unsafe { LLVMGetFunctionAddress(engine, c.as_ptr()) };
        if a != 0 { a } else { unsafe { LLVMGetGlobalValueAddress(engine, c.as_ptr()) } }
    };
    // Makes the code (finalizes the object)
    patch_vtables(irs, &lookup)?;
    let mut bodies = Vec::new();
    for ir in irs {
        bodies.push((lookup(&format!("{}.body", ir.name)), lookup(&format!("{}.final", ir.name))));
    }
    for (ir, &(b, f)) in irs.iter().zip(&bodies) {
        debug(format!("{}.body &{:X} .final &{:X}\n", ir.name, b, f));
    }
    compiled(t0.elapsed().as_millis());

    let mut initialized = 0usize;
    let mut first_error: Option<String> = None;
    let mut halt_code: Option<i32> = None;
    for (ir, &(body, _)) in irs.iter().zip(&bodies) {
        match run_void_at(body, &ir.name, "body") {
            RunOutcome::Ran => initialized += 1,
            RunOutcome::Halted(code) => {
                initialized += 1;
                halt_code = Some(code);
                break;
            }
            RunOutcome::Failed(e) => {
                first_error = Some(e);
                break;
            }
        }
    }
    newm2_runtime::begin_termination();
    for (ir, &(_, fin)) in irs[..initialized].iter().zip(&bodies[..initialized]).rev() {
        if let RunOutcome::Failed(e) = run_void_at(fin, &ir.name, "final") {
            if first_error.is_none() {
                first_error = Some(e);
            }
        }
    }
    match first_error {
        Some(e) => Err(e),
        None => Ok(halt_code.unwrap_or(0)),
    }
}

/// The run is over: the engine (and with it the code and its unwind
/// tables) goes.
pub fn box_end_run() {
    let mut g = ENGINE.lock().unwrap_or_else(|p| p.into_inner());
    let (engine, ctx) = *g;
    *g = (0, 0);
    if engine != 0 {
        unsafe { LLVMDisposeExecutionEngine(engine as LLVMExecutionEngineRef) };
    }
    if ctx != 0 {
        drop(unsafe { Box::from_raw(ctx as *mut Context) });
    }
    code_pages_reset();
}

/// After a fault jumped out of a run.
pub fn box_recover() {
    ENGINE.clear_poison();
    box_end_run();
}
