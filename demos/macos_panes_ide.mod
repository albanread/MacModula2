MODULE macos_panes_ide;
(* The MacM2 pane IDE — the macOS counterpart of the Windows FastPanes/PaneShell
   IDE: a project sidebar and a tabbed editor over an output pane, in draggable
   NSSplitViews. The controller is an ordinary Modula-2 class that IS an NSObject;
   its Build&Run method is the toolbar button's AppKit action (no trampoline),
   and clicking a file in the sidebar opens it in an editor tab.

     +-----------+------------------------------------+
     | PROJECT   |  file1  file2  (tabs)              |
     |  a.mod    |------------------------------------|
     |  b.mod    |  …editor (NSTextView)…             |
     |  …        |====================================|
     |           |  …build output…        [Build&Run] |
     +-----------+------------------------------------+
*)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Assign, Append, Equal;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT Proc;

CONST MaxFiles = 64;

TYPE
  SendB2 = PROCEDURE (ObjC.Id, ObjC.SEL, BOOLEAN): ObjC.Id;
  SendFI = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, INTEGER): ObjC.Id;

VAR
  win, content, outerSplit, innerSplit, sidebar, tabs, output, status, toolbar: Cocoa.Object;
  gDir: ARRAY [0..1023] OF CHAR;
  gFiles: ARRAY [0..MaxFiles-1] OF ARRAY [0..255] OF CHAR;
  gEditors: ARRAY [0..63] OF Cocoa.Object;
  gPaths: ARRAY [0..63] OF ARRAY [0..1023] OF CHAR;
  gCount, gTabCount, i, limit: INTEGER;
  s0: ObjC.Send0; sp: ObjC.SendP; sf: ObjC.SendFrame; sb: SendB2; sfi: SendFI;
  ig: ObjC.Id; ig2: INTEGER;
  ctrl: ObjC.Id;

PROCEDURE sendIInt (o: ObjC.Id; s: ObjC.SEL; n: INTEGER): ObjC.Id;
VAR f: ObjC.SendI;
BEGIN f := CAST(ObjC.SendI, ObjC.MsgSendPtr()); RETURN f(o, s, n) END sendIInt;

(* ---- a raw NSView, for split panes / containers ---- *)
PROCEDURE MakeView (x, y, w, h: REAL): Cocoa.Object;
VAR v: ObjC.Id;
BEGIN
  v := s0(ObjC.GetClass("NSView"), ObjC.Selector("alloc"));
  v := sf(v, ObjC.Selector("initWithFrame:"), x, y, w, h);
  RETURN CAST(Cocoa.Object, v)
END MakeView;

(* ---- an NSSplitView; sideBySide=TRUE -> vertical divider (left|right) ---- *)
PROCEDURE MakeSplit (x, y, w, h: REAL; sideBySide: BOOLEAN): Cocoa.Object;
VAR v: ObjC.Id;
BEGIN
  v := s0(ObjC.GetClass("NSSplitView"), ObjC.Selector("alloc"));
  v := sf(v, ObjC.Selector("initWithFrame:"), x, y, w, h);
  ig := sb(v, ObjC.Selector("setVertical:"), sideBySide);
  ig := sendIInt(v, ObjC.Selector("setDividerStyle:"), 2);  (* thin *)
  RETURN CAST(Cocoa.Object, v)
END MakeSplit;

PROCEDURE SetDivider (split: Cocoa.Object; index: INTEGER; pos: REAL);
BEGIN ig := sfi(CAST(ObjC.Id, split), ObjC.Selector("setPosition:ofDividerAtIndex:"), pos, index) END SetDivider;

(* ---- open the project file at `index` in a new editor tab ---- *)
PROCEDURE OpenDoc (index: INTEGER);
VAR full, text: ARRAY [0..16383] OF CHAR; ed, it: Cocoa.Object; n: INTEGER;
BEGIN
  IF (index < 0) OR (index >= gCount) THEN RETURN END;
  Assign(gDir, full); Append("/", full); Append(gFiles[index], full);
  n := Proc.ReadFile(full, text);
  IF n < 0 THEN RETURN END;
  ed := Cocoa.MakeEditor(0.0, 0.0, 700.0, 400.0);
  Cocoa.SetEditorText(ed, text);
  Cocoa.HighlightEditor(ed);
  it := Cocoa.AddTab(tabs, gFiles[index], ed);
  IF gTabCount <= 63 THEN
    gEditors[gTabCount] := ed;
    Assign(full, gPaths[gTabCount]);
    INC(gTabCount)
  END
END OpenDoc;

(* ---- the IDE controller: a real NSObject; BuildRun is its AppKit action ---- *)
CLASS IDE;
  <* cocoa "NSObject" *>
  PROCEDURE BuildRun (sender: ObjC.Id);          (* selector "buildRun:" *)
  VAR sel: INTEGER; src, out: ARRAY [0..16383] OF CHAR; rc, ix: INTEGER;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN Cocoa.SetText(status, "Open a file, then Build & Run."); RETURN END;
    Cocoa.SetText(status, "Building…");
    Cocoa.EditorText(gEditors[sel], src);
    ix := Proc.WriteFile("/tmp/panes_ide_buffer.mod", src);
    rc := Proc.RunCapture(
            "./target/debug/newm2-driver run --library library /tmp/panes_ide_buffer.mod 2>&1", out);
    Cocoa.SetEditorText(output, out);
    IF rc = 0 THEN Cocoa.SetText(status, "Build & run succeeded (exit 0).")
    ELSE Cocoa.SetText(status, "Build/run reported errors.") END
  END BuildRun;
END IDE;

VAR ide: IDE; n2: INTEGER; fileBtn, runBtn: Cocoa.Object;
BEGIN
  s0  := CAST(ObjC.Send0,     ObjC.MsgSendPtr());
  sp  := CAST(ObjC.SendP,     ObjC.MsgSendPtr());
  sf  := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());
  sb  := CAST(SendB2,         ObjC.MsgSendPtr());
  sfi := CAST(SendFI,         ObjC.MsgSendPtr());

  Assign("library/pimmod", gDir);

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(1100.0, 720.0, "MacM2 IDE — panes");
  content := Cocoa.ContentView(win);

  (* outer split: sidebar | right; inner split: editor tabs / (output + toolbar) *)
  outerSplit := MakeSplit(0.0, 0.0, 1100.0, 720.0, TRUE);
  ig := sendIInt(CAST(ObjC.Id, outerSplit), ObjC.Selector("setAutoresizingMask:"), 18); (* width|height sizable *)
  Cocoa.AddSubview(content, outerSplit);

  sidebar := MakeView(0.0, 0.0, 220.0, 720.0);
  innerSplit := MakeSplit(0.0, 0.0, 860.0, 720.0, FALSE);
  Cocoa.AddSubview(outerSplit, sidebar);
  Cocoa.AddSubview(outerSplit, innerSplit);

  tabs := Cocoa.MakeTabView(0.0, 0.0, 860.0, 470.0);
  output := Cocoa.MakeEditor(0.0, 0.0, 860.0, 230.0);
  Cocoa.SetEditorText(output, "(build output appears here)");
  Cocoa.AddSubview(innerSplit, tabs);
  Cocoa.AddSubview(innerSplit, output);

  (* the controller *)
  NEW(ide);
  ctrl := CAST(ObjC.Id, ide);

  (* sidebar: one button per project file (clicking opens it in a tab) *)
  Cocoa.SetListAction(OpenDoc);
  gCount := Proc.ListDir(gDir);
  limit := gCount; IF limit > MaxFiles - 1 THEN limit := MaxFiles - 1 END;
  FOR i := 0 TO limit - 1 DO
    n2 := Proc.DirEntry(i, gFiles[i]);
    fileBtn := Cocoa.MakeFileButton(8.0, FLOAT(684 - i*28), 200.0, 25.0, gFiles[i], i);
    Cocoa.AddSubview(sidebar, fileBtn)
  END;

  (* status + Build & Run button, wired to the M2 controller's method *)
  status := Cocoa.MakeLabel(228.0, 690.0, 560.0, 22.0, "Ready.");
  Cocoa.AddSubview(content, status);
  runBtn := CAST(Cocoa.Object, s0(s0(ObjC.GetClass("NSButton"), ObjC.Selector("alloc")), ObjC.Selector("init")));
  ig := sf(CAST(ObjC.Id, runBtn), ObjC.Selector("setFrame:"), 968.0, 686.0, 124.0, 30.0);
  ig := sp(CAST(ObjC.Id, runBtn), ObjC.Selector("setTitle:"), ObjC.NSString("Build & Run"));
  ig := sp(CAST(ObjC.Id, runBtn), ObjC.Selector("setTarget:"), ctrl);
  ig := sp(CAST(ObjC.Id, runBtn), ObjC.Selector("setAction:"), ObjC.Selector("buildRun:"));
  Cocoa.AddSubview(content, runBtn);

  (* open a couple of files to start *)
  IF gCount > 0 THEN OpenDoc(0) END;
  IF gCount > 4 THEN OpenDoc(4) END;

  SetDivider(outerSplit, 0, 210.0);
  SetDivider(innerSplit, 0, 470.0);

  Cocoa.ShowWindow(win);
  Cocoa.RunApp;
  WriteString("MacM2 pane IDE closed."); WriteLn
END macos_panes_ide.
