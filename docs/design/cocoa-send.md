# Design: Cocoa message-send ergonomics (extensions 1, 3, 4)

Feedback gathered from writing a complete native macOS app (the MacM2 IDE, the
rope-backed `NSTextStorage`, the audio players) in MacM2. Three groups of compiler
extensions would remove the bulk of the FFI ceremony. This documents the design;
implementation is staged so each stage builds + tests independently.

## Background — how sends work today

A Cocoa call from M2 is written as a hand-cast indirect call:

```modula2
TYPE SendRRet = PROCEDURE (ObjC.Id, ObjC.SEL): NSRangeR;
VAR  srr: SendRRet;
...
srr := CAST(SendRRet, ObjC.MsgSendPtr());
r   := srr(me, ObjC.Selector("selectedRange"));
```

The machinery underneath is already general:
- `ObjC.MsgSendPtr()` → `nm2_objc_msgsend_ptr` returns `&objc_msgSend`
  (`newm2-runtime/src/objc.rs:234`).
- An indirect call through a PROCEDURE-typed value lowers to `Inst::IndCall`
  (`newm2-ir/src/lower.rs` `eval_call`), and codegen builds the LLVM call from the
  procedure signature (`newm2-llvm/src/codegen.rs:394 indirect_fn_type`, `:1548`).
- **The struct ABI is handled by LLVM** from the function type — 16-byte records in
  x0/x1, ≥17-byte via sret/x8 — no hand-classification in NewM2.
- `obj.Method(args)` on a Cocoa-rooted M2 class already lowers to an `objc_msgSend`
  IndCall via `try_method_dispatch` (`lower.rs:5027`).

So the friction is purely *surface*: the programmer hand-declares the signature
(the `Send*` type) and hand-interns the selector, for every distinct shape. The
compiler has all the information to synthesize both.

---

## Extension 1 — message-send expression `[recv sel: args]`

### Syntax
A new primary expression, Obj-C keyword-message shaped:

```
ObjcSend  = "[" expr  ( ident                      // unary:  [obj string]
                      | ( ident ":" expr )+ )       // keyword:[obj setX: a y: b]
            "]" .
```

`[` is free as a *leading* token (it is only ever a postfix index today,
`parser.rs:2232`), so this is unambiguous: a `[` in `parse_factor` primary
position starts a send; a `[` after a designator stays array indexing.

Examples:
```modula2
ig  := [me setNeedsDisplay: TRUE];
r   := [me selectedRange];                                  (* NSRange in x0/x1 *)
[store replaceCharactersInRange: rng withString: s];        (* statement form *)
dur := [player duration];                                   (* REAL, via d0 *)
url := [Cls("NSURL") fileURLWithPath: path];
```

The selector is the concatenation of the keyword parts (`setX:y:`), or the bare
ident for a unary message. The receiver is any expression; a *class* receiver is
just an expression whose value is the class object (`ObjC.GetClass(...)`), so class
methods use the same form.

### Result type (and therefore ABI)
`objc_msgSend` must be called at the method's real return type to pick the ABI.
Resolution order:
1. If the selector is known in the **Cocoa selector database** (extension 3), use
   its declared return + argument types — full ABI, including struct returns and
   `REAL`/`BOOLEAN`/`CARDINAL` returns, for free.
2. Otherwise default the result to `ObjC.Id` (the common id/pointer case) and the
   args to their natural M2 types. A `<* sendret "REAL" *>`-style inline annotation
   (or a surrounding `CAST`) covers the rare untyped non-id return until the DB
   knows the selector.

This makes 1 fully usable on day one (default-id) and progressively better as 3
lands (typed/validated).

### AST / parser / sema / IR
- **AST** (`parser/src/ast.rs`): `Expr::ObjcSend { recv: Box<Expr>, selector: String,
  args: Vec<Expr>, span }`.
- **Parser** (`parser/src/parser.rs` `parse_factor`): on leading `LBracket`, parse
  receiver expr, then either one ident (unary) or `(ident ":" expr)+` (keyword),
  building `selector` and `args`; expect `RBracket`.
- **Sema** (`sema/src/analyze.rs`): type the receiver and args; compute the result
  type (DB or `ObjC.Id`); coerce each arg to the parameter type (or its natural
  type when untyped). Produce an `IrProcSig {params, ret}` for the call.
- **IR** (`ir/src/lower.rs`): mirror `try_method_dispatch` — evaluate the receiver,
  intern the selector (the existing `sel_registerName` path / `ObjC.Selector`),
  evaluate args, and emit `Inst::IndCall` through `objc_msgSend` with the synthesized
  signature. Codegen + LLVM already do the rest.

No codegen changes are required — this is the payoff of reusing `IndCall`.

---

## Extension 3 — selector/class database: validation + signatures

### Producer
`newm2-cocoa-gen` already reflects the live Obj-C runtime
(`class_copyMethodList`, `method_getName`, `method_getTypeEncoding`) but emits only
`.def` source. Add a second output: a machine-readable **selector database**
(JSON, alongside `CocoaNS.def`) of:

```
{ class: "NSTextView",
  selectors: [ { sel: "selectedRange", encoding: "{_NSRange=QQ}@:", ret: "NSRange",
                 args: [] }, ... ],
  super: "NSText" }
```

The type encoding is parsed (the generator already tokenizes encodings,
`cocoa-gen/src/main.rs:55`) into M2-level types: `@`→`ObjC.Id`, `:`→`ObjC.SEL`,
`Q/q`→`CARDINAL/INTEGER`, `d`→`REAL`, `B`→`BOOLEAN`, `{_NSRange=QQ}`→a known record,
`{CGRect=...}`→`NSRect`, `v`→void.

### Consumer
- **Loader/sema**: load the DB once (cached). Expose `lookup(selector) -> signature`
  and `class_exists(name)`, `class_responds(class, sel)`.
- **Signature inference** for extension 1 (above).
- **Validation pass**: `ObjC.Selector("…")` / `ObjC.GetClass("…")` *string-literal*
  arguments and every `[recv sel:]` selector are checked against the DB:
  - unknown class → error;
  - unknown selector (not found on any class) → warning (it may be private/dynamic);
  - known selector with arity mismatch on a `[…]` send → error.
  Catches `setSlectedRange:`-type typos at compile time. Non-literal selector
  strings are skipped (can't check).

Staging: 3a = generator emits the DB; 3b = sema loads it + infers send signatures;
3c = the validation diagnostics.

---

## Extension 4 — smaller frictions

### 4a. Postfix operators on call/cast results — `CAST(P, x)^.field`
Today selectors (`^`, `.f`, `[i]`) only attach to a *designator* (a NAME), so
`CAST(PFoo, x)^.field` fails in the **parser** (`Expr::Call` is not a designator,
`parser.rs:2129`). Fix: after `parse_factor` produces a primary (designator, call,
parenthesised expr, or the new send), run the existing `parse_designator_tail`
selector loop over *any* primary, wrapping it in a postfix node. This also lets
`[recv sel]^` and `f(x)^.g` work. Smallest, highest-frequency win; independent of 1/3.

### 4b. Optional bounds checking (debug)
`buf[le-1]` with `le=0` underflowed and read out of bounds *silently* (the LineSpan
bug). A `--bounds` (debug) mode that emits an index check before array access would
have turned it into an immediate, located trap. Opt-in, off in release.

### 4c. Oversized stack-frame diagnostic
A 256 KB `ARRAY OF CHAR` *local* (the original `InsertNewline`) is a footgun. A
warning when a single frame exceeds a threshold (e.g. 64 KB) would flag it.

### 4d. (later) Obj-C block literals
Passing `NIL` for completion handlers / `error:` works, but real callbacks
(`AVMIDIPlayer` completion, comparators, enumeration, animation completion) need an
M2-closure → Obj-C block bridge. Larger; design separately.

---

## Implementation order

1. **1** — the `[recv sel: args]` send expression, lowering to the existing
   `objc_msgSend` IndCall. ✅ done.
2. **3a** — cocoa-gen emits the selector DB. ✅ done
   (`library/macrtdef/cocoa-selectors.json`, 5554 selectors / 39 classes).
3. **3b** — sema loads the DB → typed send results (REAL/CARDINAL/… not just id).
   ✅ done.
4. **3c** — `--strict` unknown-selector validation (typo detection). ✅ done.
5. **4a** — postfix selectors on call/cast results (`CAST(P,x)^.field`). ✅ done
   (Expr::Postfix; IR attaches the pointee type via TypedPtr then reuses
   apply_selector; also covers `^`, `^[i]`).
6. **4b/4c** — bounds-check mode, big-frame warning. **4d** — blocks. pending.

### Follow-ups landed after the initial three
- **Struct returns** ✅ — the DB now names the geometry structs (kinds N/P/S/R), and
  a send returning one yields `ObjC.NSRange`/`NSPoint`/`NSSize`/`NSRect` (records in
  ObjC.def laid out to the C ABI). `[view frame]` → NSRect (4-double HFA in d0–d3),
  `[s rangeOfString:]` → NSRange (x0/x1). Verified.
- **Bare send statements** ✅ — `[player stop];` / `[arr addObject: x];` parse as a
  statement (Stmt::Call of an ObjcSend); sema + IR already handled it.
- **Real-code proof** ✅ — library/macrtmod/Sound.mod now drives AVMIDIPlayer/NSSound
  entirely via `[recv sel: args]`, no Send* casts.

### Notes from implementation
- **Arity validation is unnecessary**: a keyword selector's `:` count *always*
  equals the parsed argument count, so a send can't be built with the wrong arity.
  The useful check is *unknown-selector* (typo) detection — done, `--strict`-gated
  so the partial (39-class) DB doesn't add noise to normal builds.
- **Struct/void returns** (`{`, `v`) still fall back to `id`. Typed struct returns
  (NSRange/NSRect) need those record types resolvable in sema — a follow-up.
- The DB is loaded with **no JSON dependency** (hand-parsed fixed-shape lines) and
  **no sema-entry signature change** (found via the ObjC module's `def_path`).

Each stage is independently shippable; 1 was usable before 3 landed, and got
better-typed once it did.
