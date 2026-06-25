# The MacM2 runtime

MacM2 is the macOS (arm64) port of NewM2 — the same Modula-2 compiler and ISO
standard library, with a macOS-native runtime layer in place of the Windows
COM/Direct2D stack. This document is the reference for that layer: the runtime
library modules an M2 program imports, and the native object model that makes an
M2 `CLASS` a genuine Objective-C class.

Two halves, mirroring the Windows build:

| Concern | Windows build | MacM2 |
|---|---|---|
| OS object model | COM (`INTERFACE`, vtables) | Objective-C (`objc_msgSend`, classes) |
| GUI | WinShell / Direct2D / DirectWrite | AppKit / Core Graphics |
| native bridge | `@ordinal` COM vtables | `objc_msgSend` + the runtime below |

The compiler is **host-targeting**: a build run on macOS arm64 emits macOS code.
The object-model lowering described here is gated on `cfg!(target_os = "macos")`,
so it is additive and the Windows path is untouched.

---

## 1. Runtime library modules

These live under `library/macrtdef/` (DEFINITION) and `library/macrtmod/`
(IMPLEMENTATION). Their procedure bodies are either written in Modula-2 (Cocoa)
or provided by the Rust runtime (`src/newm2-runtime/src/`).

### `ObjC` — the raw Objective-C bridge (`macrtdef/ObjC.def`)

The low-level message-send layer. An Obj-C object is an `ADDRESS` (`Id`); each
selector has its own ABI, so the caller takes the address of `objc_msgSend`
(`MsgSendPtr`) and `CAST`s it to a matching `PROCEDURE` type per call site — the
exact analogue of calling through a COM vtable slot.

- `GetClass(name): Class`, `Selector(name): SEL`, `MsgSendPtr(): ADDRESS`
- `Send0/SendI/SendP/SendF/SendB/SendFrame/SendRect/Send0I/SendPI/SendC` — the
  per-signature `objc_msgSend` casts.
- `NSString(s)`, `GetString(nsstr, dest)` — M2 ↔ `NSString`.
- `AllocateClass/AddMethod/RegisterClass` — define a class at runtime; an M2
  `PROCEDURE` is a valid IMP (`(id self, SEL _cmd, …)`).
- `OpenPanel/SavePanel/OpenFolderPanel`, `SnapshotView`, `Pump`, `RunApp`,
  IDE helpers (`Highlight`, `MarkErrors`, `CursorPos`, `SetCursor`).

Most application code does **not** use `ObjC` directly — it is the substrate for
`Cocoa` and for the compiler-generated object-model code.

### `Cocoa` — ergonomic AppKit (`macrtdef/Cocoa.def`, `macrtmod/Cocoa.mod`)

A clean Modula-2 surface over AppKit, written in M2 on top of `ObjC`. Button and
list actions are ordinary M2 procedures routed back through an internal
Objective-C trampoline keyed by control tag.

- lifecycle: `InitApp`, `RunFor`, `RunApp`
- windows/views: `MakeWindow`, `ContentView`, `ShowWindow`, `AddSubview`,
  `RemoveView`, `Snapshot`
- controls: `MakeLabel`/`SetText`, `MakeButton(…, action)`, `Click`,
  `MakeEditor`/`SetEditorText`/`EditorText`/`HighlightEditor`/`MarkErrors`/
  `EditorCursor`/`SetEditorCursor`
- dialogs: `OpenFile`, `SaveFile`, `OpenFolder`
- tabs: `MakeTabView`, `AddTab`, `TabCount`, `SelectedTab`, `SelectTab`
- project list: `SetListAction`, `MakeFileButton`

> As the native object model (§3) grows `EXTERNAL` AppKit class declarations and
> a `cocoa-gen` generator, this hand-written ergonomic layer is expected to be
> superseded by generated `CLASS NSWindow ["NSWindow"]` etc. — see
> `docs/design/cocoa-classes.md`.

### `CG` — Core Graphics drawing (`macrtdef/CG.def`)

CGContext drawing primitives for custom `NSView drawRect:` rendering.

### `Proc` — processes & filesystem for the IDE (`macrtdef/Proc.def`)

The macOS analogue of the Windows `RunProg`. Bodies in
`src/newm2-runtime/src/proc.rs`.

- `RunCapture(cmd, out): INTEGER` — `/bin/sh -c`, capture stdout+stderr.
- `WriteFile`, `ReadFile`.
- `ListDir(path)` / `DirEntry(i, name)` — directory listing (subdirs first, then
  files, each sorted; dot-entries skipped), and `IsDir(path)` — so a browser can
  navigate folders vs. open files.
- `Complete(path, line, col, out)` — run the compiler's `complete` engine for IDE
  autocomplete.

---

## 2. The Rust runtime

`src/newm2-runtime/src/` holds the native bodies the compiler forwards to. The
macOS-relevant files:

- `objc.rs` — the Obj-C bridge: `nm2_objc_get_class`, `nm2_objc_sel`,
  `nm2_objc_msgsend_ptr`, `nm2_objc_nsstring`, `nm2_objc_allocate_class` /
  `_add_method` / `_register_class`, the open/save/folder panels, `SnapshotView`,
  the IDE highlight/error/cursor helpers, and the object-model helpers
  `nm2_objc_new` / `nm2_objc_release` (§3).
- `proc.rs` — `Proc.*` bodies.
- `cg.rs` — Core Graphics.

Forwarding is wired in `src/newm2-llvm/src/lib.rs`:
`runtime_forwarder_pairs()` maps M2 names (`"ObjC.GetClass"`) to symbols
(`"nm2_objc_get_class"`); `for_each_runtime_binding()` `bind`s each symbol for the
ORC JIT. Compiler-internal helpers (`nm2_objc_new`, `nm2_objc_release`,
`nm2_objc_sel`, `nm2_objc_msgsend_ptr`) are also bound by their **raw** symbol
name because the object-model lowering calls them directly.

---

## 3. The native object model: an M2 object IS an Obj-C object

A Modula-2 `CLASS` on macOS is implemented on the Objective-C runtime — same
`isa`, allocation, dispatch, and lifetime. The principle is **"everything Cocoa
below the line, M2 above it"**: a program contains no Cocoa vocabulary, yet its
objects are Cocoa objects all the way down. The design rationale is in
`docs/design/cocoa-classes.md`; this section documents what the compiler emits.

### Naming

A class declared in module `M` as `CLASS C` is registered under the Obj-C name
**`M2.M.C`**. (`objc_getClass("M2.M.C")` returns it once registered.)

### Registration — at image load, via `llvm.global_ctors`

For every concrete class the compiler emits a `Global::ObjCClass` descriptor
(IR), which codegen turns into a constructor appended to `llvm.global_ctors`
(`emit_objc_class_registrations` in `codegen.rs`). At load the constructor calls
libobjc directly:

```
cls = objc_allocateClassPair(objc_getClass(<super>), "M2.M.C", 0)
class_addIvar(cls, "__m2", <own-field bytes>, 8, "[Nc]")     // instance state
class_addMethod(cls, sel_registerName("<selector>"), &C.<Method>, "<types>")  // per method
objc_registerClassPair(cls)
```

No new runtime functions, no static vtable to materialize. Base classes are
registered before subclasses (the constructor is topologically ordered).

- **Superclass**: a root M2 class roots at `NSObject`; `INHERIT B` makes the
  superclass `M2.M.B`.
- **Selectors** are derived from method names (`DrawRect` → `drawRect:`,
  `Answer` → `answer`): lowercase initial, one trailing `:` if the method takes
  arguments. (An explicit selector pin for multi-keyword AppKit selectors is a
  later stage.)
- **Type encodings** are synthesized from the M2 signature
  (`objc_method_encoding` in `lower.rs`): `v` void, `q` INTEGER, `Q` CARDINAL,
  `d` REAL, `c` BOOLEAN, `S` CHAR, `@` object/ADDRESS, plus the leading
  `@:`(self, `_cmd`).

### Construction & lifetime

- `NEW(p)` on a class-typed pointer → `nm2_objc_new("M2.M.C")` =
  `[[getClass(C) alloc] init]`. (Pointer `NEW`, `a^`, keeps the native heap.)
- `DISPOSE(p)`/`DESTROY` → `nm2_objc_release(p)` = `[p release]`, then `p := NIL`.
- `alloc` zero-fills ivars, matching M2's `NEW`-zeroes expectation.

### Method dispatch

`obj.Method(args)` lowers to `objc_msgSend(obj, @selector(...), args)`
(`try_method_dispatch`, macOS branch). The compiler:
1. interns the selector via `nm2_objc_sel`,
2. fetches `objc_msgSend`'s address via `nm2_objc_msgsend_ptr`,
3. emits an indirect call typed by the slot's **`msgsend_sig`** — `call_sig` with
   the hidden `_cmd` (SEL) inserted after SELF — with args `(self, sel, …)`.

The method body `C.Method` is the IMP: an ordinary M2 procedure whose parameters
are `(SELF, _cmd, declared…)`. `_cmd` is a dead inserted slot so the declared
arguments land in the right registers. Dispatch on `nil` is defined (returns
nil/0), so the model is nil-safe by construction.

### Fields — real Obj-C ivars

Each class adds **one `__m2` ivar** holding its *own* fields (everything its
object record adds over its base's). Because the runtime lays a class's ivars
immediately after its superclass's, the per-class `__m2` blocks are contiguous
and reproduce the native flattened field layout — so `SELF.field` / `obj.field`
use the **unchanged** native GEP into the object record and land in genuine
per-instance Obj-C storage. Independent instances have independent state.

### Inheritance

`CLASS Dog; INHERIT Animal;` registers `Dog` with `Animal`'s Obj-C class as its
superclass. `Dog` inherits `Animal`'s methods (ordinary Obj-C method inheritance)
and its `legs` field (in `Animal.__m2`), and adds its own (`Dog.__m2`, placed
after). Verified by `demos/macos_inherit.mod`.

### Subclassing a real Cocoa class — `<* cocoa "NSView" *>`

A class pragma roots an M2 class at a **real Cocoa class** instead of `NSObject`:

```modula2
CLASS Canvas;
  <* cocoa "NSView" *>                       (* register as an NSView subclass *)
  PROCEDURE DrawRect (x, y, w, h: REAL);     (* selector drawRect: (derived), an OVERRIDE *)
  BEGIN … draw with Core Graphics … END DrawRect;
END Canvas;
```

`Canvas` is registered with `objc_getClass("NSView")` as its superclass, so
AppKit sees a genuine `NSView` and calls the M2 `DrawRect` as the view's
`drawRect:`. The `NSRect` argument arrives as `x, y, w, h` in REAL (SIMD)
registers — declare such overrides with the flattened scalar parameters
(`drawRect:` → four `REAL`, `mouseDown:` → one `ADDRESS`). Selector derivation
already yields the AppKit names (`DrawRect`→`drawRect:`, `IsFlipped`→`isFlipped`),
so common overrides need no annotation. Verified by `demos/macos_subclass.mod`
(is-a NSView + an `isFlipped` override) and `demos/macos_canvas.mod` (a CG-drawn
view rendered to PNG).

Scope: **field-free** Cocoa subclasses today. A Cocoa superclass has its own
ivars, so a subclass's `__m2` no longer sits at the native object-record offset —
stateful Cocoa subclasses need real ivar-offset resolution (next step).

---

## 4. Worked example — pure Modula-2, Cocoa underneath

```modula2
MODULE counter;
CLASS Counter;
  VAR n: INTEGER;                          (* a real per-instance Obj-C ivar *)
  PROCEDURE Bump (by: INTEGER); BEGIN n := n + by END Bump;
  PROCEDURE Value (): INTEGER;  BEGIN RETURN n END Value;
END Counter;
VAR a: Counter;
BEGIN
  NEW(a); a.Bump(40); a.Bump(2);           (* a.Value() = 42 *)
  DISPOSE(a)
END counter.
```

Below the line: `Counter` is `objc_allocateClassPair`'d as `M2.counter.Counter`
with a `__m2` ivar and a `bump:`/`value` method pair; `NEW` is
`[[Counter alloc] init]`; `a.Bump(2)` is `objc_msgSend(a, "bump:", 2)`; `n` is the
ivar; `DISPOSE` is `[a release]`.

Demos: `demos/macos_class.mod` (methods + args), `demos/macos_counter_obj.mod`
(per-instance state), `demos/macos_inherit.mod` (inheritance).

---

## 5. Building & running

```
newm2-driver build --library library demos/foo.mod   # AOT -> demos/foo.exe (Mach-O)
newm2-driver run   --library library demos/foo.mod   # ORC JIT
```

- **AOT (`build`)** runs `llvm.global_ctors` at image load, so class registration
  happens — this is the supported path for the object model today.
- **JIT (`run`)** does not yet execute `global_ctors`, so a class-using program
  under `run` sees its classes unregistered (`NEW` returns nil, gracefully — no
  crash). Tracked; fix is to run static initializers in `run_modules_orc` or hook
  registration into module init.
- After changing `src/newm2-runtime/`, rebuild the **staticlib** the AOT linker
  uses: `cargo build -p newm2-runtime` (refreshes `target/debug/libnewm2_runtime.a`).
  `cargo build -p newm2-driver` alone does not refresh it.

---

## 6. Status & roadmap

**Working (AOT):**
- Root and single-inheritance M2 classes as full Obj-C objects — registration,
  `NEW`/`DISPOSE`, `objc_msgSend` dispatch with arguments, per-instance ivar
  state, method inheritance.
- **M2 subclasses of real Cocoa classes** via `<* cocoa "NSView" *>` — AppKit
  drives an M2 class as a genuine view (e.g. an M2 `drawRect:` that draws with
  Core Graphics). Field-free for now.

**Next:**
- Real ivar-offset resolution, so **stateful** Cocoa subclasses work (the `__m2`
  ivar no longer sits at the native offset under a Cocoa superclass, so field
  access can't use native object-record GEPs — resolve `ivar_getOffset` at load).
- `EXTERNAL` Cocoa class declarations (`CLASS NSWindow ["NSWindow"]; EXTERNAL;`)
  so inherited Cocoa methods are callable as typed M2 methods (today: via the
  `ObjC`/`Cocoa` bridge); selector pinning (`["initWithFrame:"]`) for
  multi-keyword selectors; `CLASS PROCEDURE` constructors.
- `cocoa-gen` from the SDK BridgeSupport — generate the AppKit/Foundation
  `EXTERNAL` surface.
- Rewrite the IDE editor as a real `NSView` subclass; retire the hand-written
  trampoline / `Send*` layer.
- JIT `global_ctors` execution.

See `docs/design/cocoa-classes.md` for the full design and the staged plan.
