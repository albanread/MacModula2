//! Modula-2 for the BOX: the compiler and runtime as a static library that
//! rosgd's `modules/modula2` links into `/init` (design/BOX_PORT.md).
//!
//! The C API is `box/m2_box.h`. The module gives hooks (the VDU, the
//! keyboard, SWIs, RISC OS files, the run's dynamic area); `m2_box_run`
//! compiles a program module with its imports and runs it under MCJIT.
//!
//! Names: the program is named by its RISC OS name. The loader works in
//! host-style paths (`dir/Name.def`); a path that does not start with "/"
//! is a RISC OS one, and the file hook (below) looks for `dir.Name/def`
//! (HostFS's `Name.def`), then `dir.def.Name` (RISC OS's own way), then,
//! for a program, `dir.Name` (a typed file without a suffix). Paths that
//! start with "/" are the ROM's standard library, `/usr/lib/modula2`.

use std::ffi::{c_char, c_int, CStr};
use std::path::{Path, PathBuf};
use std::time::Instant;

use newm2_ir::{lower_module_opts, MemoryMode};
use newm2_lexer::Env;
use newm2_llvm::CodegenOptions;
use newm2_loader::SearchPath;
use newm2_runtime::rosbox;

pub use rosbox::Hooks;

const COMPILE_ONLY: u32 = 1;
const TIMES: u32 = 2;
const DEBUG: u32 = 4;

/// The library's root in the ROM; `M2Box$Library`-style overrides come in
/// through `m2_box_set_library`.
static LIBRARY: std::sync::Mutex<Option<PathBuf>> = std::sync::Mutex::new(None);

fn out(s: &str) {
    rosbox::write_str(s);
}

// ── RISC OS names for the loader ─────────────────────────────────────────

/// The RISC OS names a host-style `dir/Stem.ext` may have, best first.
fn ros_names(p: &Path) -> Option<Vec<String>> {
    let s = p.to_str()?;
    if s.starts_with('/') {
        return None; // the host's (the ROM's library)
    }
    let (dir, leaf) = match s.rfind('/') {
        Some(i) => (&s[..i], &s[i + 1..]),
        None => ("", s),
    };
    let join = |a: &str| if dir.is_empty() { a.to_string() } else { format!("{dir}.{a}") };
    let mut v = Vec::new();
    match leaf.rsplit_once('.') {
        Some((stem, ext)) => {
            v.push(join(&format!("{stem}/{ext}")));
            v.push(join(&format!("{ext}.{stem}")));
            if ext == "mod" {
                v.push(join(stem));
            }
        }
        None => v.push(join(leaf)),
    }
    Some(v)
}

fn hook_is_file(p: &Path) -> Option<bool> {
    let names = ros_names(p)?;
    Some(names.iter().any(|n| rosbox::file_kind(n) == 1))
}

fn hook_read(p: &Path) -> Option<std::io::Result<Vec<u8>>> {
    let names = ros_names(p)?;
    for n in &names {
        if rosbox::file_kind(n) == 1 {
            if let Some(b) = rosbox::file_load(n) {
                return Some(Ok(b));
            }
        }
    }
    Some(Err(std::io::Error::new(std::io::ErrorKind::NotFound, format!("{} not found", names[0]))))
}

/// How a module's file is named in a message: its RISC OS name if it
/// has one.
fn shown(p: &Path) -> String {
    match ros_names(p) {
        Some(names) => names
            .iter()
            .find(|n| rosbox::file_kind(n) == 1)
            .cloned()
            .unwrap_or_else(|| names[0].clone()),
        None => p.display().to_string(),
    }
}

// ── The search path ──────────────────────────────────────────────────────

fn search_path(entry: &Path) -> SearchPath {
    let mut sp = SearchPath::new();
    if let Some(parent) = entry.parent() {
        sp.push(parent);
    }
    let root = LIBRARY
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_else(|| PathBuf::from("/usr/lib/modula2"));
    if let Ok(entries) = std::fs::read_dir(&root) {
        let mut dirs: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.is_dir() && p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.ends_with("def"))
            })
            .collect();
        // boxdef first: the box's own modules come before any of the same name
        dirs.sort_by_key(|p| (p.file_name().map(|n| n != "boxdef"), p.clone()));
        for d in dirs {
            sp.push(d);
        }
    }
    sp
}

/// The host-style name of the program: `dir/Stem.mod`.
fn entry_path(ros: &str) -> PathBuf {
    let (dir, leaf) = match ros.rfind(['.', ':']) {
        Some(i) if ros.as_bytes()[i] == b'.' => (&ros[..i], &ros[i + 1..]),
        Some(i) => (&ros[..=i], &ros[i + 1..]),
        None => ("", ros),
    };
    let stem = leaf.strip_suffix("/mod").unwrap_or(leaf);
    if dir.is_empty() {
        PathBuf::from(format!("{stem}.mod"))
    } else if dir.ends_with(':') {
        // "RAM::RamDisc0.$" style roots end in "$"; a bare "X:" is a path variable
        PathBuf::from(format!("{dir}{stem}.mod"))
    } else {
        PathBuf::from(format!("{dir}/{stem}.mod"))
    }
}

// ── A run ────────────────────────────────────────────────────────────────

fn compile_and_run(name: &str, args: Vec<String>, flags: u32) -> i32 {
    let t0 = Instant::now();
    newm2_llvm::BOX_DEBUG.store(flags & DEBUG != 0, std::sync::atomic::Ordering::Relaxed);
    let entry = entry_path(name);
    let sp = search_path(&entry);
    let env = Env::target_default().with("BOX", true).with("RISCOS", true);
    let graph = match newm2_loader::build_module_graph_with_extra_roots(&entry, &sp, &env, None, &[]) {
        Ok(g) => g,
        Err(e) => {
            let at = e.path.as_deref().map(shown).unwrap_or_else(|| name.to_string());
            out(&format!("{at}:0: error: {}\n", e.message));
            return -1;
        }
    };
    let sema = newm2_sema::check_module_graph_strict(&graph, false);
    if sema.has_errors() {
        let mut n = 0;
        for d in &sema.diagnostics {
            let sev = match d.severity {
                newm2_sema::Severity::Error => "error",
                newm2_sema::Severity::Warning => "warning",
            };
            let node = graph.get(d.module_id);
            let file = node
                .impl_path
                .as_deref()
                .or(node.def_path.as_deref())
                .map(shown)
                .unwrap_or_else(|| node.name.clone());
            out(&format!("{file}:{}: {sev}: {}\n", d.span.start.line, d.message));
            n += 1;
            if n >= 50 {
                out("(more errors not shown)\n");
                break;
            }
        }
        return -1;
    }
    let t_front = t0.elapsed();
    let mode = MemoryMode::NoGc;
    let lowered: Vec<_> = graph
        .topo_order
        .iter()
        .filter_map(|&mid| lower_module_opts(&graph, mid, &sema, mode, true))
        .collect();
    let refs: Vec<_> = lowered.iter().collect();
    let opt = match (flags >> 4) & 7 {
        0 => 2,
        n => n - 1,
    };
    let opts = CodegenOptions { memory_mode: mode, opt_level: opt, aot: false, m2_heap: false, protect_heap: false };
    if flags & COMPILE_ONLY != 0 {
        // Code is made too, so that -c finds what only the back end sees
        let r = newm2_llvm::compile_modules_box(&refs, &sema, opts);
        if flags & TIMES != 0 {
            out(&format!("Compiled in {} ms (front end {} ms)\n", t0.elapsed().as_millis(), t_front.as_millis()));
        }
        return match r {
            Ok(()) => 0,
            Err(e) => {
                out(&format!("{name}:0: error: {e}\n"));
                -1
            }
        };
    }
    let mut argv = vec![graph.get(*graph.topo_order.last().unwrap()).name.clone()];
    argv.extend(args);
    newm2_runtime::nm2_program_args_set(argv);
    let report = |ms: u128| {
        if flags & TIMES != 0 {
            out(&format!("Compiled in {ms} ms (front end {} ms)\n", t_front.as_millis()));
        }
    };
    match newm2_llvm::run_modules_box(&refs, &sema, opts, &report, t0) {
        Ok(code) => code,
        Err(e) => {
            out(&format!("{e}\n"));
            -5
        }
    }
}

fn reset_run() {
    newm2_runtime::file::close_all();
    rosbox::clear_stop();
    rosbox::arena_reset();
    newm2_runtime::termination::reset_termination();
    newm2_runtime::io::reset_stdin();
}

// ── The C API (m2_box.h) ─────────────────────────────────────────────────

/// Sets the hooks (kept: the module's static table).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn m2_box_set_hooks(h: *const Hooks) {
    rosbox::set_hooks(h);
    newm2_loader::vfs::set_hooks(Some(newm2_loader::vfs::Hooks { is_file: hook_is_file, read: hook_read }));
}

/// Where the standard library is (a Linux path), NULL for the ROM's.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn m2_box_set_library(dir: *const c_char) {
    *LIBRARY.lock().unwrap() = if dir.is_null() {
        None
    } else {
        Some(PathBuf::from(unsafe { CStr::from_ptr(dir) }.to_string_lossy().into_owned()))
    };
}

/// Compiles and runs the program module `name` (a RISC OS name): its exit
/// code (HALT's), or -1 it did not compile, -2 no memory, -3 it could not
/// be started, -5 it stopped with an exception (reported).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn m2_box_run(name: *const c_char, argc: c_int, argv: *const *const c_char, flags: u32) -> c_int {
    reset_run();
    let name = unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned();
    let mut args = Vec::new();
    for i in 1..argc.max(0) as usize {
        let a = unsafe { *argv.add(i) };
        if !a.is_null() {
            args.push(unsafe { CStr::from_ptr(a) }.to_string_lossy().into_owned());
        }
    }
    match std::panic::catch_unwind(|| compile_and_run(&name, args, flags)) {
        Ok(rc) => rc,
        Err(p) => {
            let msg = p
                .downcast_ref::<String>()
                .map(String::as_str)
                .or_else(|| p.downcast_ref::<&str>().copied())
                .unwrap_or("internal error");
            out(&format!("Modula-2: internal error: {msg}\n"));
            -3
        }
    }
}

/// Escape: the program ends at its next output, input or SWI.
#[unsafe(no_mangle)]
pub extern "C" fn m2_box_stop() {
    rosbox::request_stop();
}

/// After a fault jumped out of a run: the runtime's state is reset.
#[unsafe(no_mangle)]
pub extern "C" fn m2_box_recover() {
    newm2_llvm::box_recover();
    reset_run();
}

/// The run is over (and the module has removed its dynamic area).
#[unsafe(no_mangle)]
pub extern "C" fn m2_box_end_run() {
    newm2_llvm::box_end_run();
    reset_run();
}
