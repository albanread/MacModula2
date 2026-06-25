MODULE macos_panes_ide;
(* The MacM2 IDE — a working multi-pane editor/build tool, the macOS counterpart
   of the Windows FastPanes/PaneShell IDE, on the native M2-object-on-Cocoa model.

     [ Open ] [ Save ] [ Build & Run ]   status……………………………………
     +-----------+------------------------------------------------+
     | PROJECT   |  a.mod   b.mod   (tabs)                         |
     |  a.mod  ↕ |------------------------------------------------|
     |  …        |  …syntax-highlighted editor (NSTextView)…      |
     +-----------|================================================|
     | LIBRARY ↕ |  …compiler output; error lines marked red…     |
     |  ASCII.def|                                                |
     +-----------+------------------------------------------------+

   The sidebar is a split: a scrollable PROJECT list over a scrollable LIBRARY
   list (each a flipped NSView document inside an NSScrollView). The controller
   and the flipped list views are ordinary Modula-2 classes that ARE Cocoa
   objects; the toolbar buttons' actions are the controller's methods. *)
FROM SYSTEM IMPORT CAST;
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Assign, Append;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT Proc;

CONST
  MaxFiles = 256;
  LibBase  = 1000;          (* sidebar tags >= LibBase address the library list *)
  RowH     = 27.0;

TYPE SendB2 = PROCEDURE (ObjC.Id, ObjC.SEL, BOOLEAN): ObjC.Id;
     SendFI = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, INTEGER): ObjC.Id;
     SendMI = PROCEDURE (ObjC.Id, ObjC.SEL, ObjC.Id, ObjC.SEL, ObjC.Id): ObjC.Id;

(* A flipped NSView: y=0 at the TOP, so a file list lays out top-down inside an
   NSScrollView. An ordinary M2 class overriding NSView's isFlipped. *)
CLASS FlippedDoc;
  <* cocoa "NSView" *>
  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;
END FlippedDoc;

VAR
  win, content, outerSplit, innerSplit, sidebar, tabs, output, status, helpPane: Cocoa.Object;
  projScroll, libScroll, projDoc, libDoc: Cocoa.Object;
  gHelpVisible: BOOLEAN;
  smi: SendMI;
  gHelpText: ARRAY [0..2047] OF CHAR;
  helpNL: ARRAY [0..1] OF CHAR;
  gProjDir, gLibDir: ARRAY [0..1023] OF CHAR;
  gProjFiles, gLibFiles: ARRAY [0..MaxFiles-1] OF ARRAY [0..255] OF CHAR;
  gProjBtns, gLibBtns: ARRAY [0..MaxFiles-1] OF Cocoa.Object;
  gProjCount, gLibCount, gProjBtnCount, gLibBtnCount: INTEGER;
  gEditors: ARRAY [0..63] OF Cocoa.Object;
  gPaths: ARRAY [0..63] OF ARRAY [0..1023] OF CHAR;
  gTabCount: INTEGER;
  s0: ObjC.Send0; sp: ObjC.SendP; sf: ObjC.SendFrame; sb: SendB2; sfi: SendFI;
  ig: ObjC.Id; ctrl: ObjC.Id;

PROCEDURE sendIInt (o: ObjC.Id; s: ObjC.SEL; n: INTEGER): ObjC.Id;
VAR f: ObjC.SendI;
BEGIN f := CAST(ObjC.SendI, ObjC.MsgSendPtr()); RETURN f(o, s, n) END sendIInt;

PROCEDURE SetFrameOf (v: Cocoa.Object; x, y, w, h: REAL);
BEGIN ig := sf(CAST(ObjC.Id, v), ObjC.Selector("setFrame:"), x, y, w, h) END SetFrameOf;

PROCEDURE MakeSplit (x, y, w, h: REAL; sideBySide: BOOLEAN): Cocoa.Object;
VAR v: ObjC.Id;
BEGIN
  v := s0(ObjC.GetClass("NSSplitView"), ObjC.Selector("alloc"));
  v := sf(v, ObjC.Selector("initWithFrame:"), x, y, w, h);
  ig := sb(v, ObjC.Selector("setVertical:"), sideBySide);
  ig := sendIInt(v, ObjC.Selector("setDividerStyle:"), 2);
  RETURN CAST(Cocoa.Object, v)
END MakeSplit;

PROCEDURE SetDivider (split: Cocoa.Object; index: INTEGER; pos: REAL);
BEGIN ig := sfi(CAST(ObjC.Id, split), ObjC.Selector("setPosition:ofDividerAtIndex:"), pos, index) END SetDivider;

(* an NSScrollView with a vertical scroller and a flipped document NSView. *)
PROCEDURE MakeScroll (x, y, w, h: REAL; VAR doc: Cocoa.Object): Cocoa.Object;
VAR sc: ObjC.Id; fd: FlippedDoc;
BEGIN
  sc := s0(ObjC.GetClass("NSScrollView"), ObjC.Selector("alloc"));
  sc := sf(sc, ObjC.Selector("initWithFrame:"), x, y, w, h);
  ig := sb(sc, ObjC.Selector("setHasVerticalScroller:"), TRUE);
  ig := sendIInt(sc, ObjC.Selector("setBorderType:"), 0);
  NEW(fd);
  doc := CAST(Cocoa.Object, fd);
  SetFrameOf(doc, 0.0, 0.0, w - 16.0, h);
  ig := sp(sc, ObjC.Selector("setDocumentView:"), CAST(ObjC.Id, doc));
  RETURN CAST(Cocoa.Object, sc)
END MakeScroll;

PROCEDURE CtrlButton (x, y, w: REAL; title, selector: ARRAY OF CHAR): Cocoa.Object;
VAR b: ObjC.Id;
BEGIN
  b := s0(s0(ObjC.GetClass("NSButton"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  ig := sf(b, ObjC.Selector("setFrame:"), x, y, w, 30.0);
  ig := sp(b, ObjC.Selector("setTitle:"), ObjC.NSString(title));
  ig := sp(b, ObjC.Selector("setTarget:"), ctrl);
  ig := sp(b, ObjC.Selector("setAction:"), ObjC.Selector(selector));
  RETURN CAST(Cocoa.Object, b)
END CtrlButton;

(* a top-level menu (its title shows in the menu bar); returns the submenu. *)
PROCEDURE AddMenu (bar: ObjC.Id; title: ARRAY OF CHAR): ObjC.Id;
VAR item, sub: ObjC.Id;
BEGIN
  item := s0(s0(ObjC.GetClass("NSMenuItem"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  sub := s0(ObjC.GetClass("NSMenu"), ObjC.Selector("alloc"));
  sub := sp(sub, ObjC.Selector("initWithTitle:"), ObjC.NSString(title));
  ig := sp(item, ObjC.Selector("setSubmenu:"), sub);
  ig := sp(bar, ObjC.Selector("addItem:"), item);
  RETURN sub
END AddMenu;

(* a menu item: action selector on `target`, key equivalent (with `modMask`). *)
PROCEDURE AddItem (menu, target: ObjC.Id; title, action, key: ARRAY OF CHAR; modMask: INTEGER);
VAR it: ObjC.Id;
BEGIN
  it := s0(ObjC.GetClass("NSMenuItem"), ObjC.Selector("alloc"));
  it := smi(it, ObjC.Selector("initWithTitle:action:keyEquivalent:"),
            ObjC.NSString(title), ObjC.Selector(action), ObjC.NSString(key));
  ig := sp(it, ObjC.Selector("setTarget:"), target);
  IF modMask # 0 THEN ig := sendIInt(it, ObjC.Selector("setKeyEquivalentModifierMask:"), modMask) END;
  ig := sp(menu, ObjC.Selector("addItem:"), it)
END AddItem;

PROCEDURE HL (s: ARRAY OF CHAR);   (* append a help line + newline *)
BEGIN Append(s, gHelpText); Append(helpNL, gHelpText) END HL;

(* populate one scrollable list (project or library) from its folder; buttons go
   top-down in the flipped document, whose height grows to scroll. *)
PROCEDURE RebuildList (isLib: BOOLEAN);
VAR i, count, limit, n: INTEGER; b: Cocoa.Object; docW, totalH: REAL;
BEGIN
  IF isLib THEN
    FOR i := 0 TO gLibBtnCount - 1 DO Cocoa.RemoveView(gLibBtns[i]) END;
    gLibBtnCount := 0; count := Proc.ListDir(gLibDir)
  ELSE
    FOR i := 0 TO gProjBtnCount - 1 DO Cocoa.RemoveView(gProjBtns[i]) END;
    gProjBtnCount := 0; count := Proc.ListDir(gProjDir)
  END;
  IF count < 0 THEN count := 0 END;
  limit := count; IF limit > MaxFiles - 1 THEN limit := MaxFiles - 1 END;
  docW := 200.0;
  FOR i := 0 TO limit - 1 DO
    IF isLib THEN n := Proc.DirEntry(i, gLibFiles[i]);
                  b := Cocoa.MakeFileButton(2.0, FLOAT(i) * RowH, docW, RowH - 2.0, gLibFiles[i], LibBase + i);
                  gLibBtns[i] := b; Cocoa.AddSubview(libDoc, b)
    ELSE          n := Proc.DirEntry(i, gProjFiles[i]);
                  b := Cocoa.MakeFileButton(2.0, FLOAT(i) * RowH, docW, RowH - 2.0, gProjFiles[i], i);
                  gProjBtns[i] := b; Cocoa.AddSubview(projDoc, b)
    END
  END;
  totalH := FLOAT(limit) * RowH + 4.0;
  IF isLib THEN gLibCount := count; gLibBtnCount := limit; SetFrameOf(libDoc, 0.0, 0.0, docW + 4.0, totalH)
  ELSE          gProjCount := count; gProjBtnCount := limit; SetFrameOf(projDoc, 0.0, 0.0, docW + 4.0, totalH);
                Cocoa.SetText(status, gProjDir) END
END RebuildList;

(* the sidebar click action: open file (or descend into folder). Tags >= LibBase
   are library entries; below are project entries. *)
PROCEDURE OpenDoc (tag: INTEGER);
VAR full, text: ARRAY [0..32767] OF CHAR; ed, it: Cocoa.Object; n, idx: INTEGER; isLib: BOOLEAN;
BEGIN
  isLib := tag >= LibBase;
  IF isLib THEN idx := tag - LibBase;
    IF (idx < 0) OR (idx >= gLibCount) THEN RETURN END;
    Assign(gLibDir, full); Append("/", full); Append(gLibFiles[idx], full)
  ELSE idx := tag;
    IF (idx < 0) OR (idx >= gProjCount) THEN RETURN END;
    Assign(gProjDir, full); Append("/", full); Append(gProjFiles[idx], full)
  END;
  IF Proc.IsDir(full) THEN
    IF isLib THEN Assign(full, gLibDir) ELSE Assign(full, gProjDir) END;
    RebuildList(isLib); RETURN
  END;
  n := Proc.ReadFile(full, text);
  IF n < 0 THEN RETURN END;
  ed := Cocoa.MakeEditor(0.0, 0.0, 760.0, 420.0);
  Cocoa.SetEditorText(ed, text);
  Cocoa.HighlightEditor(ed);
  it := Cocoa.AddTab(tabs, full, ed);
  IF gTabCount <= 63 THEN gEditors[gTabCount] := ed; Assign(full, gPaths[gTabCount]); INC(gTabCount) END
END OpenDoc;

(* The IDE controller — a real NSObject; its methods are the toolbar actions. *)
CLASS IDE;
  <* cocoa "NSObject" *>
  PROCEDURE OnOpen (sender: ObjC.Id);              (* "onOpen:" *)
  VAR path: ARRAY [0..1023] OF CHAR;
  BEGIN
    IF Cocoa.OpenFolder(path) THEN Assign(path, gProjDir); RebuildList(FALSE) END
  END OnOpen;
  PROCEDURE OnSave (sender: ObjC.Id);              (* "onSave:" *)
  VAR sel, ix: INTEGER; src: ARRAY [0..32767] OF CHAR;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN RETURN END;
    Cocoa.EditorText(gEditors[sel], src);
    ix := Proc.WriteFile(gPaths[sel], src);
    IF ix = 0 THEN Cocoa.SetText(status, "Saved.") ELSE Cocoa.SetText(status, "Save failed.") END
  END OnSave;
  PROCEDURE OnBuildRun (sender: ObjC.Id);          (* "onBuildRun:" *)
  VAR sel, ix, rc, marked: INTEGER; src, out: ARRAY [0..32767] OF CHAR; cmd: ARRAY [0..2047] OF CHAR;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN Cocoa.SetText(status, "Open a file first."); RETURN END;
    Cocoa.SetText(status, "Building…");
    Cocoa.EditorText(gEditors[sel], src);
    ix := Proc.WriteFile(gPaths[sel], src);
    Assign("./target/debug/newm2-driver run --library library ", cmd);
    Append(gPaths[sel], cmd); Append(" 2>&1", cmd);
    rc := Proc.RunCapture(cmd, out);
    Cocoa.SetEditorText(output, out);
    marked := Cocoa.MarkErrors(gEditors[sel], out);
    IF rc = 0 THEN Cocoa.SetText(status, "Build & run succeeded (exit 0).")
    ELSE Cocoa.SetText(status, "Build/run reported errors.") END
  END OnBuildRun;
  PROCEDURE OnHelp (sender: ObjC.Id);              (* "onHelp:" — F1 toggles the help pane *)
  BEGIN
    gHelpVisible := NOT gHelpVisible;
    ig := sb(CAST(ObjC.Id, helpPane), ObjC.Selector("setHidden:"), NOT gHelpVisible);
    IF gHelpVisible THEN Cocoa.SetText(status, "Help shown (F1 to hide).")
    ELSE Cocoa.SetText(status, "Help hidden (F1 to show).") END
  END OnHelp;
END IDE;

VAR ide: IDE; appObj, menuBar, mApp, mFile, mBuild, mHelp: ObjC.Id; f1key: ARRAY [0..2] OF CHAR;
BEGIN
  s0  := CAST(ObjC.Send0,     ObjC.MsgSendPtr());
  sp  := CAST(ObjC.SendP,     ObjC.MsgSendPtr());
  sf  := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());
  sb  := CAST(SendB2,         ObjC.MsgSendPtr());
  sfi := CAST(SendFI,         ObjC.MsgSendPtr());
  smi := CAST(SendMI,         ObjC.MsgSendPtr());
  gProjBtnCount := 0; gLibBtnCount := 0; gTabCount := 0;
  Assign("library/pimmod", gProjDir);
  Assign("library/pimdef", gLibDir);

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(1100.0, 640.0, "MacM2 IDE");
  content := Cocoa.ContentView(win);
  NEW(ide); ctrl := CAST(ObjC.Id, ide);

  Cocoa.AddSubview(content, CtrlButton(8.0,   604.0, 80.0,  "Open", "onOpen:"));
  Cocoa.AddSubview(content, CtrlButton(92.0,  604.0, 80.0,  "Save", "onSave:"));
  Cocoa.AddSubview(content, CtrlButton(176.0, 604.0, 120.0, "Build & Run", "onBuildRun:"));
  status := Cocoa.MakeLabel(308.0, 610.0, 784.0, 22.0, "Ready.");
  Cocoa.AddSubview(content, status);

  outerSplit := MakeSplit(0.0, 0.0, 1100.0, 596.0, TRUE);
  ig := sendIInt(CAST(ObjC.Id, outerSplit), ObjC.Selector("setAutoresizingMask:"), 18);
  Cocoa.AddSubview(content, outerSplit);

  (* the sidebar is itself a split: PROJECT list (top) over LIBRARY list (bottom) *)
  sidebar := MakeSplit(0.0, 0.0, 220.0, 596.0, FALSE);
  projScroll := MakeScroll(0.0, 0.0, 220.0, 360.0, projDoc);
  libScroll := MakeScroll(0.0, 0.0, 220.0, 230.0, libDoc);
  Cocoa.AddSubview(sidebar, projScroll);
  Cocoa.AddSubview(sidebar, libScroll);

  innerSplit := MakeSplit(0.0, 0.0, 860.0, 596.0, FALSE);
  Cocoa.AddSubview(outerSplit, sidebar);
  Cocoa.AddSubview(outerSplit, innerSplit);
  tabs := Cocoa.MakeTabView(0.0, 0.0, 860.0, 390.0);
  output := Cocoa.MakeEditor(0.0, 0.0, 860.0, 200.0);
  Cocoa.SetEditorText(output, "(build output appears here — Build & Run marks error lines red)");
  Cocoa.AddSubview(innerSplit, tabs);
  Cocoa.AddSubview(innerSplit, output);

  (* third pane: help (F1 toggles it) — collapsed initially *)
  helpPane := Cocoa.MakeEditor(0.0, 0.0, 320.0, 596.0);
  gHelpText[0] := CHR(0); helpNL[0] := CHR(10); helpNL[1] := CHR(0);
  HL("MacM2 IDE — Help   (F1 to hide)");
  HL("");
  HL("PROJECT (top-left): files in your project folder — click to open a tab.");
  HL("LIBRARY (bottom-left): the standard library .def modules — click to read.");
  HL("");
  HL("Menu / Toolbar:");
  HL("  Open  (Cmd-O)   choose a project folder");
  HL("  Save  (Cmd-S)   write the active tab to disk");
  HL("  Build & Run (Cmd-R)   compile + run the active tab; errors marked red");
  HL("  Help  (F1)   toggle this pane");
  HL("");
  HL("Modula-2 quick start:");
  HL("  MODULE Hello;");
  HL("  FROM STextIO IMPORT WriteString, WriteLn;");
  HL('  BEGIN WriteString("hi"); WriteLn END Hello.');
  HL("");
  HL("Drag the pane dividers to resize.  Cmd-Q quits.");
  Cocoa.SetEditorText(helpPane, gHelpText);
  (* a slide-in help panel overlaying the right of the editor area; F1 toggles. *)
  SetFrameOf(helpPane, 760.0, 0.0, 340.0, 596.0);
  Cocoa.AddSubview(content, helpPane);
  ig := sb(CAST(ObjC.Id, helpPane), ObjC.Selector("setHidden:"), TRUE);
  gHelpVisible := FALSE;

  (* a real menu bar (App / File / Build / Help), set before RunApp *)
  appObj := s0(ObjC.GetClass("NSApplication"), ObjC.Selector("sharedApplication"));
  menuBar := s0(s0(ObjC.GetClass("NSMenu"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  mApp := AddMenu(menuBar, "MacM2");
  AddItem(mApp, appObj, "Quit MacM2 IDE", "terminate:", "q", 0);
  mFile := AddMenu(menuBar, "File");
  AddItem(mFile, ctrl, "Open Folder…", "onOpen:", "o", 0);
  AddItem(mFile, ctrl, "Save", "onSave:", "s", 0);
  mBuild := AddMenu(menuBar, "Build");
  AddItem(mBuild, ctrl, "Build & Run", "onBuildRun:", "r", 0);
  mHelp := AddMenu(menuBar, "Help");
  f1key[0] := CHR(0F704H); f1key[1] := CHR(0);            (* NSF1FunctionKey *)
  AddItem(mHelp, ctrl, "Show / Hide Help", "onHelp:", f1key, 800000H);  (* function-key modifier *)
  ig := sp(appObj, ObjC.Selector("setMainMenu:"), menuBar);

  Cocoa.SetListAction(OpenDoc);
  RebuildList(FALSE);          (* project *)
  RebuildList(TRUE);           (* library *)
  IF gProjCount > 0 THEN OpenDoc(0) END;

  Cocoa.ShowWindow(win);                 (* show first so the splits have laid out *)
  SetDivider(outerSplit, 0, 210.0);
  SetDivider(innerSplit, 0, 390.0);
  SetDivider(sidebar, 0, 360.0);
  Cocoa.SetText(status, "Ready — PROJECT (top) and LIBRARY (bottom). F1 = help.");

  Cocoa.RunApp;
  WriteString("MacM2 IDE closed."); WriteLn
END macos_panes_ide.
