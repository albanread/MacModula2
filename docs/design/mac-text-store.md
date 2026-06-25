# MacM2 IDE — an efficient text store for NSTextView (rope-backed)

## The problem

Today the editor is a plain `NSTextView`; its buffer is Cocoa's
`NSTextStorage` (an `NSMutableAttributedString`). That forces three O(n)
whole-buffer operations:

1. **Load / save** — `setString:` / `string` copy the entire document.
2. **Highlight** — `HighlightEditor` re-colours the *whole* document on every
   change.
3. **No M2 source of truth** — the text lives in Cocoa, so M2 can't edit it
   incrementally and the Windows and Mac editors share no buffer model.

## The idea: make `NSTextStorage` an M2 class backed by `TextRope`

`NSTextStorage` is an *abstract* class with exactly four primitive methods you
override; everything else (the whole `NSMutableAttributedString` API the layout
system uses) is built on top of them. So we subclass it — as an ordinary
Modula-2 `CLASS` on the Cocoa model — and back it with the existing
`TextRope` (balanced rope, O(log n) edits, already UTF-16/wide-CHAR).

```
   NSTextView  ──uses──▶  NSLayoutManager ──reads──▶  RopeStore : NSTextStorage
   (view / input)          (lazy, viewport)            ├─ chars:  TextRope  (M2)
                                                        └─ attrs:  run list  (M2)
                                          string ──▶  RopeString : NSString  (M2)
```

Two M2 classes, both `<* cocoa ... *>`:

### `RopeStore` — `<* cocoa "NSTextStorage" *>`
Holds `doc: TextRope.Rope` and an attribute run list. Overrides the four
primitives (NSRange is two `NSUInteger`s → passes as two `INTEGER`s; the ABI is
clean — unlike the 32-bit `NSLayoutPriority` float that crashed the split work):

| Obj-C primitive | selector | M2 method → rope op |
|---|---|---|
| `-(NSString*)string` | `string` | return the `RopeString` view (O(1)) |
| `-replaceCharactersInRange:withString:` | … | `DeleteRange` + `Insert` (O(log n)) then `edited:range:changeInLength:` |
| `-(NSDictionary*)attributesAtIndex:effectiveRange:` | … | look up the colour run covering the index |
| `-setAttributes:range:` | … | split/merge runs |

### `RopeString` — `<* cocoa "NSString" *>`
The two NSString primitives + the bulk accessor the layout manager actually
uses, forwarded straight to the rope:

| primitive | rope op |
|---|---|
| `-(NSUInteger)length` | `TextRope.Length` |
| `-(unichar)characterAtIndex:` | `TextRope.CharAt` (O(log n)) |
| `-getCharacters:range:` | `TextRope.Sub` (bulk copy, O(n+log n)) |

`NSLayoutManager` lays out **lazily / by viewport** (TextKit 1 with
`allowsNonContiguousLayout`, TextKit 2 by design), so it only ever calls
`getCharacters:` for the visible window → O(visible·log n), not O(document).

## Attributes & incremental highlighting

The attribute store is an M2 **run list** — `ARRAY OF { len, kind }` covering the
document, `kind` ∈ {default, keyword, comment, string, number, …}. On an edit we
re-lex only the **affected line range** (the existing NewM2 lexer over the rope's
`Sub` of those lines), patch the runs there, and emit `edited:…:` for that range
only. `attributesAtIndex:effectiveRange:` walks the run list (binary search) and
hands back the colour for the run + the run's extent as `effectiveRange` so the
layout manager batches. **No whole-document re-colour, ever.**

## Wiring into the editor

`MakeEditor` builds the TextKit stack by hand instead of a bare `NSTextView`:

```
store     := RopeStore.New(initialText)         (* M2 object that IS an NSTextStorage *)
layout    := [NSLayoutManager new]; [layout setAllowsNonContiguousLayout: YES]
[store addLayoutManager: layout]
container := [[NSTextContainer alloc] initWithSize: huge]
[layout addTextContainer: container]
tv        := [[NSTextView alloc] initWithFrame: f textContainer: container]
```

Then `SetEditorText` → one `replaceCharactersInRange:` over the whole range
(unavoidable on load, but *one* op); `EditorText`/Build/save read the rope
directly via `TextRope.ToString`/`Sub` with **no NSString round-trip**; typing
flows view → `replaceCharactersInRange:` → rope, so the **rope is the source of
truth** and the same buffer model can back the Windows editor.

## Wins

- Edits **O(log n)**; highlight **O(edited range)**; load **one** op; save reads
  the rope directly — the three O(n)-per-keystroke/Build costs are gone.
- Large files: only the viewport is laid out and only touched ranges re-lex.
- One M2 buffer model shared by Windows + Mac ("M2 above, Cocoa below").

## Staging (each independently shippable)

1. **`RopeStore` forwarding to an internal `NSMutableAttributedString`** — proves
   an M2 class can *be* an `NSTextStorage` that `NSTextView` drives, and moves
   highlighting into `processEditing` (incremental) — biggest practical win,
   lowest risk. No `RopeString` yet.
2. **Swap the character backing to `TextRope` + `RopeString`** — true O(log n)
   edits and large-file scaling; Build/save read the rope directly.
3. **Make the rope the cross-platform source of truth** — share the buffer model
   with the Windows editor; load/save as rope, not strings.
