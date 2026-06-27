//! macOS / Unix resident compiler daemon — the warm channel for the IDE's
//! read-only calls (`complete` / `describe` / `check`) so they don't pay a
//! process spawn + LLVM init each time. Same framed protocol as the Windows
//! daemon (a 4-byte little-endian length prefix, then a UTF-8 payload), but over
//! a Unix-domain socket. The verb handlers reuse the crate's `*_core` functions,
//! so a daemon answer is byte-identical to the equivalent CLI subcommand output.

#![cfg(unix)]

use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::process::ExitCode;

use newm2_sema::{SemaResult, Severity};

const DEFAULT_SOCKET: &str = "/tmp/macm2-driver.sock";
const MAX_FRAME: usize = 64 * 1024 * 1024;

/// `newm2-driver daemon [--socket PATH] [--library PATH ...] [...driver flags]`.
/// Non-`--socket` flags become the base `DriverOptions` for every request.
pub fn run_daemon(rest: &[String]) -> ExitCode {
    let mut socket = DEFAULT_SOCKET.to_string();
    let mut base: Vec<String> = Vec::new();
    let mut i = 0;
    while i < rest.len() {
        if rest[i] == "--socket" {
            if let Some(n) = rest.get(i + 1) {
                socket = n.clone();
            }
            i += 2;
            continue;
        }
        if let Some(n) = rest[i].strip_prefix("--socket=") {
            socket = n.to_string();
            i += 1;
            continue;
        }
        base.push(rest[i].clone());
        i += 1;
    }
    serve(base, socket)
}

fn serve(base: Vec<String>, socket: String) -> ExitCode {
    // Don't start a second daemon: if one already owns the socket, exit. Only
    // remove the socket file when it's stale (no daemon answering) — never steal
    // a live one out from under it.
    let listener = match UnixListener::bind(&socket) {
        Ok(l) => l,
        Err(_) => {
            if std::os::unix::net::UnixStream::connect(&socket).is_ok() {
                eprintln!("newm2 daemon: already running on {socket}");
                return ExitCode::SUCCESS;
            }
            let _ = std::fs::remove_file(&socket); // stale socket from a dead daemon
            match UnixListener::bind(&socket) {
                Ok(l) => l,
                Err(e) => {
                    eprintln!("newm2 daemon: bind {socket}: {e}");
                    return ExitCode::from(1);
                }
            }
        }
    };
    eprintln!("newm2 daemon: listening on {socket}");
    for conn in listener.incoming() {
        let mut s = match conn {
            Ok(s) => s,
            Err(_) => continue,
        };
        // Serve framed requests on this connection until the client closes it.
        loop {
            let req = match read_frame(&mut s) {
                Some(r) => r,
                None => break,
            };
            let (resp, halt) = handle(&req, &base);
            if write_frame(&mut s, resp.as_bytes()).is_err() {
                break;
            }
            if halt {
                let _ = std::fs::remove_file(&socket);
                eprintln!("newm2 daemon: shutdown");
                return ExitCode::SUCCESS;
            }
        }
    }
    ExitCode::SUCCESS
}

// ---- framing (4-byte LE length prefix + UTF-8 payload) ----

fn read_frame(s: &mut impl Read) -> Option<String> {
    let mut len = [0u8; 4];
    s.read_exact(&mut len).ok()?;
    let n = u32::from_le_bytes(len) as usize;
    if n == 0 {
        return Some(String::new());
    }
    if n > MAX_FRAME {
        return None;
    }
    let mut buf = vec![0u8; n];
    s.read_exact(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

fn write_frame(s: &mut impl Write, payload: &[u8]) -> std::io::Result<()> {
    s.write_all(&(payload.len() as u32).to_le_bytes())?;
    s.write_all(payload)?;
    s.flush()
}

// ---- dispatch ----

fn handle(req: &str, base: &[String]) -> (String, bool) {
    let words = read_words(req);
    let Some(verb) = words.first() else {
        return (String::new(), false);
    };
    match verb.as_str() {
        "ping" => ("pong".to_string(), false),
        "version" => (format!("newm2-daemon {}", env!("CARGO_PKG_VERSION")), false),
        "shutdown" => ("bye".to_string(), true),
        "check" => (cmd_check(words.get(1), base), false),
        "complete" => (cmd_complete(words.get(1), words.get(2), words.get(3), base), false),
        "describe" => (cmd_describe(words.get(1), words.get(2), words.get(3), base), false),
        other => (err(format!("unknown command: {other}")), false),
    }
}

fn options(base: &[String]) -> Result<crate::DriverOptions, String> {
    crate::DriverOptions::parse(base)
}

fn diags_list(res: &SemaResult) -> String {
    let mut lines: Vec<String> = Vec::new();
    for d in &res.diagnostics {
        let sev = match d.severity {
            Severity::Error => "error",
            Severity::Warning => "warning",
        };
        lines.push(diag(d.span.start.line, d.span.start.column, sev, &d.message));
    }
    lines.join("\n")
}

fn cmd_check(file: Option<&String>, base: &[String]) -> String {
    let Some(file) = file else {
        return err("check: missing file");
    };
    let opts = match options(base) {
        Ok(o) => o,
        Err(e) => return err(e),
    };
    let graph = match crate::build_graph_from_entry(Path::new(file), &opts) {
        Ok(g) => g,
        Err(e) => return format!("errors\n{}", diag(0, 0, "error", &e.to_string())),
    };
    let res = crate::check_graph(&graph, &opts);
    let list = diags_list(&res);
    if list.is_empty() {
        "ok".to_string()
    } else {
        format!("errors\n{list}")
    }
}

/// `complete <file> <line> <col>` -> candidate lines `name<TAB>kind<TAB>detail`,
/// or `ok` when there are none. Same payload as the `complete` CLI verb.
fn cmd_complete(
    file: Option<&String>,
    line: Option<&String>,
    col: Option<&String>,
    base: &[String],
) -> String {
    let Some(file) = file else {
        return err("complete: missing file");
    };
    let Some(line) = line.and_then(|s| s.parse::<usize>().ok()) else {
        return err("complete: bad line");
    };
    let Some(col) = col.and_then(|s| s.parse::<usize>().ok()) else {
        return err("complete: bad col");
    };
    let opts = match options(base) {
        Ok(o) => o,
        Err(e) => return err(e),
    };
    let cands = crate::complete_core(file, line, col, &opts);
    if cands.is_empty() {
        return "ok".to_string();
    }
    cands
        .iter()
        .map(|c| format!("{}\t{}\t{}", c.name, c.kind, oneline(&c.detail)))
        .collect::<Vec<_>>()
        .join("\n")
}

/// `describe <file> <line> <col>` -> context-help markdown, or `ok` when nothing
/// resolves at the cursor.
fn cmd_describe(
    file: Option<&String>,
    line: Option<&String>,
    col: Option<&String>,
    base: &[String],
) -> String {
    let Some(file) = file else {
        return err("describe: missing file");
    };
    let Some(line) = line.and_then(|s| s.parse::<usize>().ok()) else {
        return err("describe: bad line");
    };
    let Some(col) = col.and_then(|s| s.parse::<usize>().ok()) else {
        return err("describe: bad col");
    };
    let opts = match options(base) {
        Ok(o) => o,
        Err(e) => return err(e),
    };
    match crate::describe_core(file, line, col, &opts) {
        Some(md) if !md.trim().is_empty() => md,
        _ => "ok".to_string(),
    }
}

// ---- helpers (mirror the Windows daemon's minimal ptcl reader) ----

fn read_words(line: &str) -> Vec<String> {
    let cs: Vec<char> = line.chars().collect();
    let mut words = Vec::new();
    let mut i = 0;
    while i < cs.len() {
        while i < cs.len() && cs[i].is_whitespace() {
            i += 1;
        }
        if i >= cs.len() {
            break;
        }
        let mut w = String::new();
        match cs[i] {
            '"' => {
                i += 1;
                while i < cs.len() && cs[i] != '"' {
                    w.push(cs[i]);
                    i += 1;
                }
                if i < cs.len() {
                    i += 1;
                }
            }
            '{' => {
                let mut depth = 1;
                i += 1;
                while i < cs.len() && depth > 0 {
                    match cs[i] {
                        '{' => {
                            depth += 1;
                            w.push('{');
                        }
                        '}' => {
                            depth -= 1;
                            if depth > 0 {
                                w.push('}');
                            }
                        }
                        c => w.push(c),
                    }
                    i += 1;
                }
            }
            _ => {
                while i < cs.len() && !cs[i].is_whitespace() {
                    w.push(cs[i]);
                    i += 1;
                }
            }
        }
        words.push(w);
    }
    words
}

fn oneline(s: &str) -> String {
    s.replace('\r', "").replace('\n', " ")
}

fn err(msg: impl std::fmt::Display) -> String {
    format!("error {}", oneline(&msg.to_string()))
}

fn diag(line: usize, col: usize, sev: &str, msg: &str) -> String {
    format!("{} {} {} {}", line, col, sev, oneline(msg))
}
