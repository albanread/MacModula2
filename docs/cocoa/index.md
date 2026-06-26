# MacM2 and Cocoa

MacM2 is the macOS (Apple-silicon, `arm64-apple-darwin`) port of the NewM2
Modula-2 compiler. Modula-2 programs for macOS and for Windows share only the
**base ISO Modula-2 layer**; above that line each platform has its own native
extension. On macOS that extension is **Cocoa** — AppKit, Foundation, Core
Graphics — reached directly through the Objective-C runtime.

This is not an FFI bolted onto the side. The macOS backend teaches the language
itself to speak Objective-C:

- **Every Modula-2 `CLASS` *is* an Objective-C class — there is no other kind.**
  Every class you declare is registered with the Obj-C runtime
  (`objc_allocateClassPair`); its fields are real ivars, its methods are real
  Obj-C methods, and `NEW`/`DISPOSE` are `alloc`/`init` and `release`. A bare
  class is rooted at `NSObject`; `INHERIT NSView` (or the `<* cocoa "NSView" *>`
  pragma) picks a different superclass, so AppKit calls straight into your
  `DrawRect`.
- **Objective-C's `[ receiver message ]` syntax is now part of the language.**
  The bracket message send is a real syntactic extension borrowed from
  Objective-C — `[receiver selector: arg …]`, lowered to `objc_msgSend`, with
  return types inferred from a 5,500-plus-selector database so `[arr count]` is a
  `CARDINAL` and `[view frame]` is an `NSRect`, no casts.
- **The whole of Cocoa is reachable.** A bound, typed surface covers the common
  classes; anything else is one `objc_getClass`/`Selector` away, and an unbound
  selector still dispatches correctly (it just defaults to an `id` result).

The result is "Cocoa all the way down, Modula-2 all the way up": the
[`projects/macide/`](../../projects/macide/) IDE — a multi-pane, syntax-
highlighting, Cocoa editor — is written entirely in this dialect.

## A complete program

```modula2
MODULE hello;
IMPORT ObjC, Cocoa;

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

VAR win, content, label: Cocoa.Object;
BEGIN
  Cocoa.InitApp;
  win     := Cocoa.MakeWindow(420.0, 160.0, "Hello from Modula-2");
  content := Cocoa.ContentView(win);
  label   := Cocoa.MakeLabel(20.0, 70.0, 380.0, 24.0, "native Cocoa, native M2");
  Cocoa.AddSubview(content, label);
  [CAST(ObjC.Id, win) makeKeyAndOrderFront: NIL];   (* a raw message send *)
  Cocoa.RunApp                                        (* run until quit *)
END hello.
```

Build and run it on macOS:

```
./target/debug/newm2-driver run   --library library hello.mod   # JIT
./target/debug/newm2-driver build --library library hello.mod   # -> Mach-O
```

## The guide

1. [**Message sends**](message-send.md) — the `[recv sel: args]` bridge: the
   `ObjC` helpers, the selector database and typed returns, the geometry value
   types, Obj-C blocks, and the low-level `Send*` idiom.
2. [**Classes as Cocoa classes**](classes.md) — declaring a `CLASS` that the
   Obj-C runtime sees; the `<* cocoa "…" *>` and `<* selector "…" *>` pragmas;
   `INHERIT`, `OVERRIDE`, `NEW`/`DISPOSE`, `SELF`; and installing delegates /
   data sources / blocks.
3. [**The bound library**](library-and-bindings.md#the-bound-library) — the
   `Cocoa` ergonomic layer, the `ObjC` primitives, the generated `CocoaNS`
   class bindings, `NSString`, attributed strings, file dialogs, and the run
   loop.
4. [**Reaching any Cocoa API**](library-and-bindings.md#reaching-any-cocoa-api)
   — the `cocoa-selectors.json` database, the `newm2-cocoa-gen` generator, and
   how to call something that is not bound yet.

> Framing note: nothing here is portable to the Windows build, and that is by
> design. The shared contract between the two ports is ISO Modula-2; the GUI /
> OS surface is deliberately platform-native.
