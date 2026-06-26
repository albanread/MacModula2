# The bound library and reaching any Cocoa API

There are three layers between your program and Cocoa, and you mix them freely:

- **`ObjC`** — the low-level bridge (message sends, class/selector interning,
  blocks, dynamic class building). See [Message sends](message-send.md).
- **`Cocoa`** — a hand-written, ergonomic AppKit layer (windows, editors,
  buttons, dialogs) for getting an app on screen fast.
- **`CocoaNS`** — a generated set of typed `EXTERNAL` class bindings for
  Foundation/AppKit, so common classes read as ordinary M2 classes.

> The snippets below use the one-line local helpers from
> [Message sends](message-send.md): `Cls(name)` wraps `ObjC.GetClass` (so a class
> can be a message receiver) and `Range(loc, len)` builds an `ObjC.NSRange`.
> They are conventions you define per module, not library exports.

## The bound library

### `Cocoa` — the ergonomic AppKit layer

[`library/macrtdef/Cocoa.def`](../../library/macrtdef/Cocoa.def) wraps the common
AppKit constructors and operations as plain procedures:

| Area | Procedures |
|---|---|
| App | `InitApp`, `RunApp`, `RunFor` (run the loop for a bounded time) |
| Window | `MakeWindow(w, h, title)`, `ContentView`, `ShowWindow`, `AddSubview`, `RemoveView` |
| Text | `MakeLabel`, `SetText`, `MakeEditor`, `SetEditorText`, `EditorText`, `EditorCursor`, `SetEditorCursor` |
| Editor services | `HighlightEditor` (M2 syntax colouring), `MarkErrors`, `GotoFirstError` |
| Controls | `MakeButton(x, y, w, h, title, action)`, `Click`, `MakeTabView`, `AddTab`, `SelectedTab` |
| Dialogs | `OpenFile`, `SaveFile`, `OpenFolder` |
| Capture | `Snapshot(view, path)` — render a view to PNG offscreen |

`MakeButton`'s `action` is an ordinary M2 procedure — the wrapper installs the
target/action plumbing for you:

```modula2
PROCEDURE OnComplete; BEGIN ... END OnComplete;

editor := Cocoa.MakeEditor(10.0, 360.0, 700.0, 168.0);
Cocoa.SetEditorText(editor, code);
Cocoa.HighlightEditor(editor);                 (* colour it with the M2 lexer *)
Cocoa.AddSubview(content, editor);
btn := Cocoa.MakeButton(580.0, 10.0, 130.0, 34.0, "Complete", OnComplete);
```

`Snapshot` renders a view hierarchy to a PNG without a window server, which is
how the IDE's GUI is regression-tested and how the screenshots in this repo are
produced.

### `ObjC` — utilities beyond message sends

Besides the message-send primitives, [`ObjC.def`](../../library/macrtdef/ObjC.def)
exposes:

- **Run loop / capture:** `RunApp` (interactive, blocks until quit), `Pump(secs)`
  (run the loop for a bounded time — e.g. while audio plays), `SnapshotView`.
- **Frameworks:** `LoadFramework(name)` `dlopen`s a framework that is not linked
  at startup, so its classes register and become reachable via `GetClass`:

  ```modula2
  ObjC.LoadFramework("AVFoundation");
  player := [[Cls("AVMIDIPlayer") alloc] initWithContentsOfURL: url soundBankURL: NIL error: NIL];
  ```

- **File panels:** `OpenPanel`, `SavePanel`, `OpenFolderPanel` (the raw forms
  under `Cocoa.OpenFile`/`SaveFile`/`OpenFolder`).
- **Editor/compiler services:** `Highlight`, `MarkErrors`, `CursorPos`,
  `SetCursor`, `GotoFirstError`, `LineNumbers` — the M2 lexer and compiler-output
  parsing exposed through an `NSTextView`.
- **Dynamic classes / blocks:** `AllocateClass`, `AddMethod`, `RegisterClass`,
  `MakeBlock` (see [Classes](classes.md#delegates-data-sources-and-blocks)).

### Building Cocoa collections

The bracket syntax makes Foundation collections read naturally — this is the
attributed-string builder from the IDE's markdown renderer:

```modula2
d := [[Cls("NSMutableDictionary") alloc] init];
[d setObject: font  forKey: ObjC.NSString("NSFont")];
[d setObject: color forKey: ObjC.NSString("NSColor")];

doc := [[Cls("NSMutableAttributedString") alloc] init];
ms  := [doc mutableString];
loc := [ms length];
[ms appendString: ns];
[doc setAttributes: d range: Range(loc, [ns length])];
```

### `CocoaNS` — typed class bindings

[`library/macrtdef/CocoaNS.def`](../../library/macrtdef/CocoaNS.def) declares
Foundation/AppKit classes as typed M2 classes, each bound to its existing Obj-C
class with `<* cocoa_class "…" *>` (see
[Binding to an existing class](classes.md#binding-to-an-existing-class)), so you
use them through the M2 type system instead of raw sends:

```modula2
CLASS NSMutableArray;
  <* cocoa_class "NSMutableArray" *>
  ABSTRACT PROCEDURE AddObject (a0: ObjC.Id) <* selector "addObject:" *>;
  ABSTRACT PROCEDURE Count    (): CARDINAL    <* selector "count" *>;
END NSMutableArray;
```

```modula2
IMPORT CocoaNS;
VAR items: CocoaNS.NSMutableArray;
BEGIN
  NEW(items);                          (* a real NSMutableArray *)
  items.AddObject(ObjC.NSString("alpha"));
  WriteInt(items.Count(), 0);
```

The object is a genuine Cocoa instance; `items.AddObject(x)` lowers to the same
`objc_msgSend`, but the selector and casts are hidden. Class methods (e.g.
`NSColor.RedColor()`) are emitted as `CLASS PROCEDURE`s.

## Reaching any Cocoa API

The bound surface is a convenience, not a limit. **Two things make the whole of
Cocoa reachable.**

First, an **unbound selector still works**: a send to a selector that is not in
the database dispatches correctly through `objc_msgSend` and simply types its
result as `ObjC.Id` (you `CAST` if you need something else). So you can call any
method on any class today — binding only adds typed returns and editor
assistance.

Second, the typed surface is **generated and extensible.**

### The selector database

[`library/macrtdef/cocoa-selectors.json`](../../library/macrtdef/cocoa-selectors.json)
holds over 5,500 selectors across 40 curated Foundation/AppKit classes. It is a JSON
object with `note` (metadata + the kind legend), `classes` (the curated list),
and `selectors` (a flat `name -> {ret, args}` map). The single-letter *kinds*
are: `@` id · `:` SEL · `i` int · `u` uint · `d` real · `B` bool · `v` void ·
`N`/`P`/`S`/`R` the four geometry structs · `{…}` a synthesized struct. The
compiler hand-parses it at compile time (no JSON dependency) to type sends and,
under `--strict`, to flag unknown literal selectors.

### `newm2-cocoa-gen`

[`src/newm2-cocoa-gen/`](../../src/newm2-cocoa-gen/) is a standalone tool that
`dlopen`s Foundation/AppKit/AVFoundation and **introspects the live Obj-C
runtime** (`class_copyMethodList`, `method_getTypeEncoding`, `sel_getName`,
`class_getSuperclass`, …). For each class in its curated list it walks the
superclass and metaclass chains and emits, from the same scan:

- **`cocoa-selectors.json`** — run with `COCOA_GEN_JSON=1`.
- **`CocoaNS.def`** — the typed `EXTERNAL` bindings, emitted **base-first** along
  the inheritance chain (so every `INHERIT` target is declared first), with an
  `ABSTRACT PROCEDURE` / `ABSTRACT CLASS PROCEDURE` per method carrying its pinned
  selector. Struct return shapes are mapped to the geometry kinds or synthesized
  records; **BridgeSupport** data, when present, supplies real struct field names
  instead of positional `f0`/`f1`.

### Binding a new class

1. Add the class name to the curated list in
   [`src/newm2-cocoa-gen/src/main.rs`](../../src/newm2-cocoa-gen/src/main.rs)
   (or pass it as a CLI argument).
2. Regenerate on a machine with the frameworks available:

   ```
   cargo build -p newm2-cocoa-gen
   COCOA_GEN_JSON=1 target/debug/newm2-cocoa-gen > library/macrtdef/cocoa-selectors.json
   target/debug/newm2-cocoa-gen                  > library/macrtdef/CocoaNS.def
   ```
3. For a class in a framework that is not auto-linked, `ObjC.LoadFramework(...)`
   at run time before using it.

But remember step 0: you do **not** have to do any of this to *call* the API —
the default-`id` path already reaches it. Generation is for typed returns, the
`CocoaNS` class surface, and `--strict` checking.

> See also: [The Modula-2 object model on the Obj-C runtime](../design/cocoa-classes.md)
> and [Cocoa message-send ergonomics](../design/cocoa-send.md) for the design
> rationale, and [The MacM2 runtime](../macm2-runtime.md) for the runtime layer.
