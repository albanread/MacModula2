MODULE snap;
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;

VAR
  p: ADDRESS;
  send0: ObjC.Send0; sendI: ObjC.SendI; sendP: ObjC.SendP;
  sendB: ObjC.SendB; sendRect: ObjC.SendRect; sendFrame: ObjC.SendFrame;
  app, win, content, label, ignore: ObjC.Id;
  ok: BOOLEAN;

PROCEDURE Sel(name: ARRAY OF CHAR): ObjC.SEL;
BEGIN RETURN ObjC.Selector(name) END Sel;

BEGIN
  p := ObjC.MsgSendPtr();
  send0 := CAST(ObjC.Send0,p); sendI := CAST(ObjC.SendI,p); sendP := CAST(ObjC.SendP,p);
  sendB := CAST(ObjC.SendB,p); sendRect := CAST(ObjC.SendRect,p); sendFrame := CAST(ObjC.SendFrame,p);

  app := send0(ObjC.GetClass("NSApplication"), Sel("sharedApplication"));
  ignore := sendI(app, Sel("setActivationPolicy:"), 0);

  win := send0(ObjC.GetClass("NSWindow"), Sel("alloc"));
  win := sendRect(win, Sel("initWithContentRect:styleMask:backing:defer:"),
                  0.0, 0.0, 520.0, 200.0, 15, 2, FALSE);
  ignore := sendP(win, Sel("setTitle:"), ObjC.NSString("MacModula2"));

  label := send0(ObjC.GetClass("NSTextField"), Sel("alloc"));
  label := sendFrame(label, Sel("initWithFrame:"), 20.0, 80.0, 480.0, 40.0);
  ignore := sendP(label, Sel("setStringValue:"), ObjC.NSString("Hello from Modula-2, via objc_msgSend."));
  ignore := sendB(label, Sel("setBezeled:"), FALSE);
  ignore := sendB(label, Sel("setEditable:"), FALSE);
  ignore := sendB(label, Sel("setDrawsBackground:"), FALSE);

  content := send0(win, Sel("contentView"));
  ignore := sendP(content, Sel("addSubview:"), label);

  ok := ObjC.SnapshotView(content, "/tmp/macmodula2_ui.png");
  IF ok THEN WriteString("snapshot written: /tmp/macmodula2_ui.png")
        ELSE WriteString("snapshot FAILED") END;
  WriteLn
END snap.
