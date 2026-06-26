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
FROM Strings IMPORT Assign, Append, Equal;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT Proc;
IMPORT RopeEditor;

CONST
  MaxFiles = 256;
  LibBase  = 1000;          (* sidebar tags >= LibBase address the library list *)
  RowH     = 27.0;

TYPE SendB2 = PROCEDURE (ObjC.Id, ObjC.SEL, BOOLEAN): ObjC.Id;
     SendFI = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, INTEGER): ObjC.Id;
     SendMI = PROCEDURE (ObjC.Id, ObjC.SEL, ObjC.Id, ObjC.SEL, ObjC.Id): ObjC.Id;
     SendRetI = PROCEDURE (ObjC.Id, ObjC.SEL): INTEGER;
     Send2F = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, REAL): ObjC.Id;

(* A flipped NSView: y=0 at the TOP, so a file list lays out top-down inside an
   NSScrollView. An ordinary M2 class overriding NSView's isFlipped. *)
CLASS FlippedDoc;
  <* cocoa "NSView" *>
  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;
END FlippedDoc;

VAR
  win, content, outerSplit, rightStack, innerSplit, sidebar, tabs, output, status, editStat, helpPane, searchField: Cocoa.Object;
  projScroll, libScroll, projDoc, libDoc, editorArea, tabBar, tabDoc: Cocoa.Object;
  gTabNames: ARRAY [0..63] OF ARRAY [0..255] OF CHAR;
  gTabBtns, gTabCloseBtns: ARRAY [0..63] OF Cocoa.Object;
  gTabBarCount: INTEGER;
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
  gReadOnly: ARRAY [0..63] OF BOOLEAN;     (* TRUE for LIBRARY (reference) tabs *)
  gTabCount: INTEGER;
  s0: ObjC.Send0; sp: ObjC.SendP; sf: ObjC.SendFrame; sb: SendB2; sfi: SendFI; s2f: Send2F;
  ig: ObjC.Id; ctrl: ObjC.Id;

PROCEDURE sendIInt (o: ObjC.Id; s: ObjC.SEL; n: INTEGER): ObjC.Id;
VAR f: ObjC.SendI;
BEGIN f := CAST(ObjC.SendI, ObjC.MsgSendPtr()); RETURN f(o, s, n) END sendIInt;

PROCEDURE SetFrameOf (v: Cocoa.Object; x, y, w, h: REAL);
BEGIN ig := sf(CAST(ObjC.Id, v), ObjC.Selector("setFrame:"), x, y, w, h) END SetFrameOf;

PROCEDURE MakeView (x, y, w, h: REAL): Cocoa.Object;   (* a plain NSView container *)
VAR v: ObjC.Id;
BEGIN
  v := s0(ObjC.GetClass("NSView"), ObjC.Selector("alloc"));
  RETURN CAST(Cocoa.Object, sf(v, ObjC.Selector("initWithFrame:"), x, y, w, h))
END MakeView;

(* a horizontally-scrolling container (overlay scroller, so the tab bar slides
   when full without the scroller taking layout space); returns its document. *)
PROCEDURE MakeScrollH (x, y, w, h: REAL; VAR doc: Cocoa.Object): Cocoa.Object;
VAR sc: ObjC.Id;
BEGIN
  sc := s0(ObjC.GetClass("NSScrollView"), ObjC.Selector("alloc"));
  sc := sf(sc, ObjC.Selector("initWithFrame:"), x, y, w, h);
  ig := sb(sc, ObjC.Selector("setHasHorizontalScroller:"), FALSE);  (* no scroll bar — tabs still
                                       slide via trackpad and the auto-scroll-to-active *)
  ig := sendIInt(sc, ObjC.Selector("setBorderType:"), 0);
  doc := MakeView(0.0, 0.0, w, h);
  ig := sp(sc, ObjC.Selector("setDocumentView:"), CAST(ObjC.Id, doc));
  RETURN CAST(Cocoa.Object, sc)
END MakeScrollH;

PROCEDURE MakeSplit (x, y, w, h: REAL; sideBySide: BOOLEAN): Cocoa.Object;
VAR v: ObjC.Id;
BEGIN
  v := s0(ObjC.GetClass("NSSplitView"), ObjC.Selector("alloc"));
  v := sf(v, ObjC.Selector("initWithFrame:"), x, y, w, h);
  ig := sb(v, ObjC.Selector("setVertical:"), sideBySide);
  ig := sendIInt(v, ObjC.Selector("setDividerStyle:"), 1);   (* thick, draggable — every split matches *)
  RETURN CAST(Cocoa.Object, v)
END MakeSplit;

PROCEDURE SetDivider (split: Cocoa.Object; index: INTEGER; pos: REAL);
BEGIN ig := sfi(CAST(ObjC.Id, split), ObjC.Selector("setPosition:ofDividerAtIndex:"), pos, index) END SetDivider;

(* Show/hide the help pane. When hidden it is REMOVED from rightStack so the
   editor pane fills 100% (no leftover band); when shown it is re-added as the
   rightmost pane (its right edge = the window's right edge) with a draggable
   splitter. gHelpVisible tracks membership. *)
PROCEDURE HelpShow (visible: BOOLEAN);
BEGIN
  IF visible THEN
    IF NOT gHelpVisible THEN
      Cocoa.AddSubview(rightStack, helpPane);
      ig := s0(CAST(ObjC.Id, rightStack), ObjC.Selector("adjustSubviews"))   (* incorporate the new pane *)
    END;
    SetDivider(rightStack, 0, 560.0);
    gHelpVisible := TRUE
  ELSE
    IF gHelpVisible THEN
      Cocoa.RemoveView(helpPane);
      ig := s0(CAST(ObjC.Id, rightStack), ObjC.Selector("adjustSubviews"))
    END;
    gHelpVisible := FALSE
  END
END HelpShow;

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

PROCEDURE CtrlButton (x, y, w: REAL; title, selector: ARRAY OF CHAR; mask: INTEGER): Cocoa.Object;
VAR b: ObjC.Id;
BEGIN
  b := s0(s0(ObjC.GetClass("NSButton"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  ig := sf(b, ObjC.Selector("setFrame:"), x, y, w, 30.0);
  ig := sp(b, ObjC.Selector("setTitle:"), ObjC.NSString(title));
  ig := sp(b, ObjC.Selector("setTarget:"), ctrl);
  ig := sp(b, ObjC.Selector("setAction:"), ObjC.Selector(selector));
  ig := sendIInt(b, ObjC.Selector("setAutoresizingMask:"), mask);
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

(* [sender tag] — which tab a tab-bar button belongs to. *)
PROCEDURE TagOf (o: ObjC.Id): INTEGER;
VAR f: SendRetI;
BEGIN f := CAST(SendRetI, ObjC.MsgSendPtr()); RETURN f(o, ObjC.Selector("tag")) END TagOf;

(* a tab-bar button (filename or ✕): target = controller, carries its tab index. *)
PROCEDURE TagButton (x, w: REAL; title, action: ARRAY OF CHAR; tag: INTEGER): Cocoa.Object;
VAR b: ObjC.Id;
BEGIN
  b := s0(s0(ObjC.GetClass("NSButton"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  ig := sf(b, ObjC.Selector("setFrame:"), x, 2.0, w, 22.0);
  ig := sp(b, ObjC.Selector("setTitle:"), ObjC.NSString(title));
  ig := sp(b, ObjC.Selector("setTarget:"), ctrl);
  ig := sp(b, ObjC.Selector("setAction:"), ObjC.Selector(action));
  ig := sendIInt(b, ObjC.Selector("setTag:"), tag);
  ig := sendIInt(b, ObjC.Selector("setBezelStyle:"), 1);   (* rounded/flat tab look *)
  RETURN CAST(Cocoa.Object, b)
END TagButton;

(* (re)draw the custom tab bar from the open-tab arrays; ✕ on every tab. *)
PROCEDURE RebuildTabBar;
VAR i, active: INTEGER; nameB, closeB: Cocoa.Object; label: ARRAY [0..271] OF CHAR; x, totalW: REAL;
BEGIN
  FOR i := 0 TO gTabBarCount - 1 DO
    Cocoa.RemoveView(gTabBtns[i]); Cocoa.RemoveView(gTabCloseBtns[i])
  END;
  gTabBarCount := 0;
  active := Cocoa.SelectedTab(tabs);
  FOR i := 0 TO gTabCount - 1 DO
    x := FLOAT(i) * 150.0;
    Assign("", label);
    IF i = active THEN Append("▸ ", label) END;       (* mark the active tab *)
    Append(gTabNames[i], label);
    nameB  := TagButton(x + 2.0, 122.0, label, "onSelectTab:", i);
    closeB := TagButton(x + 126.0, 22.0, "✕", "onCloseTab:", i);
    Cocoa.AddSubview(tabDoc, nameB); Cocoa.AddSubview(tabDoc, closeB);
    gTabBtns[i] := nameB; gTabCloseBtns[i] := closeB
  END;
  gTabBarCount := gTabCount;
  (* grow the document to the total tab width so the bar slides when full *)
  totalW := FLOAT(gTabCount) * 150.0 + 4.0;
  IF totalW < 860.0 THEN totalW := 860.0 END;
  SetFrameOf(tabDoc, 0.0, 0.0, totalW, 26.0);
  (* slide so the active tab is in view *)
  IF active >= 0 THEN
    ig := s2f(CAST(ObjC.Id, tabDoc), ObjC.Selector("scrollPoint:"), FLOAT(active) * 150.0, 0.0)
  END
END RebuildTabBar;

(* close the tab at `idx`: remove its NSTabViewItem, shift bookkeeping, redraw. *)
PROCEDURE CloseTabAt (idx: INTEGER);
VAR i: INTEGER; item: ObjC.Id;
BEGIN
  IF (idx < 0) OR (idx >= gTabCount) THEN RETURN END;
  item := sendIInt(CAST(ObjC.Id, tabs), ObjC.Selector("tabViewItemAtIndex:"), idx);
  ig := sp(CAST(ObjC.Id, tabs), ObjC.Selector("removeTabViewItem:"), item);
  FOR i := idx TO gTabCount - 2 DO
    gEditors[i] := gEditors[i+1]; Assign(gPaths[i+1], gPaths[i]);
    Assign(gTabNames[i+1], gTabNames[i]); gReadOnly[i] := gReadOnly[i+1]
  END;
  DEC(gTabCount);
  RebuildTabBar;
  Cocoa.SetText(status, "Tab closed.")
END CloseTabAt;

(* show text in the right "Assist" pane (Help / Completions / Cocoa search). *)
PROCEDURE ShowAssist (title, body: ARRAY OF CHAR);
VAR t: ARRAY [0..32767] OF CHAR;
BEGIN
  Assign(title, t); Append(helpNL, t); Append(helpNL, t); Append(body, t);
  Cocoa.SetEditorText(helpPane, t);
  HelpShow(TRUE)
END ShowAssist;

(* the sidebar click action: open file (or descend into folder). Tags >= LibBase
   are library entries; below are project entries. *)
PROCEDURE CardStr (n: CARDINAL; VAR s: ARRAY OF CHAR);
VAR d: ARRAY [0..31] OF CHAR; i, j: CARDINAL;
BEGIN
  IF n = 0 THEN s[0] := '0'; s[1] := CHR(0); RETURN END;
  i := 0; WHILE n > 0 DO d[i] := CHR(ORD('0') + (n MOD 10)); n := n DIV 10; INC(i) END;
  j := 0; WHILE i > 0 DO DEC(i); s[j] := d[i]; INC(j) END; s[j] := CHR(0)
END CardStr;

(* refresh the right side of the status bar with the current tab's editor status:
   cursor line/column, plus a read-only / unsaved tag *)
PROCEDURE ShowTabStatus;
VAR sel, line, col: INTEGER; s, num: ARRAY [0..255] OF CHAR;
BEGIN
  sel := Cocoa.SelectedTab(tabs);
  IF sel < 0 THEN Cocoa.SetText(editStat, ""); RETURN END;
  Cocoa.EditorCursor(gEditors[sel], line, col);
  Assign("Ln ", s); CardStr(VAL(CARDINAL, line), num); Append(num, s);
  Append(", Col ", s); CardStr(VAL(CARDINAL, col), num); Append(num, s);
  IF gReadOnly[sel] THEN Append("   ·  read-only", s)
  ELSIF gPaths[sel][0] = CHR(0) THEN Append("   ·  unsaved", s) END;
  Cocoa.SetText(editStat, s)
END ShowTabStatus;

PROCEDURE Basename (path: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);   (* file part of a path *)
VAR i, j, start: CARDINAL;
BEGIN
  start := 0; i := 0;
  WHILE path[i] # CHR(0) DO IF path[i] = '/' THEN start := i+1 END; INC(i) END;
  j := 0; i := start;
  WHILE path[i] # CHR(0) DO name[j] := path[i]; INC(i); INC(j) END;
  name[j] := CHR(0)
END Basename;

PROCEDURE OpenDoc (tag: INTEGER);
VAR full, text: ARRAY [0..262143] OF CHAR; ed, it: Cocoa.Object; n, idx, i: INTEGER; isLib: BOOLEAN; tv: ObjC.Id;
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
  (* already open? switch to its tab instead of loading a second copy *)
  i := 0;
  WHILE i < gTabCount DO
    IF Equal(gPaths[i], full) THEN
      ig := sendIInt(CAST(ObjC.Id, tabs), ObjC.Selector("selectTabViewItemAtIndex:"), i);
      RebuildTabBar; Cocoa.SetText(status, "Already open — switched to its tab."); RETURN
    END;
    INC(i)
  END;
  n := Proc.ReadFile(full, text);
  IF n < 0 THEN RETURN END;
  ed := CAST(Cocoa.Object, RopeEditor.Make(0.0, 0.0, 760.0, 420.0));  (* rope-backed editor *)
  Cocoa.SetEditorText(ed, text);                 (* colours itself; no HighlightEditor needed *)
  tv := s0(CAST(ObjC.Id, ed), ObjC.Selector("documentView"));
  ig := sb(tv, ObjC.Selector("setAllowsUndo:"), TRUE);       (* ⌘Z / ⌘⇧Z *)
  ig := sb(tv, ObjC.Selector("setUsesFindBar:"), TRUE);      (* ⌘F find bar *)
  (* delegate set for both kinds: autosave on edit + cursor status on selection.
     LIBRARY files open read-only — the library is reference from this IDE. *)
  ig := sp(tv, ObjC.Selector("setDelegate:"), ctrl);
  IF isLib THEN
    ig := sb(tv, ObjC.Selector("setEditable:"), FALSE);
    Cocoa.SetText(status, "Opened (read-only reference).")
  END;
  it := Cocoa.AddTab(tabs, full, ed);
  IF gTabCount <= 63 THEN
    gEditors[gTabCount] := ed; Assign(full, gPaths[gTabCount]); gReadOnly[gTabCount] := isLib;
    IF isLib THEN Assign(gLibFiles[idx], gTabNames[gTabCount])
    ELSE Assign(gProjFiles[idx], gTabNames[gTabCount]) END;
    INC(gTabCount);
    RebuildTabBar; ShowTabStatus
  END
END OpenDoc;

(* The IDE controller — a real NSObject; its methods are the toolbar actions. *)
CLASS IDE;
  <* cocoa "NSObject" *>
  PROCEDURE OnOpen (sender: ObjC.Id);              (* "onOpen:" *)
  VAR path: ARRAY [0..1023] OF CHAR;
  BEGIN
    IF Cocoa.OpenFolder(path) THEN Assign(path, gProjDir); RebuildList(FALSE) END
  END OnOpen;
  PROCEDURE OnNew (sender: ObjC.Id);               (* "onNew:" — a fresh, untitled, editable tab *)
  VAR ed, it: Cocoa.Object; tv: ObjC.Id;
  BEGIN
    IF gTabCount > 63 THEN Cocoa.SetText(status, "Too many tabs."); RETURN END;
    ed := CAST(Cocoa.Object, RopeEditor.Make(0.0, 0.0, 760.0, 420.0));
    Cocoa.SetEditorText(ed, "");
    tv := s0(CAST(ObjC.Id, ed), ObjC.Selector("documentView"));
    ig := sb(tv, ObjC.Selector("setAllowsUndo:"), TRUE);
    ig := sb(tv, ObjC.Selector("setUsesFindBar:"), TRUE);
    ig := sp(tv, ObjC.Selector("setDelegate:"), ctrl);
    it := Cocoa.AddTab(tabs, "untitled", ed);
    gEditors[gTabCount] := ed; gPaths[gTabCount][0] := CHR(0);   (* empty path = untitled *)
    gReadOnly[gTabCount] := FALSE; Assign("untitled", gTabNames[gTabCount]);
    INC(gTabCount);
    ig := sendIInt(CAST(ObjC.Id, tabs), ObjC.Selector("selectTabViewItemAtIndex:"), gTabCount-1);
    RebuildTabBar;
    Cocoa.SetText(status, "New file — Save (Cmd-S) to name it.")
  END OnNew;
  PROCEDURE OnSaveAs (sender: ObjC.Id);            (* "onSaveAs:" — choose a path, then save *)
  VAR sel, ix: INTEGER; src: ARRAY [0..262143] OF CHAR; path: ARRAY [0..1023] OF CHAR;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN RETURN END;
    IF NOT ObjC.SavePanel(path) THEN RETURN END;   (* user cancelled *)
    Cocoa.EditorText(gEditors[sel], src);
    ix := Proc.WriteFile(path, src);
    IF ix = 0 THEN
      Assign(path, gPaths[sel]); gReadOnly[sel] := FALSE;
      Basename(path, gTabNames[sel]); RebuildTabBar;
      Cocoa.SetText(status, "Saved.")
    ELSE Cocoa.SetText(status, "Save As failed.") END
  END OnSaveAs;
  PROCEDURE OnSave (sender: ObjC.Id);              (* "onSave:" *)
  VAR sel, ix: INTEGER; src: ARRAY [0..262143] OF CHAR;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN RETURN END;
    IF gReadOnly[sel] THEN Cocoa.SetText(status, "Library file is read-only (reference)."); RETURN END;
    IF gPaths[sel][0] = CHR(0) THEN SELF.OnSaveAs(sender); RETURN END;   (* untitled -> Save As *)
    Cocoa.EditorText(gEditors[sel], src);
    ix := Proc.WriteFile(gPaths[sel], src);
    IF ix = 0 THEN Cocoa.SetText(status, "Saved.") ELSE Cocoa.SetText(status, "Save failed.") END
  END OnSave;
  PROCEDURE OnBuildRun (sender: ObjC.Id);          (* "onBuildRun:" *)
  VAR sel, ix, rc, marked, errLine: INTEGER; src: ARRAY [0..262143] OF CHAR; out: ARRAY [0..65535] OF CHAR; cmd: ARRAY [0..2047] OF CHAR;
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
    ELSE
      errLine := Cocoa.GotoFirstError(gEditors[sel], out);   (* jump the cursor to the first error *)
      IF errLine > 0 THEN Cocoa.SetText(status, "Build failed — jumped to first error.")
      ELSE Cocoa.SetText(status, "Build/run reported errors.") END
    END
  END OnBuildRun;
  PROCEDURE OnHelp (sender: ObjC.Id);              (* "onHelp:" — F1 shows/hides the help pane *)
  BEGIN
    HelpShow(NOT gHelpVisible);
    IF gHelpVisible THEN Cocoa.SetText(status, "Help shown (F1 to hide).")
    ELSE Cocoa.SetText(status, "Help hidden (F1 to show).") END
  END OnHelp;
  PROCEDURE OnHome (sender: ObjC.Id);             (* "onHome:" — reveal help, restoring its text *)
  BEGIN
    Cocoa.SetEditorText(helpPane, gHelpText);
    HelpShow(TRUE);
    Cocoa.SetText(status, "Home — welcome / help (F1 to hide).")
  END OnHome;
  PROCEDURE OnComplete (sender: ObjC.Id);         (* "onComplete:" — ⌘/ : completions at the cursor *)
  VAR sel, line, col, n, ix: INTEGER; src, cand: ARRAY [0..16383] OF CHAR;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN Cocoa.SetText(status, "Open a file first."); RETURN END;
    IF NOT gReadOnly[sel] THEN Cocoa.EditorText(gEditors[sel], src); ix := Proc.WriteFile(gPaths[sel], src) END;
    Cocoa.EditorCursor(gEditors[sel], line, col);
    n := Proc.Complete(gPaths[sel], line, col, cand);
    ShowAssist("Completions at cursor (name / kind / detail):", cand);
    IF n > 0 THEN Cocoa.SetText(status, "Completions in the right pane.")
    ELSE Cocoa.SetText(status, "No completions at this position.") END
  END OnComplete;
  PROCEDURE OnCocoaSearch (sender: ObjC.Id);      (* "onCocoaSearch:" — search the Obj-C runtime *)
  VAR q, res: ARRAY [0..16383] OF CHAR; n: INTEGER; sv: ObjC.Id; title: ARRAY [0..511] OF CHAR;
  BEGIN
    sv := s0(CAST(ObjC.Id, searchField), ObjC.Selector("stringValue"));
    n := ObjC.GetString(sv, q);
    IF q[0] = CHR(0) THEN Cocoa.SetText(status, "Type a Cocoa class name, then Enter."); RETURN END;
    n := ObjC.FindClasses(q, res);
    Assign("Cocoa classes matching '", title); Append(q, title); Append("'   (Name : Superclass):", title);
    ShowAssist(title, res);
    IF n > 0 THEN Cocoa.SetText(status, "Cocoa search — results in the right pane.")
    ELSE Cocoa.SetText(status, "No Cocoa class matches that.") END
  END OnCocoaSearch;
  PROCEDURE OnClose (sender: ObjC.Id);            (* "onClose:" — close the active tab (⌘W) *)
  BEGIN CloseTabAt(Cocoa.SelectedTab(tabs)) END OnClose;
  PROCEDURE OnCloseTab (sender: ObjC.Id);         (* "onCloseTab:" — the ✕ on a tab *)
  BEGIN CloseTabAt(TagOf(sender)) END OnCloseTab;
  PROCEDURE OnSelectTab (sender: ObjC.Id);        (* "onSelectTab:" — click a tab name *)
  BEGIN
    ig := sendIInt(CAST(ObjC.Id, tabs), ObjC.Selector("selectTabViewItemAtIndex:"), TagOf(sender));
    RebuildTabBar; ShowTabStatus
  END OnSelectTab;
  PROCEDURE TextViewDidChangeSelection (note: ObjC.Id) <* selector "textViewDidChangeSelection:" *>;
  BEGIN ShowTabStatus END TextViewDidChangeSelection;
  PROCEDURE TextDidChange (note: ObjC.Id);        (* NSText delegate "textDidChange:" — autosave *)
  VAR sel, ix: INTEGER; src: ARRAY [0..32767] OF CHAR;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN RETURN END;
    IF gPaths[sel][0] = CHR(0) THEN RETURN END;     (* untitled: no autosave until named *)
    Cocoa.EditorText(gEditors[sel], src);
    ix := Proc.WriteFile(gPaths[sel], src);
    IF ix = 0 THEN Cocoa.SetText(status, "Autosaved.") END
  END TextDidChange;
END IDE;

VAR ide: IDE; appObj, menuBar, mApp, mFile, mEdit, mBuild, mHelp, findItem: ObjC.Id;
    f1key, upKey, downKey: ARRAY [0..2] OF CHAR;
BEGIN
  s0  := CAST(ObjC.Send0,     ObjC.MsgSendPtr());
  sp  := CAST(ObjC.SendP,     ObjC.MsgSendPtr());
  sf  := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());
  sb  := CAST(SendB2,         ObjC.MsgSendPtr());
  sfi := CAST(SendFI,         ObjC.MsgSendPtr());
  s2f := CAST(Send2F,         ObjC.MsgSendPtr());
  smi := CAST(SendMI,         ObjC.MsgSendPtr());
  gProjBtnCount := 0; gLibBtnCount := 0; gTabCount := 0;
  Assign("library/pimmod", gProjDir);
  Assign("library/pimdef", gLibDir);

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(1100.0, 640.0, "MacM2 IDE");
  content := Cocoa.ContentView(win);
  NEW(ide); ctrl := CAST(ObjC.Id, ide);

  Cocoa.AddSubview(content, CtrlButton(8.0,   604.0, 56.0,  "New", "onNew:", 8));
  Cocoa.AddSubview(content, CtrlButton(68.0,  604.0, 64.0,  "Open", "onOpen:", 8));
  Cocoa.AddSubview(content, CtrlButton(136.0, 604.0, 56.0,  "Save", "onSave:", 8));
  Cocoa.AddSubview(content, CtrlButton(196.0, 604.0, 104.0, "Build & Run", "onBuildRun:", 8));
  Cocoa.AddSubview(content, CtrlButton(304.0, 604.0, 92.0,  "✕ Close Tab", "onClose:", 8));
  (* bottom status bar: messages on the left, current-tab editor status on the right *)
  status := Cocoa.MakeLabel(10.0, 4.0, 700.0, 18.0, "Ready.");
  ig := sendIInt(CAST(ObjC.Id, status), ObjC.Selector("setAutoresizingMask:"), 34);  (* width + stick bottom *)
  Cocoa.AddSubview(content, status);
  editStat := Cocoa.MakeLabel(720.0, 4.0, 370.0, 18.0, "");
  ig := sendIInt(CAST(ObjC.Id, editStat), ObjC.Selector("setAutoresizingMask:"), 33);  (* stick bottom-right *)
  Cocoa.AddSubview(content, editStat);
  (* Cocoa class search box — type a name + Enter to search the live Obj-C runtime *)
  searchField := s0(s0(ObjC.GetClass("NSSearchField"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  ig := sf(CAST(ObjC.Id, searchField), ObjC.Selector("setFrame:"), 700.0, 605.0, 280.0, 26.0);
  ig := sp(CAST(ObjC.Id, searchField), ObjC.Selector("setTarget:"), ctrl);
  ig := sp(CAST(ObjC.Id, searchField), ObjC.Selector("setAction:"), ObjC.Selector("onCocoaSearch:"));
  ig := sp(s0(CAST(ObjC.Id, searchField), ObjC.Selector("cell")),
           ObjC.Selector("setPlaceholderString:"), ObjC.NSString("Find Cocoa class…"));
  ig := sendIInt(CAST(ObjC.Id, searchField), ObjC.Selector("setAutoresizingMask:"), 9);  (* stick top-right *)
  Cocoa.AddSubview(content, searchField);
  (* Home button — above the help pane (top-right); reveals the help/welcome pane *)
  Cocoa.AddSubview(content, CtrlButton(1006.0, 604.0, 86.0, "Home", "onHome:", 9));

  outerSplit := MakeSplit(0.0, 26.0, 1100.0, 570.0, TRUE);   (* leave 0..26 for the status bar *)
  ig := sendIInt(CAST(ObjC.Id, outerSplit), ObjC.Selector("setAutoresizingMask:"), 18);
  Cocoa.AddSubview(content, outerSplit);

  (* the sidebar is itself a split: PROJECT list (top) over LIBRARY list (bottom),
     with a thick, draggable divider between the two scrolling lists *)
  sidebar := MakeSplit(0.0, 0.0, 220.0, 596.0, FALSE);
  projScroll := MakeScroll(0.0, 0.0, 220.0, 360.0, projDoc);
  libScroll := MakeScroll(0.0, 0.0, 220.0, 230.0, libDoc);
  Cocoa.AddSubview(sidebar, projScroll);
  Cocoa.AddSubview(sidebar, libScroll);

  (* rightStack is a 2-pane split: the editor/output centre | the help pane.
     (Two 2-pane splits nest reliably; a single 3-pane split does not position.) *)
  rightStack := MakeSplit(0.0, 0.0, 880.0, 596.0, TRUE);
  innerSplit := MakeSplit(0.0, 0.0, 560.0, 596.0, FALSE);
  Cocoa.AddSubview(outerSplit, sidebar);
  Cocoa.AddSubview(outerSplit, rightStack);
  Cocoa.AddSubview(rightStack, innerSplit);

  (* editor area = a custom tab bar (closeable tabs) over a tab-less NSTabView *)
  editorArea := MakeView(0.0, 0.0, 860.0, 390.0);
  tabs := Cocoa.MakeTabView(0.0, 0.0, 860.0, 362.0);
  ig := sendIInt(CAST(ObjC.Id, tabs), ObjC.Selector("setTabViewType:"), 6);     (* NSNoTabsNoBorder *)
  ig := sendIInt(CAST(ObjC.Id, tabs), ObjC.Selector("setAutoresizingMask:"), 18);
  tabBar := MakeScrollH(0.0, 362.0, 860.0, 28.0, tabDoc);
  ig := sendIInt(CAST(ObjC.Id, tabBar), ObjC.Selector("setAutoresizingMask:"), 10);  (* width + stick to top *)
  Cocoa.AddSubview(editorArea, tabs);
  Cocoa.AddSubview(editorArea, tabBar);
  gTabBarCount := 0;

  output := Cocoa.MakeEditor(0.0, 0.0, 860.0, 200.0);
  Cocoa.SetEditorText(output, "(build output appears here — Build & Run marks error lines red)");
  Cocoa.AddSubview(innerSplit, editorArea);
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
  (* the help / Assist pane joins rightStack (as the rightmost pane) only when
     shown — see HelpShow; hidden, it is removed so the editor fills with no band *)
  gHelpVisible := FALSE;

  (* a real menu bar (App / File / Build / Help), set before RunApp *)
  appObj := s0(ObjC.GetClass("NSApplication"), ObjC.Selector("sharedApplication"));
  menuBar := s0(s0(ObjC.GetClass("NSMenu"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  mApp := AddMenu(menuBar, "MacM2");
  AddItem(mApp, appObj, "Quit MacM2 IDE", "terminate:", "q", 0);
  mFile := AddMenu(menuBar, "File");
  AddItem(mFile, ctrl, "New", "onNew:", "n", 0);                 (* ⌘N *)
  AddItem(mFile, ctrl, "Open Folder…", "onOpen:", "o", 0);
  AddItem(mFile, ctrl, "Save", "onSave:", "s", 0);
  AddItem(mFile, ctrl, "Save As…", "onSaveAs:", "s", 120000H);   (* ⌘⇧S *)
  AddItem(mFile, ctrl, "Close Tab", "onClose:", "w", 0);
  (* Edit menu — standard responder-chain actions (target nil -> the focused editor) *)
  mEdit := AddMenu(menuBar, "Edit");
  AddItem(mEdit, NIL, "Undo", "undo:", "z", 0);
  AddItem(mEdit, NIL, "Redo", "redo:", "z", 120000H);       (* ⌘⇧Z *)
  AddItem(mEdit, NIL, "Cut", "cut:", "x", 0);
  AddItem(mEdit, NIL, "Copy", "copy:", "c", 0);
  AddItem(mEdit, NIL, "Paste", "paste:", "v", 0);
  AddItem(mEdit, NIL, "Select All", "selectAll:", "a", 0);
  AddItem(mEdit, ctrl, "Complete at Cursor", "onComplete:", "i", 0);     (* ⌘I autocomplete *)
  AddItem(mEdit, NIL, "Toggle Comment", "toggleComment:", "/", 0);       (* ⌘/ -> first responder *)
  AddItem(mEdit, NIL, "Shift Right", "insertTab:", "]", 0);              (* ⌘] indent *)
  AddItem(mEdit, NIL, "Shift Left", "insertBacktab:", "[", 0);           (* ⌘[ outdent *)
  AddItem(mEdit, NIL, "Select Line", "selectLine:", "l", 0);             (* ⌘L *)
  AddItem(mEdit, NIL, "Duplicate Line", "duplicateLine:", "d", 120000H); (* ⌘⇧D *)
  AddItem(mEdit, NIL, "Delete Line", "deleteLine:", "k", 120000H);       (* ⌘⇧K *)
  upKey[0] := CHR(0F700H); upKey[1] := CHR(0);                           (* NSUpArrowFunctionKey *)
  downKey[0] := CHR(0F701H); downKey[1] := CHR(0);                       (* NSDownArrowFunctionKey *)
  AddItem(mEdit, NIL, "Move Line Up", "moveLineUp:", upKey, 980000H);    (* ⌥⌘↑ (+function) *)
  AddItem(mEdit, NIL, "Move Line Down", "moveLineDown:", downKey, 980000H); (* ⌥⌘↓ *)
  findItem := s0(ObjC.GetClass("NSMenuItem"), ObjC.Selector("alloc"));   (* Find… ⌘F *)
  findItem := smi(findItem, ObjC.Selector("initWithTitle:action:keyEquivalent:"),
                  ObjC.NSString("Find…"), ObjC.Selector("performFindPanelAction:"), ObjC.NSString("f"));
  ig := sendIInt(findItem, ObjC.Selector("setTag:"), 1);    (* NSFindPanelActionShowFindInterface *)
  ig := sp(mEdit, ObjC.Selector("addItem:"), findItem);
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
  gHelpVisible := FALSE;                  (* help starts out of the split (editor fills) *)
  Cocoa.SetText(status, "Ready — PROJECT (top) and LIBRARY (bottom). F1 = help.");

  Cocoa.RunApp;
  WriteString("MacM2 IDE closed."); WriteLn
END macos_panes_ide.
