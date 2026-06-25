MODULE window;
(* First AppKit window from Modula-2, via the Objective-C runtime bridge. *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;

VAR
  p: ADDRESS;
  send0: ObjC.Send0; sendI: ObjC.SendI; sendP: ObjC.SendP;
  sendB: ObjC.SendB; sendRect: ObjC.SendRect;
  appCls, winCls, app, winAlloc, win, title: ObjC.Id;
  dummy: ObjC.Id;

PROCEDURE Report(label: ARRAY OF CHAR; obj: ObjC.Id);
BEGIN
  WriteString(label);
  IF obj # NIL THEN WriteString(" = ok (non-nil)") ELSE WriteString(" = NIL!") END;
  WriteLn
END Report;

BEGIN
  p := ObjC.MsgSendPtr();
  send0    := CAST(ObjC.Send0, p);
  sendI    := CAST(ObjC.SendI, p);
  sendP    := CAST(ObjC.SendP, p);
  sendB    := CAST(ObjC.SendB, p);
  sendRect := CAST(ObjC.SendRect, p);

  appCls := ObjC.GetClass("NSApplication");
  Report("NSApplication class", appCls);
  app := send0(appCls, ObjC.Selector("sharedApplication"));
  Report("sharedApplication", app);
  dummy := sendI(app, ObjC.Selector("setActivationPolicy:"), 0);

  winCls := ObjC.GetClass("NSWindow");
  Report("NSWindow class", winCls);
  winAlloc := send0(winCls, ObjC.Selector("alloc"));
  win := sendRect(winAlloc,
                  ObjC.Selector("initWithContentRect:styleMask:backing:defer:"),
                  120.0, 120.0, 480.0, 320.0,  (* x, y, w, h *)
                  15,    (* titled|closable|miniaturizable|resizable *)
                  2,     (* NSBackingStoreBuffered *)
                  FALSE);
  Report("NSWindow instance", win);

  title := ObjC.NSString("MacModula2 - first AppKit window");
  dummy := sendP(win, ObjC.Selector("setTitle:"), title);
  dummy := send0(win, ObjC.Selector("center"));
  dummy := sendP(win, ObjC.Selector("makeKeyAndOrderFront:"), NIL);
  dummy := sendB(app, ObjC.Selector("activateIgnoringOtherApps:"), TRUE);

  WriteString("window created; pumping run loop for 3s..."); WriteLn;
  ObjC.Pump(3.0);
  WriteString("done"); WriteLn
END window.
