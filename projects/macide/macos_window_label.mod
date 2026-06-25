MODULE macos_window_label;
(* An AppKit window containing a real NSTextField label — visible UI built
   entirely from Modula-2 through the Objective-C runtime bridge. *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;

VAR
  p: ADDRESS;
  send0: ObjC.Send0; sendI: ObjC.SendI; sendP: ObjC.SendP;
  sendB: ObjC.SendB; sendRect: ObjC.SendRect; sendFrame: ObjC.SendFrame;
  app, win, content, label, ignore: ObjC.Id;

PROCEDURE Sel(name: ARRAY OF CHAR): ObjC.SEL;
BEGIN RETURN ObjC.Selector(name) END Sel;

BEGIN
  p := ObjC.MsgSendPtr();
  send0     := CAST(ObjC.Send0, p);
  sendI     := CAST(ObjC.SendI, p);
  sendP     := CAST(ObjC.SendP, p);
  sendB     := CAST(ObjC.SendB, p);
  sendRect  := CAST(ObjC.SendRect, p);
  sendFrame := CAST(ObjC.SendFrame, p);

  (* NSApplication, regular activation policy (shows in Dock / can be frontmost) *)
  app := send0(ObjC.GetClass("NSApplication"), Sel("sharedApplication"));
  ignore := sendI(app, Sel("setActivationPolicy:"), 0);

  (* A 520x200 titled window *)
  win := send0(ObjC.GetClass("NSWindow"), Sel("alloc"));
  win := sendRect(win, Sel("initWithContentRect:styleMask:backing:defer:"),
                  140.0, 140.0, 520.0, 200.0, 15, 2, FALSE);
  ignore := sendP(win, Sel("setTitle:"), ObjC.NSString("MacModula2 - AppKit from Modula-2"));

  (* An NSTextField configured as a borderless, non-editable label *)
  label := send0(ObjC.GetClass("NSTextField"), Sel("alloc"));
  label := sendFrame(label, Sel("initWithFrame:"), 20.0, 80.0, 480.0, 40.0);
  ignore := sendP(label, Sel("setStringValue:"),
                  ObjC.NSString("Hello from Modula-2, via objc_msgSend."));
  ignore := sendB(label, Sel("setBezeled:"), FALSE);
  ignore := sendB(label, Sel("setEditable:"), FALSE);
  ignore := sendB(label, Sel("setSelectable:"), FALSE);
  ignore := sendB(label, Sel("setDrawsBackground:"), FALSE);

  (* Add the label to the window's content view and show the window *)
  content := send0(win, Sel("contentView"));
  ignore := sendP(content, Sel("addSubview:"), label);
  ignore := send0(win, Sel("center"));
  ignore := sendP(win, Sel("makeKeyAndOrderFront:"), NIL);
  ignore := sendB(app, Sel("activateIgnoringOtherApps:"), TRUE);

  WriteString("window + label built; pumping run loop 3s..."); WriteLn;
  ObjC.Pump(3.0);
  WriteString("done"); WriteLn
END macos_window_label.
