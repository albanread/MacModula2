MODULE macos_canvas;
(* A native macOS view written as an ordinary Modula-2 CLASS. The `<* cocoa
   "NSView" *>` pragma makes Canvas a real NSView subclass; the M2 method DrawRect
   (selector `drawRect:`, derived) is the view's drawing code, which AppKit calls.
   The NSRect arrives as x,y,w,h in REAL registers. Rendered to a PNG via
   ObjC.SnapshotView. This is the MacM2 analogue of a Direct2D drawing host —
   pixels on screen from a Modula-2 object that *is* an NSView. *)
FROM SYSTEM IMPORT CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;
IMPORT CG;

CLASS Canvas;
  <* cocoa "NSView" *>
  PROCEDURE DrawRect (x, y, w, h: REAL);          (* -> -[Canvas drawRect:] *)
  VAR gc, cg: ObjC.Id; s0: ObjC.Send0;
  BEGIN
    s0 := CAST(ObjC.Send0, ObjC.MsgSendPtr());
    gc := s0(ObjC.GetClass("NSGraphicsContext"), ObjC.Selector("currentContext"));
    cg := s0(gc, ObjC.Selector("CGContext"));
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.11, 0.12, 0.18, 1.0);  CG.FillRect(cg, 0.0, 0.0, w, h);
    CG.SetRGBFillColor(cg, 0.20, 0.55, 0.92, 1.0);  CG.FillRect(cg, 40.0, 40.0, 120.0, 120.0);
    CG.SetRGBFillColor(cg, 0.96, 0.62, 0.16, 1.0);  CG.FillEllipseInRect(cg, 200.0, 40.0, 120.0, 120.0);
    CG.SetRGBStrokeColor(cg, 0.93, 0.30, 0.40, 1.0);
    CG.SetLineWidth(cg, 5.0);
    CG.MoveToPoint(cg, 360.0, 40.0);   CG.AddLineToPoint(cg, 470.0, 160.0);
    CG.MoveToPoint(cg, 360.0, 160.0);  CG.AddLineToPoint(cg, 470.0, 40.0);
    CG.StrokePath(cg)
  END DrawRect;
END Canvas;

VAR
  canvas: ObjC.Id;
  s0: ObjC.Send0;
  sf: ObjC.SendFrame;
  ok: BOOLEAN;
BEGIN
  s0 := CAST(ObjC.Send0, ObjC.MsgSendPtr());
  sf := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());
  (* Construct a sized instance of our M2 class (a real NSView). *)
  canvas := sf(s0(ObjC.GetClass("M2.macos_canvas.Canvas"), ObjC.Selector("alloc")),
               ObjC.Selector("initWithFrame:"), 0.0, 0.0, 520.0, 200.0);
  ok := ObjC.SnapshotView(canvas, "/tmp/macm2_canvas.png");
  IF ok THEN WriteString("M2 NSView subclass drew via Core Graphics -> /tmp/macm2_canvas.png")
        ELSE WriteString("snapshot FAILED") END;
  WriteLn
END macos_canvas.
