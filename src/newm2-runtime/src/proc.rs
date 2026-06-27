//! Subprocess + file helpers for the macOS runtime — the native equivalent of
//! the Windows build's `RunProg` / file utilities, used by the IDE to build and
//! run the editor buffer and capture the compiler's output.

#![cfg(not(windows))]

use std::collections::HashMap;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::OnceLock;

/// The most recent `ListDir` result, so `DirEntry` can return names by index
/// without the caller re-splitting a packed string.
fn dir_cache() -> &'static Mutex<Vec<String>> {
    static C: OnceLock<Mutex<Vec<String>>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(Vec::new()))
}

/// Decode a (wide) M2 `ARRAY OF CHAR` `(ptr, high)` to a Rust `String`, stopping
/// at the first NUL.
fn wide_to_string(ptr: *const u16, high: u64) -> String {
    if ptr.is_null() {
        return String::new();
    }
    let cap = (high as usize).saturating_add(1);
    let units = unsafe { std::slice::from_raw_parts(ptr, cap) };
    let end = units.iter().position(|&u| u == 0).unwrap_or(units.len());
    String::from_utf16_lossy(&units[..end])
}

/// Write `s` into a (wide) M2 `ARRAY OF CHAR` `(ptr, high)`, NUL-terminated.
fn write_wide(ptr: *mut u16, high: u64, s: &str) {
    if ptr.is_null() {
        return;
    }
    let cap = (high as usize).saturating_add(1);
    if cap == 0 {
        return;
    }
    let units: Vec<u16> = s.encode_utf16().collect();
    let n = units.len().min(cap - 1);
    for (i, &u) in units.iter().take(n).enumerate() {
        unsafe { *ptr.add(i) = u };
    }
    unsafe { *ptr.add(n) = 0 };
}

/// `Proc.RunCapture(cmd, VAR output): INTEGER` — run `cmd` via `/bin/sh -c`,
/// capture stdout+stderr into `output`, and return the process exit code
/// (-1 on spawn failure).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_run_capture(
    cmd_ptr: *const u16,
    cmd_high: u64,
    out_ptr: *mut u16,
    out_high: u64,
) -> i64 {
    let cmd = wide_to_string(cmd_ptr, cmd_high);
    match Command::new("/bin/sh").arg("-c").arg(&cmd).output() {
        Ok(o) => {
            let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
            s.push_str(&String::from_utf8_lossy(&o.stderr));
            write_wide(out_ptr, out_high, &s);
            o.status.code().unwrap_or(-1) as i64
        }
        Err(e) => {
            write_wide(out_ptr, out_high, &format!("failed to run command: {e}"));
            -1
        }
    }
}

// ---- asynchronous run -----------------------------------------------------
// `RunCapture` blocks the calling thread until the child closes its stdout. For
// a GUI program (e.g. a Cocoa demo) that never happens until the user closes its
// window, so running it on the IDE's main thread freezes the whole UI (the
// beachball). The async API below runs the command on a worker thread and lets
// the caller poll for completion from its run-loop timer, so the IDE stays live.

/// Result slot shared with the worker thread: `Some((exit_code, output))` once
/// the child has finished.
type JobSlot = Arc<Mutex<Option<(i64, String)>>>;

fn job_table() -> &'static Mutex<HashMap<u64, JobSlot>> {
    static T: OnceLock<Mutex<HashMap<u64, JobSlot>>> = OnceLock::new();
    T.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_JOB_ID: AtomicU64 = AtomicU64::new(1);

/// `Proc.RunAsync(cmd): INTEGER` — start `cmd` via `/bin/sh -c` on a worker
/// thread and return a job id (>0), or -1 if the table is unavailable. Never
/// blocks: poll with `RunDone` and gather the result with `RunCollect`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_run_async(cmd_ptr: *const u16, cmd_high: u64) -> i64 {
    let cmd = wide_to_string(cmd_ptr, cmd_high);
    let slot: JobSlot = Arc::new(Mutex::new(None));
    let id = NEXT_JOB_ID.fetch_add(1, Ordering::Relaxed);
    {
        let Ok(mut t) = job_table().lock() else {
            return -1;
        };
        t.insert(id, slot.clone());
    }
    // Detach the worker: it owns its slot clone and stores the result there.
    std::thread::spawn(move || {
        let res = match Command::new("/bin/sh").arg("-c").arg(&cmd).output() {
            Ok(o) => {
                let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
                s.push_str(&String::from_utf8_lossy(&o.stderr));
                (o.status.code().unwrap_or(-1) as i64, s)
            }
            Err(e) => (-1, format!("failed to run command: {e}")),
        };
        if let Ok(mut g) = slot.lock() {
            *g = Some(res);
        }
    });
    id as i64
}

/// `Proc.RunDone(id): INTEGER` — 1 if the job has finished, 0 if still running,
/// -1 if `id` is unknown (already collected or never existed).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_run_done(id: i64) -> i64 {
    let Ok(t) = job_table().lock() else {
        return -1;
    };
    match t.get(&(id as u64)) {
        Some(slot) => match slot.lock() {
            Ok(g) if g.is_some() => 1,
            _ => 0,
        },
        None => -1,
    }
}

/// `Proc.RunCollect(id, VAR output): INTEGER` — when the job is done, copy its
/// captured stdout+stderr into `output`, drop the job, and return the exit code.
/// Returns -2 if the job is not finished yet (nothing written), -1 if unknown.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_run_collect(
    id: i64,
    out_ptr: *mut u16,
    out_high: u64,
) -> i64 {
    // Take the slot Arc out under a short lock, but only remove the job once we
    // know its result is ready (so a premature poll doesn't lose the output).
    let slot = {
        let Ok(t) = job_table().lock() else {
            return -1;
        };
        match t.get(&(id as u64)) {
            Some(s) => s.clone(),
            None => return -1,
        }
    };
    let ready = slot.lock().ok().and_then(|mut g| g.take());
    match ready {
        Some((code, s)) => {
            if let Ok(mut t) = job_table().lock() {
                t.remove(&(id as u64));
            }
            write_wide(out_ptr, out_high, &s);
            code
        }
        None => -2, // not finished yet — caller should keep polling
    }
}

/// `Proc.ListDir(path): INTEGER` — list the entries of `path` (subdirectories
/// first, then files, each group sorted), cache them, and return the count (-1
/// if the directory can't be read). Hidden entries (leading `.`) are skipped.
/// Read each name with `DirEntry`, and use `IsDir` to tell folders from files so
/// a browser can descend into one or open the other.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_list_dir(path_ptr: *const u16, path_high: u64) -> i64 {
    let path = wide_to_string(path_ptr, path_high);
    let Ok(rd) = std::fs::read_dir(&path) else {
        return -1;
    };
    let mut dirs: Vec<String> = Vec::new();
    let mut files: Vec<String> = Vec::new();
    for entry in rd.flatten() {
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            dirs.push(name);
        } else {
            files.push(name);
        }
    }
    dirs.sort();
    files.sort();
    dirs.extend(files);
    let names = dirs;
    let n = names.len() as i64;
    if let Ok(mut c) = dir_cache().lock() {
        *c = names;
    }
    n
}

/// `Proc.DirEntry(index, VAR name): INTEGER` — the cached file name at `index`.
/// Returns the length, or -1 if out of range.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_dir_entry(index: i64, out_ptr: *mut u16, out_high: u64) -> i64 {
    let Ok(c) = dir_cache().lock() else {
        return -1;
    };
    if index < 0 || index as usize >= c.len() {
        return -1;
    }
    let name = &c[index as usize];
    write_wide(out_ptr, out_high, name);
    name.encode_utf16().count() as i64
}

/// `Proc.IsDir(path): BOOLEAN` — 1 if `path` exists and is a directory, else 0.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_is_dir(path_ptr: *const u16, path_high: u64) -> i64 {
    let path = wide_to_string(path_ptr, path_high);
    if std::path::Path::new(&path).is_dir() {
        1
    } else {
        0
    }
}

/// Locate the `newm2-driver` (compiler) binary to run `complete` against.
///
/// `current_exe()` is correct ONLY when the IDE was launched via `newm2-driver
/// run …` (then the running binary IS the driver). But the IDE also ships as a
/// standalone AOT executable (`macos_panes_ide.exe`); run that way, `current_exe`
/// is the GUI itself, which ignores argv and would launch a SECOND IDE instead of
/// completing — the historical completion hang. So: use `current_exe` only if it
/// is actually the driver, otherwise fall back to the build-tree driver (the same
/// `./target/{debug,release}/newm2-driver` the IDE's Build & Run already assumes,
/// resolved against the current working directory = repo root).
fn resolve_driver_exe() -> std::path::PathBuf {
    use std::path::PathBuf;
    if let Ok(e) = std::env::current_exe() {
        if e.file_name().and_then(|n| n.to_str()) == Some("newm2-driver") {
            return e;
        }
    }
    for cand in ["target/debug/newm2-driver", "target/release/newm2-driver"] {
        let p = PathBuf::from(cand);
        if p.exists() {
            return p;
        }
    }
    // Last resort: whatever current_exe was (keeps prior behaviour if the build
    // tree isn't where we expect).
    std::env::current_exe().unwrap_or_else(|_| PathBuf::from("newm2-driver"))
}

// ---- resident-daemon client (the IDE's warm channel) ----------------------
//
// complete/describe normally route to one long-lived `newm2-driver daemon` over
// a Unix socket, so they don't pay a process spawn + LLVM init each call. The
// daemon is started lazily on first use. Any miss or error falls back to
// spawning the CLI verb, so behaviour is never worse than before.

fn daemon_socket() -> std::path::PathBuf {
    std::path::PathBuf::from("/tmp/macm2-driver.sock")
}

#[cfg(unix)]
fn daemon_frame_write(s: &mut std::os::unix::net::UnixStream, payload: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    s.write_all(&(payload.len() as u32).to_le_bytes())?;
    s.write_all(payload)?;
    s.flush()
}

#[cfg(unix)]
fn daemon_frame_read(s: &mut std::os::unix::net::UnixStream) -> Option<String> {
    use std::io::Read;
    let mut len = [0u8; 4];
    s.read_exact(&mut len).ok()?;
    let n = u32::from_le_bytes(len) as usize;
    if n == 0 {
        return Some(String::new());
    }
    if n > 64 * 1024 * 1024 {
        return None;
    }
    let mut buf = vec![0u8; n];
    s.read_exact(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

#[cfg(unix)]
fn start_daemon() {
    use std::process::Stdio;
    let exe = resolve_driver_exe();
    let _ = Command::new(exe)
        .arg("daemon")
        .arg("--socket")
        .arg(daemon_socket())
        .arg("--library")
        .arg("library")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

/// Send `req` to the resident daemon and return its response, starting the
/// daemon on first use. `None` => unreachable (caller falls back to spawning).
#[cfg(unix)]
fn daemon_request(req: &str) -> Option<String> {
    use std::os::unix::net::UnixStream;
    use std::time::Duration;
    let path = daemon_socket();
    for attempt in 0..2 {
        if let Ok(mut s) = UnixStream::connect(&path) {
            let _ = s.set_read_timeout(Some(Duration::from_secs(4)));
            let _ = s.set_write_timeout(Some(Duration::from_secs(4)));
            if daemon_frame_write(&mut s, req.as_bytes()).is_ok() {
                return daemon_frame_read(&mut s);
            }
            return None;
        }
        if attempt == 0 {
            start_daemon();
            std::thread::sleep(Duration::from_millis(500));
        }
    }
    None
}

#[cfg(not(unix))]
fn daemon_request(_req: &str) -> Option<String> {
    None
}

/// `Proc.Complete(path, line, col, VAR out): INTEGER` — run the compiler's
/// `complete` command on `path` at (1-based `line`, 0-based `col`) and capture
/// its `name<TAB>kind<TAB>detail` candidate lines into `out`. Returns the number
/// of candidates, or a negative sentinel on failure:
///   -1  could not spawn the child / read its output
///   -2  the child overran the watchdog and was killed (see below)
///
/// Uses the running driver binary itself (`current_exe`).
///
/// WATCHDOG: the child is spawned (not `.output()`-blocked) and waited on with a
/// hard deadline. A healthy completion is ~15ms; if the child ever wedges — a
/// pathological mid-edit parse, a future remote/daemon path that stalls, or the
/// degenerate case where `current_exe` is itself a GUI whose event loop never
/// exits — it is KILLED after `COMPLETE_TIMEOUT` and we return -2 instead of
/// hanging. The IDE calls this synchronously on the main thread, so an unbounded
/// wait here would freeze the whole UI and force a hard shutdown; the deadline
/// makes that impossible. See projects/macide/macos_panes_ide.mod.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_ide_complete(
    path_ptr: *const u16,
    path_high: u64,
    line: i64,
    col: i64,
    out_ptr: *mut u16,
    out_high: u64,
) -> i64 {
    use std::io::Read;
    use std::process::Stdio;
    use std::time::{Duration, Instant};

    const COMPLETE_TIMEOUT: Duration = Duration::from_secs(4);

    let path = wide_to_string(path_ptr, path_high);

    // Warm path: ask the resident daemon first; fall through to a spawn on miss.
    if let Some(resp) = daemon_request(&format!("complete {{{path}}} {line} {col}")) {
        if resp == "ok" {
            write_wide(out_ptr, out_high, "");
            return 0;
        }
        if !resp.starts_with("error") {
            let count = resp.lines().filter(|l| !l.trim().is_empty()).count() as i64;
            write_wide(out_ptr, out_high, &resp);
            return count;
        }
    }

    let exe = resolve_driver_exe();
    let mut child = match Command::new(&exe)
        .arg("complete")
        .arg(&path)
        .arg(line.to_string())
        .arg(col.to_string())
        .arg("--library")
        .arg("library")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return -1,
    };

    // Poll for exit up to the deadline; kill the child if it overruns so the
    // caller (the IDE's main thread) is never blocked indefinitely.
    let deadline = Instant::now() + COMPLETE_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    write_wide(out_ptr, out_high, "");
                    return -2;
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return -1;
            }
        }
    }

    // Completion output is small (a candidate list), well under the pipe buffer,
    // so reading it after exit cannot deadlock.
    let mut s = String::new();
    if let Some(mut so) = child.stdout.take() {
        let _ = so.read_to_string(&mut s);
    }
    let count = s.lines().filter(|l| !l.trim().is_empty()).count() as i64;
    write_wide(out_ptr, out_high, &s);
    count
}

/// `Proc.Describe(path, line, col, VAR out): INTEGER` — run the compiler's
/// `describe` command on `path` at (1-based `line`, 0-based `col`) and capture the
/// context-help **markdown** for the symbol there into `out`. Returns the number
/// of UTF-16 code units written, `0` when nothing resolves at the cursor, or a
/// negative sentinel on failure (-1 spawn/read, -2 watchdog kill). Same driver +
/// watchdog discipline as [`nm2_ide_complete`]; used by the IDE's context help.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_ide_describe(
    path_ptr: *const u16,
    path_high: u64,
    line: i64,
    col: i64,
    out_ptr: *mut u16,
    out_high: u64,
) -> i64 {
    use std::io::Read;
    use std::process::Stdio;
    use std::time::{Duration, Instant};

    const DESCRIBE_TIMEOUT: Duration = Duration::from_secs(4);

    let path = wide_to_string(path_ptr, path_high);

    // Warm path: ask the resident daemon first; fall through to a spawn on miss.
    if let Some(resp) = daemon_request(&format!("describe {{{path}}} {line} {col}")) {
        if resp == "ok" {
            write_wide(out_ptr, out_high, "");
            return 0;
        }
        if !resp.starts_with("error") {
            let len = resp.encode_utf16().count() as i64;
            write_wide(out_ptr, out_high, &resp);
            return len;
        }
    }

    let exe = resolve_driver_exe();
    let mut child = match Command::new(&exe)
        .arg("describe")
        .arg(&path)
        .arg(line.to_string())
        .arg(col.to_string())
        .arg("--library")
        .arg("library")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return -1,
    };

    let deadline = Instant::now() + DESCRIBE_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    write_wide(out_ptr, out_high, "");
                    return -2;
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return -1;
            }
        }
    }

    let mut s = String::new();
    if let Some(mut so) = child.stdout.take() {
        let _ = so.read_to_string(&mut s);
    }
    if s.trim().is_empty() {
        write_wide(out_ptr, out_high, "");
        return 0;
    }
    let len = s.encode_utf16().count() as i64;
    write_wide(out_ptr, out_high, &s);
    len
}

/// `Proc.ReadFile(path, VAR content): INTEGER` — read `path` (UTF-8) into a
/// (wide) M2 `ARRAY OF CHAR`. Returns the number of code units read, or -1 on
/// error.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_read_file(
    path_ptr: *const u16,
    path_high: u64,
    out_ptr: *mut u16,
    out_high: u64,
) -> i64 {
    let path = wide_to_string(path_ptr, path_high);
    match std::fs::read_to_string(&path) {
        Ok(s) => {
            write_wide(out_ptr, out_high, &s);
            s.encode_utf16().count() as i64
        }
        Err(_) => -1,
    }
}

/// `Proc.WriteFile(path, content): INTEGER` — write `content` to `path` as UTF-8.
/// Returns 0 on success, -1 on error.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_write_file(
    path_ptr: *const u16,
    path_high: u64,
    content_ptr: *const u16,
    content_high: u64,
) -> i64 {
    let path = wide_to_string(path_ptr, path_high);
    let content = wide_to_string(content_ptr, content_high);
    match std::fs::write(&path, content) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// `Proc.WriteBytes(path, data, len)` — write `len` raw bytes from `data` to a
/// file (binary; for .wav / .mid output). Returns 0 on success, -1 on error.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_write_bytes(
    path_ptr: *const u16,
    path_high: u64,
    data: *const u8,
    len: u64,
) -> i64 {
    let path = wide_to_string(path_ptr, path_high);
    if data.is_null() {
        return -1;
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, len as usize) };
    match std::fs::write(&path, bytes) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

/// `Proc.FileSize(path)` — size of `path` in bytes, or -1 if it can't be read.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_file_size(path_ptr: *const u16, path_high: u64) -> i64 {
    let path = wide_to_string(path_ptr, path_high);
    match std::fs::metadata(&path) {
        Ok(m) => m.len() as i64,
        Err(_) => -1,
    }
}

/// `Proc.ReadBytes(path, buf, max)` — read up to `max` raw bytes of `path` into
/// `buf` (binary; for .wav input). Returns the number of bytes read, -1 on error.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_proc_read_bytes(
    path_ptr: *const u16,
    path_high: u64,
    buf: *mut u8,
    max: u64,
) -> i64 {
    let path = wide_to_string(path_ptr, path_high);
    if buf.is_null() {
        return -1;
    }
    match std::fs::read(&path) {
        Ok(data) => {
            let n = data.len().min(max as usize);
            unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), buf, n) };
            n as i64
        }
        Err(_) => -1,
    }
}
