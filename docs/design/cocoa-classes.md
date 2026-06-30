# The Modula-2 object model on the Objective-C runtime (macOS backend)

Status: **design, awaiting sign-off** · Acceptance test: the macOS IDE's editor written as a plain M2 `CLASS` that `INHERIT`s `NSView`

## Thesis

This is **not** a COM-style emulation or a hand-written bridge. We take the
language's existing ISO-10514-2 / ADW object model — `CLASS`, `ABSTRACT CLASS`,
`INHERIT`, `OVERRIDE`, fields, methods, `REVEAL`, `NEW`/`DISPOSE` — and make the
**macOS code generator implement it on the Objective-C runtime as the object
substrate.** On this target, an M2 object *is* an Objective-C object: same `isa`,
same allocation, same dispatch, same retain/release. There is no wrapper layer
and no marshalling — the two object models are made to be the same model.

The front end does not change. What changes is one target-specific lowering: where
the LLVM backend today emits the native vtable representation for a class
(`object_record = { __vtable, fields… }`, a `{Class}.vtable` global with RTTI at
slot 0, field-0 indexed dispatch — `class.rs` `object_record`, `module.rs`
`Global::ClassDesc`), the **macOS backend emits Objective-C runtime calls
instead**. Same `ClassSymbol`, `MethodSlot`, `ProcSig`, name resolution; different
realization.

The payoff falls straight out of the thesis: because every M2 class is an Obj-C
class, a class can `INHERIT NSView` and its instances *are* `NSView`s. You hand one
to AppKit and AppKit's `drawRect:`/`mouseDown:` dispatch lands directly in the M2
method body — no trampoline, no `tag` table, no `Send*` casts. The hand-written
machinery in `library/macrtmod/Cocoa.mod` (the `gActions[tag]` dispatch, the
`M2CocoaTrampoline` class, the ten `Send*` signatures in `ObjC.def`) becomes
**the thing the compiler now generates**, and the demos' raw `objc_msgSend` casts
disappear.

## The mapping

| Modula-2 object model | Objective-C realization (macOS backend) |
|---|---|
| `CLASS C` (root, no `INHERIT`) | an Obj-C class rooted at `NSObject` (free alloc/init/retain/release/dealloc) |
| `CLASS C; INHERIT B;` | Obj-C class whose superclass is `B`'s Obj-C class |
| instance fields (`VAR x: T`) | ivars (`class_addIvar`), offsets resolved at registration |
| method `PROCEDURE M(...)` | an IMP added with `class_addMethod`; selector + type-encoding synthesized |
| `OVERRIDE PROCEDURE M` | `class_addMethod` for `M`'s selector on the subclass (runtime override) |
| method call `o.M(a)` | `objc_msgSend(o, @selector(M…), a)` |
| `NEW(p)` | `objc_msgSend(getClass(C), alloc)` then `init` |
| `DISPOSE(p)` | `release` (NSObject lifetime) |
| the hidden `SELF` receiver | the Obj-C `self` (first arg); compiler inserts the `_cmd` slot |
| `ABSTRACT CLASS` | a class with un-added (or `doesNotRecognizeSelector`) slots; concrete subclass must add them |

Every M2 class on macOS therefore registers itself with the Obj-C runtime. That
registration is a **pure runtime operation** (`objc_allocateClassPair` +
`class_addIvar` + `class_addMethod` + `objc_registerClassPair` — already exported
by `objc.rs:269/292/313`), so unlike the native backend's vtable globals there is
**nothing static to materialize and nothing for the JIT to patch — it works in
both back ends identically.** (This is the one place the COM design is genuinely
harder: its producer side is AOT-only because of static tear-off vtables. Here
there are none.)

## Three shapes of class, one construct

The same `CLASS` keyword covers three cases; the compiler tells them apart by
whether a body is defined and whether the base is foreign:

1. **Pure M2 class** — defined here, root `NSObject`. We `allocateClassPair` it
   under a mangled name (`M2.<Module>.<Class>`), add its ivars and IMPs, register.
   Its objects are ordinary Cocoa objects that happen to have M2-authored methods.

2. **Imported Cocoa class** (`NSView`, `NSWindow`, …) — *not* defined here, bound
   to an existing Obj-C class. We never `allocateClassPair`; we `objc_getClass`
   it, and its methods bind to existing selectors. Declared in a DEF as an external
   class (see "syntax", below). This replaces today's `ObjC.GetClass("NSView")` +
   hand casts.

3. **M2 subclass of a Cocoa class** (`CLASS EditorView; INHERIT NSView;`) — the
   headline. We `allocateClassPair(getClass("NSView"), …)`, add the overrides as
   IMPs, register. The instance is a real `NSView` subclass with M2 method bodies.

All three are the same front-end path. Only codegen forks on "do I create this
class or look it up."

## Syntax — reuse, with the minimum change

Stock M2 class syntax is kept verbatim. Two small, *optional* additions, used only
where Cocoa interop forces a name we can't derive:

- **Binding a class to an existing Obj-C class name.** An imported/overridden
  Cocoa class needs its real runtime name. Reuse the header-annotation slot
  introduced for COM IIDs (`ClassDecl` already carries an optional `["…"]`):

  ```modula2
  CLASS NSView ["NSView"]; EXTERNAL; END NSView;        (* imported, we getClass it *)
  CLASS EditorView; INHERIT NSView; ... END EditorView; (* our subclass, auto-named *)
  ```

  A pure M2 class needs no annotation — its Obj-C name is auto-mangled.

- **Selector override on a method.** By default the selector is *derived* from the
  M2 method name (rule below). Only when a method must match a pre-existing Cocoa
  selector with embedded colons do you pin it:

  ```modula2
  OVERRIDE PROCEDURE DrawRect (dirty: NSRect) ["drawRect:"];
  PROCEDURE SetTitle (t: NSString)            ["setTitle:"];
  ```

  This is the same post-signature `["…"]` slot `@N` already added for COM — a
  second use, no new parser concept.

### Selector derivation (so most methods need no annotation)

For an M2-authored method the selector is mechanical: lowercase-initial method
name, one trailing `:` per parameter for the keyword-less M2 calling style — e.g.
`PROCEDURE MoveTo (x, y: REAL)` → `moveTo::` is ambiguous, so the rule is **one
colon total for a method that takes arguments, none for a nullary method**:
`moveTo:` carrying all args, `refresh` for nullary. M2 has a single method name
(not Obj-C's interleaved keywords), so a single-keyword selector is the honest
mapping; the explicit `["…"]` override exists precisely for the cases that must
interleave (`initWithFrame:` style) or match AppKit exactly.

## Fields → ivars (decided: real ivars)

Each M2 field becomes a genuine Obj-C ivar — `class_addIvar` per field during the
`allocateClassPair` window; after registration, resolve each offset once via
`ivar_getOffset(class_getInstanceVariable(cls,"x"))` and cache it in a global
(exactly the `OBJC_IVAR_$_…` indirection clang emits for the non-fragile ABI).
`SELF.x` lowers to `self + offset`. This is the faithful choice the thesis demands:
fields are real per-instance Obj-C storage, visible to KVO/introspection, and
subclassing composes the way Cocoa expects. (A single `__m2fields` pointer-ivar
holding a compiler-laid-out record is a known fallback if the offset plumbing slips
a milestone — same source, no surface change — but it is not the target.)

## Dispatch, ABI, and type-encoding synthesis

`o.M(args)` resolves `M` to its `ProcSig`/`call_sig` today (`class.rs`
`VtableSlot.call_sig` — "hidden SELF receiver followed by the declared
parameters"). The macOS backend lowers it to a call of the fixed `objc_msgSend`
symbol, **bitcast to a signature the compiler synthesizes from `call_sig`** —
which is exactly what the hand-written `Send0`/`SendP`/`SendFrame`/`SendRect` zoo
encodes today, now produced by the compiler. arm64 rules the compiler now owns:
REAL→v-regs, INTEGER/CARDINAL/ADDRESS→x-regs, BOOLEAN→i8, `NSRect`(4×f64)→flattened
v-regs, small-struct returns in registers (so `objc_msgSend_stret` is needed only
for the bounded shim list).

For methods we *register*, `class_addMethod` needs the Obj-C type-encoding string;
the compiler synthesizes it from the same signature via a fixed table (`v` void,
`@` object/SELF/ADDRESS, `:` the `_cmd`, `q` INTEGER, `Q` CARDINAL, `c`/`B`
BOOLEAN, `d` REAL, `{CGRect=dddd}` NSRect). Hand-encodings like `"v@:@"` in
`demos/macos_button.mod` vanish.

`objc_msgSend(nil, …)` is defined to return nil/0, so M2-on-Obj-C dispatch is
**nil-safe by construction** — strictly safer than the native-vtable and COM
paths, both of which null-deref on a NIL receiver. Optional later: cache the IMP
(`class_getMethodImplementation`) for hot/final dispatch to skip the send lookup.

## Construction and lifetime

The principle is **everything Cocoa below, M2 above**: under the line it is
`[[Class alloc] init…]` and `retain`/`release`; above the line it is `NEW`,
`DISPOSE`, and ordinary procedure calls. No `alloc`, no `msgSend`, no `Sel(...)`
ever appears in a program.

- `NEW(p)` → `objc_msgSend(getClass(C), alloc)` + `init` (stops routing through
  the self-hosted `Heap`, `codegen.rs:59`). The zero-argument case.
- **Parameterised construction is a class-method constructor**, so it reads M2 and
  maps faithfully to a designated initializer. A class declares a class (static)
  method that pins the Cocoa initializer; the program calls it `Type.Make(args)`:

  ```modula2
  CLASS NSButton ["NSButton"]; EXTERNAL;
    CLASS PROCEDURE New (r: NSRect): NSButton ["initWithFrame:"];  (* alloc+initWithFrame: *)
    ...
  END NSButton;

  VAR b: NSButton;
  b := NSButton.New(frame);          (* reads pure M2; emits [[NSButton alloc] initWithFrame:frame] *)
  ```

  `CLASS PROCEDURE` is the static-method form (dispatched on the metaclass); when
  its pinned selector is an `init…`, the compiler prepends the `alloc`. This is the
  one construction idiom — no `alloc`/`init` two-step leaks into source.
- `DISPOSE(p)` → `release`. Because objects are NSObject-rooted, dealloc /
  finalization is Cocoa's. Retain/release of **+1 owned** objects is still manual
  (storing a long-lived object reference into a field calls `retain`; `DISPOSE`
  releases) — a full ARC-style scope-release is later design. **+0 autoreleased
  objects** (convenience constructors, `ObjC.NSString`, autoreleased returns) are
  now handled: each program run is wrapped in an **autorelease pool** (default on;
  off via `--no-autorelease-pool` for a JIT run or `NM2_NO_AUTORELEASE_POOL` for
  an AOT executable), so they have a defined lifetime and drain at run end instead
  of leaking with no pool in place. (`newm2_runtime::objc::autorelease_pool_push/
  pop` around `run_modules` and `nm2_aot_run`.)
- For finer control there is a **manual pool API** in `ObjC`, the
  programmer-controlled counterpart to the implicit run pool — it brackets an
  *inner* scope (typically a loop body) so its temporaries drain each iteration,
  bounding peak memory the single run-scoped pool can't:

  ```
  TYPE Pool;                      (* opaque token *)
  PROCEDURE PushPool (): Pool;    (* open;  pair LIFO with PopPool, like Open/Close *)
  PROCEDURE PopPool (p: Pool);    (* drain — release everything autoreleased since push *)
  PROCEDURE Autorelease (obj: Id): Id;   (* dual of DISPOSE: release at next drain, not now *)
  ```

  ```
  FOR i := 1 TO frames DO
    pool := ObjC.PushPool();
      DrawFrame(i)          (* many +0 temporaries *)
    ObjC.PopPool(pool)      (* released here, not at run end *)
  END
  ```

  These nest inside the implicit run pool (LIFO). Caveat: an exception between
  push and pop skips the pop — guard a protected block with an `EXCEPT` arm that
  calls `PopPool` then `RAISE`. A language-level pool *block* with guaranteed
  cleanup, and a full ARC-style scope-release for +1 objects, remain future work.

## Surface — the programs are Modula-2

The dividing line is strict: **a program built on these objects contains no Cocoa
vocabulary at all.** Selectors, `objc_msgSend`, `alloc`, type encodings — all live
*below* the line, in compiler output and in generated/library class declarations.
Above the line is stock Modula-2: typed object variables, `NEW`/`DISPOSE`, `NIL`,
dotted method calls, `INHERIT`/`OVERRIDE`.

What the surface guarantees:

- **Typed object references, not `ADDRESS`.** `VAR v: NSView` — a real class type,
  not today's `Cocoa.Object = ADDRESS`. Assignment, `=`/`#` against `NIL`, and
  parameter passing are ordinary M2.
- **Calls are dotted and positional.** `view.SetFrame(r)`, `arr.ObjectAtIndex(i)`.
  Obj-C's interleaved keyword selector (`initWithFrame:styleMask:backing:defer:`)
  becomes ordinary positional M2 parameters on a single M2 method name; the
  selector that stitches them is recorded once, in the declaration, never at a call
  site.
- **Selector derivation keeps even the declarations clean** for the common shapes:
  a nullary method `Frame` derives selector `frame`; a single-keyword method
  `DrawRect (r)` derives `drawRect:`; `MouseDown (e)` derives `mouseDown:`. So an
  AppKit *override* in a user program needs **zero annotation** — only genuinely
  multi-keyword selectors carry an explicit `["…:…:"]`, and those sit in generated
  headers, not application code.
- **String literals coerce.** An `ARRAY OF CHAR` / string literal where an
  `NSString` is expected is converted implicitly (the `ObjC.NSString` call moves
  below the line), so `b.SetTitle("Run")` is what you write.
- **`NIL` is `nil`** — same keyword, and dispatch on it is defined (no crash).

A representative program — a custom view, instantiated and handed to a window —
reads end to end as Modula-2:

```modula2
MODULE Paint;
IMPORT AppKit;                          (* generated EXTERNAL Cocoa classes *)

CLASS Canvas;                           (* a real NSView subclass, no annotations *)
  INHERIT AppKit.NSView;
  VAR strokes: AppKit.NSMutableArray;   (* a genuine ivar *)
  OVERRIDE PROCEDURE DrawRect (dirty: AppKit.NSRect);   (* -> drawRect: by derivation *)
  OVERRIDE PROCEDURE MouseDown (e: AppKit.NSEvent);     (* -> mouseDown: *)
  PROCEDURE Clear;                                      (* an ordinary M2 method *)
END Canvas;

OVERRIDE PROCEDURE Canvas.DrawRect (dirty: AppKit.NSRect);
BEGIN
  SELF.strokes.MakeObjectsPerformDraw;   (* method calls on real Cocoa objects *)
END DrawRect;

PROCEDURE Canvas.Clear;
BEGIN
  SELF.strokes.RemoveAllObjects;
  SELF.SetNeedsDisplay(TRUE)
END Clear;

VAR win: AppKit.NSWindow; view: Canvas;
BEGIN
  win  := AppKit.NSWindow.New(900.0, 600.0, "Paint");
  view := NEW(Canvas);                   (* [[Canvas alloc] init] under the line *)
  view.strokes := AppKit.NSMutableArray.New();
  win.ContentView().AddSubview(view);
  AppKit.RunApp
END Paint.
```

Nothing in that module names a selector or a message send; it is Modula-2 whose
objects happen to be, all the way down, Cocoa.

## Why this is a clean target-lowering, not a fork of the language

Reused unchanged: all class parsing; `ClassArena`/`ClassSymbol`/`MethodSlot`/
`FieldSlot`/`ProcSig`/`call_sig`; method-name resolution (`find_class_method_
binding`); abstract/override/reveal validation; the `["…"]` annotation slots.

Net-new, and contained in the macOS codegen path:
1. **Class registration emission** at module-init: `allocateClassPair` + per-field
   `class_addIvar` + per-method `class_addMethod`(synthesized selector+encoding) +
   `register`. Skipped for `EXTERNAL` classes (just `getClass`).
2. **Dispatch lowering** → `objc_msgSend` + synthesized cast (replaces field-0
   vtable dispatch on this target).
3. **Field access** → ivar offset load (strategy (a)).
4. **`NEW`/`DISPOSE`** → alloc/init / release for class-typed pointers.
5. **Selector derivation + type-encoding synthesis** helpers.
6. Optional `EXTERNAL` keyword (or reuse the opaque-DEF convention) to mark
   imported Cocoa classes.

No new IR object node, no tear-offs, no static vtable, no JIT patching. The native
backend's class lowering is untouched; macOS selects the Obj-C lowering at the
same point it already selects target ABI.

## Acceptance test (the teacher)

The macOS IDE's editor surface, today an `NSScrollView`+`NSTextView` poked through
`Cocoa.mod`, rewritten as:

```modula2
CLASS EditorView;
  INHERIT NSView;
  VAR buffer: TextBuffer; cursor: INTEGER;          (* real ivars *)
  OVERRIDE PROCEDURE DrawRect (dirty: NSRect) ["drawRect:"];
  OVERRIDE PROCEDURE MouseDown (e: NSEvent)   ["mouseDown:"];
  PROCEDURE Load (path: ARRAY OF CHAR);             (* an ordinary M2 method *)
END EditorView;
```

`NEW`ing one yields a genuine `NSView` subclass; adding it to a window makes AppKit
call `DrawRect`/`MouseDown` straight into M2; `Load` is a normal method on a normal
object. When this replaces the trampoline path, the model is proven.

## Staged plan

| Stage | Component | Work |
|------|-----------|------|
| **M0** | sema/codegen | macOS class lowering scaffold: pure M2 `CLASS` (root `NSObject`) → registration emission; `NEW`/`DISPOSE` → alloc/init / release; dispatch → `objc_msgSend`. Strategy-(b) single ivar to get instances + methods + one field working end-to-end, JIT and AOT. |
| **M1** | codegen | Real ivars (strategy (a)): `class_addIvar` + cached offset loads for `SELF.field`. |
| **M2** | sema/codegen | `INHERIT` → Obj-C superclass; `OVERRIDE` → IMP install by selector; selector derivation + the optional `["sel:"]` pin; type-encoding synthesis. |
| **M3** | parser/sema | `EXTERNAL` (imported) Cocoa classes via `["Name"]` → `getClass` binding; declare `NSObject`/`NSView`/`NSWindow`/`NSButton`/`NSTextView`. |
| **M4** | library/demos | Rewrite the IDE editor as `CLASS EditorView INHERIT NSView`; retire the `M2CocoaTrampoline`/`gActions[tag]` path and the `Send*` zoo for the rewritten surfaces. |
| **M5** | tooling | `cocoa-gen` from the SDK BridgeSupport XML: emit `EXTERNAL` class decls with selectors + encodings for the common AppKit/Foundation surface; named shim list for hand-marshalled selectors. |

M0–M2 deliver the model (M2 objects are Obj-C objects, with state, inheritance,
and override); M3–M5 make Cocoa interop ergonomic and exhaustive.

## Decisions (Max Mac Native)

Locked, in favour of fidelity over divergence:

- **Every M2 class is NSObject-rooted**, uniformly — Cocoa-blind compute classes
  included. msgSend overhead is accepted; a lightweight native lowering for
  non-escaping classes is explicitly *not* pursued (one representation, maximally
  native). A final/hot-path IMP cache (`class_getMethodImplementation`) is the
  sanctioned optimisation, and it stays below the line.
- **Real ivars** (not the `__m2fields` record), offsets resolved+cached at
  registration ourselves (no clang-compatible `OBJC_IVAR_$_…` image sections to
  emit).
- **Eager class registration at module-init**, matching module-init ordering.

## Open questions

- **Obj-C exceptions through M2 frames** — documented-UB v1 (the bridge is already
  `extern "C-unwind"`); a `@try` boundary shim is a later runtime seam.
- **Threading / ARC** — manual retain/release for +1 objects; interlocked
  refcount deferred. A run-scoped **autorelease pool is now in place** (default on)
  so +0 objects no longer leak for the process lifetime; per-scope pools and full
  ARC scope-release remain deferred. The surface (`NEW`/`DISPOSE`, field-store
  `retain`) is ARC-ready: turning on ARC-like ownership later changes lowering, not
  source.
- **`ABSTRACT`/protocols** — an M2 `ABSTRACT CLASS` maps to a class with missing
  IMPs; a future `PROTOCOL` models Obj-C `@protocol` for delegate typing.
- **`CLASS PROCEDURE` (static methods)** — confirm the spelling for class-method
  constructors / Cocoa class methods (`[NSColor redColor]` → `NSColor.RedColor()`).
  `CLASS PROCEDURE` reuses existing keywords; an alternative is a `<*class*>` pragma.

## Explicitly out of scope

- Multiple inheritance (Obj-C is single-inheritance; protocols are a later `PROTOCOL`).
- Swift interop (different ABI).
- Obj-C exception *propagation* semantics (see open questions).
