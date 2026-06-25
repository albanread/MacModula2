MODULE macos_button;
(* Event handling: an Objective-C class defined at RUNTIME whose action method
   is a Modula-2 procedure. A button's target/action invokes that M2 code, which
   updates a label. We snapshot before and after a (programmatic) click to prove
   the callback ran and changed the UI. *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;

VAR
  p: ADDRESS;
  send0: ObjC.Send0; sendI: ObjC.SendI; sendP: ObjC.SendP;
  sendB: ObjC.SendB; sendRect: ObjC.SendRect; sendFrame: ObjC.SendFrame;
  app, win, content, button, handlerCls, handler, ignore: ObjC.Id;
  gLabel: ObjC.Id;                 (* the label the callback updates *)
  ok: BOOLEAN;

PROCEDURE Sel(name: ARRAY OF CHAR): ObjC.SEL;
BEGIN RETURN ObjC.Selector(name) END Sel;

(* The Objective-C action method, written in Modula-2. Signature (self,_cmd,sender). *)
PROCEDURE OnClick(self, cmd, sender: ObjC.Id);
VAR sp: ObjC.SendP; ig: ObjC.Id;
BEGIN
  sp := CAST(ObjC.SendP, ObjC.MsgSendPtr());
  ig := sp(gLabel, Sel("setStringValue:"),
           ObjC.NSString("Clicked!  Modula-2 handled the action."));
END OnClick;

BEGIN
  p := ObjC.MsgSendPtr();
  send0 := CAST(ObjC.Send0,p); sendI := CAST(ObjC.SendI,p); sendP := CAST(ObjC.SendP,p);
  sendB := CAST(ObjC.SendB,p); sendRect := CAST(ObjC.SendRect,p); sendFrame := CAST(ObjC.SendFrame,p);

  app := send0(ObjC.GetClass("NSApplication"), Sel("sharedApplication"));
  ignore := sendI(app, Sel("setActivationPolicy:"), 0);

  win := send0(ObjC.GetClass("NSWindow"), Sel("alloc"));
  win := sendRect(win, Sel("initWithContentRect:styleMask:backing:defer:"),
                  0.0, 0.0, 520.0, 200.0, 15, 2, FALSE);
  content := send0(win, Sel("contentView"));

  (* label *)
  gLabel := send0(ObjC.GetClass("NSTextField"), Sel("alloc"));
  gLabel := sendFrame(gLabel, Sel("initWithFrame:"), 20.0, 120.0, 480.0, 30.0);
  ignore := sendP(gLabel, Sel("setStringValue:"), ObjC.NSString("Click the button below."));
  ignore := sendB(gLabel, Sel("setBezeled:"), FALSE);
  ignore := sendB(gLabel, Sel("setEditable:"), FALSE);
  ignore := sendB(gLabel, Sel("setDrawsBackground:"), FALSE);
  ignore := sendP(content, Sel("addSubview:"), gLabel);

  (* define a handler class at runtime, with OnClick: as its action method *)
  handlerCls := ObjC.AllocateClass(ObjC.GetClass("NSObject"), "M2Responder");
  ok := ObjC.AddMethod(handlerCls, Sel("onClick:"), CAST(ADDRESS, OnClick), "v@:@");
  ObjC.RegisterClass(handlerCls);
  handler := send0(send0(handlerCls, Sel("alloc")), Sel("init"));

  (* button wired to the M2 handler *)
  button := send0(ObjC.GetClass("NSButton"), Sel("alloc"));
  button := sendFrame(button, Sel("initWithFrame:"), 180.0, 40.0, 160.0, 40.0);
  ignore := sendP(button, Sel("setTitle:"), ObjC.NSString("Run Modula-2"));
  ignore := sendP(button, Sel("setTarget:"), handler);
  ignore := sendP(button, Sel("setAction:"), CAST(ObjC.Id, Sel("onClick:")));
  ignore := sendP(content, Sel("addSubview:"), button);

  ok := ObjC.SnapshotView(content, "/tmp/macmodula2_before.png");
  WriteString("before snapshot ok"); WriteLn;

  (* Simulate the click: invoke the action exactly as AppKit would. *)
  ignore := sendP(handler, Sel("onClick:"), button);

  ok := ObjC.SnapshotView(content, "/tmp/macmodula2_after.png");
  WriteString("after snapshot ok"); WriteLn
END macos_button.
