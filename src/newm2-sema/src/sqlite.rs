//! Minimal read-only libsqlite3 binding, linked from the macOS SDK (`-lsqlite3`).
//!
//! Just enough to query the shared `cocoa_data/cocoa.sqlite` mirror: open a
//! database read-only, run a parameter-free or single-text-bound query, and read
//! column 0 of the result rows as strings. No external crate (rusqlite pulls a
//! vendored C build over the network); this is the same "bind the system library
//! directly" approach the generator uses for libobjc.

use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::Path;
use std::ptr;

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_OPEN_READONLY: c_int = 0x0000_0001;
const SQLITE_OPEN_FULLMUTEX: c_int = 0x0001_0000; // serialize; safe to share across threads
const SQLITE_TRANSIENT: isize = -1; // tell sqlite to copy bound text immediately

#[link(name = "sqlite3")]
unsafe extern "C" {
    fn sqlite3_open_v2(
        filename: *const c_char,
        db: *mut *mut c_void,
        flags: c_int,
        vfs: *const c_char,
    ) -> c_int;
    fn sqlite3_close(db: *mut c_void) -> c_int;
    fn sqlite3_prepare_v2(
        db: *mut c_void,
        sql: *const c_char,
        n_byte: c_int,
        stmt: *mut *mut c_void,
        tail: *mut *const c_char,
    ) -> c_int;
    fn sqlite3_bind_text(
        stmt: *mut c_void,
        idx: c_int,
        text: *const c_char,
        n: c_int,
        destructor: *mut c_void,
    ) -> c_int;
    fn sqlite3_step(stmt: *mut c_void) -> c_int;
    fn sqlite3_column_text(stmt: *mut c_void, col: c_int) -> *const u8;
    fn sqlite3_finalize(stmt: *mut c_void) -> c_int;
}

/// An open, read-only SQLite connection. Opened with FULLMUTEX so the handle is
/// safe to use from any thread (the Send/Sync impls below rely on that).
pub struct Sqlite {
    db: *mut c_void,
}

unsafe impl Send for Sqlite {}
unsafe impl Sync for Sqlite {}

impl Drop for Sqlite {
    fn drop(&mut self) {
        unsafe { sqlite3_close(self.db) };
    }
}

impl Sqlite {
    pub fn open(path: &Path) -> Option<Sqlite> {
        let c = CString::new(path.to_str()?).ok()?;
        let mut db: *mut c_void = ptr::null_mut();
        let rc = unsafe {
            sqlite3_open_v2(
                c.as_ptr(),
                &mut db,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                ptr::null(),
            )
        };
        if rc != SQLITE_OK || db.is_null() {
            if !db.is_null() {
                unsafe { sqlite3_close(db) };
            }
            return None;
        }
        Some(Sqlite { db })
    }

    fn prepare(&self, sql: &str) -> Option<*mut c_void> {
        let c = CString::new(sql).ok()?;
        let mut stmt: *mut c_void = ptr::null_mut();
        let rc = unsafe { sqlite3_prepare_v2(self.db, c.as_ptr(), -1, &mut stmt, ptr::null_mut()) };
        if rc != SQLITE_OK || stmt.is_null() {
            return None;
        }
        Some(stmt)
    }

    /// First row's column 0 as a String, optionally binding one text param at `?1`.
    pub fn query_one(&self, sql: &str, bind: Option<&str>) -> Option<String> {
        let stmt = self.prepare(sql)?;
        let bound = bind.and_then(|b| CString::new(b).ok());
        let mut out = None;
        unsafe {
            if let Some(cb) = &bound {
                sqlite3_bind_text(
                    stmt,
                    1,
                    cb.as_ptr(),
                    cb.as_bytes().len() as c_int,
                    SQLITE_TRANSIENT as *mut c_void,
                );
            }
            if sqlite3_step(stmt) == SQLITE_ROW {
                out = column0(stmt);
            }
            sqlite3_finalize(stmt);
        }
        out
    }

    /// Column 0 of every row, for a parameter-free query.
    pub fn query_all(&self, sql: &str) -> Vec<String> {
        let mut out = Vec::new();
        if let Some(stmt) = self.prepare(sql) {
            unsafe {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let Some(s) = column0(stmt) {
                        out.push(s);
                    }
                }
                sqlite3_finalize(stmt);
            }
        }
        out
    }
}

unsafe fn column0(stmt: *mut c_void) -> Option<String> {
    let p = unsafe { sqlite3_column_text(stmt, 0) };
    if p.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(p as *const c_char) }.to_string_lossy().into_owned())
}
