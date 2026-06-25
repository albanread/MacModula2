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
- Subclass any Cocoa class: `<* cocoa "NSView" *>`, `<* cocoa "NSTextStorage" *>`,
  `<* cocoa_class "NSMutableArray" *>` (bind to an existing class). `GUARD` /
  `ISMEMBER` use `isKindOfClass:` (the Cocoa analogue of COM's `QueryInterface`).

See `docs/design/cocoa-classes.md` for the full design.

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

## Repository layout

```
src/                Rust + LLVM compiler: lexer, sema, IR, LLVM codegen, runtime, driver
library/macrtdef    Mac runtime interfaces  — Cocoa / ObjC / Proc / CG / CocoaNS
library/macrtmod    Mac runtime implementation
library/shareddef   portable runtime (Base64, Vector, StrUtil, Terminal model, …)
library/sharedmod
library/isodef|isomod, pimdef|pimmod, rtdef, utildef|utilmod   stdlib (ISO 10514-1 + PIM 4)
library/uidef|uimod, NewM2                                     shared UI (Ptcl) + compiler modules
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
