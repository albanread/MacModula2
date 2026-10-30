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
- the program's stack (planned: the body on a stack in the dynamic area,
  so that `ADR` of a local is a RISC OS address too; not done, see
  section 11).

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

## 11. As built (30 Oct 2026)

Branches: this repository's `cli/m2-box`; A7232ToolChain's `modula2`
(from `fbllvm`; worktree `src/A7232ToolChain-modula2`).

**Build.** `sh box/build.sh aarch64|x86_64` (cargo for
`<arch>-unknown-linux-musl`, zig 0.15 as the C compiler, about a minute
from clean, seconds after) makes `BOX/caches/modula2/out-<arch>/`:
`libm2-box.a` (the Rust staticlib, which already carries the NCL LLVM
archives that llvm-sys links statically, partly linked and every symbol
but `box/exports.txt` made local) and `lib/`, the standard library
(isodef/isomod, pimdef/pimmod, rtdef, utildef/utilmod, ulibdef/ulibmod,
shareddef/sharedmod, boxdef/boxmod). The A7232ToolChain Makefile links the
library into `/init` when it is there (`M2_LIB`), puts `lib/` in the ROM
as `/usr/lib/modula2`, and `make usershare` copies `box/app/!Modula2`.

**Size.** The Arm `/init`'s code is 109 MB (FasterBASIC's branch: 75 MB):
LLVM is in it twice now, FasterBASIC's copy and this one, each made local
to its library. Sharing one copy of LLVM between the two (or with rosbas)
is the box's choice to make; it would need both libraries to be linked
against one set of LLVM symbols.

**The JIT.** MCJIT, as section 3. One thing differed from the plan: the
AArch64 code MCJIT makes is position-independent and reaches its data
through a GOT by ADRP (+-4 GB) whatever code model is asked for. With the
data in the arena (below 4 GB) and the code mmap'd anywhere, the first run
faulted on a wrapped address. The memory manager now puts code just above
4 GB (asked for at 0x1_0000_0000 upwards), in reach of the arena.

**What was found and fixed on the way** (all in these branches):
- `static_dl.rs`, taken from NewCL-BOX: the table of C routines LLVM's code
  calls on its own (memcpy, the maths library, 128-bit division) was
  evaluated and its answer dropped, so every one resolved to null and a
  program that copied a string jumped to address 0. NewCL-BOX has the same
  code (src/ncl-llvm/src/static_dl.rs) and should take the fix.
- The coroutine switch's assembly named its symbols for Mach-O only
  ("_nm2_ctx_switch"); it now works on ELF, and there is an x86-64 switch.
- The ISO file devices (SeqFile, StreamFile, RndFile) and the console
  (StdChans, TermFile) read text past the line mark, so `ReadString` ran
  lines together and `ReadString; SkipLine` swallowed the next line; they
  now stop at it (ISO), on the Mac too.
- Cocoa, ObjC, Proc and the POSIX crash handler are macOS-only in the
  runtime; the Cocoa selector database (SQLite) is absent on Linux.
- Classes are Objective-C or vtables by a run-time switch
  (`set_native_classes`), so the host check sees the box's classes.

**What had to go**: Cocoa, Objective-C, CG, Proc, COM, Win32 and their
library directories (macrt*, NewM2), inline ASM procedures, `newm2 build`
(executables) and the GC feature. **Kept**: modules (a program's own
modules beside it, as `Name/def` and `Name/mod` or `def.Name`, `mod.Name`),
the ISO and PIM libraries, exceptions with EXCEPT and FINALLY, coroutines,
sets, LONGREAL, CLASS (with vtables), HALT's code in `Sys$ReturnCode`.

**Proved in the Arm box under QEMU** (slots A and B):
- `*Modula2` (box/boxtest.sh): output through the VDU; `-c`, `-t`, `-O0`
  to `-O3`; a compile error as `FILE:LINE: error: TEXT` with the RISC OS
  name; SWIs by name and number, registers in and out, `XCall`'s error
  block with V set, `Call`'s error caught as an exception, a global
  ACHAR buffer and a NEW'd one given to SWIs; files written and read back
  through RISC OS (ISO SeqFile, TextIO); coroutines; a class with an
  overridden method; an unhandled exception reported; a stack overflow
  ending the run and the next run normal.
- `tools/build-arm-mac.sh --check`: 4 of 2023 checks failed, the known
  four (three share checks, one MimeMap); the 13 Modula-2 checks
  (boot/selftest_modula2.c) pass.
- The desktop, driven with deskdrive (box/deskbox.sh): `!Modula2` in the
  Filer with its icon, its !Run opening Examples, the file types' icons;
  a double-click on Hello running it in a TaskWindow; input read there;
  Escape ending a printing loop (its FINALLY ran); a double-click on
  Greeter running it as its own task: the Declaritive window, its tick,
  change events ("Hello, Box!"), Quit.
- !Code: a Modula-2 file dropped on it, highlighted (nested comments,
  pragmas, strings, numbers); Build reporting the compiler's error in the
  problems and F8 going to its line; Ctrl-Shift-F formatting; F1 showing
  `STextIO.WriteString`'s declaration and comment from the ROM's library;
  Run; a directory dropped on it made a Modula-2 project by the Project
  pane, run with Ctrl-F5 (`*Make run`: main/mod importing Greet).

**Benchmarks** (`box/tests/bench.mod`, best of three, Arm box under QEMU,
beside docs/cli-tasks/bench-fasterbasic.bas's numbers in
zfb2026's design/BOX_PORT.md):

| test | Modula-2 (O2) | FasterBASIC LLVM (O2) | FasterBASIC QBE |
|---|---|---|---|
| fib(30) | 1.67 ms | 1.37 ms | 1.8 ms |
| sieve, primes below 2,000,000 | 4.24 ms (148933) | 7.0 ms | 14.7 ms |

At -O3 LLVM sees that Fib(30) is pure and the loop's result unused and
hoists it (0.00 ms): not a measurement. -O0: fib 2.37 ms, sieve 10.6 ms.
The bench compiles in 335 ms (front end 33 ms), most of it the ISO library
modules it imports, which are compiled with every program.

**The Intel box.** Built on the Studio: `box/build.sh x86_64` (the X86
backend only: the AArch64 initialisers are gone from the x86 library) and
`make ARCH=x86_64` in A7232ToolChain `modula2`: `build/init` links the
module and library (an x86-64 ELF, 119 MB of text; `build/initramfs.cpio`
341 MB, with /usr/lib/modula2). Host-side, `sh box/hostcheck.sh` compiles
box/tests/*.mod (hello, swi, cls, cor, files, exc, deep, bench) with the
box's front end and code generator for x86_64-unknown-linux-musl, as the
JIT does (the large code model), and checks: ELF x86-64; no 32-bit
PC-relative reference out of an object; every name an object needs is
bound by the JIT. All eight pass. Nothing has run on x86-64: the x86-64
coroutine switch, the MCJIT memory manager's placement on x86-64 and the
fault escape there are unproved.

**What must be run on the Mac Pro** (`ssh macpro`, BOX root
/Users/Shared/BOX; one session at a time):

1. Check out A7232ToolChain branch `modula2` and this repository's branch
   `cli/m2-box` side by side in `BOX/src` (as `A7232ToolChain-modula2` and
   `MacModula2-cli-m2-box`); `rosgd/tools/box-root.sh` in the first.
2. The library: copy the Studio's `BOX/caches/modula2/out-x86_64` to the
   same place there (or build it: `sh box/build.sh x86_64` needs Rust with
   the x86_64-unknown-linux-musl target, zig 0.15 and the x86-64 NCL LLVM
   set in `BOX/caches/intel-mac/llvm-libs-box-x86_64-ncl`).
3. In `rosgd`: `tools/build-intel-mac.sh --check`. Pass: no more than the
   4 known failures, and every check from "the Modula2 module is in the
   ROM" to "the run after a fault is as good as the first" (13) reading
   `ok`. These prove MCJIT's x86-64 code with data in the arena, the
   runtime and the SWI bridge, files, the x86-64 coroutine switch, and
   the fault escape on x86-64.
4. The bench: `box/tests/bench.mod` on a share as `bench,a7b`, then
   `*Modula2 -t HostFS::Host.$.bench` in a box under HVF.
5. The desktop (`run/run-x86_64.sh` with `make ARCH=x86_64 usershare`):
   `!Modula2`, a double-click on Examples.Hello and Examples.Greeter, and
   !Code with a Modula-2 file (Build, F8, F1, Ctrl-Shift-F, Run).

**Left.**
- Everything Intel beyond building and the host check: the run above.
- Escape is seen when a program prints, reads or calls a SWI: a loop that
  does none of these cannot be stopped (as FasterBASIC).
- A fault inside the runtime's Rust while it holds a lock (the arena's,
  the files') would leave that lock held for the next run.
- The library is compiled with every program (no interface or object
  cache in the box); a cache in the dynamic area or on disc would cut the
  300 ms of a program that imports the ISO I/O modules.
- Text in files is written as UTF-8 (a character above 127 is two bytes),
  the console as Latin-1.
- A text file read through the ISO channels costs a SWI per character (the
  device reads a character at a time); a buffer in the RISC OS file would
  remove that.
- The program's stack is /init's, not in the arena: `ADR` of a local
  variable is not a RISC OS address (SWI.Addr says so); globals, NEW'd
  memory and SWI.Str are. Running the program body on a stack in the
  dynamic area (section 5) is not done.
- A module's own FINALLY does not run when its body ends with an unhandled
  exception (the Mac's behaviour too).
- !Code: no completion or rename for Modula-2 (no language server);
  Comment out has no line comment to use.

## LLVM shared with /init (30 Oct 2026, later)

`box/build.sh` no longer puts LLVM in the library: LLVM's calls stay
undefined and /init links the NCL set once for both LLVM languages, with
one dlopen and dlsym for MCJIT (A7232ToolChain `rosgd/runtime/llvm/llvm_dl.c`).
`llvm-stamp.txt` beside the library names the LLVM it was compiled
against; /init's link refuses a mismatch.  Set `FB_LLVM_INSIDE=1` or
`M2_LLVM_INSIDE=1` to build the old way.  On A7232ToolChain branch `langs`
(all four languages): the Arm /init's text went from 110.1 to 78.6 MB.
See A7232ToolChain `rosgd/docs/llvm-in-the-box.md`.
