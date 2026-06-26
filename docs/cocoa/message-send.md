# Message sends

MacM2 adds **Objective-C's bracket message-send syntax directly to Modula-2** —
the same `[ ]` you write in Objective-C, now a real construct in the language:

```modula2
[receiver selector: arg ...]
```

It is an ordinary primary expression (it may also stand alone as a statement),
parsed by the front end into an `ObjcSend` AST node, type-checked against the
selector database, and lowered to a call through `objc_msgSend`.

## Unary, keyword, and chained sends

```modula2
n   := [arr count];                                  (* unary, no args        *)
obj := [arr objectAtIndex: i];                       (* one keyword argument  *)
[store replaceCharactersInRange: r withString: s];   (* statement, two args   *)
arr := [[Cls("NSMutableArray") alloc] init];         (* chained sends         *)
```

A **keyword** selector is the concatenation of its keyword parts, so
`[v setX: a y: b]` sends the selector `setX:y:`. A **unary** selector has no
colon. Chaining reads left-to-right: `[[Cls("NSMutableArray") alloc] init]` first
sends `alloc` to the class, then `init` to the resulting object.

## The `ObjC` primitives

The bracket syntax is built on a handful of primitives in
[`library/macrtdef/ObjC.def`](../../library/macrtdef/ObjC.def):

| Primitive | Meaning |
|---|---|
| `ObjC.Id`, `ObjC.SEL`, `ObjC.Class` | opaque `ADDRESS`-typed handles (an object, a selector, a class) |
| `ObjC.GetClass(name): Class` | `objc_getClass` — look up a class by name |
| `ObjC.Selector(name): SEL` | `sel_registerName` — intern a selector |
| `ObjC.NSString(s): Id` | build an (autoreleased) `NSString` from M2 text |
| `ObjC.GetString(ns, VAR dest): INTEGER` | read an `NSString` back into an `ARRAY OF CHAR` |
| `ObjC.MsgSendPtr(): ADDRESS` | `&objc_msgSend`, for the low-level idiom below |

All of these transcode between Modula-2's 16-bit `CHAR` (UTF-16) and the C
runtime's UTF-8 at the boundary, so M2 string literals just work as class names,
selector names, and `NSString` contents.

A class object is a valid receiver, so a one-line local helper is idiomatic:

```modula2
PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

win := [[Cls("NSWindow") alloc] init];
```

### Casting a class instance to a receiver

A variable of an M2 `CLASS` type is a *typed* object pointer, not a bare
`ADDRESS`. To use it as a message receiver, cast it to `ObjC.Id`:

```modula2
me := CAST(ObjC.Id, SELF);
r  := [me selectedRange];
```

## Typed return values (the selector database)

Sends are **not** uniformly `id`. The compiler loads
[`library/macrtdef/cocoa-selectors.json`](../../library/macrtdef/cocoa-selectors.json)
— a database of over 5,500 selectors across 40 Foundation/AppKit classes — and infers
each send's result type from the selector's recorded return *kind*:

| Kind | M2 type | Example |
|---|---|---|
| `@` | `ObjC.Id` (object) | `[arr objectAtIndex: i]` |
| `v` | *(statement)* | `[player stop]` |
| `i` | `INTEGER` | |
| `u` | `CARDINAL` | `[arr count]` |
| `d` | `REAL` | `[num doubleValue]` |
| `B` | `BOOLEAN` | `[view isFlipped]` |
| `N` `P` `S` `R` | `NSRange` `NSPoint` `NSSize` `NSRect` | `[view frame]` |
| `{…}` | a synthesized record | `[xform transformStruct]` (an `NSAffineTransform`) |

```modula2
n := [arr count];        (* CARDINAL — no CAST *)
d := [num doubleValue];  (* REAL              *)
r := [view frame];       (* NSRect            *)
```

A selector **not** in the database (a private method, or a class from a framework
the database does not cover) still dispatches correctly — its result simply
defaults to `ObjC.Id`, which you `CAST` as needed. So the database is an
ergonomic convenience, not a gate: the whole runtime is reachable either way.

Compiling with `--strict` turns an *unknown literal selector* into a warning,
which catches typos like `setSlectedRange:`. Runtime-computed selectors are not
checked.

## Geometry value types

Four small structs are declared as records in `ObjC.def`, laid out to match the
C ABI so they pass and return in registers on arm64:

```modula2
TYPE
  NSPoint = RECORD x, y: REAL END;                     (* d0/d1            *)
  NSSize  = RECORD width, height: REAL END;            (* d0/d1            *)
  NSRect  = RECORD origin: NSPoint; size: NSSize END;  (* d0–d3 (HFA)      *)
  NSRange = RECORD location, length: CARDINAL END;     (* x0/x1            *)
```

Because the database types `frame`/`bounds`/`selectedRange` as `R`/`R`/`N`, those
sends return the struct directly — access `r.origin.x`, `r.size.width`,
`rng.location`. One-line builders make struct *arguments* readable:

```modula2
PROCEDURE Rect  (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rect;

PROCEDURE Range (loc, len: CARDINAL): ObjC.NSRange;
VAR r: ObjC.NSRange;
BEGIN r.location := loc; r.length := len; RETURN r END Range;

view := [[Cls("NSView") alloc] initWithFrame: Rect(0.0, 0.0, 100.0, 200.0)];
[store replaceCharactersInRange: Range(loc, len) withString: ns];
```

Larger structs are handled too: a struct too big for the four-register HFA rule —
a 48-byte transform of six doubles, say — comes back via the AAPCS
*indirect-result* path (`x8`) rather than in registers, so such a send works
without a bus error.

## Passing Obj-C blocks

Cocoa APIs that take a block (comparators, `…UsingBlock:` enumerators, timer
handlers) accept an M2 procedure wrapped by `ObjC.MakeBlock`:

```modula2
PROCEDURE Cmp (blk, a, b: ObjC.Id): INTEGER;   (* block ABI: 1st param IS the block *)
BEGIN ... END Cmp;

sorted := [arr sortedArrayUsingComparator: ObjC.MakeBlock(CAST(ADDRESS, Cmp))];
```

The procedure uses the **block invoke ABI**: its first parameter is the block
itself (usually ignored), then the real arguments. The block is a capture-free
global that lives for the program's lifetime. See
[Classes as Cocoa classes](classes.md#delegates-data-sources-and-blocks) for
using blocks as event/timer callbacks.

## The low-level `Send*` idiom

Before the bracket syntax there was — and still is — a direct idiom: cast
`ObjC.MsgSendPtr()` to a procedure type matching the call's ABI and call it.

```modula2
(* send0, app: ObjC.Send0, ObjC.Id — Send0 is a one-call typedef for this ABI *)
send0 := CAST(ObjC.Send0, ObjC.MsgSendPtr());
app   := send0(Cls("NSApplication"), ObjC.Selector("sharedApplication"));
```

`ObjC.def` provides `Send0` (no args), `SendI`/`SendP`/`SendB`/`SendF`/`SendC`
(one `INTEGER`/`Id`/`BOOLEAN`/`REAL`/`CARDINAL`), `SendFrame`/`SendRect` (the
multi-`REAL` window/frame initializers), and `Send0I`/`SendPI` (`INTEGER`
returns). Each `CAST` picks the calling convention for that one call site. The
bracket form supersedes this for everyday code — `[Cls("NSApplication")
sharedApplication]` is the same call — but the typedefs remain useful when you
need a precise hand-built signature.
