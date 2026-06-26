# Classes as Cocoa classes

The defining feature of MacM2 is that **every** Modula-2 `CLASS` **is** an
Objective-C class — there is no other kind of class on macOS. There is no wrapper
object and no trampoline: for *every* class you declare, the compiler emits a
registration constructor (run at image load for an AOT build, or by the JIT
before module bodies) that calls the Obj-C runtime directly —

```
objc_allocateClassPair(superclass, "M2.<module>.<Class>", 0)
class_addIvar(cls, "__m2", <bytes>, ...)     (* one ivar holds the class's M2 fields *)
class_addMethod(cls, sel, &Class.Method, typeEncoding)   (* per method *)
objc_registerClassPair(cls)
```

— so the result is a genuine class the Obj-C runtime, and therefore AppKit, can
see. Fields become real ivars; methods become real methods dispatched through
`objc_msgSend`; the arm64 type encoding for each method is synthesized from its
M2 signature.

## A plain class

A class with no Cocoa superclass is rooted at `NSObject`. Its fields are
per-instance ivars; `NEW` is `alloc`/`init`, `DISPOSE` is `release`; method calls
dispatch dynamically.

```modula2
MODULE counter;
IMPORT STextIO, SWholeIO;

CLASS Counter;
  VAR n: INTEGER;                                    (* a real Obj-C ivar *)
  PROCEDURE Bump (by: INTEGER); BEGIN n := n + by END Bump;
  PROCEDURE Value (): INTEGER;  BEGIN RETURN n END Value;
END Counter;

VAR a: Counter;
BEGIN
  NEW(a);                 (* [[M2.counter.Counter alloc] init]; ivars zero-filled *)
  a.Bump(40); a.Bump(2);  (* objc_msgSend dispatch                                *)
  SWholeIO.WriteInt(a.Value(), 0); STextIO.WriteLn;
  DISPOSE(a)              (* [a release]; a := NIL                                 *)
END counter.
```

Inside a method, `SELF` is the instance. `a.Bump(2)` and a self-call
`SELF.Bump(2)` both lower to `objc_msgSend(obj, @selector(bump:), 2)`. `NEW`
zero-fills, matching Modula-2's semantics, because `alloc` zeroes ivars.

## Subclassing a Cocoa class

To subclass a real Cocoa class, name it as the base with ordinary `INHERIT` — no
import, no annotation. The compiler resolves the name from the Cocoa metadata and
registers your class as a genuine subclass, so AppKit calls your overrides
directly:

```modula2
CLASS FlippedView;
  INHERIT NSView;                       (* a genuine NSView subclass — no pragma, no IMPORT *)
  PROCEDURE IsFlipped (): BOOLEAN;      (* selector "isFlipped" (derived) *)
  BEGIN RETURN TRUE END IsFlipped;      (* NSView's default is FALSE; ours wins *)
END FlippedView;
```

The base name is checked against the curated Cocoa metadata (~40 Foundation /
AppKit classes — `NSView`, `NSWindow`, `NSTextView`, `NSResponder`, …), so a
misspelled base like `INHERIT NSVeiw` is a *compile* error, not a runtime nil.

For a class the metadata does not cover — e.g. a framework class you bring in with
`ObjC.LoadFramework`, like `MTKView` — name it by string with the
`<* cocoa "ClassName" *>` pragma instead. It has the same effect (root at that
Obj-C class), just unchecked. This is the IDE's rope-backed `NSTextView` editor:

```modula2
CLASS RopeTextView;
  <* cocoa "NSTextView" *>              (* equivalent to INHERIT NSTextView *)
  ...
  PROCEDURE InsertNewline (sender: ObjC.Id) <* selector "insertNewline:" *>;
  BEGIN ... END InsertNewline;

  PROCEDURE GetCharacters (buffer: ADDRESS; loc, len: CARDINAL)
    <* selector "getCharacters:range:" *>;
  BEGIN ... END GetCharacters;
END RopeTextView;
```

(`NSTextView` is in the metadata, so `INHERIT NSTextView` works too — the IDE
predates metadata-resolved `INHERIT` and still uses the pragma.)

### Selectors: derived or pinned

By default a method's selector is **derived** from its name: lowercase the
initial letter and add a trailing colon if it takes arguments
(`DrawRect` → `drawRect:`, `OnOpen(sender)` → `onOpen:`). That covers most
single-keyword overrides and target/action handlers with no annotation.

When the Obj-C selector is multi-keyword or otherwise does not follow the rule,
pin it explicitly with `<* selector "exactSelector:" *>`:

```modula2
PROCEDURE OnLink (tv, link: ObjC.Id; idx: CARDINAL): BOOLEAN
  <* selector "textView:clickedOnLink:atIndex:" *>;
```

Use `OVERRIDE` to replace an inherited method (it keeps the vtable slot, so a
call through a base reference reaches your implementation):

```modula2
CLASS FlippedView;
  <* cocoa "NSView" *>
  OVERRIDE PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;
END FlippedView;
```

### Fields on a Cocoa-rooted instance

Each class adds exactly one `__m2` ivar holding its own fields. For an
`NSObject`-rooted class that ivar sits right after `isa` and field access is an
ordinary GEP. For a class that subclasses, say, `NSView`, the `__m2` ivar sits
after the superclass's ivars, so at runtime the object pointer is adjusted by
`nm2_objc_field_base` (which reads the live `__m2` ivar offset) before the field
GEP — transparent to your code:

```modula2
CLASS EditorView;
  <* cocoa "NSView" *>
  VAR strokes: ObjC.Id;     (* lives in this class's __m2 ivar *)
  OVERRIDE PROCEDURE DrawRect (dirty: ObjC.NSRect);
  BEGIN ... uses SELF.strokes ... END DrawRect;
END EditorView;
```

## Binding to an existing class

The two class pragmas are opposites. `<* cocoa "NSView" *>` *subclasses* a Cocoa
class — it creates a new Obj-C subclass. `<* cocoa_class "NSView" *>` says this M2
class **is** the existing `NSView`: a typed binding, no new class.

| Pragma | Meaning |
|---|---|
| `<* cocoa "NSView" *>` | this class is a **new subclass** of `NSView` |
| `<* cocoa_class "NSView" *>` | this class **is** the existing `NSView` — a typed face on it, not a subclass |

Reach for `<* cocoa "…" *>` when you are *extending* Cocoa (adding state,
overriding methods). Reach for `<* cocoa_class "…" *>` when you only want a typed
Modula-2 surface on a class Cocoa already provides. The generated `CocoaNS`
bindings are built entirely from `cocoa_class`: each declares `ABSTRACT` methods
(selector-pinned, no body) over the real class.

```modula2
CLASS NSMutableArray;
  <* cocoa_class "NSMutableArray" *>               (* IS NSMutableArray, not a subclass *)
  ABSTRACT PROCEDURE AddObject (a0: ObjC.Id) <* selector "addObject:" *>;
  ABSTRACT PROCEDURE Count    (): CARDINAL    <* selector "count" *>;
END NSMutableArray;
```

## `INHERIT` — one keyword, two sources

`INHERIT` is the single inheritance mechanism, and it resolves its base from
whichever source has it:

```modula2
CLASS Animal;        VAR legs: INTEGER; ... END Animal;
CLASS Dog;   INHERIT Animal;  VAR barks: INTEGER; ... END Dog;   (* an M2 class      *)
CLASS MyView; INHERIT NSView; ... END MyView;                    (* a Cocoa class    *)
```

- a base that resolves to an M2 class in scope → ordinary single inheritance;
- a base that resolves to an in-scope `cocoa_class` binding (e.g. an imported
  `CocoaNS.NSView`) → a Cocoa subclass with the binding's methods visible;
- an *unresolved* bare name that the Cocoa metadata knows → a Cocoa subclass
  rooted at that class (the common case above, equivalent to `<* cocoa "…" *>`);
- anything else → a compile error.

So you reach for the `<* cocoa "…" *>` pragma only for a class the metadata does
not cover — never for the everyday AppKit/Foundation classes.

## Runtime class tests — `GUARD` and `ISMEMBER`

Because every instance is a genuine Obj-C object that carries its dynamic type,
runtime type discrimination is built in. `ISMEMBER(obj, T): BOOLEAN` is true when
`obj`'s dynamic class is `T` or a subclass; the `GUARD` statement dispatches on
dynamic type and binds a read-only narrowed reference in each arm. For
Cocoa-rooted classes both lower to `[obj isKindOfClass: [T class]]` — the Cocoa
counterpart of the Windows build's COM `QueryInterface`.

```modula2
IF ISMEMBER(view, EditorView) THEN ... END;

PROCEDURE Describe (x: Shape);
BEGIN
  GUARD x AS
    c: Circle DO  WriteCircle(c.r, c.Area())     (* c is a read-only Circle here *)
  | s: Square DO  WriteSquare(s.side)
  ELSE
    WriteString("unknown")     (* no match and no ELSE traps with guardException *)
  END
END Describe;
```

## Delegates, data sources, and blocks

Most AppKit integration is delegation. The cleanest form is a controller
`CLASS` rooted at `NSObject` whose methods are the action and delegate callbacks
— exactly how the IDE is built:

```modula2
CLASS IDE;
  <* cocoa "NSObject" *>
  PROCEDURE OnOpen (sender: ObjC.Id);    (* selector onOpen: (derived) — a menu action *)
  BEGIN ... END OnOpen;
  PROCEDURE WindowDidResize (note: ObjC.Id) <* selector "windowDidResize:" *>;
  BEGIN Relayout END WindowDidResize;
END IDE;

VAR ide: IDE; ctrl: ObjC.Id;
BEGIN
  NEW(ide); ctrl := CAST(ObjC.Id, ide);
  [win setDelegate: ctrl];               (* the controller is the window delegate *)
  ...
```

When a callback's signature is awkward to express as a pinned method — a Cocoa
data source with a complex type encoding, for instance — install the IMP
directly onto a class with `ObjC.AddMethod`. The procedure must take the
Obj-C calling convention `(self, _cmd, args…)` and the type-encoding string
describes the ABI:

```modula2
(* an NSTextView completion data source: returns an NSArray, takes (tv, words, range, *idx) *)
PROCEDURE Completions (self, cmd, tv, words: ObjC.Id;
                       rangeLoc, rangeLen: CARDINAL; idx: ObjC.Id): ObjC.Id;
BEGIN ... END Completions;

okAdd := ObjC.AddMethod(CAST(ObjC.Class, [ctrl class]),
                        ObjC.Selector("textView:completions:forPartialWordRange:indexOfSelectedItem:"),
                        CAST(ADDRESS, Completions),
                        "@@:@@QQ^q");      (* return id; self,_cmd; id,id,2×NSUInteger,*NSInteger *)
```

For a completely synthetic class, build one from scratch:

```modula2
cls := ObjC.AllocateClass(ObjC.GetClass("NSObject"), "M2Handler");
ok  := ObjC.AddMethod(cls, ObjC.Selector("onClick:"), CAST(ADDRESS, OnClick), "v@:@");
ObjC.RegisterClass(cls);
```

**Blocks** cover the callback APIs that take a block rather than a delegate —
notably `NSTimer`. Wrap a procedure (block invoke ABI: first parameter is the
block) with `ObjC.MakeBlock`:

```modula2
PROCEDURE Tick (block, timer: ObjC.Id);   (* fires every interval *)
BEGIN ... update the clock ... END Tick;

[Cls("NSTimer") scheduledTimerWithTimeInterval: 1.0
                repeats: TRUE
                block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
```

> Lifetime note: M2 objects use manual reference counting (`NEW`/`DISPOSE` →
> `alloc`/`init`/`release`), and blocks/IMPs registered this way are capture-free
> globals that live for the program. Hold a reference (e.g. a module variable) to
> anything Cocoa does not retain for you — a controller you set as a delegate, a
> data source, a timer — so ARC cannot reclaim it while it is still in use.
