# Modula-2 on the BOX

How this compiler (MacModula2: Rust, LLVM 22.1 through inkwell, driver
`newm2`) goes onto the BOX, our 64-bit RISC OS translated to C over Linux
(A7232ToolChain/rosgd), the Arm box first and the Intel box after.

Written 30 Oct 2026 from the code of this repository (branch
`cli/m2-box`) and of the three ports made today, whose designs this
follows and does not repeat: the QBE FasterBASIC
(FasterBASIC `cli/fasterbasic-box`, design/BOX_PORT.md), the Forth (MF66
`cli/forth-box`) and the LLVM FasterBASIC (zfb2026 `cli/fbllvm-box`). The
box side is A7232ToolChain branch `modula2`, made from `fbllvm`.

## 1. What is wanted

- `*Modula2 [-c] [-t] [-O0..3] <file> [<args>]` compiles a program module
  and runs it in process, as `*FasterBASIC` does: output through the VDU,
  input from the keyboard, files through RISC OS, Escape stops it, a fault
  ends the run and not the box.
- SWIs from Modula-2 (`SWI`, a definition module), Declaritive windows
  (`Declaritive`), the desktop application `!Modula2`, and Modula-2 in
  !Code (highlighting, Build/Run, problems, F1, formatting).
- Both boxes from one code base: LLVM emits AArch64 and x86-64.

## 2. Where the compiler runs: inside /init

As for both FasterBASICs: programs must call SWIs with registers in and out
and the compiler and runtime assume 64-bit pointers, and only a native
module in `/init` gives both. So the compiler and runtime are a static
library linked into `/init` behind a small C API (`m2_box.h`), and rosgd's
`modules/modula2` (the command, the VDU sink, the SWI hook, the fault
escape) is a near copy of `modules/fasterbasic`.

The library is a new crate, `box/` here (`newm2-box`, a `staticlib`),
which uses the compiler's crates (loader, sema, ir, llvm, runtime) as the
driver does and replaces only the driver: no rusqlite, no daemon, no
Win32 finder, no symbol cache.

## 3. Which LLVM, and which JIT

The NCL set the box already builds (deps/build-llvm-libs-box.sh with
`LLVM_FOR_NCL=1`: `caches/arm-mac/llvm-libs-box-ncl`,
`caches/intel-mac/llvm-libs-box-x86_64-ncl`), LLVM 22.1.2, the version
inkwell's `llvm22-1` feature and llvm-sys 221 expect. No new LLVM build
(A7232ToolChain#287).

That set has MCJIT, ExecutionEngine and RuntimeDyld but not ORC's JIT
(only OrcShared and OrcTargetProcess). The Mac runs programs through ORC
LLJIT (`run_modules_orc`). **The box uses MCJIT**, and does not add the ORC
libraries to the set, because:

- the Mac's LLJIT already loads code through RuntimeDyld with an
  MCJIT-style memory manager and binds every runtime symbol by address
  (no dlsym), so MCJIT does the same job with the same pieces;
- NewCL and the LLVM FasterBASIC already run MCJIT in a static musl
  program in the box: their traps (musl's failing static `dlopen`, which
  `static_dl.rs` answers; `__register_frame` given a whole `.eh_frame`
  where LLVM's libunwind wants one FDE) are known and solved;
- adding ORC would change a library set three other programs use and
  grow `/init` by ORC's code for no new ability (we run one program at a
  time, never lazily compile).

So `newm2-llvm` gets `run_modules_mcjit` beside `run_modules_orc` (one
linked module, as now; `LLVMCreateMCJITCompilerForModule` with the large
code model; a memory manager whose code sections are mmap'd and made
executable and whose data sections come from the program's dynamic area,
section 5; each runtime symbol mapped by `LLVMAddGlobalMapping` from the
same `for_each_runtime_binding` table ORC uses). The Mac keeps ORC.

Exceptions (ISO `EXCEPTIONS`, `RAISE`, `TRY`-style protected calls) are
Rust panics that unwind through JIT frames, so the MCJIT memory manager
registers the JIT's `.eh_frame` with `/init`'s libunwind one FDE at a
time (NewCL's walk).

## 4. Output, input, files, Escape, faults

The runtime's I/O surface is narrow: `NM2IO` (io.rs) for the terminal and
`NM2File` (file.rs) for files. In the box:

- **io.rs** writes and reads through hooks set by the module: writes to
  the VDU (OS_WriteC, OS_NewLine for "\n"), reads by OS_ReadLine32. CHAR
  is a 16-bit cell here; text crosses the boundary as Latin-1, RISC OS's
  alphabet (a cell above 255 prints as "?").
- **file.rs** gets a box backend: OS_Find, OS_GBPB, OS_Args and OS_BGet
  through the SWI hook, with RISC OS file names; the handle stays an
  opaque 64-bit value. `NM2File` and the ISO channel modules above it do
  not change.
- **Escape** is checked in the write, read and SWI hooks (as
  `*FasterBASIC` does, yielding to other tasks in a TaskWindow every
  10 cs); when it is seen the runtime raises HALT, so the program ends as
  if `HALT` had been called, unwinding through FINALLY parts.
- **Faults**: the module's `ros_fault_escape` around each run; after a
  fault `m2_box_recover` resets the runtime (exception state, coroutine
  state, the heap) and frees the JIT's memory. The runtime's own crash
  handlers (crash.rs) are not installed in the box.
- `ProgramArgs` gets the command's arguments.

## 5. SWIs and memory the SWIs can see

RISC OS addresses are 32-bit: the arena is the low 4 GB of `/init`'s
address space, mapped one to one, and `/init`'s own heap, stack and JIT
memory lie above it. As the Forth does, the program's **data is put in a
RISC OS dynamic area** ("Modula-2", made for each run and removed after
it), so that its pointers are RISC OS addresses:

- `NEW`, `Storage.ALLOCATE` and the runtime's heap: a dlmalloc whose
  system memory is the dynamic area, grown with OS_ChangeDynamicArea;
- the program's global variables: the JIT's data sections are allocated
  in the dynamic area by the memory manager;
- the program's stack: the program body runs on a stack in the dynamic
  area (the coroutine code's context switch, with the stack taken from
  the area), so `ADR` of a local is a RISC OS address too.

Only code (and Rust's own memory: the compiler, the runtime's tables)
stays above 4 GB. A register value passed to a SWI that does not fit in
32 bits is refused with an error, never truncated.

The `SWI` definition module (in `library/boxdef`, its body in the
runtime's `riscos.rs`):

```modula2
TYPE Regs = ARRAY [0..9] OF CARDINAL32;
PROCEDURE Call (swi: CARDINAL32; VAR r: Regs);       (* raises on an error *)
PROCEDURE XCall (swi: CARDINAL32; VAR r: Regs): ADDRESS;  (* the error block or NIL *)
PROCEDURE CallName (name: ARRAY OF CHAR; VAR r: Regs);
PROCEDURE XCallName (name: ARRAY OF CHAR; VAR r: Regs): ADDRESS;
PROCEDURE Number (name: ARRAY OF CHAR): CARDINAL32;  (* OS_SWINumberFromString *)
PROCEDURE Flags (): CARDINAL32;                      (* N Z C V of the last call *)
PROCEDURE Addr (a: ADDRESS): CARDINAL32;             (* checked: a RISC OS address *)
PROCEDURE Str (s: ARRAY OF CHAR): CARDINAL32;        (* a 0-terminated Latin-1 copy *)
PROCEDURE GetStr (a: CARDINAL32; VAR s: ARRAY OF CHAR);  (* a control-terminated string *)
PROCEDURE ErrorNumber (e: ADDRESS): CARDINAL32;
PROCEDURE ErrorText (e: ADDRESS; VAR s: ARRAY OF CHAR);
```

`Call` raises an ISO exception (source `SWI`) carrying the error's number
and text, which a program can catch in an EXCEPT part; `XCall` returns
with V set and the error block. `Str` copies are freed when the run ends.
`ARRAY OF ACHAR` buffers (8-bit) are passed as they are by `Addr(ADR(b))`.
A module `RISCOS` gives the common calls by name over `SWI` (OS_Write0,
OS_ReadMonotonicTime, OS_File, Wimp_ ... as needed by the examples).

## 6. The language in the box

Kept: modules (separate DEFINITION and IMPLEMENTATION modules found beside
the program, then in the library), the ISO and PIM standard library,
exceptions and FINALLY, coroutines (`COROUTINES`, `SYSTEM.NEWPROCESS` /
`TRANSFER`: the AArch64 switch exists; an x86-64 one is added), sets,
LONGREAL, and `CLASS`: off macOS the compiler lowers classes to its own
vtables (the Windows path without COM), which needs no Objective-C.

Gone, and left out of the build: Cocoa, Objective-C, CG, `Proc`
(macrtdef/macrtmod), COM, Win32 (`NewM2`, the winapi generators), inline
`ASM` procedures for x86 on the Arm box, `newm2 build` (AOT executables:
the box has no linker for them; programs are JIT-run), the GC feature and
the iGui. Not in the library path in the box: `macrt*`, `NewM2`.

Where modules come from: the standard library is in the ROM, at
`/usr/lib/modula2` (isodef/isomod, pimdef/pimmod, rtdef, utildef/utilmod,
shareddef/sharedmod, boxdef/boxmod), read by Rust's std::fs. A program's
own modules are looked for beside it through RISC OS (the loader gains a
file hook): for `Foo`, `Foo/def` and `Foo/mod` (HostFS's `Foo.def`), then
the RISC OS convention `def.Foo` and `mod.Foo`.

## 7. Declaritive

`library/boxdef/Declaritive.def` over the module's SWIs (chunk &C0380:
Create, Poll for events, Get, Set, ...), as the C binding
(declaritive/bindings/c) does; a program passes its JSON, becomes a Wimp
task and handles events in a loop. Example: `Greeter`, as
!FasterBASIC's and !F66's.

## 8. The desktop and !Code

`!Modula2` (in this repository, `box/app/!Modula2`; `make usershare` in
A7232ToolChain copies it): an icon, two file types, `!Help`, Examples.

- &A7B "Modula2": a program or implementation module (`.mod`);
- &A7C "M2Def": a definition module (`.def`).

(Free in the box's MimeMap: &A79 is CUE, &A7A is taken; &A77 is the
Forth's, &A75 FasterBASIC's.) Double-clicking a program runs it with
`*Modula2` in a TaskWindow; a program that makes a Declaritive window
runs as a task of its own.

!Code (rosapps/code-engine): a Modula-2 highlighter in syntax.rs
(keywords, nested `(* *)` comments, strings, `<* *>` pragmas), Build
(`*Modula2 -c`) and Run of the file in front and of a project, the
compiler's `file:line: error: text` lines parsed into the problems list,
F1 help from the definition modules in `/usr/lib/modula2`, and formatting:
a Rust port of the IDE formatter's rules (projects/macide/fmtcli.mod)
in the engine, so F5 / Ctrl-Shift-F work without a run of the compiler.

## 9. The Intel box

`/init` is x86_64-linux-musl there, so the same library is built for
x86-64 against `caches/intel-mac/llvm-libs-box-x86_64-ncl`, with an
x86-64 coroutine switch. What the Studio can prove: the library and the
Intel ROM build and link; host-side, the box's code generator makes
x86-64 objects for the test programs (disassembled and checked). What
must be run on the Mac Pro is written in section 11 when that step is
done.

## 10. Steps

1. This design.
2. `box/build.sh aarch64`; A7232ToolChain `modula2` links it;
   `*Modula2` runs a program that prints and calls SWIs in the Arm box
   under QEMU.
3. `SWI`, `RISCOS`, `Declaritive`; `!Modula2` with examples; self-test
   checks in `boot/selftest_modula2.c`; `tools/build-arm-mac.sh --check`
   with only its 4 known failures; the desktop driven with deskdrive.
   Benchmarks: fib(30) and the sieve (docs/cli-tasks/bench-fasterbasic.bas).
4. !Code.
5. Intel: build, host checks, the Mac Pro run written down.

## 11. As built

(Filled in as the steps are done.)
