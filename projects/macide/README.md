# MacM2 IDE & Cocoa demos

The macOS side of NewM2 — kept here, out of the Windows `demos/` tree.

Everything in this folder is built on the **M2-object-on-Cocoa** model: a Modula-2
`CLASS` *is* a real Objective-C object, so the IDE's controller is an `NSObject`,
its list/document views are `NSView` subclasses, and the whole UI is just
messages to Cocoa (`library/macrtdef` + `library/macrtmod`: `Cocoa` / `ObjC` /
`Proc` / `CG`).

## The IDE

- **`macos_panes_ide.mod`** — the MacM2 IDE (the macOS counterpart of the Windows
  FastPanes/PaneShell IDE). Scrollable PROJECT/LIBRARY sidebar (draggable
  divider), closeable sliding tabs, syntax-highlighted editing with autosave
  (LIBRARY is read-only reference), Build & Run with red error marking +
  jump-to-error, autocomplete (⌘/), a live Obj-C class search, a real menu
  (File/Edit/Build/Help, ⌘O/⌘S/⌘R/⌘W/⌘Z/⌘F/⌘/), and an F1/Home help pane that
  splits off the right with its own divider. Resizes cleanly.

Build & run (from the repo root — the runtime library stays in `library/`):

```
./target/debug/newm2-driver run --library library projects/macide/macos_panes_ide.mod
```

## Supporting demos

Object model: `macos_class`, `macos_counter`, `macos_counter_obj`,
`macos_inherit`, `macos_inherited_calls`, `macos_subclass`, `macos_stateful_view`,
`macos_clickview`, `macos_cocoa_lib`.
UI / drawing: `macos_window`, `macos_window_label`, `macos_button`, `macos_bars`,
`macos_canvas`, `macos_draw`, `macos_editor`, `macos_open`, `macos_snapshot`.
Earlier IDE iterations: `macos_ide`, `macos_ide_m2`, `macos_ide_app`,
`macos_ide_class`, `macos_ide_error`, `macos_ide_project`, `macos_complete`,
`macos_project`.

Build any with `./target/debug/newm2-driver build --library library projects/macide/<name>.mod`.
GUI demos that call `Cocoa.RunApp` open a real window; snapshot demos render
offscreen via `ObjC.SnapshotView`.
