//! Subprocess + file helpers for the macOS runtime — the native equivalent of
//! the Windows build's `RunProg` / file utilities, used by the IDE to build and
//! run the editor buffer and capture the compiler's output.

#![cfg(not(windows))]

use std::process::Command;
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

/// `Proc.Complete(path, line, col, VAR out): INTEGER` — run the compiler's
/// `complete` command on `path` at (1-based `line`, 0-based `col`) and capture
/// its `name<TAB>kind<TAB>detail` candidate lines into `out`. Returns the number
/// of candidates (-1 on failure). Uses the running driver binary itself.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_ide_complete(
    path_ptr: *const u16,
    path_high: u64,
    line: i64,
    col: i64,
    out_ptr: *mut u16,
    out_high: u64,
) -> i64 {
    let path = wide_to_string(path_ptr, path_high);
    let exe = match std::env::current_exe() {
        Ok(e) => e,
        Err(_) => return -1,
    };
    let out = Command::new(&exe)
        .arg("complete")
        .arg(&path)
        .arg(line.to_string())
        .arg(col.to_string())
        .arg("--library")
        .arg("library")
        .output();
    match out {
        Ok(o) => {
            let s = String::from_utf8_lossy(&o.stdout).into_owned();
            let count = s.lines().filter(|l| !l.trim().is_empty()).count() as i64;
            write_wide(out_ptr, out_high, &s);
            count
        }
        Err(_) => -1,
    }
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
