# Compiler bugs found during the macOS port — portability audit for the Windows team

During a full compiler review on `macos-arm64-port` (lexer/parser/sema/IR/loader/GC), 9
commits fixed roughly 20 bugs. Since this repo's `main` branch is the codebase frozen at
the exact commit where the mac port forked off (`4460b6c`, 2026-06-23) — i.e. it *is* the
still-current Windows-only compiler as maintained separately — each fix was checked
against `main` to see whether it's a mac-specific defect or a bug inherited from the
shared frontend/runtime design. Most turned out to be the latter: present verbatim in
`main`, unrelated to anything macOS-specific.

This file lists exactly which ones apply to the Windows codebase, with `main`-branch
citations, so they can be ported back without re-deriving the analysis.

## Confirmed present in `main` — worth fixing there too

### RAISE with a value silently crashes (most severe)

`Stmt::Raise(Some(e))` evaluates the exception value expression, but codegen then
discards it and unconditionally emits `llvm.trap()` + `unreachable`
(`src/newm2-ir/src/lower.rs:2069`, `src/newm2-llvm/src/codegen.rs:1621`). Any Windows
program that does `RAISE SomeException(x)` — a legitimate ISO value-carrying raise —
traps/crashes today instead of raising a catchable exception. This is a real,
concrete runtime crash on valid input, not just a latent hazard.

### Lexer / preprocessor (`src/newm2-lexer/src/preprocess.rs`)

- **`VALIDVERSION:`/`VALIDVER:` pragma aliases are silent no-ops.** `apply_pragma_body`
  matches all three alias spellings in the outer `if let`, but the inner guard
  (`preprocess.rs:359-364`) re-tests the original text against `"VERSION:"` only, so
  `apply_version_names` is never called for the alias spellings — no diagnostic, and a
  later `%IF Name %THEN` guarded by it silently takes the FALSE branch even though the
  source declared the version active.
- **UTF-8 corruption in `%IF` expressions.** `read_expr_then` accumulates the directive
  text into a buffer via `buf.push(c as char)` on raw bytes (`preprocess.rs:496`) —
  casting individual UTF-8 continuation bytes to `char` corrupts any non-ASCII text
  inside a `%IF`-guarded region before the expression is evaluated.

### Parser (`src/newm2-parser/src/parser.rs`)

- **VAR initializer silently discarded.** `VAR x: INTEGER = 5;` parses and throws away
  the `= expr` part instead of rejecting it — the code is even commented "ADW
  extension" (`parser.rs:910-912`), but nothing downstream ever uses the parsed value,
  so it's a syntax error being silently accepted and ignored.
- **Typed CONST silently discarded.** `CONST x: INTEGER = 5;` (ISO CONST is untyped)
  parses and discards the `: type` part instead of rejecting it (`parser.rs:784-786`).

### Sema — type identity (`src/newm2-sema/src/types.rs`)

- **`Builtin::name()` collisions:** `SysWord`/`Word` → `"WORD"`, `SysByte`/`Byte` →
  `"BYTE"`, `SysAddress`/`Address` → `"ADDRESS"` (`types.rs:178-182`). This name feeds
  directly into `IfaceType::Builtin(b.name().to_string())` (`src/newm2-sema/src/iface.rs:235`),
  which is the serialized interface identity used by the `.m2i`/symcache system — two
  distinct types hashing to the same key risks returning a stale cached interface.

### Sema — control-flow / parameter-mode analysis (`src/newm2-sema/src/analyze.rs`)

- **EXCEPT-fallthrough not checked for definite-return.** The top-level check that a
  function-with-a-result-type can't fall off the end without RETURN calls
  `seq_completes(&body.body.stmts)` directly (`analyze.rs:5291`), and `stmt_completes`'s
  own `Block` arm (`analyze.rs:5349`) also calls `seq_completes(&b.stmts)` with no
  regard for `except`/`finally` — even though `ast::Block` has real ISO `except`/
  `finally` fields. A function body ending in an EXCEPT clause where not every handler
  path returns a value is incorrectly accepted as always-returning.
- **WITH-CONST bypass.** The WITH statement's readonly-target check is
  `readonly = is_readonly_target(ctx, designator, scope)` only (`analyze.rs:5844`),
  missing an OR against `is_const_param_target(...)` — a sibling call site earlier in
  the same file (`analyze.rs:5619-5621`) checks both, showing the omission here is a
  gap rather than intentional. Writing through a WITH-bound designator over a CONST
  parameter is incorrectly allowed.

### IR lowering (`src/newm2-ir/src/lower.rs`)

- **Capture analysis drops field/index expressions.** `collect_refs_expr`'s match ends
  in a `_ => {}` wildcard (`lower.rs:653`) with no arm for `ast::Expr::Postfix` — a
  nested procedure that captures an outer variable only through `outerRec.field` or
  `outerArr[i]` (never as a bare reference) silently fails to capture it.
- **ACHAR aggregate copy misses narrow/differently-sized char arrays.**
  `lower_aggregate_constructor`'s char-copy check only tests the fixed-size
  `array_char_count(st)` path (`lower.rs:3168`); there's no equivalent check for a
  differently-sized narrow char array at that call site, so the bounds-checked runtime
  copy is skipped entirely for that shape.

### Runtime — string/math (`src/newm2-runtime/src/`)

- **`nm2_copy_wstring_narrow` off-by-one.** `strings.rs:143` computes
  `max = cap.saturating_sub(1)` and copies `while i < max`, reserving a NUL slot even
  when the source exactly fits the destination — truncating the last character
  unnecessarily. The sibling `nm2_copy_wstring` doesn't have this bug.
- **`nm2_math_ldexp` intermediate overflow.** `fmath.rs:60-61` does a single
  `x * (2.0f64).powi(n_clamped)` — for a tiny/subnormal `x` paired with a large
  compensating `n`, this overflows to `Inf`/`0` even though the true product `x*2^n`
  is finite and representable.

### Driver / loader (`src/newm2-driver/src/main.rs`, `src/newm2-loader/src/`)

- **`.m2i` cache key never hashes the `windows`/`win_source` build flags.**
  `cache_config` sets `codegen_flags: String::new()` unconditionally (`main.rs:311`),
  despite `DriverOptions` carrying both `windows: bool` and `win_source: WinSource`
  (`main.rs:154-155`) — switching either flag between builds can silently reuse a
  stale `.m2i` cache entry built under the other setting.
- **`def_hash` hashes raw bytes before `%IF` preprocessing.** `parse_def_with_hash`
  (`loader.rs:53-58`) hashes the file's raw bytes, then separately preprocesses for the
  actual AST — two builds with different preprocessor environments but identical raw
  bytes get the same cache key, risking reuse of an interface built from different
  effective (post-preprocessing) source.
- **`find_def` precedence bug.** `search_path.rs:34-47` does one interleaved
  per-directory loop checking each directory for both `Module.def` and
  `Module_types.def` before moving on — the function's own comment states
  `Module.def` should take precedence over `Module_types.def` across the *whole*
  search path, but the interleaved loop can return an earlier directory's
  `_types.def` over a later directory's more-specific `.def`.
- **Win32 def-index never detects deletions.** `win32_finder.rs:206-229`'s
  `index_needs_rebuild` only scans current `.def` files for a newer mtime than the
  index; it has no logic at all to detect a previously-indexed file being deleted
  (worse than the mac pre-fix version, which at least attempted new-file detection).
  This file's entire purpose is indexing Windows API `.def` bindings, so it's used
  directly (not just cross-target) on the Windows side.

### GC (`src/newm2-runtime/src/gc.rs`)

- **Finalizers run after mutators resume.** `collect_stw` resumes all parked mutators
  (`gc.rs:973-977`) and only then runs `pending_finalizers`
  (`gc.rs:982-984`, explicitly commented "Run finalizers outside the safepoint
  window"). Since `cluster_sweep` earlier in the same cycle already linked the
  finalizer-bearing dead objects' memory onto the free list, a resumed mutator racing
  to allocate can receive that exact address and start writing into it before the
  finalizer runs against the same memory.
- **`ensure_mutator` uses the wrong thread's stack bounds.** When lazily
  auto-registering a thread that was never explicitly registered, it falls back to
  `BOOTSTRAP_STACK_BASE` (`gc.rs:531-536`) — the *bootstrap* thread's stack bounds —
  instead of querying this thread's own real stack range. Since the collector skips
  scanning a mutator once `sp >= top`, such a thread's real stack is frequently never
  scanned at all.

### Runtime — file handles (`src/newm2-runtime/src/file.rs`)

- **Double-close is a real double-free.** `nm2_file_close` unconditionally does
  `Box::from_raw(h as *mut File)` (`file.rs:92-96`) with zero liveness tracking —
  closing (or performing any operation on) an already-closed handle is undefined
  behavior, not merely a wrong-value bug. This is the same raw-boxed-pointer
  representation as the mac side (not a different Win32-`HANDLE`-based design), so
  the fix (a live-handle registry making double-close/use-after-close a safe no-op)
  should port directly.

## Checked and NOT applicable (mac-specific, confirmed on `main`)

- **Coroutine stack guard page** — `main` uses real `CreateFiber`/`SwitchToFiber`
  (`src/newm2-runtime/src/coroutine.rs`), which already gets OS-managed guard pages.
  The unguarded-stack bug was introduced only because macOS has no native fiber API,
  forcing a hand-rolled AArch64 context-switch implementation.
- **`crash.rs` SIGALRM watchdog** — POSIX signal handling has no Windows analogue;
  Windows crash recovery goes through SEH (a separately-tracked, still-pending piece
  of the port).
- **`sqlite.rs` leak fix** — this file doesn't exist on `main` at all; it's new
  Mac-only code bridging the `cocoa_data` Objective-C class-metadata database.
- **ISMEMBER direction fix** — `main`'s native-class ISMEMBER path uses a symmetric
  `nm2_rtti_isa(cand, target)` typeinfo design (`lower.rs:3991-4046`), structurally
  different from the asymmetric `objc_msgSend` dispatch that caused the mac bug. No
  evidence found of the same defect, though `nm2_rtti_isa`'s own runtime
  implementation wasn't inspected to be fully certain.

## Method

For each fix, `git show main:<path>` was diffed against the pre-fix macOS code to check
whether the same buggy pattern (not just the same file) is present. Only items with a
direct citation above are being reported; anything inconclusive is listed as such rather
than guessed.
