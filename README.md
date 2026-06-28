# MacModula2

A from-scratch **Modula-2** compiler and runtime **specialized for macOS**, on
**Rust + LLVM** — PIM 4 + ISO 10514-1, JIT-first, with a **Cocoa-native object
model**: a Modula-2 `CLASS` *is* an Objective-C object. The toolchain driver is
`newm2`.

This is deliberately **Mac-native** Modula-2: not a portable compiler that happens
to run on macOS, but one that targets Apple silicon (`arm64-apple-darwin`) and
uses the platform to the hilt — the Objective-C runtime, Cocoa / AppKit /
Foundation, Core Graphics — all reachable directly from clean Modula-2 source.
"**Everything Cocoa below, M2 above.**"

It is the Modula-2 member of a portfolio of from-scratch Rust+LLVM language
implementations.

📸 **[See the demo gallery →](cocoademos/gallery/GALLERY.md)** — Tetris, Asteroids, a
3-D warp turret, a software synth with a live oscilloscope, Mandelbrot, the IDE, and
more: native Cocoa apps written entirely in Modula-2 (every screenshot rendered
headlessly by the demo itself).

**Status.** Builds and runs on Apple Silicon (`arm64-apple-darwin`), both AOT
(Mach-O) and via the ORC JIT. The Cocoa object model is complete — every `CLASS`
is an Obj-C class, Cocoa superclasses are named with plain `INHERIT NSView`
(resolved from the binding metadata), and Cocoa is reached with `[recv sel: args]`
message sends. The flagship program is the multi-pane, rope-backed Modula-2 IDE in
`projects/macide/`.

## The headline: M2 classes and objects ARE Cocoa objects

Where the Windows lineage of this compiler dispatched through COM vtables, the Mac
port lowers Modula-2's object model straight onto the **Objective-C runtime**. A
Modula-2 `CLASS` is not *wrapped* by an `NSObject` — it **is** one:

```modula2
CLASS IDEController;
  <* cocoa "NSObject" *>                 (* root this class at NSObject *)
  VAR editor, output: Cocoa.Object;
  PROCEDURE BuildRun (sender: ObjC.Id);  (* an AppKit action: selector "buildRun:" *)
  BEGIN ... END BuildRun;
END IDEController;
```

- Each `CLASS` is registered as a real Obj-C class (`objc_allocateClassPair` /
  `class_addMethod` / `objc_registerClassPair`) via an `llvm.global_ctors`
  constructor — so `[obj isKindOfClass:]`, KVC, target/action, and delegation all
  see a genuine object.
- `NEW(obj)` → `[[Class alloc] init]`; `DISPOSE` → `[release]`. Fields are real
  ivars; methods dispatch through `objc_msgSend` with compiler-synthesized casts.
- Method names derive Cocoa selectors (`DrawRect` → `drawRect:`), or pin them
  explicitly with `<* selector "replaceCharactersInRange:withString:" *>`.
- Subclass any Cocoa class with plain `INHERIT NSView` — resolved from the Cocoa
  metadata, no pragma and no import, and typo-checked. `<* cocoa "NSView" *>` names
  a class by string for the long tail the metadata does not cover, and
  `<* cocoa_class "NSMutableArray" *>` binds to an existing class. `GUARD` /
  `ISMEMBER` use `isKindOfClass:` (the Cocoa analogue of COM's `QueryInterface`).
- **Message sends** without hand-casts: `[recv sel: a withThing: b]`, as an
  expression or a statement. Return and argument types come from a data-driven
  selector database (`cocoa-gen` reflecting the live runtime), so `REAL` / `CARDINAL`
  / struct returns pick the right ABI automatically.
- **Structs, both ways**: passing/returning a struct works for every arm64 ABI class
  — registers, HFA in `v0–v3`, `sret` in `x8`, and large-by-pointer. Structs are
  synthesized as named, declarable records (`VAR r: ObjC.NSEdgeInsets`) with **real
  field names** read from the system's BridgeSupport metadata (`[v alignmentRectInsets].top`).
- **Blocks**: `ObjC.MakeBlock(CAST(ADDRESS, proc))` wraps an M2 procedure as a Cocoa
  block, so Cocoa can call *into* Modula-2 — comparators, `enumerate…UsingBlock:`,
  completion handlers, `NSTimer` blocks (the IDE's status-bar clock is one).

A full walkthrough is in the **[Cocoa guide](docs/cocoa/index.md)** — message
sends, classes as Cocoa classes, the bound library, and reaching any Cocoa API.
See `docs/design/cocoa-classes.md` and `docs/design/cocoa-send.md` for the design.

## Mac-native, feature by feature

| Modula-2 / runtime feature | macOS facility it uses |
|---|---|
| `CLASS`, objects, methods | the **Objective-C runtime** — a `CLASS` *is* an `NSObject` |
| `NEW` / `DISPOSE`, `Storage.ALLOCATE` | `malloc` / `free` |
| `ARRAY OF CHAR`, string literals | **UTF-16** (wide) — interops directly with `NSString` |
| GUI, drawing, windows | **Cocoa / AppKit / Foundation / Core Graphics** via the Obj-C bridge |
| `newm2 build` | a native **Mach-O** executable |
| `newm2 run` | an in-memory image via **ORC JIT** |

The Cocoa runtime library lives in `library/macrtdef` + `library/macrtmod`:
`Cocoa` (windows, views, controls, editors), `ObjC` (the message-send bridge),
`Proc` (files / dirs / subprocess), `CG` (Core Graphics), and `CocoaNS` — typed
`EXTERNAL` bindings introspected from the live Obj-C runtime by `newm2-cocoa-gen`.

## Documentation

- **[The Cocoa guide](docs/cocoa/index.md)** — Modula-2 meets Cocoa: the
  `[recv sel: args]` message send, classes *as* Cocoa classes (`INHERIT NSView`),
  the bound `Cocoa` / `ObjC` / `CocoaNS` surface, and how to reach any Cocoa API.
- **[The Modula-2 guide](docs/m2-guide/index.md)** — a tour of the language as
  implemented here; **[the reference manual](docs/newm2-manual/01-getting-started.md)**
  is the chapter-by-chapter spec.
- **[The MacM2 runtime](docs/macm2-runtime.md)** — the Obj-C object lowering,
  memory, strings, and the AOT / JIT model.
- Design notes under **[`docs/design/`](docs/design/)** — `cocoa-classes.md`,
  `cocoa-send.md`, `guard-ismember.md`, `mac-text-store.md`, … — plus
  `docs/aot.md`, `docs/strings.md`, and `docs/module-graph.md`.

## The MacM2 IDE — built on this object model

`projects/macide/` is a working multi-pane IDE, the macOS counterpart of the
Windows FastPanes/PaneShell IDE, written *in* Mac-native Modula-2:

- A scrollable **PROJECT / LIBRARY** sidebar split, **closeable sliding tabs**, a
  real menu (⌘O/⌘S/⌘R/⌘W/⌘Z/⌘F/⌘/, F1 help), an F1/Home help pane, draggable
  `NSSplitView`s, a live **Obj-C class search**, Build & Run with red error
  marking + jump-to-error, autocomplete (the compiler's own `complete` engine).
- The controller is an ordinary `CLASS` that *is* an `NSObject`; its methods are
  the toolbar/menu AppKit actions — no trampoline.
- **A rope-backed editor.** Each tab's `NSTextStorage` is a Modula-2 class
  (`RopeStore`) whose characters live in an M2 `TextRope` (O(log n) edits) and
  whose syntax colours come from an M2 lexer + an incrementally-spliced run list;
  the `NSString` the layout system reads is another M2 class (`RopeString`) backed
  by the same rope. Typing flows straight into the rope; line numbers are an
  `NSRulerView` subclass. See `docs/design/mac-text-store.md`.

Build & run it:

```sh
cargo build -p newm2-driver
./target/debug/newm2-driver run --library library projects/macide/macos_panes_ide.mod
```

Or package it as a double-clickable **`.app`** — bundles the editor *and* the
compiler/JIT toolchain, so Build & Run and autocomplete work with no dev checkout
and no Xcode at run time:

```sh
scripts/build-macapp.sh                 # writes dist/MacM2 IDE.app  (--debug for a fast build)
open "dist/MacM2 IDE.app"
```

## Repository layout

```
src/                Rust + LLVM compiler: lexer, sema, IR, LLVM codegen, runtime, driver
library/macrtdef    Mac runtime interfaces  — Cocoa / ObjC / Proc / CG / CocoaNS
library/macrtmod    Mac runtime implementation
library/shareddef   portable runtime (Base64, Vector, StrUtil, Terminal model, Ptcl, …)
library/sharedmod
library/isodef|isomod, pimdef|pimmod, rtdef, utildef|utilmod   stdlib (ISO 10514-1 + PIM 4)
library/NewM2                                                  compiler-internal Modula-2 modules
projects/macide     the MacM2 IDE + Cocoa demos + the rope text store + Ptcl tests
docs/design         cocoa-classes.md, mac-text-store.md, …
```

## Testing

The IDE is exercised headlessly via **Ptcl** (the in-repo embeddable Tcl dialect):
IDE operations are registered as verbs and driven by scripts — see
`projects/macide/macos_ide_test.mod` (load/save, auto-indent, build) and
`macos_ide_stress.mod` (large-file load/save/autosave, hash-checked). GUI demos
are verified by rendering offscreen with `ObjC.SnapshotView`, and on real windows
via `Cocoa.RunApp`.

```sh
cargo test                 # the Rust + compiler test suite
./target/debug/newm2-driver run --library library projects/macide/macos_ide_test.mod
```
