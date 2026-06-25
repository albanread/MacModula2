//! Subprocess + file helpers for the macOS runtime — the native equivalent of
//! the Windows build's `RunProg` / file utilities, used by the IDE to build and
//! run the editor buffer and capture the compiler's output.

#![cfg(not(windows))]

use std::process::Command;

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
