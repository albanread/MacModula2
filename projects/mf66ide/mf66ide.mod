MODULE mf66ide;
(* The MF66 Forth IDE — a fork of the MacM2 panes IDE, retargeted to drive the
   MF66 Forth compiler/JIT (`mf66`) instead of `newm2-driver`. Same native Cocoa
   shell (NSSplitView panes, NSTextView editors, native menu, offscreen snapshot
   via Ptcl `snap`); Build & Run runs the active `.f` buffer through `mf66` and
   shows its output. See the original macos_panes_ide.mod, the macOS counterpart
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
FROM SYSTEM IMPORT CAST, ADDRESS;
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Assign, Append, Equal, Length;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT Proc;
IMPORT RopeEditor;
IMPORT MarkView;
IMPORT Ptcl;
IMPORT M2Format;

CONST
  MaxFiles = 256;
  MaxJobs  = 16;            (* concurrent Build & Run jobs we track for output/errors *)
  LibBase  = 1000;          (* sidebar tags >= LibBase address the library list *)
  RowH     = 27.0;
  Dot      = 2EH;           (* '.' as a unichar (ORD('.')) — the completion trigger *)

TYPE
  IntPtr = POINTER TO INTEGER;   (* to write indexOfSelectedItem, an NSInteger out-pointer *)

(* The send machinery is gone: every Cocoa call below uses the `[recv sel: args]`
   message-send syntax, with Rect()/Point() building struct arguments. *)

VAR
  win, content, outerSplit, rightStack, innerSplit, sidebar, tabs, output, status, editStat, helpPane, searchField: Cocoa.Object;
  projScroll, libScroll, projDoc, libDoc, editorArea, tabBar, tabDoc: Cocoa.Object;
  clock: Cocoa.Object;          (* status-bar clock label, driven by an NSTimer block *)
  gFmt: ObjC.Id;                (* shared NSDateFormatter for the clock *)
  gTabNames: ARRAY [0..63] OF ARRAY [0..255] OF CHAR;
  gTabBtns, gTabCloseBtns: ARRAY [0..63] OF Cocoa.Object;
  gTabBarCount: INTEGER;
  gHelpVisible: BOOLEAN;
  gSplitInit: BOOLEAN;                    (* re-pin the editor/output divider once after first layout *)
  gBridgeSeq: CARDINAL;                   (* monotonic request id for the mf66-tcl file-mailbox bridge *)
  gMf66, gMf66Tcl, gExamples: ARRAY [0..1023] OF CHAR;   (* engine paths — bundle-relative, dev fallback *)
  gCnslTV: ObjC.Id;                       (* the CNSL console text view (to identify it in the Enter hook) *)
  gCnslCompiling: BOOLEAN;                (* CNSL mid-`:`-definition state *)
  gHelpText: ARRAY [0..4095] OF CHAR;     (* welcome/help markdown (rendered by MarkView) *)
  gTopicMd: ARRAY [0..262143] OF CHAR;    (* current topic markdown (docs/m2-guide/*.md) *)
  gHovIdx: CARDINAL;                      (* char index under the pointer (hover) *)
  gHovLine, gHovCol: INTEGER;             (* last described hover position *)
  gHovMoved, gHovPending: BOOLEAN;        (* dwell state for the hover timer *)
  gCmdBuf: ARRAY [0..8191] OF CHAR;       (* ptcl script read from the command file *)
  gFmtIn, gFmtOut: ARRAY [0..1048575] OF CHAR;   (* source re-indent scratch (1 MiB) *)
  helpNL: ARRAY [0..1] OF CHAR;
  gProjDir, gLibDir: ARRAY [0..1023] OF CHAR;
  gProjFiles, gLibFiles: ARRAY [0..MaxFiles-1] OF ARRAY [0..255] OF CHAR;
  gProjBtns, gLibBtns: ARRAY [0..MaxFiles-1] OF Cocoa.Object;
  gProjCount, gLibCount, gProjBtnCount, gLibBtnCount: INTEGER;
  gEditors: ARRAY [0..63] OF Cocoa.Object;
  gPaths: ARRAY [0..63] OF ARRAY [0..1023] OF CHAR;
  gReadOnly: ARRAY [0..63] OF BOOLEAN;     (* TRUE for LIBRARY (reference) tabs *)
  gTabCount: INTEGER;
  ctrl: ObjC.Id;
  gCandBuf: ARRAY [0..65535] OF CHAR;   (* completion candidates, module-level so the *)
                                        (* delegate never puts a 128 KB array on the stack *)
  gJobs:   ARRAY [0..MaxJobs-1] OF INTEGER;  (* async run job ids (0 = free slot) *)
  gJobTab: ARRAY [0..MaxJobs-1] OF INTEGER;  (* tab each job came from (for error marking) *)
  gBuildOut: ARRAY [0..65535] OF CHAR;       (* captured run output (module-level: big) *)

(* A flipped NSView: y=0 at the TOP, so a file list lays out top-down inside an
   NSScrollView. An ordinary M2 class overriding NSView's isFlipped. *)
CLASS FlippedDoc;
  <* cocoa "NSView" *>
  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;
END FlippedDoc;

(* Build an NSRect / NSPoint value for a frame / scroll send.  With typed struct
   args we pass a real struct, instead of the old 4-REAL HFA-packing cast trick. *)
PROCEDURE Rect (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rect;

PROCEDURE Point (px, py: REAL): ObjC.NSPoint;
VAR p: ObjC.NSPoint;
BEGIN p.x := px; p.y := py; RETURN p END Point;

PROCEDURE Size (w, h: REAL): ObjC.NSSize;
VAR s: ObjC.NSSize;
BEGIN s.width := w; s.height := h; RETURN s END Size;

PROCEDURE Cls (name: ARRAY OF CHAR): ObjC.Id;   (* class object as a send receiver *)
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(name)) END Cls;

PROCEDURE SetFrameOf (v: Cocoa.Object; x, y, w, h: REAL);
BEGIN [CAST(ObjC.Id, v) setFrame: Rect(x, y, w, h)] END SetFrameOf;

PROCEDURE MakeView (x, y, w, h: REAL): Cocoa.Object;   (* a plain NSView container *)
BEGIN
  RETURN CAST(Cocoa.Object, [[Cls("NSView") alloc] initWithFrame: Rect(x, y, w, h)])
END MakeView;

(* A scrollable NSTextView whose text container tracks the pane width, so text
   wraps to and fills the whole pane (no right-hand gap). Cocoa.MakeEditor omits
   this; configuring it AFTER setDocumentView collapses the container, so — like
   RopeEditor.Make — we configure the text view BEFORE attaching it. *)
PROCEDURE MakeFillEditor (x, y, w, h: REAL): Cocoa.Object;
VAR tv, scroll, font: ObjC.Id;
BEGIN
  tv   := [[Cls("NSTextView") alloc] initWithFrame: Rect(0.0, 0.0, w, h)];
  font := [Cls("NSFont") userFixedPitchFontOfSize: 13.0];
  [tv setFont: font];
  [tv setMinSize: Size(0.0, 0.0)];
  [tv setMaxSize: Size(1000000.0, 1000000.0)];         (* default max = creation frame, which caps width *)
  [tv setVerticallyResizable: TRUE];
  [tv setHorizontallyResizable: FALSE];
  [tv setAutoresizingMask: 2];                         (* NSViewWidthSizable *)
  [[tv textContainer] setWidthTracksTextView: TRUE];
  scroll := [[Cls("NSScrollView") alloc] initWithFrame: Rect(x, y, w, h)];
  [scroll setHasVerticalScroller: TRUE];
  [scroll setDocumentView: tv];
  RETURN CAST(Cocoa.Object, scroll)
END MakeFillEditor;

(* a horizontally-scrolling container (overlay scroller, so the tab bar slides
   when full without the scroller taking layout space); returns its document. *)
PROCEDURE MakeScrollH (x, y, w, h: REAL; VAR doc: Cocoa.Object): Cocoa.Object;
VAR sc: ObjC.Id;
BEGIN
  sc := [[Cls("NSScrollView") alloc] initWithFrame: Rect(x, y, w, h)];
  [sc setHasHorizontalScroller: FALSE];   (* no scroll bar — tabs slide via trackpad *)
  [sc setBorderType: 0];
  doc := MakeView(0.0, 0.0, w, h);
  [sc setDocumentView: CAST(ObjC.Id, doc)];
  RETURN CAST(Cocoa.Object, sc)
END MakeScrollH;

PROCEDURE MakeSplit (x, y, w, h: REAL; sideBySide: BOOLEAN): Cocoa.Object;
VAR v: ObjC.Id;
BEGIN
  v := [[Cls("NSSplitView") alloc] initWithFrame: Rect(x, y, w, h)];
  [v setVertical: sideBySide];
  [v setDividerStyle: 1];   (* thick, draggable — every split matches *)
  RETURN CAST(Cocoa.Object, v)
END MakeSplit;

PROCEDURE SetDivider (split: Cocoa.Object; index: INTEGER; pos: REAL);
BEGIN [CAST(ObjC.Id, split) setPosition: pos ofDividerAtIndex: index] END SetDivider;

(* The 3-column sizing policy, re-applied on EVERY layout change (window resize +
   help toggle): a fixed-width sidebar on the left, a fixed-width help pane
   anchored on the right (only while visible), and the editor taking the rest.
   Re-pinning each time stops NSSplitView from redistributing the fixed columns
   proportionally as the window resizes. *)
PROCEDURE Relayout;
VAR rw: REAL;
BEGIN
  SetDivider(outerSplit, 0, 160.0);                          (* sidebar: fixed 160 on the left *)
  IF gHelpVisible THEN
    rw := [CAST(ObjC.Id, rightStack) frame].size.width;
    IF rw > 480.0 THEN SetDivider(rightStack, 0, rw - 360.0) END   (* help: fixed 360 on the right *)
  END
END Relayout;

(* Show/hide the help pane. When hidden it is REMOVED from rightStack so the
   editor pane fills 100% (no leftover band); when shown it is re-added as the
   rightmost pane (its right edge = the window's right edge) with a draggable
   splitter. gHelpVisible tracks membership. *)
PROCEDURE HelpShow (visible: BOOLEAN);
BEGIN
  IF visible THEN
    IF NOT gHelpVisible THEN
      Cocoa.AddSubview(rightStack, helpPane);
      [CAST(ObjC.Id, rightStack) adjustSubviews]   (* incorporate the new pane *)
    END;
    gHelpVisible := TRUE
  ELSE
    IF gHelpVisible THEN
      Cocoa.RemoveView(helpPane);                  (* removed -> editor reclaims its space *)
      [CAST(ObjC.Id, rightStack) adjustSubviews]
    END;
    gHelpVisible := FALSE
  END;
  Relayout
END HelpShow;

(* an NSScrollView with a vertical scroller and a flipped document NSView. *)
PROCEDURE MakeScroll (x, y, w, h: REAL; VAR doc: Cocoa.Object): Cocoa.Object;
VAR sc: ObjC.Id; fd: FlippedDoc;
BEGIN
  sc := [[Cls("NSScrollView") alloc] initWithFrame: Rect(x, y, w, h)];
  [sc setHasVerticalScroller: TRUE];
  [sc setBorderType: 0];
  NEW(fd);
  doc := CAST(Cocoa.Object, fd);
  SetFrameOf(doc, 0.0, 0.0, w - 16.0, h);
  [sc setDocumentView: CAST(ObjC.Id, doc)];
  RETURN CAST(Cocoa.Object, sc)
END MakeScroll;

PROCEDURE CtrlButton (x, y, w: REAL; title, selector: ARRAY OF CHAR; mask: INTEGER): Cocoa.Object;
VAR b: ObjC.Id;
BEGIN
  b := [[Cls("NSButton") alloc] init];
  [b setFrame: Rect(x, y, w, 30.0)];
  [b setTitle: ObjC.NSString(title)];
  [b setTarget: ctrl];
  [b setAction: ObjC.Selector(selector)];
  [b setAutoresizingMask: mask];
  RETURN CAST(Cocoa.Object, b)
END CtrlButton;

(* a top-level menu (its title shows in the menu bar); returns the submenu. *)
PROCEDURE AddMenu (bar: ObjC.Id; title: ARRAY OF CHAR): ObjC.Id;
VAR item, sub: ObjC.Id;
BEGIN
  item := [[Cls("NSMenuItem") alloc] init];
  sub := [[Cls("NSMenu") alloc] initWithTitle: ObjC.NSString(title)];
  [item setSubmenu: sub];
  [bar addItem: item];
  RETURN sub
END AddMenu;

(* a menu item: action selector on `target`, key equivalent (with `modMask`). *)
PROCEDURE AddItem (menu, target: ObjC.Id; title, action, key: ARRAY OF CHAR; modMask: INTEGER);
VAR it: ObjC.Id;
BEGIN
  it := [[Cls("NSMenuItem") alloc] initWithTitle: ObjC.NSString(title)
                                   action: ObjC.Selector(action)
                                   keyEquivalent: ObjC.NSString(key)];
  [it setTarget: target];
  IF modMask # 0 THEN [it setKeyEquivalentModifierMask: modMask] END;
  [menu addItem: it]
END AddItem;

(* a menu item carrying a tag (read back via [sender tag] in the action). *)
PROCEDURE AddTagItem (menu, target: ObjC.Id; title, action: ARRAY OF CHAR; tag: INTEGER);
VAR it: ObjC.Id;
BEGIN
  it := [[Cls("NSMenuItem") alloc] initWithTitle: ObjC.NSString(title)
                                   action: ObjC.Selector(action)
                                   keyEquivalent: ObjC.NSString("")];
  [it setTarget: target]; [it setTag: tag]; [menu addItem: it]
END AddTagItem;

PROCEDURE HL (s: ARRAY OF CHAR);   (* append a help line + newline *)
BEGIN Append(s, gHelpText); Append(helpNL, gHelpText) END HL;

PROCEDURE LowerCh (c: CHAR): CHAR;
BEGIN IF (c >= 'A') AND (c <= 'Z') THEN RETURN CHR(ORD(c) + 32) ELSE RETURN c END END LowerCh;

(* TRUE for editable Forth source we want in the file lists: *.f / *.fs / *.fth
   (case-insensitive). *)
PROCEDURE IsSource (VAR nm: ARRAY OF CHAR): BOOLEAN;
VAR L: CARDINAL; a, b, c: CHAR;
BEGIN
  L := Length(nm);
  IF L < 3 THEN RETURN FALSE END;                       (* "x.f" is 3 chars minimum *)
  IF (nm[L-2] = '.') AND (LowerCh(nm[L-1]) = 'f') THEN RETURN TRUE END;   (* .f *)
  IF L >= 4 THEN                                         (* .fs *)
    IF (nm[L-3] = '.') AND (LowerCh(nm[L-2]) = 'f') AND (LowerCh(nm[L-1]) = 's') THEN RETURN TRUE END
  END;
  IF L >= 5 THEN                                         (* .fth *)
    a := LowerCh(nm[L-3]); b := LowerCh(nm[L-2]); c := LowerCh(nm[L-1]);
    IF (nm[L-4] = '.') AND (a = 'f') AND (b = 't') AND (c = 'h') THEN RETURN TRUE END;
    (* .masm — JASM macro-assembly (MF66 CODE words) *)
    IF (nm[L-5] = '.') AND (LowerCh(nm[L-4]) = 'm') AND (LowerCh(nm[L-3]) = 'a')
       AND (LowerCh(nm[L-2]) = 's') AND (LowerCh(nm[L-1]) = 'm') THEN RETURN TRUE END
  END;
  RETURN FALSE
END IsSource;

(* TRUE for a *.masm path (JASM macro-assembly) — selects the masm lexer. *)
PROCEDURE PathIsMasm (p: ARRAY OF CHAR): BOOLEAN;
VAR L: CARDINAL;
BEGIN
  L := Length(p);
  IF L < 5 THEN RETURN FALSE END;
  RETURN (p[L-5] = '.') AND (LowerCh(p[L-4]) = 'm') AND (LowerCh(p[L-3]) = 'a')
     AND (LowerCh(p[L-2]) = 's') AND (LowerCh(p[L-1]) = 'm')
END PathIsMasm;

(* Point the editor lexer at the active tab's grammar (.masm -> masm, else Forth),
   so re-lexing on edit and on tab switch uses the right colours. *)
PROCEDURE UpdateLexMode;
VAR sel: INTEGER;
BEGIN
  sel := Cocoa.SelectedTab(tabs);
  IF (sel >= 0) AND (sel < gTabCount) AND PathIsMasm(gPaths[sel]) THEN RopeEditor.SetLexMode(1)
  ELSE RopeEditor.SetLexMode(0) END
END UpdateLexMode;

(* populate one scrollable list (project or library) from its folder. Shows only
   folders ([name]) and source files; a leading [..] navigates up a level.
   Buttons go top-down in the flipped document, whose height grows to scroll. *)
PROCEDURE RebuildList (isLib: BOOLEAN);
VAR i, raw, out, n: INTEGER; b: Cocoa.Object; docW, totalH: REAL; isDir: BOOLEAN;
    dir, full: ARRAY [0..1023] OF CHAR; nm: ARRAY [0..255] OF CHAR; title: ARRAY [0..271] OF CHAR;

  PROCEDURE Emit (VAR realName, displayTitle: ARRAY OF CHAR);
  BEGIN
    IF isLib THEN
      Assign(realName, gLibFiles[out]);
      b := Cocoa.MakeFileButton(2.0, FLOAT(out) * RowH, docW, RowH - 2.0, displayTitle, LibBase + out);
      gLibBtns[out] := b; Cocoa.AddSubview(libDoc, b)
    ELSE
      Assign(realName, gProjFiles[out]);
      b := Cocoa.MakeFileButton(2.0, FLOAT(out) * RowH, docW, RowH - 2.0, displayTitle, out);
      gProjBtns[out] := b; Cocoa.AddSubview(projDoc, b)
    END;
    INC(out)
  END Emit;

BEGIN
  IF isLib THEN
    FOR i := 0 TO gLibBtnCount - 1 DO Cocoa.RemoveView(gLibBtns[i]) END;
    gLibBtnCount := 0; Assign(gLibDir, dir); raw := Proc.ListDir(gLibDir)
  ELSE
    FOR i := 0 TO gProjBtnCount - 1 DO Cocoa.RemoveView(gProjBtns[i]) END;
    gProjBtnCount := 0; Assign(gProjDir, dir); raw := Proc.ListDir(gProjDir)
  END;
  IF raw < 0 THEN raw := 0 END;
  docW := 150.0; out := 0;
  Assign("..", nm); Assign("[..]", title); Emit(nm, title);   (* up a level *)
  i := 0;
  WHILE (i < raw) AND (out < MaxFiles - 1) DO
    n := Proc.DirEntry(i, nm);
    Assign(dir, full); Append("/", full); Append(nm, full);
    isDir := Proc.IsDir(full);
    IF isDir THEN Assign("[", title); Append(nm, title); Append("]", title); Emit(nm, title)
    ELSIF IsSource(nm) THEN Assign(nm, title); Emit(nm, title) END;
    INC(i)
  END;
  totalH := FLOAT(out) * RowH + 4.0;
  IF isLib THEN gLibCount := out; gLibBtnCount := out; SetFrameOf(libDoc, 0.0, 0.0, docW + 4.0, totalH)
  ELSE          gProjCount := out; gProjBtnCount := out; SetFrameOf(projDoc, 0.0, 0.0, docW + 4.0, totalH);
                Cocoa.SetText(status, gProjDir) END
END RebuildList;

(* [sender tag] — which tab a tab-bar button belongs to. *)
PROCEDURE TagOf (o: ObjC.Id): INTEGER;
BEGIN RETURN [o tag] END TagOf;

(* a tab-bar button (filename or ✕): target = controller, carries its tab index. *)
PROCEDURE TagButton (x, w: REAL; title, action: ARRAY OF CHAR; tag: INTEGER): Cocoa.Object;
VAR b: ObjC.Id;
BEGIN
  b := [[Cls("NSButton") alloc] init];
  [b setFrame: Rect(x, 2.0, w, 22.0)];
  [b setTitle: ObjC.NSString(title)];
  [b setTarget: ctrl];
  [b setAction: ObjC.Selector(action)];
  [b setTag: tag];
  [b setBezelStyle: 1];   (* rounded/flat tab look *)
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
    [CAST(ObjC.Id, tabDoc) scrollPoint: Point(FLOAT(active) * 150.0, 0.0)]
  END
END RebuildTabBar;

(* close the tab at `idx`: remove its NSTabViewItem, shift bookkeeping, redraw. *)
PROCEDURE CloseTabAt (idx: INTEGER);
VAR i: INTEGER; item: ObjC.Id;
BEGIN
  IF (idx < 0) OR (idx >= gTabCount) THEN RETURN END;
  IF Equal(gPaths[idx], "*STAT*") THEN Cocoa.SetText(status, "The STAT tab stays open — live engine state."); RETURN END;
  IF Equal(gPaths[idx], "*CNSL*") THEN Cocoa.SetText(status, "The CNSL tab stays open — live Forth terminal."); RETURN END;
  item := [CAST(ObjC.Id, tabs) tabViewItemAtIndex: idx];
  [CAST(ObjC.Id, tabs) removeTabViewItem: item];
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

(* Render a help topic from docs/m2-guide/<stem>.md (paths are repo-root relative,
   matching how the IDE already resolves ./target/debug/newm2-driver and library). *)
PROCEDURE LoadTopic (stem: ARRAY OF CHAR);
VAR path: ARRAY [0..511] OF CHAR; n: INTEGER;
BEGIN
  Assign("docs/m2-guide/", path); Append(stem, path); Append(".md", path);
  n := Proc.ReadFile(path, gTopicMd);
  IF n < 0 THEN
    Assign("# Topic not found", gTopicMd); Append(helpNL, gTopicMd); Append(helpNL, gTopicMd);
    Append("Could not read ", gTopicMd); Append(path, gTopicMd)
  END;
  MarkView.Render(helpPane, gTopicMd);
  HelpShow(TRUE)
END LoadTopic;

(* Follow a help/markdown link: sym:<path>#<line> (definition) | <stem>.md (topic)
   | http… (external) | <stem> (topic). Topic links wire the whole guide together. *)
PROCEDURE HelpNavigate (VAR tgt: ARRAY OF CHAR);
VAR i, n: CARDINAL; stem: ARRAY [0..255] OF CHAR;
BEGIN
  n := 0; WHILE tgt[n] # CHR(0) DO INC(n) END;
  IF (n > 4) & (tgt[0] = 's') & (tgt[1] = 'y') & (tgt[2] = 'm') & (tgt[3] = ':') THEN
    Cocoa.SetText(status, "Definition link — open the file from the PROJECT/LIBRARY list.")
  ELSIF (n > 4) & (tgt[0] = 'h') & (tgt[1] = 't') & (tgt[2] = 't') & (tgt[3] = 'p') THEN
    Cocoa.SetText(status, "External link — open it in a browser.")
  ELSIF (n > 3) & (tgt[n-3] = '.') & (tgt[n-2] = 'm') & (tgt[n-1] = 'd') THEN
    i := 0; WHILE i < n - 3 DO stem[i] := tgt[i]; INC(i) END; stem[n-3] := CHR(0);
    LoadTopic(stem)
  ELSE
    LoadTopic(tgt)
  END
END HelpNavigate;

(* ---- help search (guide full-text) ---------------------------------------- *)

PROCEDURE LowCh (c: CHAR): CHAR;
BEGIN IF (c >= 'A') & (c <= 'Z') THEN RETURN CHR(ORD(c) + 32) ELSE RETURN c END END LowCh;

PROCEDURE MatchAt (VAR line: ARRAY OF CHAR; at: CARDINAL; VAR q: ARRAY OF CHAR): BOOLEAN;  (* q at line[at..], case-insensitive *)
VAR j: CARDINAL;
BEGIN
  j := 0;
  WHILE q[j] # CHR(0) DO
    IF (line[at+j] = CHR(0)) OR (LowCh(line[at+j]) # LowCh(q[j])) THEN RETURN FALSE END;
    INC(j)
  END;
  RETURN TRUE
END MatchAt;

PROCEDURE LineMatch (VAR line: ARRAY OF CHAR; VAR q: ARRAY OF CHAR): BOOLEAN;  (* q occurs anywhere in line *)
VAR i: CARDINAL;
BEGIN
  IF q[0] = CHR(0) THEN RETURN FALSE END;
  i := 0;
  WHILE line[i] # CHR(0) DO IF MatchAt(line, i, q) THEN RETURN TRUE END; INC(i) END;
  RETURN FALSE
END LineMatch;

PROCEDURE NumStr (n: CARDINAL; VAR s: ARRAY OF CHAR);
VAR d: ARRAY [0..15] OF CHAR; i, j: CARDINAL;
BEGIN
  IF n = 0 THEN s[0] := '0'; s[1] := CHR(0); RETURN END;
  i := 0; WHILE n > 0 DO d[i] := CHR(ORD('0') + (n MOD 10)); n := n DIV 10; INC(i) END;
  j := 0; WHILE i > 0 DO DEC(i); s[j] := d[i]; INC(j) END; s[j] := CHR(0)
END NumStr;

(* the i-th guide topic: a friendly label + its docs/m2-guide/<stem>.md stem *)
PROCEDURE TopicStem (i: CARDINAL; VAR label, stem: ARRAY OF CHAR): BOOLEAN;
BEGIN
  CASE i OF
    0: Assign("Getting Started", label); Assign("getting-started", stem) |
    1: Assign("Lexical Structure", label); Assign("lexical-structure", stem) |
    2: Assign("Declarations & Types", label); Assign("declarations-and-types", stem) |
    3: Assign("Expressions", label); Assign("expressions-and-operators", stem) |
    4: Assign("Statements", label); Assign("statements-and-control-flow", stem) |
    5: Assign("Procedures", label); Assign("procedures", stem) |
    6: Assign("Objects & Classes", label); Assign("objects-and-classes", stem) |
    7: Assign("Modules", label); Assign("modules-and-compilation", stem) |
    8: Assign("Standard Environment", label); Assign("standard-environment", stem) |
    9: Assign("Reference", label); Assign("reference", stem)
  ELSE RETURN FALSE END;
  RETURN TRUE
END TopicStem;

(* Append per-topic guide hits for `q` to `md` as clickable links; returns the
   total hit count. Uses gTopicMd as a per-file scratch (not held across calls). *)
PROCEDURE SearchGuide (VAR q: ARRAY OF CHAR; VAR md: ARRAY OF CHAR): INTEGER;
VAR ti, hits, i, c: CARDINAL; total, n: INTEGER;
    label, stem, path: ARRAY [0..255] OF CHAR; ln: ARRAY [0..1023] OF CHAR; num: ARRAY [0..15] OF CHAR;
BEGIN
  total := 0; ti := 0;
  WHILE TopicStem(ti, label, stem) DO
    Assign("docs/m2-guide/", path); Append(stem, path); Append(".md", path);
    n := Proc.ReadFile(path, gTopicMd);
    IF n >= 0 THEN
      hits := 0; i := 0;
      WHILE gTopicMd[i] # CHR(0) DO
        c := 0;
        WHILE (gTopicMd[i] # CHR(0)) & (gTopicMd[i] # CHR(10)) DO IF c < 1023 THEN ln[c] := gTopicMd[i]; INC(c) END; INC(i) END;
        ln[c] := CHR(0);
        IF gTopicMd[i] = CHR(10) THEN INC(i) END;
        IF LineMatch(ln, q) THEN INC(hits) END
      END;
      IF hits > 0 THEN
        Append("- [", md); Append(label, md); Append("](", md); Append(stem, md); Append(".md) — ", md);
        NumStr(hits, num); Append(num, md); Append(" hit(s)", md); Append(helpNL, md);
        total := total + VAL(INTEGER, hits)
      END
    END;
    INC(ti)
  END;
  RETURN total
END SearchGuide;

(* ---- hover help (dwell over a symbol -> describe) ------------------------- *)

(* RopeEditor hover callback: just record the char index under the pointer + arm
   the dwell. Cheap, runs on every mouse move; the timer does the real work. *)
PROCEDURE HoverMove (idx: CARDINAL);
BEGIN gHovIdx := idx; gHovMoved := TRUE; gHovPending := TRUE END HoverMove;

(* Map the hovered char index to (line, col) and describe the symbol there,
   refreshing the help pane — but only when help is already open (so the pane is
   not yanked in/out as the pointer moves) and the position actually changed. *)
PROCEDURE HoverDescribe;
VAR sel, line, col, n: INTEGER; i, idx: CARDINAL; md: ARRAY [0..16383] OF CHAR;
BEGIN
  IF NOT gHelpVisible THEN RETURN END;
  sel := Cocoa.SelectedTab(tabs);
  IF (sel < 0) OR (gPaths[sel][0] = CHR(0)) THEN RETURN END;
  idx := gHovIdx;
  Cocoa.EditorText(gEditors[sel], gTopicMd);             (* whole doc into scratch *)
  line := 1; col := 0; i := 0;
  WHILE (i < idx) & (gTopicMd[i] # CHR(0)) DO
    IF gTopicMd[i] = CHR(10) THEN INC(line); col := 0 ELSE INC(col) END;
    INC(i)
  END;
  IF (line = gHovLine) & (col = gHovCol) THEN RETURN END; (* same spot as last time *)
  gHovLine := line; gHovCol := col;
  n := Proc.Describe(gPaths[sel], line, col, md);
  IF n > 0 THEN MarkView.Render(helpPane, md) END
END HoverDescribe;

(* NSTimer block (~0.35s): describe once the pointer settles (one tick with no
   move) on a fresh position — a debounced dwell, no per-move compiler calls. *)
PROCEDURE HoverTick (block, timer: ObjC.Id);
BEGIN
  IF gHovMoved THEN gHovMoved := FALSE
  ELSIF gHovPending THEN gHovPending := FALSE; HoverDescribe END
END HoverTick;

(* ---- shared actions (used by both menu handlers and ptcl verbs) ----------- *)

PROCEDURE ApplyThemeAll (t: CARDINAL);   (* set the theme + repaint every open editor *)
VAR i: CARDINAL;
BEGIN
  RopeEditor.SetTheme(t);
  IF gTabCount > 0 THEN
    FOR i := 0 TO gTabCount-1 DO RopeEditor.ApplyTheme(CAST(ObjC.Id, gEditors[i])) END
  END
END ApplyThemeAll;

PROCEDURE DescribeCursor;   (* describe the symbol at the active editor's cursor *)
VAR sel, line, col, n: INTEGER; md: ARRAY [0..16383] OF CHAR;
BEGIN
  sel := Cocoa.SelectedTab(tabs);
  IF sel < 0 THEN Cocoa.SetText(status, "Open a file first."); RETURN END;
  IF gPaths[sel][0] = CHR(0) THEN Cocoa.SetText(status, "Save the file first to enable help."); RETURN END;
  Cocoa.EditorCursor(gEditors[sel], line, col);
  n := Proc.Describe(gPaths[sel], line, col, md);
  IF n <= 0 THEN Cocoa.SetText(status, "No help for the symbol at the cursor."); RETURN END;
  MarkView.Render(helpPane, md); HelpShow(TRUE);
  Cocoa.SetText(status, "Context help — describe at cursor (F1 to hide).")
END DescribeCursor;

(* case-insensitive substring test *)
PROCEDURE ContainsCI (hay, needle: ARRAY OF CHAR): BOOLEAN;
VAR i, j, hl, nl: CARDINAL; ok: BOOLEAN;
BEGIN
  hl := Length(hay); nl := Length(needle);
  IF nl = 0 THEN RETURN TRUE END;
  IF nl > hl THEN RETURN FALSE END;
  i := 0;
  WHILE i + nl <= hl DO
    ok := TRUE; j := 0;
    WHILE ok AND (j < nl) DO IF LowerCh(hay[i+j]) # LowerCh(needle[j]) THEN ok := FALSE END; INC(j) END;
    IF ok THEN RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END ContainsCI;

(* Search the live Forth vocabulary: a `see` report for an exact user word, plus
   every word whose name contains the query — rendered into the help pane. *)
PROCEDURE RunSearch (VAR q: ARRAY OF CHAR);
VAR md: ARRAY [0..131071] OF CHAR; words, see, w: ARRAY [0..65535] OF CHAR;
    cmd: ARRAY [0..2047] OF CHAR; nl: ARRAY [0..1] OF CHAR; i, k, nmatch: INTEGER;
BEGIN
  IF q[0] = CHR(0) THEN Cocoa.SetText(status, "Type a word to search."); RETURN END;
  nl[0] := CHR(10); nl[1] := CHR(0);
  Assign("# Forth words matching  ", md); Append(q, md); Append(nl, md); Append(nl, md);
  Assign("see ", cmd); Append(q, cmd); BridgeSend(cmd, see);   (* exact word -> its definition report *)
  IF (see[0] # CHR(0)) AND NOT ContainsCI(see, "not a user-defined") AND NOT ContainsCI(see, "no response") THEN
    Append("```", md); Append(nl, md); Append(see, md); Append(nl, md); Append("```", md); Append(nl, md); Append(nl, md)
  END;
  Append("## words", md); Append(nl, md);
  BridgeSend("words", words);
  i := 0; nmatch := 0;
  WHILE words[i] # CHR(0) DO
    IF words[i] = ' ' THEN INC(i)
    ELSE
      k := 0;
      WHILE (words[i] # ' ') AND (words[i] # CHR(0)) AND (k < 255) DO w[k] := words[i]; INC(k); INC(i) END;
      w[k] := CHR(0);
      IF ContainsCI(w, q) THEN Append("- `", md); Append(w, md); Append("`", md); Append(nl, md); INC(nmatch) END
    END
  END;
  IF nmatch = 0 THEN Append("_no matching words_", md); Append(nl, md) END;
  MarkView.Render(helpPane, md); HelpShow(TRUE);
  Cocoa.SetText(status, "Word search in the help pane.")
END RunSearch;

(* ---- ptcl automation: register IDE actions as verbs; a timer runs scripts
   left in /tmp/mf66.ptcl (e.g. `echo 'topics; snap /tmp/x.png' > /tmp/mf66.ptcl`).
   Uses the built-in Ptcl interpreter (library/sharedmod/Ptcl.mod). -------------- *)

PROCEDURE VHelp (): BOOLEAN;
BEGIN MarkView.Render(helpPane, gHelpText); HelpShow(TRUE); RETURN TRUE END VHelp;

PROCEDURE VTopics (): BOOLEAN;
BEGIN LoadTopic("index"); RETURN TRUE END VTopics;

PROCEDURE VDescribe (): BOOLEAN;
BEGIN DescribeCursor; RETURN TRUE END VDescribe;

PROCEDURE VSearch (): BOOLEAN;
VAR q: ARRAY [0..1023] OF CHAR;
BEGIN Ptcl.Arg(1, q); RunSearch(q); RETURN TRUE END VSearch;

PROCEDURE VTopic (): BOOLEAN;
VAR stem: ARRAY [0..255] OF CHAR;
BEGIN Ptcl.Arg(1, stem); LoadTopic(stem); RETURN TRUE END VTopic;

PROCEDURE VSnap (): BOOLEAN;
VAR path: ARRAY [0..511] OF CHAR;
BEGIN Ptcl.Arg(1, path); RETURN Cocoa.Snapshot(content, path) END VSnap;

PROCEDURE VTheme (): BOOLEAN;    (* switch editor colour theme: `theme <0..4>` *)
BEGIN ApplyThemeAll(VAL(CARDINAL, Ptcl.ArgInt(1))); RETURN TRUE END VTheme;

PROCEDURE VFormat (): BOOLEAN;   (* re-indent the active editor: `format` *)
VAR sel: INTEGER;
BEGIN
  sel := Cocoa.SelectedTab(tabs);
  IF sel < 0 THEN RETURN FALSE END;
  Cocoa.EditorText(gEditors[sel], gFmtIn);
  IF NOT M2Format.Format(gFmtIn, gFmtOut) THEN RETURN FALSE END;
  Cocoa.SetEditorText(gEditors[sel], gFmtOut);
  RETURN TRUE
END VFormat;

PROCEDURE VResize (): BOOLEAN;   (* resize the window content (drives the resize policy) *)
BEGIN [CAST(ObjC.Id, win) setContentSize: Size(FLOAT(Ptcl.ArgInt(1)), FLOAT(Ptcl.ArgInt(2)))]; RETURN TRUE END VResize;

PROCEDURE VOpen (): BOOLEAN;     (* open a file path in a new editor tab *)
VAR path: ARRAY [0..1023] OF CHAR;
BEGIN Ptcl.Arg(1, path); OpenPath(path, FALSE); RETURN TRUE END VOpen;

PROCEDURE VBuild (): BOOLEAN;    (* build & run the active tab: `build` — same path as the toolbar action *)
BEGIN BuildRunSelected(FALSE); RETURN TRUE END VBuild;

PROCEDURE VBuildOpt (): BOOLEAN; (* build & run optimized (--opt 2): `buildopt` *)
BEGIN BuildRunSelected(TRUE); RETURN TRUE END VBuildOpt;

PROCEDURE VStatTab (): BOOLEAN; (* `stattab` — switch to the live-state STAT tab *)
BEGIN ShowStatTab; RETURN TRUE END VStatTab;

PROCEDURE VCnsl (): BOOLEAN;    (* `cnsl <line>` — simulate typing a line + Enter in the console (headless test) *)
VAR line: ARRAY [0..16383] OF CHAR; full: ARRAY [0..262143] OF CHAR; idx: INTEGER; ig: BOOLEAN;
BEGIN
  Ptcl.Arg(1, line);
  ShowCnslTab;
  idx := CnslTabIdx(); IF idx < 0 THEN RETURN FALSE END;
  Cocoa.EditorText(gEditors[idx], full); Append(line, full); Cocoa.SetEditorText(gEditors[idx], full);
  ig := ConsoleEnter(gCnslTV);
  RETURN TRUE
END VCnsl;

PROCEDURE VDescribeAt (): BOOLEAN;   (* describe the symbol at (line,col) of the active tab -> help pane.
                                        This is exactly the hover payload (idx -> describe -> render). *)
VAR sel, n: INTEGER; md: ARRAY [0..16383] OF CHAR;
BEGIN
  sel := Cocoa.SelectedTab(tabs);
  IF (sel < 0) OR (gPaths[sel][0] = CHR(0)) THEN RETURN FALSE END;
  n := Proc.Describe(gPaths[sel], Ptcl.ArgInt(1), Ptcl.ArgInt(2), md);
  IF n > 0 THEN MarkView.Render(helpPane, md); HelpShow(TRUE) END;
  RETURN n > 0
END VDescribeAt;

PROCEDURE RegisterCmds;
BEGIN
  Ptcl.Register("help", VHelp);
  Ptcl.Register("topics", VTopics);
  Ptcl.Register("topic", VTopic);
  Ptcl.Register("describe", VDescribe);
  Ptcl.Register("search", VSearch);
  Ptcl.Register("snap", VSnap);
  Ptcl.Register("stattab", VStatTab);
  Ptcl.Register("cnsl", VCnsl);
  Ptcl.Register("theme", VTheme);
  Ptcl.Register("format", VFormat);
  Ptcl.Register("resize", VResize);
  Ptcl.Register("open", VOpen);
  Ptcl.Register("build", VBuild);
  Ptcl.Register("buildopt", VBuildOpt);
  Ptcl.Register("describeat", VDescribeAt)
END RegisterCmds;

(* poll /tmp/mf66.ptcl on the run loop; run + consume any script left there *)
PROCEDURE CmdTick (block, timer: ObjC.Id);
VAR n, ig, si: INTEGER; out: ARRAY [0..1023] OF CHAR; ok: BOOLEAN;
BEGIN
  BuildPoll;                              (* collect an async build/run when it ends *)
  (* NSSplitView overrides setPosition: on its first display pass, collapsing the
     output pane; re-pin it once now that the run loop (and real layout) is up. *)
  IF NOT gSplitInit THEN SetDivider(innerSplit, 0, 496.0); gSplitInit := TRUE END;  (* editor big, output a few lines *)
  (* poll the live-state dashboard while the STAT tab is the one showing *)
  si := StatTabIdx();
  IF (si >= 0) AND (Cocoa.SelectedTab(tabs) = si) THEN RefreshStat END;
  IF Proc.FileSize("/tmp/mf66.ptcl") > 0 THEN
    n  := Proc.ReadFile("/tmp/mf66.ptcl", gCmdBuf);
    ig := Proc.WriteFile("/tmp/mf66.ptcl", "");   (* consume so it runs once *)
    IF n > 0 THEN ok := Ptcl.Eval(gCmdBuf, out) END
  END
END CmdTick;

(* Serialize an editor straight from its rope to disk.  The text lives in the
   editor's NSTextStorage (the rope); `[[ed documentView] string]` is the whole
   document as an NSString, which writes ITSELF to the file.  No fixed M2 buffer
   ever holds the document, so nothing truncates however large it grows — this is
   the one and only way the IDE puts editor text on disk (save / autosave /
   build / the completion scratch all go through here).  4 = NSUTF8StringEncoding.
   Returns TRUE on success. *)
PROCEDURE SaveEditorTo (ed: Cocoa.Object; path: ARRAY OF CHAR): BOOLEAN;
VAR tv, str: ObjC.Id; ok: BOOLEAN;
BEGIN
  tv  := [CAST(ObjC.Id, ed) documentView];
  str := [tv string];
  ok  := [str writeToFile: ObjC.NSString(path) atomically: TRUE encoding: 4 error: NIL];
  RETURN ok
END SaveEditorTo;

(* the sidebar click action: open file (or descend into folder). Tags >= LibBase
   are library entries; below are project entries. *)
PROCEDURE CardStr (n: CARDINAL; VAR s: ARRAY OF CHAR);
VAR d: ARRAY [0..31] OF CHAR; i, j: CARDINAL;
BEGIN
  IF n = 0 THEN s[0] := '0'; s[1] := CHR(0); RETURN END;
  i := 0; WHILE n > 0 DO d[i] := CHR(ORD('0') + (n MOD 10)); n := n DIV 10; INC(i) END;
  j := 0; WHILE i > 0 DO DEC(i); s[j] := d[i]; INC(j) END; s[j] := CHR(0)
END CardStr;

(* ---- mf66 engine bridge: a file-mailbox to a persistent `mf66-tcl --serve`.
   The Modula-2 side has no persistent pipe, so the live Forth image is reached
   through request/response files. BridgeStart launches the engine once;
   BridgeSend posts `<seq>\n<tclcmd>` to req and busy-polls resp (which the engine
   writes atomically, prefixed with the echoed seq so it is never empty). ------ *)
CONST
  BridgeReq  = "/tmp/mf66bridge/req";
  BridgeResp = "/tmp/mf66bridge/resp";

(* Resolve the engine executables + examples. In a `.app` they sit beside the IDE
   (Contents/MacOS/mf66, /mf66-tcl) and in Contents/Resources/examples; running the
   bare dev binary, fall back to the MF66 build tree. *)
PROCEDURE InitPaths;
VAR execPath, dir: ARRAY [0..1023] OF CHAR; b: ObjC.Id; n: INTEGER;
BEGIN
  b := [Cls("NSBundle") mainBundle];
  n := ObjC.GetString([b executablePath], execPath);
  Assign(execPath, dir); ParentDir(dir);                 (* the dir holding mf66ide *)
  Assign(dir, gMf66); Append("/mf66", gMf66);
  IF Proc.FileSize(gMf66) <= 0 THEN Assign("/Users/oberon/claudeprojects/MF66/target/release/mf66", gMf66) END;
  IF Proc.FileSize(gMf66) <= 0 THEN Assign("/Users/oberon/claudeprojects/MF66/target/debug/mf66", gMf66) END;
  Assign(dir, gMf66Tcl); Append("/mf66-tcl", gMf66Tcl);
  IF Proc.FileSize(gMf66Tcl) <= 0 THEN Assign("/Users/oberon/claudeprojects/MF66/target/release/mf66-tcl", gMf66Tcl) END;
  IF Proc.FileSize(gMf66Tcl) <= 0 THEN Assign("/Users/oberon/claudeprojects/MF66/target/debug/mf66-tcl", gMf66Tcl) END;
  Assign(dir, gExamples); ParentDir(gExamples); Append("/Resources/examples", gExamples);
  IF NOT Proc.IsDir(gExamples) THEN Assign("/Users/oberon/claudeprojects/MF66/examples", gExamples) END
END InitPaths;

PROCEDURE BridgeStart;
VAR ig: INTEGER; cmd: ARRAY [0..1279] OF CHAR;
BEGIN
  gBridgeSeq := 0;
  Assign(gMf66Tcl, cmd); Append(" --serve /tmp/mf66bridge", cmd);
  ig := Proc.RunAsync(cmd)
END BridgeStart;

PROCEDURE BridgeSend (cmd: ARRAY OF CHAR; VAR resp: ARRAY OF CHAR);
VAR req, buf: ARRAY [0..65535] OF CHAR; seqs: ARRAY [0..31] OF CHAR;
    ig, n, i, nl, cap: INTEGER; got: BOOLEAN;
BEGIN
  INC(gBridgeSeq);
  CardStr(gBridgeSeq, seqs);
  Assign(seqs, req);
  i := VAL(INTEGER, Length(req)); req[i] := CHR(10); req[i+1] := CHR(0);   (* "<seq>\n" *)
  Append(cmd, req);                                                        (* "<seq>\n<cmd>" *)
  ig := Proc.WriteFile(BridgeResp, "");        (* clear: any non-empty resp now answers THIS request *)
  ig := Proc.WriteFile(BridgeReq, req);
  got := FALSE; cap := 0;
  WHILE (NOT got) AND (cap < 4000000) DO
    IF Proc.FileSize(BridgeResp) > 0 THEN
      n := Proc.ReadFile(BridgeResp, buf);
      IF n > 0 THEN
        nl := 0;                                                    (* skip the echoed seq line *)
        WHILE (buf[nl] # CHR(0)) AND (buf[nl] # CHR(10)) DO INC(nl) END;
        IF buf[nl] = CHR(10) THEN INC(nl) END;
        i := 0;
        WHILE buf[nl] # CHR(0) DO resp[i] := buf[nl]; INC(i); INC(nl) END;
        resp[i] := CHR(0);
        got := TRUE
      END
    END;
    INC(cap)
  END;
  IF NOT got THEN Assign("(no response from mf66 engine)", resp) END
END BridgeSend;

(* The permanent live-state inspector tab (sentinel path "*STAT*"): the `stat`
   verb returns a formatted data/fp/locals/state view; fetched when shown and
   polled by CmdTick while it is the active tab. *)
PROCEDURE StatTabIdx (): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < gTabCount DO IF Equal(gPaths[i], "*STAT*") THEN RETURN i END; INC(i) END;
  RETURN -1
END StatTabIdx;

PROCEDURE RefreshStat;
VAR buf: ARRAY [0..65535] OF CHAR; idx: INTEGER;
BEGIN
  idx := StatTabIdx();
  IF idx < 0 THEN RETURN END;
  BridgeSend("stat", buf);
  Cocoa.SetEditorText(gEditors[idx], buf)
END RefreshStat;

PROCEDURE CreateStatTab;
VAR ed, it: Cocoa.Object; tv: ObjC.Id;
BEGIN
  IF StatTabIdx() >= 0 THEN RETURN END;
  IF gTabCount > 63 THEN RETURN END;
  ed := CAST(Cocoa.Object, RopeEditor.Make(0.0, 0.0, 760.0, 420.0));
  Cocoa.SetEditorText(ed, "live engine state — fetched on open, then polled");
  tv := [CAST(ObjC.Id, ed) documentView];
  [tv setEditable: FALSE];
  it := Cocoa.AddTab(tabs, "STAT", ed);
  gEditors[gTabCount] := ed; Assign("*STAT*", gPaths[gTabCount]);
  Assign("STAT", gTabNames[gTabCount]); gReadOnly[gTabCount] := TRUE;
  INC(gTabCount);
  RebuildTabBar
END CreateStatTab;

PROCEDURE ShowStatTab;
VAR i: INTEGER;
BEGIN
  IF StatTabIdx() < 0 THEN CreateStatTab END;
  i := StatTabIdx();
  IF i >= 0 THEN
    [CAST(ObjC.Id, tabs) selectTabViewItemAtIndex: i];
    UpdateLexMode; RebuildTabBar; ShowTabStatus; RefreshStat        (* fetch on open *)
  END
END ShowStatTab;

(* ── CNSL: a live terminal to the persistent engine. Unlike the REPL tab (a
   transcript fed from the bottom command line), the CNSL pane is EDITABLE and you
   type directly at the prompt; Enter (via RopeEditor's hook -> ConsoleEnter)
   evaluates the typed line in place and appends the output + a fresh prompt. ── *)
PROCEDURE CnslTabIdx (): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < gTabCount DO IF Equal(gPaths[i], "*CNSL*") THEN RETURN i END; INC(i) END;
  RETURN -1
END CnslTabIdx;

PROCEDURE CreateCnslTab;
VAR ed, it: Cocoa.Object; wel: ARRAY [0..255] OF CHAR; k: INTEGER;
BEGIN
  IF CnslTabIdx() >= 0 THEN RETURN END;
  IF gTabCount > 63 THEN RETURN END;
  ed := CAST(Cocoa.Object, RopeEditor.Make(0.0, 0.0, 760.0, 420.0));
  Assign("MF66 console — a live terminal to the persistent Forth.  Type and press Enter.", wel);
  k := VAL(INTEGER, Length(wel)); wel[k] := CHR(10); wel[k+1] := CHR(0);   (* real newline, not \n *)
  Append("ok> ", wel);
  Cocoa.SetEditorText(ed, wel);
  gCnslTV := [CAST(ObjC.Id, ed) documentView];           (* editable; this view's Enter is the console *)
  it := Cocoa.AddTab(tabs, "CNSL", ed);
  gEditors[gTabCount] := ed; Assign("*CNSL*", gPaths[gTabCount]);
  Assign("CNSL", gTabNames[gTabCount]); gReadOnly[gTabCount] := FALSE;
  gCnslCompiling := FALSE;
  INC(gTabCount);
  RebuildTabBar
END CreateCnslTab;

PROCEDURE ShowCnslTab;
VAR i: INTEGER;
BEGIN
  IF CnslTabIdx() < 0 THEN CreateCnslTab END;
  i := CnslTabIdx();
  IF i >= 0 THEN
    [CAST(ObjC.Id, tabs) selectTabViewItemAtIndex: i];
    UpdateLexMode; RebuildTabBar; ShowTabStatus;
    [CAST(ObjC.Id, win) makeFirstResponder: gCnslTV]      (* type straight into the console *)
  END
END ShowCnslTab;

(* RopeEditor's Enter hook: handle Return in the CNSL pane (evaluate the typed
   line), or return FALSE so every other editor gets its normal auto-indent. *)
PROCEDURE ConsoleEnter (tv: ObjC.Id): BOOLEAN;
VAR full: ARRAY [0..262143] OF CHAR; input, cmd, out: ARRAY [0..65535] OF CHAR;
    comp: ARRAY [0..15] OF CHAR; nl: ARRAY [0..1] OF CHAR; idx, lng, st, ist, i: INTEGER;
BEGIN
  idx := CnslTabIdx();
  IF (idx < 0) OR (tv # gCnslTV) THEN RETURN FALSE END;
  Cocoa.EditorText(gEditors[idx], full);
  lng := VAL(INTEGER, Length(full));
  nl[0] := CHR(10); nl[1] := CHR(0);
  IF lng > 200000 THEN                                   (* keep the console bounded *)
    Assign("ok> ", full); Cocoa.SetEditorText(gEditors[idx], full);
    Cocoa.SetEditorCursor(gEditors[idx], 4); RETURN TRUE
  END;
  st := lng;                                             (* start of the last (input) line *)
  WHILE (st > 0) AND (full[st-1] # CHR(10)) DO DEC(st) END;
  ist := st;                                             (* skip the prompt prefix *)
  IF (st+4 <= lng) AND (full[st]='o') AND (full[st+1]='k') AND (full[st+2]='>') AND (full[st+3]=' ') THEN
    ist := st+4
  ELSE
    WHILE (ist < lng) AND (full[ist] = ' ') DO INC(ist) END
  END;
  i := 0; WHILE ist < lng DO input[i] := full[ist]; INC(i); INC(ist) END; input[i] := CHR(0);
  Assign("eval {", cmd); Append(input, cmd); Append("}", cmd);
  BridgeSend(cmd, out);
  Append(nl, full);                                      (* end the input line *)
  IF out[0] # CHR(0) THEN Append(out, full); Append(nl, full) END;
  BridgeSend("compiling", comp);
  gCnslCompiling := (comp[0] = '1');
  IF gCnslCompiling THEN Append("    ", full) ELSE Append("ok> ", full) END;
  Cocoa.SetEditorText(gEditors[idx], full);
  Cocoa.SetEditorCursor(gEditors[idx], VAL(INTEGER, Length(full)));
  [CAST(ObjC.Id, gCnslTV) scrollToEndOfDocument: NIL];   (* keep the newest line in view *)
  RETURN TRUE
END ConsoleEnter;

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

(* Load `full` into a new editor tab (read-only if isLib). Switches to an
   existing tab if the file is already open. The shared core of OpenDoc and the
   ptcl `open` verb. *)
PROCEDURE OpenPath (full: ARRAY OF CHAR; isLib: BOOLEAN);
VAR text: ARRAY [0..262143] OF CHAR; ed, it: Cocoa.Object; n, i: INTEGER; tv: ObjC.Id;
BEGIN
  (* already open? switch to its tab instead of loading a second copy *)
  i := 0;
  WHILE i < gTabCount DO
    IF Equal(gPaths[i], full) THEN
      [CAST(ObjC.Id, tabs) selectTabViewItemAtIndex: i];
      RebuildTabBar; Cocoa.SetText(status, "Already open — switched to its tab."); RETURN
    END;
    INC(i)
  END;
  n := Proc.ReadFile(full, text);
  IF n < 0 THEN RETURN END;
  (* Check capacity BEFORE adding the tab: the bookkeeping arrays are [0..63], so
     a 65th tab would otherwise be added to the NSTabView with no backing entry,
     desyncing the UI from gEditors/gPaths/gReadOnly. *)
  IF gTabCount > 63 THEN Cocoa.SetText(status, "Too many tabs open (max 64) — close one first."); RETURN END;
  ed := CAST(Cocoa.Object, RopeEditor.Make(0.0, 0.0, 760.0, 420.0));  (* rope-backed editor *)
  IF PathIsMasm(full) THEN RopeEditor.SetLexMode(1) ELSE RopeEditor.SetLexMode(0) END;
  Cocoa.SetEditorText(ed, text);                 (* colours itself with the right lexer *)
  tv := [CAST(ObjC.Id, ed) documentView];
  [tv setAllowsUndo: TRUE];       (* ⌘Z / ⌘⇧Z *)
  [tv setUsesFindBar: TRUE];      (* ⌘F find bar *)
  [tv setDelegate: ctrl];         (* autosave on edit + cursor status on selection *)
  IF isLib THEN
    [tv setEditable: FALSE];
    Cocoa.SetText(status, "Opened (read-only reference).")
  END;
  it := Cocoa.AddTab(tabs, full, ed);
  gEditors[gTabCount] := ed; Assign(full, gPaths[gTabCount]); gReadOnly[gTabCount] := isLib;
  Basename(full, gTabNames[gTabCount]);
  INC(gTabCount);
  RebuildTabBar; ShowTabStatus
END OpenPath;

(* Build & run the active tab — shared by the toolbar/menu action and the `build`
   ptcl verb. Fire-and-forget: launch the program on a WORKER THREAD
   (Proc.RunAsync) and return immediately. The IDE never blocks, never waits for a
   window to close, and never limits how many programs you run at once — launch as
   many as you like. The job is parked in a free slot only so its output / error
   marks can be shown WHEN it eventually exits; if every slot is busy it still
   runs, just untracked. Nothing is ever gated on a previous run. *)
PROCEDURE BuildRunSelected (optimized: BOOLEAN);
VAR sel, i, slot, job: INTEGER; cmd: ARRAY [0..2047] OF CHAR;
BEGIN
  sel := Cocoa.SelectedTab(tabs);
  IF sel < 0 THEN Cocoa.SetText(status, "Open a file first."); RETURN END;
  IF NOT SaveEditorTo(gEditors[sel], gPaths[sel]) THEN Cocoa.SetText(status, "Build failed — could not save buffer."); RETURN END;
  (* Run the active .f buffer through the MF66 Forth compiler/JIT. `< /dev/null`
     so mf66 runs the file then exits at EOF (no interactive REPL); 2>&1 folds
     errors into the captured output. The `--opt`-equivalent is mf66's own. *)
  Assign(gMf66, cmd); Append(" '", cmd);
  Append(gPaths[sel], cmd); Append("' < /dev/null 2>&1", cmd);
  job := Proc.RunAsync(cmd);
  IF job <= 0 THEN Cocoa.SetText(status, "Build failed — could not start."); RETURN END;
  slot := -1;
  FOR i := 0 TO MaxJobs-1 DO IF (slot < 0) AND (gJobs[i] = 0) THEN slot := i END END;
  IF slot >= 0 THEN gJobs[slot] := job; gJobTab[slot] := sel END;   (* else: runs untracked — never blocked *)
  IF optimized THEN Cocoa.SetText(status, "Building & running OPTIMIZED (--opt 2)…  (IDE stays live — launch as many as you like)")
  ELSE Cocoa.SetText(status, "Building & running…  (IDE stays live — launch as many as you like)") END
END BuildRunSelected;

(* Run-loop tick: reap any finished run and surface its output / error marks.
   Non-blocking: each still-running job is simply left alone. *)
PROCEDURE BuildPoll;
VAR i, rc, marked, errLine, tab: INTEGER;
BEGIN
  FOR i := 0 TO MaxJobs-1 DO
    IF gJobs[i] # 0 THEN
      IF Proc.RunDone(gJobs[i]) = 1 THEN
        rc := Proc.RunCollect(gJobs[i], gBuildOut);
        IF rc # -2 THEN                                  (* -2 = not ready; retry next tick *)
          tab := gJobTab[i];
          gJobs[i] := 0;
          Cocoa.SetEditorText(output, gBuildOut);
          IF (tab >= 0) AND (tab < gTabCount) THEN
            marked := Cocoa.MarkErrors(gEditors[tab], gBuildOut);
            IF rc = 0 THEN Cocoa.SetText(status, "A run finished (exit 0).")
            ELSE
              errLine := Cocoa.GotoFirstError(gEditors[tab], gBuildOut);
              IF errLine > 0 THEN Cocoa.SetText(status, "Build failed — jumped to first error.")
              ELSE Cocoa.SetText(status, "Run reported errors.") END
            END
          ELSE
            Cocoa.SetText(status, "A run finished.")
          END
        END
      END
    END
  END
END BuildPoll;

(* Strip the last "/component" of a path (go up a level). "a/b/c" -> "a/b";
   a path with no slash -> ".". *)
PROCEDURE ParentDir (VAR path: ARRAY OF CHAR);
VAR i, last: INTEGER;
BEGIN
  last := -1; i := 0;
  WHILE path[i] # CHR(0) DO IF path[i] = '/' THEN last := i END; INC(i) END;
  IF last < 0 THEN Assign(".", path)
  ELSIF last = 0 THEN path[1] := CHR(0)            (* "/x" -> "/" *)
  ELSE path[last] := CHR(0) END
END ParentDir;

PROCEDURE OpenDoc (tag: INTEGER);
VAR full: ARRAY [0..262143] OF CHAR; idx: INTEGER; isLib: BOOLEAN; name: ARRAY [0..255] OF CHAR;
BEGIN
  isLib := tag >= LibBase;
  IF isLib THEN idx := tag - LibBase;
    IF (idx < 0) OR (idx >= gLibCount) THEN RETURN END;
    Assign(gLibFiles[idx], name)
  ELSE idx := tag;
    IF (idx < 0) OR (idx >= gProjCount) THEN RETURN END;
    Assign(gProjFiles[idx], name)
  END;
  IF Equal(name, "..") THEN                          (* up a level *)
    IF isLib THEN ParentDir(gLibDir) ELSE ParentDir(gProjDir) END;
    RebuildList(isLib); RETURN
  END;
  IF isLib THEN Assign(gLibDir, full) ELSE Assign(gProjDir, full) END;
  Append("/", full); Append(name, full);
  IF Proc.IsDir(full) THEN                            (* descend into a subfolder *)
    IF isLib THEN Assign(full, gLibDir) ELSE Assign(full, gProjDir) END;
    RebuildList(isLib); RETURN
  END;
  OpenPath(full, isLib)
END OpenDoc;

(* The NSTextView completion data source, installed on the controller's class at
   startup (ObjC.AddMethod) for the selector

     textView:completions:forPartialWordRange:indexOfSelectedItem:

   which returns an NSArray of candidate strings and takes the text view, the
   default word list, an NSRange (the partial word) and an NSInteger out-pointer
   for the preselected row.  AppKit calls this from [tv complete: nil]; we return
   the candidate names and it draws/narrows the popup and inserts the chosen word
   itself.  It is a plain module-level procedure (NOT a class method) so its
   parameters map straight onto the Obj-C call registers: self, _cmd, then the
   four real arguments — and the 16-byte NSRange is taken as its two CARDINAL
   halves (rangeLoc/rangeLen) rather than a by-value record, so the ABI matches
   exactly and nothing is misread.

   It runs synchronously on the main thread; Proc.Complete is ~15 ms and, thanks
   to its runtime watchdog, can never block the UI even if the compiler wedges. *)
PROCEDURE Completions (self, cmd, tv, words: ObjC.Id;
                       rangeLoc, rangeLen: CARDINAL; idx: ObjC.Id): ObjC.Id;
VAR arr: ObjC.Id; sel, line, col, n, i, j: INTEGER; name: ARRAY [0..255] OF CHAR; ip: IntPtr;
BEGIN
  arr := [Cls("NSMutableArray") array];     (* the list AppKit will display *)
  IF idx # NIL THEN ip := CAST(IntPtr, idx); ip^ := 0 END;   (* preselect the first row *)
  sel := Cocoa.SelectedTab(tabs);
  IF (sel < 0) OR (gPaths[sel][0] = CHR(0)) THEN
    Cocoa.SetText(status, "no completion"); RETURN arr
  END;
  Cocoa.EditorCursor(gEditors[sel], line, col);              (* 1-based line / 0-based col *)
  n := Proc.Complete(gPaths[sel], line, col, gCandBuf);
  IF n <= 0 THEN Cocoa.SetText(status, "no completion"); RETURN arr END;
  (* Each line is name<TAB>kind<TAB>detail; we feed AppKit just the names. *)
  i := 0;
  WHILE gCandBuf[i] # CHR(0) DO
    j := 0;
    WHILE (gCandBuf[i] # CHR(0)) & (gCandBuf[i] # CHR(9)) & (gCandBuf[i] # CHR(10)) DO
      IF j <= 254 THEN name[j] := gCandBuf[i]; INC(j) END; INC(i)
    END;
    name[j] := CHR(0);
    WHILE (gCandBuf[i] # CHR(0)) & (gCandBuf[i] # CHR(10)) DO INC(i) END;   (* skip kind/detail *)
    IF gCandBuf[i] = CHR(10) THEN INC(i) END;
    IF name[0] # CHR(0) THEN [arr addObject: ObjC.NSString(name)] END
  END;
  Cocoa.SetText(status, "Completions — Tab/Enter to insert.");
  RETURN arr
END Completions;

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
    tv := [CAST(ObjC.Id, ed) documentView];
    [tv setAllowsUndo: TRUE];
    [tv setUsesFindBar: TRUE];
    [tv setDelegate: ctrl];
    it := Cocoa.AddTab(tabs, "untitled", ed);
    gEditors[gTabCount] := ed; gPaths[gTabCount][0] := CHR(0);   (* empty path = untitled *)
    gReadOnly[gTabCount] := FALSE; Assign("untitled", gTabNames[gTabCount]);
    INC(gTabCount);
    [CAST(ObjC.Id, tabs) selectTabViewItemAtIndex: gTabCount-1];
    RebuildTabBar;
    Cocoa.SetText(status, "New file — Save (Cmd-S) to name it.")
  END OnNew;
  PROCEDURE OnSaveAs (sender: ObjC.Id);            (* "onSaveAs:" — choose a path, then save *)
  VAR sel: INTEGER; path: ARRAY [0..1023] OF CHAR;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN RETURN END;
    IF NOT ObjC.SavePanel(path) THEN RETURN END;   (* user cancelled *)
    IF SaveEditorTo(gEditors[sel], path) THEN
      Assign(path, gPaths[sel]); gReadOnly[sel] := FALSE;
      Basename(path, gTabNames[sel]); RebuildTabBar;
      Cocoa.SetText(status, "Saved.")
    ELSE Cocoa.SetText(status, "Save As failed.") END
  END OnSaveAs;
  PROCEDURE OnSave (sender: ObjC.Id);              (* "onSave:" *)
  VAR sel: INTEGER;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN RETURN END;
    IF gReadOnly[sel] THEN Cocoa.SetText(status, "Library file is read-only (reference)."); RETURN END;
    IF gPaths[sel][0] = CHR(0) THEN SELF.OnSaveAs(sender); RETURN END;   (* untitled -> Save As *)
    IF SaveEditorTo(gEditors[sel], gPaths[sel]) THEN Cocoa.SetText(status, "Saved.") ELSE Cocoa.SetText(status, "Save failed.") END
  END OnSave;
  PROCEDURE OnBuildRun (sender: ObjC.Id);          (* "onBuildRun:" *)
  BEGIN BuildRunSelected(FALSE) END OnBuildRun;
  PROCEDURE OnBuildRunOpt (sender: ObjC.Id);       (* "onBuildRunOpt:" — build & run with --opt 2 *)
  BEGIN BuildRunSelected(TRUE) END OnBuildRunOpt;
  PROCEDURE OnHelp (sender: ObjC.Id);              (* "onHelp:" — F1 shows/hides the help pane *)
  BEGIN
    HelpShow(NOT gHelpVisible);
    IF gHelpVisible THEN Cocoa.SetText(status, "Help shown (F1 to hide).")
    ELSE Cocoa.SetText(status, "Help hidden (F1 to show).") END
  END OnHelp;
  PROCEDURE OnHome (sender: ObjC.Id);             (* "onHome:" — reveal help, restoring its text *)
  BEGIN
    MarkView.Render(helpPane, gHelpText);
    HelpShow(TRUE);
    Cocoa.SetText(status, "Home — welcome / help (F1 to hide).")
  END OnHome;
  PROCEDURE OnTheme (sender: ObjC.Id);            (* "onTheme:" — switch the editor colour theme *)
  VAR t: CARDINAL; nm, msg: ARRAY [0..63] OF CHAR;
  BEGIN
    t := VAL(CARDINAL, [sender tag]);
    ApplyThemeAll(t);
    RopeEditor.ThemeName(t, nm); Assign("Theme: ", msg); Append(nm, msg);
    Cocoa.SetText(status, msg)
  END OnTheme;
  PROCEDURE OnFormat (sender: ObjC.Id);           (* "onFormat:" — re-indent the active editor *)
  VAR sel: INTEGER;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN Cocoa.SetText(status, "Open a file first."); RETURN END;
    IF gReadOnly[sel] THEN Cocoa.SetText(status, "Library file is read-only (reference)."); RETURN END;
    Cocoa.EditorText(gEditors[sel], gFmtIn);
    IF M2Format.Format(gFmtIn, gFmtOut) THEN
      Cocoa.SetEditorText(gEditors[sel], gFmtOut);
      Cocoa.SetText(status, "Formatted — source re-indented.")
    ELSE
      Cocoa.SetText(status, "Format: file too large to re-indent.")
    END
  END OnFormat;
  PROCEDURE OnComplete (sender: ObjC.Id);         (* "onComplete:" — ⌘I : completion popup at the cursor *)
  (* Explicit trigger for the SAME native popup that typing '.' raises: ask the
     focused NSTextView to `complete:`, which calls our Completions data source
     and draws the narrowing list inline (Tab/Enter inserts).  No pane, no buffer,
     so the old crash path is gone. *)
  VAR sel: INTEGER; tv: ObjC.Id;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN Cocoa.SetText(status, "Open a file first."); RETURN END;
    IF gPaths[sel][0] = CHR(0) THEN Cocoa.SetText(status, "Save the file first to enable completions."); RETURN END;
    tv := [CAST(ObjC.Id, gEditors[sel]) documentView];
    [tv complete: NIL]
  END OnComplete;
  PROCEDURE OnDescribe (sender: ObjC.Id);         (* "onDescribe:" — context help for the symbol at the cursor *)
  (* Ask the compiler's `describe` engine for the symbol under the cursor and show
     its real signature / module / siblings in the help pane (vs. the static blob).
     Saved-file only: describe reads from disk, which autosave keeps current. *)
  BEGIN DescribeCursor END OnDescribe;
  PROCEDURE OnTopics (sender: ObjC.Id);           (* "onTopics:" — open the guide index in the help pane *)
  BEGIN LoadTopic("index"); Cocoa.SetText(status, "Help topics — click a link to navigate.") END OnTopics;
  PROCEDURE OnLink (tv, link: ObjC.Id; idx: CARDINAL): BOOLEAN <* selector "textView:clickedOnLink:atIndex:" *>;
  (* NSTextView delegate: a click on a rendered [text](target) link. The NSLink
     value is the target string MarkView stored; route it through HelpNavigate. *)
  VAR tgt: ARRAY [0..1023] OF CHAR; ig: INTEGER;
  BEGIN
    ig := ObjC.GetString(link, tgt);
    HelpNavigate(tgt);
    RETURN TRUE
  END OnLink;
  PROCEDURE OnCocoaSearch (sender: ObjC.Id);      (* "onCocoaSearch:" — unified help + Cocoa search *)
  (* Search both the guide docs (docs/m2-guide/*.md) and the Obj-C class list,
     and render the combined results as markdown in the help pane; guide hits are
     clickable topic links (OnLink -> HelpNavigate -> LoadTopic). *)
  VAR q: ARRAY [0..16383] OF CHAR; n: INTEGER; sv: ObjC.Id;
  BEGIN
    sv := [CAST(ObjC.Id, searchField) stringValue];
    n := ObjC.GetString(sv, q);
    RunSearch(q)
  END OnCocoaSearch;
  PROCEDURE OnStatTab (sender: ObjC.Id);          (* "onStatTab:" — jump to the live-state STAT tab *)
  BEGIN ShowStatTab END OnStatTab;
  PROCEDURE OnCnslTab (sender: ObjC.Id);          (* "onCnslTab:" — jump to the CNSL terminal tab *)
  BEGIN ShowCnslTab END OnCnslTab;
  PROCEDURE OnClose (sender: ObjC.Id);            (* "onClose:" — close the active tab (⌘W) *)
  BEGIN CloseTabAt(Cocoa.SelectedTab(tabs)) END OnClose;
  PROCEDURE OnCloseTab (sender: ObjC.Id);         (* "onCloseTab:" — the ✕ on a tab *)
  BEGIN CloseTabAt(TagOf(sender)) END OnCloseTab;
  PROCEDURE OnSelectTab (sender: ObjC.Id);        (* "onSelectTab:" — click a tab name *)
  BEGIN
    [CAST(ObjC.Id, tabs) selectTabViewItemAtIndex: TagOf(sender)];
    UpdateLexMode;
    RebuildTabBar; ShowTabStatus
  END OnSelectTab;
  PROCEDURE TextViewDidChangeSelection (note: ObjC.Id) <* selector "textViewDidChangeSelection:" *>;
  BEGIN ShowTabStatus END TextViewDidChangeSelection;
  PROCEDURE WindowDidResize (note: ObjC.Id) <* selector "windowDidResize:" *>;   (* keep the 3-column policy on resize *)
  BEGIN Relayout END WindowDidResize;
  PROCEDURE TextDidChange (note: ObjC.Id);        (* NSText delegate "textDidChange:" — autosave + completion trigger *)
  (* Autosave is just another rope-to-disk write — no buffer, no truncation,
     whatever the document size.  Then, if the character just typed is a '.', raise
     the completion popup: we read the char immediately left of the insertion point
     and, on a dot, ask the text view to `complete:` on the NEXT run-loop turn
     (afterDelay: 0) — deferring past this edit notification is what AppKit wants,
     and it keeps us off any re-entrant edit.  Typing more letters narrows the list
     (the char before the caret is then a letter, so this does not re-fire). *)
  VAR sel: INTEGER; tv, str: ObjC.Id; r: ObjC.NSRange; ch: CARDINAL;
  BEGIN
    sel := Cocoa.SelectedTab(tabs);
    IF sel < 0 THEN RETURN END;
    IF gPaths[sel][0] # CHR(0) THEN                 (* untitled: no autosave until named *)
      IF SaveEditorTo(gEditors[sel], gPaths[sel]) THEN Cocoa.SetText(status, "Autosaved.") END
    END;
    tv := [note object];                            (* the NSTextView that changed *)
    r  := [tv selectedRange];
    IF r.location > 0 THEN
      str := [tv string];
      ch  := [str characterAtIndex: r.location - 1];
      IF ch = Dot THEN
        [tv performSelector: ObjC.Selector("complete:") withObject: NIL afterDelay: 0.0]
      END
    END
  END TextDidChange;
END IDE;

(* --- live status-bar clock, driven by an Obj-C block ----------------------- *)
(* Tick: an NSTimer block whose invoke ABI is void (^)(NSTimer), so as a plain M2
   procedure its FIRST parameter is the block itself, then the timer.  ObjC.MakeBlock
   wraps it; the Cocoa run loop calls back into Modula-2 every second.  It reads
   module globals (gFmt, clock); the block is global/capture-free, exactly what
   MakeBlock provides. *)
PROCEDURE Tick (block, timer: ObjC.Id);
VAR now: ObjC.Id; buf: ARRAY [0..63] OF CHAR; n: INTEGER;
BEGIN
  now := [gFmt stringFromDate: [Cls("NSDate") date]];
  n := ObjC.GetString(now, buf);
  Cocoa.SetText(clock, buf)
END Tick;

VAR ide: IDE; appObj, menuBar, mApp, mFile, mEdit, mBuild, mTheme, mFormat, mHelp, findItem: ObjC.Id;
    f1key, upKey, downKey: ARRAY [0..2] OF CHAR;
    okAdd: BOOLEAN;
    gi: INTEGER;
BEGIN
  gProjBtnCount := 0; gLibBtnCount := 0; gTabCount := 0; gSplitInit := FALSE;
  FOR gi := 0 TO MaxJobs-1 DO gJobs[gi] := 0 END;
  InitPaths;                             (* resolve mf66 / mf66-tcl / examples first *)
  BridgeStart;                           (* then launch the persistent engine (file-mailbox) *)
  Assign(gExamples, gProjDir);
  Assign(gExamples, gLibDir);

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(1100.0, 640.0, "MF66 Forth IDE");
  [CAST(ObjC.Id, win) setDelegate: ctrl];                  (* windowDidResize: -> Relayout *)
  [CAST(ObjC.Id, win) setContentMinSize: Size(1000.0, 560.0)];   (* keep sidebar+editor+help all usable *)
  content := Cocoa.ContentView(win);
  NEW(ide); ctrl := CAST(ObjC.Id, ide);
  (* Install the completion data source on the controller's Obj-C class.  Its
     ABI (an NSRange split into two CARDINALs, an NSInteger* out-param, an NSArray
     return) does not fit the `<* cocoa *>` method shape, so it is a hand-written
     IMP added at runtime. Encoding: @ ret, @: self/_cmd, @@ tv/words, QQ the
     NSRange halves, ^q the NSInteger*. *)
  okAdd := ObjC.AddMethod(CAST(ObjC.Class, [ctrl class]),
                          ObjC.Selector("textView:completions:forPartialWordRange:indexOfSelectedItem:"),
                          CAST(ADDRESS, Completions), "@@:@@QQ^q");

  Cocoa.AddSubview(content, CtrlButton(8.0,   604.0, 56.0,  "New", "onNew:", 8));
  Cocoa.AddSubview(content, CtrlButton(68.0,  604.0, 64.0,  "Open", "onOpen:", 8));
  Cocoa.AddSubview(content, CtrlButton(136.0, 604.0, 56.0,  "Save", "onSave:", 8));
  Cocoa.AddSubview(content, CtrlButton(196.0, 604.0, 104.0, "Build & Run", "onBuildRun:", 8));
  Cocoa.AddSubview(content, CtrlButton(304.0, 604.0, 90.0,  "▸ CNSL", "onCnslTab:", 8));
  Cocoa.AddSubview(content, CtrlButton(398.0, 604.0, 90.0,  "▸ STAT", "onStatTab:", 8));
  (* bottom status bar: messages on the left, current-tab editor status on the right *)
  status := Cocoa.MakeLabel(10.0, 4.0, 700.0, 18.0, "Ready.");
  [CAST(ObjC.Id, status) setAutoresizingMask: 34];      (* width + stick bottom *)
  Cocoa.AddSubview(content, status);
  editStat := Cocoa.MakeLabel(720.0, 4.0, 270.0, 18.0, "");
  [CAST(ObjC.Id, editStat) setAutoresizingMask: 33];    (* stick bottom-right *)
  Cocoa.AddSubview(content, editStat);
  clock := Cocoa.MakeLabel(995.0, 4.0, 95.0, 18.0, "");                 (* set live by the NSTimer block *)
  [CAST(ObjC.Id, clock) setAutoresizingMask: 33];
  Cocoa.AddSubview(content, clock);
  (* Cocoa class search box — type a name + Enter to search the live Obj-C runtime *)
  searchField := [[Cls("NSSearchField") alloc] init];
  [CAST(ObjC.Id, searchField) setFrame: Rect(700.0, 605.0, 280.0, 26.0)];
  [CAST(ObjC.Id, searchField) setTarget: ctrl];
  [CAST(ObjC.Id, searchField) setAction: ObjC.Selector("onCocoaSearch:")];
  [[CAST(ObjC.Id, searchField) cell] setPlaceholderString: ObjC.NSString("Search help…")];
  [CAST(ObjC.Id, searchField) setAutoresizingMask: 9];  (* stick top-right *)
  Cocoa.AddSubview(content, searchField);
  (* Home button — above the help pane (top-right); reveals the help/welcome pane *)
  Cocoa.AddSubview(content, CtrlButton(1006.0, 604.0, 86.0, "Home", "onHome:", 9));

  outerSplit := MakeSplit(0.0, 26.0, 1100.0, 570.0, TRUE);   (* leave 0..26 for the status bar *)
  [CAST(ObjC.Id, outerSplit) setAutoresizingMask: 18];
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
  [CAST(ObjC.Id, tabs) setTabViewType: 6];     (* NSNoTabsNoBorder *)
  [CAST(ObjC.Id, tabs) setAutoresizingMask: 18];
  tabBar := MakeScrollH(0.0, 362.0, 860.0, 28.0, tabDoc);
  [CAST(ObjC.Id, tabBar) setAutoresizingMask: 10];  (* width + stick to top *)
  Cocoa.AddSubview(editorArea, tabs);
  Cocoa.AddSubview(editorArea, tabBar);
  gTabBarCount := 0;

  output := MakeFillEditor(0.0, 0.0, 860.0, 200.0);
  Cocoa.SetEditorText(output, "(build output appears here — Build & Run marks error lines red)");
  Cocoa.AddSubview(innerSplit, editorArea);
  Cocoa.AddSubview(innerSplit, output);

  (* third pane: help (F1 toggles it) — collapsed initially *)
  helpPane := MakeFillEditor(0.0, 0.0, 320.0, 596.0);
  gHelpText[0] := CHR(0); helpNL[0] := CHR(10); helpNL[1] := CHR(0);
  HL("# MF66 Forth IDE");
  HL("A native workbench for **MF66** — an optimizing Forth for Apple Silicon.");
  HL("Press **F1** to toggle this pane.");
  HL("");
  HL("## Panes & tabs");
  HL("- **PROJECT / LIBRARY** (left): your `.f` / `.masm` files — click to open a tab.");
  HL("- **CNSL** tab: a live terminal to the persistent Forth. Type at the prompt; **Enter** runs it.");
  HL("- **STAT** tab: live engine state — data / return / float / local stacks, base, words.");
  HL("- **Output** (bottom): Build & Run output; errors marked red.");
  HL("");
  HL("## Toolbar");
  HL("- **Build & Run** — run the active `.f` file through `mf66`; an error reddens + jumps to its line.");
  HL("- **▸ CNSL** / **▸ STAT** — jump to the console or live-state tab.");
  HL("");
  HL("## The console");
  HL("`:` opens a **multi-line definition** — the prompt continues until `;`. Any other line runs at once.");
  HL("");
  HL("## Forth quick reference");
  HL("- Define:  `: square dup * ;`  ·  run:  `5 square .`");
  HL("- Stack:  `dup drop swap over rot nip tuck`  ·  show:  `.s`");
  HL("- Maths:  `+ - * / mod negate abs`  ·  compare:  `= < > 0= 0< <>`");
  HL("- Floats:  `1.5e 2.5e f+ f.`  ·  `fsqrt fsin fdup`");
  HL("- Control:  `if … else … then`  ·  `begin … until`  ·  `?do … loop`  ·  `i`");
  HL('- Text:  `s" a string"`  ·  print:  `." hello" cr`');
  HL("- Numbers:  `42`  `-5`  `$ff` (hex)  `3.14e` (float)");
  HL("");
  HL("## Example");
  HL("```");
  HL("\ iterative Fibonacci");
  HL(": fib  ( n -- ) 0 1 rot 0 ?do over + swap loop drop ;");
  HL("10 fib .   \ 55");
  HL("```");
  [[CAST(ObjC.Id, helpPane) documentView] setDelegate: ctrl];   (* link clicks -> OnLink *)
  MarkView.Render(helpPane, gHelpText);
  (* the help / Assist pane joins rightStack (as the rightmost pane) only when
     shown — see HelpShow; hidden, it is removed so the editor fills with no band *)
  gHelpVisible := FALSE;

  (* a real menu bar (App / File / Build / Help), set before RunApp *)
  appObj := [Cls("NSApplication") sharedApplication];
  menuBar := [[Cls("NSMenu") alloc] init];
  mApp := AddMenu(menuBar, "MF66");
  AddItem(mApp, appObj, "About MF66 Forth IDE", "orderFrontStandardAboutPanel:", "", 0);
  AddItem(mApp, appObj, "Quit MF66 Forth IDE", "terminate:", "q", 0);
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
  findItem := [[Cls("NSMenuItem") alloc] initWithTitle: ObjC.NSString("Find…")   (* Find… ⌘F *)
                                         action: ObjC.Selector("performFindPanelAction:")
                                         keyEquivalent: ObjC.NSString("f")];
  [findItem setTag: 1];    (* NSFindPanelActionShowFindInterface *)
  [mEdit addItem: findItem];
  mBuild := AddMenu(menuBar, "Build");
  AddItem(mBuild, ctrl, "Build & Run", "onBuildRun:", "r", 0);
  AddItem(mBuild, ctrl, "Build & Run Optimized", "onBuildRunOpt:", "r", 1179648);  (* Cmd-Shift-R, --opt 2 *)
  mFormat := AddMenu(menuBar, "Format");                     (* source re-indenter *)
  AddItem(mFormat, ctrl, "Re-indent Source", "onFormat:", "i", 180000H);  (* ⌥⌘I *)
  mTheme := AddMenu(menuBar, "Theme");                       (* editor colour schemes *)
  AddTagItem(mTheme, ctrl, "Default", "onTheme:", 0);
  AddTagItem(mTheme, ctrl, "Monochrome", "onTheme:", 1);
  AddTagItem(mTheme, ctrl, "Amber CRT", "onTheme:", 2);
  AddTagItem(mTheme, ctrl, "Green CRT", "onTheme:", 3);
  AddTagItem(mTheme, ctrl, "Turbo Pascal", "onTheme:", 4);
  mHelp := AddMenu(menuBar, "Help");
  f1key[0] := CHR(0F704H); f1key[1] := CHR(0);            (* NSF1FunctionKey *)
  AddItem(mHelp, ctrl, "Show / Hide Help", "onHelp:", f1key, 800000H);  (* function-key modifier *)
  AddItem(mHelp, ctrl, "Describe Symbol at Cursor", "onDescribe:", "j", 0);  (* ⌘J context help *)
  AddItem(mHelp, ctrl, "Help Topics", "onTopics:", "y", 0);                  (* ⌘Y guide index *)
  [appObj setMainMenu: menuBar];

  Cocoa.SetListAction(OpenDoc);
  RebuildList(FALSE);          (* project *)
  RebuildList(TRUE);           (* library *)
  IF gProjCount > 0 THEN OpenDoc(0) END;
  RopeEditor.SetEnterProc(ConsoleEnter); (* Return in the CNSL pane runs the typed line *)
  CreateStatTab; CreateCnslTab;          (* live-state + console tabs open automatically *)
  ShowCnslTab;                           (* the console is the interactive surface on launch *)

  Cocoa.ShowWindow(win);                 (* show first so the splits have laid out *)
  SetDivider(innerSplit, 0, 496.0);      (* editor big; build output is a few lines — re-pinned on first tick *)
  SetDivider(sidebar, 0, 360.0);         (* project over library (height) *)
  Relayout;                              (* apply the 3-column width policy (sidebar 160; help when shown) *)
  gHelpVisible := FALSE;                  (* help starts out of the split (editor fills) *)
  Cocoa.SetText(status, "Ready — PROJECT (top) and LIBRARY (bottom). F1 = help.");

  (* Live clock in the status bar, driven by an Obj-C block (ObjC.MakeBlock):
     the Cocoa run loop fires the NSTimer every second and calls Tick - an M2
     procedure — back through the block.  Proof the M2 -> block bridge works. *)
  gFmt := [[Cls("NSDateFormatter") alloc] init];
  [gFmt setDateFormat: ObjC.NSString("HH:mm:ss")];
  [Cls("NSTimer") scheduledTimerWithTimeInterval: 1.0
                  repeats: TRUE
                  block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
  Tick(NIL, NIL);                        (* show the time immediately *)

  (* Hover help: the window generates mouseMoved: events to the focused editor,
     which reports the char index under the pointer; a 0.35s dwell timer then
     describes that symbol into the help pane (when it is open). *)
  gHovMoved := FALSE; gHovPending := FALSE; gHovIdx := 0; gHovLine := 0; gHovCol := 0;
  RopeEditor.SetHoverProc(HoverMove);
  [CAST(ObjC.Id, win) setAcceptsMouseMovedEvents: TRUE];
  [Cls("NSTimer") scheduledTimerWithTimeInterval: 0.35
                  repeats: TRUE
                  block: ObjC.MakeBlock(CAST(ADDRESS, HoverTick))];

  (* ptcl automation channel: register IDE verbs and poll /tmp/mf66.ptcl. *)
  RegisterCmds;
  [Cls("NSTimer") scheduledTimerWithTimeInterval: 0.25
                  repeats: TRUE
                  block: ObjC.MakeBlock(CAST(ADDRESS, CmdTick))];

  Cocoa.RunApp;
  WriteString("MF66 Forth IDE closed."); WriteLn
END mf66ide.
