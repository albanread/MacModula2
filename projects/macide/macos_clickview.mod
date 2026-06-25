MODULE macos_clickview;
(* An interactive Cocoa control written as a Modula-2 class. ClickView is a real
   NSView subclass that OVERRIDEs mouseDown: (AppKit calls it on a click),
   bumps its own ivar state, and asks to redraw via a typed inherited call
   (SetNeedsDisplay). DrawRect renders one disc per click. We simulate five
   clicks by sending mouseDown: and snapshot the result. Swap the simulation +
   Snapshot for a window + Cocoa.RunApp to get a live clickable view. *)
FROM SYSTEM IMPORT CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;
IMPORT CG;

CLASS ClickView;
  <* cocoa "NSView" *>
  VAR clicks: INTEGER;                            (* our own per-instance state *)
  ABSTRACT PROCEDURE SetNeedsDisplay (flag: BOOLEAN);   (* inherited NSView method *)
  OVERRIDE PROCEDURE MouseDown (event: ObjC.Id);  (* -> NSView mouseDown: *)
  BEGIN
    clicks := clicks + 1;
    SELF.SetNeedsDisplay(TRUE)                     (* typed inherited call *)
  END MouseDown;
  PROCEDURE Clicks (): INTEGER;
  BEGIN RETURN clicks END Clicks;
  PROCEDURE DrawRect (x, y, w, h: REAL);
  VAR gc, cg: ObjC.Id; s0: ObjC.Send0; i: INTEGER; cx: REAL;
  BEGIN
    s0 := CAST(ObjC.Send0, ObjC.MsgSendPtr());
    gc := s0(ObjC.GetClass("NSGraphicsContext"), ObjC.Selector("currentContext"));
    cg := s0(gc, ObjC.Selector("CGContext"));
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.10, 0.11, 0.16, 1.0);  CG.FillRect(cg, 0.0, 0.0, w, h);
    FOR i := 0 TO clicks - 1 DO                     (* one disc per recorded click *)
      cx := 40.0 + FLOAT(i) * 86.0;
      CG.SetRGBFillColor(cg, 0.30, 0.78, 0.55, 1.0);
      CG.FillEllipseInRect(cg, cx, 60.0, 64.0, 64.0)
    END
  END DrawRect;
END ClickView;

VAR
  view: ClickView;
  sf: ObjC.SendFrame;
  sp: ObjC.SendP;
  i: INTEGER;
  ok: BOOLEAN;
  ig: ObjC.Id;
BEGIN
  sf := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());
  sp := CAST(ObjC.SendP, ObjC.MsgSendPtr());
  NEW(view);
  ig := sf(CAST(ObjC.Id, view), ObjC.Selector("setFrame:"), 0.0, 0.0, 480.0, 180.0);
  FOR i := 1 TO 5 DO                                (* simulate five clicks *)
    ig := sp(CAST(ObjC.Id, view), ObjC.Selector("mouseDown:"), NIL)
  END;
  ok := ObjC.SnapshotView(CAST(ObjC.Id, view), "/tmp/macm2_clickview.png");
  WriteString("ClickView handled 5 mouseDown: events -> ");
  IF view.Clicks() = 5 THEN WriteString("clicks=5 (OK), drew 5 discs") ELSE WriteString("WRONG") END;
  WriteLn
END macos_clickview.
