MODULE macos_panes_ide;
(* The MacM2 IDE — a working multi-pane editor/build tool, the macOS counterpart
   of the Windows FastPanes/PaneShell IDE, built on the native M2-object-on-Cocoa
   model.  Layout (draggable NSSplitViews):

     [ Open ] [ Save ] [ Build & Run ]   status……………………………………
     +-----------+------------------------------------------------+
     | PROJECT   |  a.mod   b.mod   (tabs)                         |
     |  a.mod    |------------------------------------------------|
     |  b.mod    |  …syntax-highlighted editor (NSTextView)…      |
     |  …        |================================================|
     |           |  …compiler output; error lines marked above…  |
     +-----------+------------------------------------------------+

   The controller is an ordinary Modula-2 class that IS an NSObject; its Open /
   Save / BuildRun methods are the toolbar buttons' AppKit actions (no
   trampoline).  Open picks a project folder; clicking a file opens it in a tab;
   Save writes the active tab back; Build & Run saves it, runs the compiler,
   streams the output, and marks any error lines red in the editor. *)
FROM SYSTEM IMPORT CAST;
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Assign, Append;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT Proc;

CONST MaxFiles = 128;

TYPE SendB2 = PROCEDURE (ObjC.Id, ObjC.SEL, BOOLEAN): ObjC.Id;
     SendFI = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, INTEGER): ObjC.Id;

VAR
  win, content, outerSplit, innerSplit, sidebar, tabs, output, status: Cocoa.Object;
  gDir: ARRAY [0..1023] OF CHAR;
  gFiles: ARRAY [0..MaxFiles-1] OF ARRAY [0..255] OF CHAR;
  gBtns: ARRAY [0..MaxFiles-1] OF Cocoa.Object;
  gEditors: ARRAY [0..63] OF Cocoa.Object;
  gPaths: ARRAY [0..63] OF ARRAY [0..1023] OF CHAR;
  gCount, gBtnCount, gTabCount: INTEGER;
  s0: ObjC.Send0; sp: ObjC.SendP; sf: ObjC.SendFrame; sb: SendB2; sfi: SendFI;
  ig: ObjC.Id;
  ctrl: ObjC.Id;

PROCEDURE sendIInt (o: ObjC.Id; s: ObjC.SEL; n: INTEGER): ObjC.Id;
VAR f: ObjC.SendI;
BEGIN f := CAST(ObjC.SendI, ObjC.MsgSendPtr()); RETURN f(o, s, n) END sendIInt;

PROCEDURE MakeView (x, y, w, h: REAL): Cocoa.Object;
VAR v: ObjC.Id;
BEGIN
  v := s0(ObjC.GetClass("NSView"), ObjC.Selector("alloc"));
  RETURN CAST(Cocoa.Object, sf(v, ObjC.Selector("initWithFrame:"), x, y, w, h))
END MakeView;

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

(* a toolbar button wired straight to a controller method (selector). *)
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

(* (re)populate the project sidebar from gDir. *)
PROCEDURE RebuildSidebar;
VAR i, limit, n: INTEGER;
BEGIN
  FOR i := 0 TO gBtnCount - 1 DO Cocoa.RemoveView(gBtns[i]) END;
  gBtnCount := 0;
  gCount := Proc.ListDir(gDir);
  IF gCount < 0 THEN gCount := 0 END;
  limit := gCount; IF limit > MaxFiles - 1 THEN limit := MaxFiles - 1 END;
  FOR i := 0 TO limit - 1 DO
    n := Proc.DirEntry(i, gFiles[i]);
    gBtns[i] := Cocoa.MakeFileButton(8.0, FLOAT(580 - i*28), 200.0, 25.0, gFiles[i], i);
    Cocoa.AddSubview(sidebar, gBtns[i])
  END;
  gBtnCount := limit;
  Cocoa.SetText(status, gDir)
END RebuildSidebar;

(* open the project file at `index` in a new editor tab (the sidebar action). *)
PROCEDURE OpenDoc (index: INTEGER);
VAR full, text: ARRAY [0..32767] OF CHAR; ed, it: Cocoa.Object; n: INTEGER;
BEGIN
  IF (index < 0) OR (index >= gCount) THEN RETURN END;
  Assign(gDir, full); Append("/", full); Append(gFiles[index], full);
  IF Proc.IsDir(full) THEN Assign(full, gDir); RebuildSidebar; RETURN END;
  n := Proc.ReadFile(full, text);
  IF n < 0 THEN RETURN END;
  ed := Cocoa.MakeEditor(0.0, 0.0, 760.0, 420.0);
  Cocoa.SetEditorText(ed, text);
  Cocoa.HighlightEditor(ed);
  it := Cocoa.AddTab(tabs, gFiles[index], ed);
  IF gTabCount <= 63 THEN
    gEditors[gTabCount] := ed; Assign(full, gPaths[gTabCount]); INC(gTabCount)
  END
END OpenDoc;

(* ---- the IDE controller: a real NSObject; its methods are the AppKit actions ---- *)
CLASS IDE;
  <* cocoa "NSObject" *>
  PROCEDURE OnOpen (sender: ObjC.Id);            (* "onOpen:" — choose a project folder *)
  VAR path: ARRAY [0..1023] OF CHAR;
  BEGIN
    IF Cocoa.OpenFolder(path) THEN Assign(path, gDir); RebuildSidebar END
  END OnOpen;
  PROCEDURE OnSave (sender: ObjC.Id);            (* "onSave:" — write the active tab to disk *)
  VAR sel, ix: INTEGER; src: ARRAY [0..32767] OF CHAR;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN RETURN END;
    Cocoa.EditorText(gEditors[sel], src);
    ix := Proc.WriteFile(gPaths[sel], src);
    IF ix = 0 THEN Cocoa.SetText(status, "Saved.") ELSE Cocoa.SetText(status, "Save failed.") END
  END OnSave;
  PROCEDURE OnBuildRun (sender: ObjC.Id);        (* "onBuildRun:" — save, compile, show output, mark errors *)
  VAR sel, ix, rc, marked: INTEGER; src, out: ARRAY [0..32767] OF CHAR; cmd: ARRAY [0..2047] OF CHAR;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN Cocoa.SetText(status, "Open a file first."); RETURN END;
    Cocoa.SetText(status, "Building…");
    Cocoa.EditorText(gEditors[sel], src);
    ix := Proc.WriteFile(gPaths[sel], src);          (* save before building *)
    Assign("./target/debug/newm2-driver run --library library ", cmd);
    Append(gPaths[sel], cmd); Append(" 2>&1", cmd);
    rc := Proc.RunCapture(cmd, out);
    Cocoa.SetEditorText(output, out);
    marked := Cocoa.MarkErrors(gEditors[sel], out);  (* red-mark error lines in the editor *)
    IF rc = 0 THEN Cocoa.SetText(status, "Build & run succeeded (exit 0).")
    ELSE Cocoa.SetText(status, "Build/run reported errors.") END
  END OnBuildRun;
END IDE;

VAR ide: IDE;
BEGIN
  s0  := CAST(ObjC.Send0,     ObjC.MsgSendPtr());
  sp  := CAST(ObjC.SendP,     ObjC.MsgSendPtr());
  sf  := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());
  sb  := CAST(SendB2,         ObjC.MsgSendPtr());
  sfi := CAST(SendFI,         ObjC.MsgSendPtr());
  gBtnCount := 0; gTabCount := 0;
  Assign("library/pimmod", gDir);

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(1100.0, 640.0, "MacM2 IDE");
  content := Cocoa.ContentView(win);

  NEW(ide); ctrl := CAST(ObjC.Id, ide);

  (* toolbar *)
  Cocoa.AddSubview(content, CtrlButton(8.0, 604.0, 80.0, "Open", "onOpen:"));
  Cocoa.AddSubview(content, CtrlButton(92.0, 604.0, 80.0, "Save", "onSave:"));
  Cocoa.AddSubview(content, CtrlButton(176.0, 604.0, 120.0, "Build & Run", "onBuildRun:"));
  status := Cocoa.MakeLabel(308.0, 610.0, 784.0, 22.0, "Ready.");
  Cocoa.AddSubview(content, status);

  (* panes *)
  outerSplit := MakeSplit(0.0, 0.0, 1100.0, 596.0, TRUE);
  ig := sendIInt(CAST(ObjC.Id, outerSplit), ObjC.Selector("setAutoresizingMask:"), 18);
  Cocoa.AddSubview(content, outerSplit);
  sidebar := MakeView(0.0, 0.0, 220.0, 596.0);
  innerSplit := MakeSplit(0.0, 0.0, 860.0, 596.0, FALSE);
  Cocoa.AddSubview(outerSplit, sidebar);
  Cocoa.AddSubview(outerSplit, innerSplit);
  tabs := Cocoa.MakeTabView(0.0, 0.0, 860.0, 390.0);
  output := Cocoa.MakeEditor(0.0, 0.0, 860.0, 230.0);
  Cocoa.SetEditorText(output, "(build output appears here — Build & Run marks error lines red)");
  Cocoa.AddSubview(innerSplit, tabs);
  Cocoa.AddSubview(innerSplit, output);

  Cocoa.SetListAction(OpenDoc);
  RebuildSidebar;
  IF gCount > 0 THEN OpenDoc(0) END;

  SetDivider(outerSplit, 0, 210.0);
  SetDivider(innerSplit, 0, 390.0);
  Cocoa.SetText(status, "Ready — Open a folder, click a file, edit, Build & Run.");

  Cocoa.ShowWindow(win);
  Cocoa.RunApp;
  WriteString("MacM2 IDE closed."); WriteLn
END macos_panes_ide.
