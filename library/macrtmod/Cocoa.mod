IMPLEMENTATION MODULE Cocoa;

FROM SYSTEM IMPORT ADDRESS, CAST;
IMPORT ObjC;

CONST
  StyleTitledClosableMinResize = 15;   (* titled|closable|miniaturizable|resizable *)
  BackingBuffered = 2;                  (* NSBackingStoreBuffered *)
  PolicyRegular = 0;                    (* NSApplicationActivationPolicyRegular *)
  PngLater = 0;

VAR
  gApp: Object;
  (* cached objc_msgSend, cast to each ABI signature once *)
  send0: ObjC.Send0;
  sendI: ObjC.SendI;
  sendP: ObjC.SendP;
  sendB: ObjC.SendB;
  sendF: ObjC.SendF;
  sendFrame: ObjC.SendFrame;
  sendRect: ObjC.SendRect;
  send0I: ObjC.Send0I;
  sendPI: ObjC.SendPI;
  (* button-action trampoline state *)
  gTrampReady: BOOLEAN;
  gTramp: Object;
  gActions: ARRAY [0..255] OF ActionProc;
  gActionCount: INTEGER;
  (* file-list (indexed) action *)
  gListAction: IndexAction;
  gListSet: BOOLEAN;

PROCEDURE Sel (name: ARRAY OF CHAR): ObjC.SEL;
BEGIN RETURN ObjC.Selector(name) END Sel;

PROCEDURE Cls (name: ARRAY OF CHAR): ObjC.Class;
BEGIN RETURN ObjC.GetClass(name) END Cls;

PROCEDURE InitApp;
VAR ignore: Object;
BEGIN
  gApp := send0(Cls("NSApplication"), Sel("sharedApplication"));
  ignore := sendI(gApp, Sel("setActivationPolicy:"), PolicyRegular)
END InitApp;

PROCEDURE RunFor (seconds: REAL);
BEGIN ObjC.Pump(seconds) END RunFor;

PROCEDURE RunApp;
BEGIN ObjC.RunApp END RunApp;

PROCEDURE MakeWindow (width, height: REAL; title: ARRAY OF CHAR): Window;
VAR w: Window; ignore: Object;
BEGIN
  w := send0(Cls("NSWindow"), Sel("alloc"));
  w := sendRect(w, Sel("initWithContentRect:styleMask:backing:defer:"),
                0.0, 0.0, width, height,
                StyleTitledClosableMinResize, BackingBuffered, FALSE);
  ignore := sendP(w, Sel("setTitle:"), ObjC.NSString(title));  (* setTitle: is void — keep w *)
  RETURN w
END MakeWindow;

PROCEDURE ContentView (w: Window): View;
BEGIN RETURN send0(w, Sel("contentView")) END ContentView;

PROCEDURE ShowWindow (w: Window);
VAR ignore: Object;
BEGIN
  ignore := send0(w, Sel("center"));
  ignore := sendP(w, Sel("makeKeyAndOrderFront:"), NIL)
END ShowWindow;

PROCEDURE AddSubview (parent, child: View);
VAR ignore: Object;
BEGIN ignore := sendP(parent, Sel("addSubview:"), child) END AddSubview;

PROCEDURE RemoveView (child: View);
VAR ignore: Object;
BEGIN ignore := send0(child, Sel("removeFromSuperview")) END RemoveView;

PROCEDURE Snapshot (view: View; path: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN ObjC.SnapshotView(view, path) END Snapshot;

PROCEDURE MakeLabel (x, y, w, h: REAL; text: ARRAY OF CHAR): Control;
VAR l: Control; ignore: Object;
BEGIN
  l := send0(Cls("NSTextField"), Sel("alloc"));
  l := sendFrame(l, Sel("initWithFrame:"), x, y, w, h);
  ignore := sendP(l, Sel("setStringValue:"), ObjC.NSString(text));
  ignore := sendB(l, Sel("setBezeled:"), FALSE);
  ignore := sendB(l, Sel("setEditable:"), FALSE);
  ignore := sendB(l, Sel("setDrawsBackground:"), FALSE);
  RETURN l
END MakeLabel;

PROCEDURE SetText (control: Control; text: ARRAY OF CHAR);
VAR ignore: Object;
BEGIN ignore := sendP(control, Sel("setStringValue:"), ObjC.NSString(text)) END SetText;

PROCEDURE MakeEditor (x, y, w, h: REAL): View;
VAR scroll, tv, font: Object; ignore: Object;
BEGIN
  scroll := send0(Cls("NSScrollView"), Sel("alloc"));
  scroll := sendFrame(scroll, Sel("initWithFrame:"), x, y, w, h);
  ignore := sendB(scroll, Sel("setHasVerticalScroller:"), TRUE);
  tv := send0(Cls("NSTextView"), Sel("alloc"));
  tv := sendFrame(tv, Sel("initWithFrame:"), 0.0, 0.0, w, h);
  font := sendF(Cls("NSFont"), Sel("userFixedPitchFontOfSize:"), 13.0);
  ignore := sendP(tv, Sel("setFont:"), font);
  ignore := sendP(scroll, Sel("setDocumentView:"), tv);
  RETURN scroll
END MakeEditor;

PROCEDURE SetEditorText (editor: View; text: ARRAY OF CHAR);
VAR tv: Object; ignore: Object;
BEGIN
  tv := send0(editor, Sel("documentView"));
  ignore := sendP(tv, Sel("setString:"), ObjC.NSString(text))
END SetEditorText;

PROCEDURE EditorText (editor: View; VAR dest: ARRAY OF CHAR);
VAR tv, s: Object; n: INTEGER;
BEGIN
  tv := send0(editor, Sel("documentView"));
  s := send0(tv, Sel("string"));
  n := ObjC.GetString(s, dest)
END EditorText;

PROCEDURE HighlightEditor (editor: View);
BEGIN ObjC.Highlight(send0(editor, Sel("documentView"))) END HighlightEditor;

PROCEDURE MarkErrors (editor: View; compilerOutput: ARRAY OF CHAR): INTEGER;
BEGIN RETURN ObjC.MarkErrors(send0(editor, Sel("documentView")), compilerOutput) END MarkErrors;

PROCEDURE EditorCursor (editor: View; VAR line, col: INTEGER);
BEGIN ObjC.CursorPos(send0(editor, Sel("documentView")), line, col) END EditorCursor;

PROCEDURE SetEditorCursor (editor: View; offset: INTEGER);
BEGIN ObjC.SetCursor(send0(editor, Sel("documentView")), offset) END SetEditorCursor;

PROCEDURE GotoFirstError (editor: View; compilerOutput: ARRAY OF CHAR): INTEGER;
BEGIN RETURN ObjC.GotoFirstError(send0(editor, Sel("documentView")), compilerOutput) END GotoFirstError;

(* The Objective-C action method shared by every Cocoa button. It reads the
   sender's tag and invokes the Modula-2 ActionProc registered at that index. *)
PROCEDURE TrampDispatch (self, cmd, sender: ObjC.Id);
VAR idx: INTEGER;
BEGIN
  idx := send0I(sender, Sel("tag"));
  IF (idx >= 0) AND (idx < gActionCount) THEN
    gActions[idx]()
  END
END TrampDispatch;

(* Shared action for project file buttons: invoke the registered IndexAction
   with the clicked button's tag (its row index). *)
PROCEDURE TrampIndex (self, cmd, sender: ObjC.Id);
VAR idx: INTEGER;
BEGIN
  idx := send0I(sender, Sel("tag"));
  IF gListSet THEN gListAction(idx) END
END TrampIndex;

PROCEDURE EnsureTramp;
VAR cls: ObjC.Class; ok: BOOLEAN;
BEGIN
  IF gTrampReady THEN RETURN END;
  cls := ObjC.AllocateClass(Cls("NSObject"), "M2CocoaTrampoline");
  ok := ObjC.AddMethod(cls, Sel("m2act:"), CAST(ADDRESS, TrampDispatch), "v@:@");
  ok := ObjC.AddMethod(cls, Sel("m2idx:"), CAST(ADDRESS, TrampIndex), "v@:@");
  ObjC.RegisterClass(cls);
  gTramp := send0(send0(cls, Sel("alloc")), Sel("init"));
  gTrampReady := TRUE
END EnsureTramp;

PROCEDURE SetListAction (action: IndexAction);
BEGIN EnsureTramp; gListAction := action; gListSet := TRUE END SetListAction;

PROCEDURE MakeFileButton (x, y, w, h: REAL; label: ARRAY OF CHAR; index: INTEGER): Control;
VAR b: Control; ignore: Object;
BEGIN
  EnsureTramp;
  b := send0(Cls("NSButton"), Sel("alloc"));
  b := sendFrame(b, Sel("initWithFrame:"), x, y, w, h);
  ignore := sendP(b, Sel("setTitle:"), ObjC.NSString(label));
  ignore := sendI(b, Sel("setTag:"), index);
  ignore := sendI(b, Sel("setBezelStyle:"), 1);          (* rounded/regular *)
  ignore := sendP(b, Sel("setTarget:"), gTramp);
  ignore := sendP(b, Sel("setAction:"), Sel("m2idx:"));
  RETURN b
END MakeFileButton;

PROCEDURE MakeTabView (x, y, w, h: REAL): View;
VAR t: View;
BEGIN
  t := send0(Cls("NSTabView"), Sel("alloc"));
  t := sendFrame(t, Sel("initWithFrame:"), x, y, w, h);
  RETURN t
END MakeTabView;

PROCEDURE AddTab (tabs: View; label: ARRAY OF CHAR; content: View): Object;
VAR item, ignore: Object;
BEGIN
  item := send0(Cls("NSTabViewItem"), Sel("alloc"));
  item := sendP(item, Sel("initWithIdentifier:"), NIL);
  ignore := sendP(item, Sel("setLabel:"), ObjC.NSString(label));
  ignore := sendP(item, Sel("setView:"), content);
  ignore := sendP(tabs, Sel("addTabViewItem:"), item);
  ignore := sendP(tabs, Sel("selectTabViewItem:"), item);
  RETURN item
END AddTab;

PROCEDURE TabCount (tabs: View): INTEGER;
BEGIN RETURN send0I(tabs, Sel("numberOfTabViewItems")) END TabCount;

PROCEDURE SelectedTab (tabs: View): INTEGER;
VAR item: Object;
BEGIN
  item := send0(tabs, Sel("selectedTabViewItem"));
  IF item = NIL THEN RETURN -1 END;
  RETURN sendPI(tabs, Sel("indexOfTabViewItem:"), item)
END SelectedTab;

PROCEDURE SelectTab (tabs: View; index: INTEGER);
VAR ignore: Object;
BEGIN ignore := sendI(tabs, Sel("selectTabViewItemAtIndex:"), index) END SelectTab;

PROCEDURE OpenFolder (VAR path: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN ObjC.OpenFolderPanel(path) END OpenFolder;

PROCEDURE MakeButton (x, y, w, h: REAL; title: ARRAY OF CHAR;
                      action: ActionProc): Control;
VAR b: Control; idx: INTEGER; ignore: Object;
BEGIN
  EnsureTramp;
  idx := gActionCount;
  gActions[idx] := action;
  INC(gActionCount);
  b := send0(Cls("NSButton"), Sel("alloc"));
  b := sendFrame(b, Sel("initWithFrame:"), x, y, w, h);
  ignore := sendP(b, Sel("setTitle:"), ObjC.NSString(title));
  ignore := sendI(b, Sel("setTag:"), idx);
  ignore := sendP(b, Sel("setTarget:"), gTramp);
  ignore := sendP(b, Sel("setAction:"), Sel("m2act:"));
  RETURN b
END MakeButton;

PROCEDURE OpenFile (VAR path: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN ObjC.OpenPanel(path) END OpenFile;

PROCEDURE SaveFile (VAR path: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN ObjC.SavePanel(path) END SaveFile;

PROCEDURE Click (button: Control);
(* Synthetic click for scripting/headless testing: dispatch the registered
   ActionProc by the button's tag — the same procedure AppKit's target/action
   trampoline calls on a real click, but without needing a running event loop
   (performClick: / live dispatch require one). *)
VAR idx: INTEGER;
BEGIN
  idx := send0I(button, Sel("tag"));
  IF (idx >= 0) AND (idx < gActionCount) THEN
    gActions[idx]()
  END
END Click;

BEGIN
  gActionCount := 0;
  gTrampReady := FALSE;
  gListSet := FALSE;
  send0     := CAST(ObjC.Send0,    ObjC.MsgSendPtr());
  sendI     := CAST(ObjC.SendI,    ObjC.MsgSendPtr());
  sendP     := CAST(ObjC.SendP,    ObjC.MsgSendPtr());
  sendB     := CAST(ObjC.SendB,    ObjC.MsgSendPtr());
  sendF     := CAST(ObjC.SendF,    ObjC.MsgSendPtr());
  sendFrame := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());
  sendRect  := CAST(ObjC.SendRect, ObjC.MsgSendPtr());
  send0I    := CAST(ObjC.Send0I,   ObjC.MsgSendPtr());
  sendPI    := CAST(ObjC.SendPI,   ObjC.MsgSendPtr())
END Cocoa.
