# Ahead-of-time (Mach-O executable) compilation

NewM2 is JIT-first (the JIT is now an **ORC LLJIT** engine — see `docs/` history
and `run_modules_orc` in `newm2-llvm`), but `newm2 build` produces a standalone
native macOS Mach-O executable. The same lowered IR feeds both paths; only the back
end differs.

## Usage

```
newm2 build prog.mod                 # writes prog (Mach-O) next to prog.mod
newm2 build prog.mod --out bin/p     # explicit output path
newm2 build prog.mod -O2             # optimisation level passed to the backend

newm2 build-stdlib                   # pre-compile the ISO library -> libstdlib.a (+ .o, .manifest)
newm2 build prog.mod --stdlib libstdlib.a  # link prog against the prebuilt stdlib
```

The driver also writes a sibling `prog.o` (the emitted object).

## How it works

1. **Lower** every module in dependency (topological) order — identical to `run`.
2. **AOT codegen** (`CodegenOptions { aot: true }`):
   - Class **vtables** are emitted as *constant* function-pointer arrays the
     static linker resolves via relocations. (The JIT instead emits zeroed
     vtables and patches them after load via `patch_vtables`.)
3. **Runtime forwarders** — the ISO library calls dotted intrinsics like
   `NM2RT.Raise` / `NM2.IO.WriteText`. The JIT binds these to `nm2_*` runtime
   functions by address; AOT emits a tiny forwarder body for each referenced
   name that calls the `nm2_*` export, which the linker resolves from the
   runtime static library. (`runtime_forwarder_pairs` in `newm2-llvm`; keep it
   in sync with the shared runtime binder `for_each_runtime_binding` — a missing
   pair is a loud link error.)
4. **Entry driver** — a constant `nm2_aot_table` of `{body, final}` function
   pointers (one record per module, topo order) plus `int main()` that calls
   `nm2_aot_run(table, N)`.
5. **`nm2_aot_run`** (in the runtime) reproduces the JIT's semantics: run each
   module body in order under `catch_unwind`; a `HALT` (HaltMarker) is clean
   termination, an uncaught exception is a diagnostic; then begin termination
   and run finalizers LIFO for every initialized module; exit code 0 / 1.
6. **Link** — `.o` + `libnewm2_runtime.a` (the runtime built as a `staticlib`,
   bundling Rust std) + the system libraries. The linker (`ld`, invoked via
   `clang`) links the program.

## Separate compilation against a prebuilt standard library

Re-lowering the whole ISO library (plus its transitive runtime-support modules)
for every build is wasteful. `build-stdlib` compiles it once into an archive a
later program build links against.

**`newm2 build-stdlib [--out libstdlib.a]`** (`run_build_stdlib`):
- synthesises a root that `IMPORT`s the whole ISO surface (`ISO_MODULES`) so the
  loader pulls in every ISO module and its transitive `NM2.*` / `Heap` / `Storage`
  / … support modules;
- lowers them all and emits **one library object** (`emit_library_object`, no
  entry driver) to `stdlib.o`, then archives it into `libstdlib.a` with the
  librarian (`ar`);
- writes `stdlib.manifest`: the contained modules in initialisation
  (topological) order, each flagged `body` and/or `final` if it has one.

**`newm2 build prog.mod --stdlib libstdlib.a`** (`build_against_stdlib`):
- reads the manifest; lowers **only the program's own modules** — every module
  the archive provides is referenced as an external symbol;
- builds the **full init order** (every non-intrinsic module in topo order) with
  each module's `(has_body, has_final)` flags taken from the manifest for stdlib
  modules and from the lowered IR for program modules, and emits the AOT entry
  driver over that order (`emit_aot_object_with_init_order` — stdlib module
  bodies/finalizers are referenced as externals resolved from the archive);
- links `prog.o` + `libstdlib.a`.

This is the same partitioning the JIT would need to load a prebuilt stdlib
object via `LLVMOrcLLJITAddObjectFile`; wiring that into `newm2 run --stdlib`
(so the JIT skips re-lowering the library too) is a tracked follow-up.

## Validation

The original Sprint-L bring-up diffed `newm2 build` against `newm2 run` (JIT)
across the `Mod/tests` corpus: **99 / 102 identical**, the three differences
failing identically (or worse) under the JIT (a sema error and a pre-existing
float-library AV among them) rather than being AOT regressions. The full
numbered suite (`newm2-tests`) now passes on the ORC JIT (224 passed, 0 failed).

End-to-end AOT tests live in `src/newm2-driver/tests/aot_build.rs` (const arith,
OO virtual dispatch, method EXCEPT/FINALLY, HALT + finalization); they skip
gracefully if no linker is present.

## Limitations (AOT)

- **Manual memory.** Uses `nm2_alloc`/`nm2_free`; no GC safepoints or stack maps.
- **`ProgramArgs` is not wired into the static `main`.** The `nm2_program_args_*`
  forwarders are emitted, but the AOT entry is `int main()` (no `argc`/`argv`
  capture), so a built executable sees no command-line arguments yet. The JIT path
  forwards them (`run_run` calls `nm2_program_args_set`).
- **No M2-level crash backtrace symbol table.** The crash handler is installed,
  but the JIT-only high-level symbol registration is skipped; the OS still
  produces a native backtrace.
