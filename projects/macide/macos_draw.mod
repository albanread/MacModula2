MODULE macos_draw;
(* A custom NSView whose drawRect: is a Modula-2 procedure drawing with Core
   Graphics (Quartz). "Pixels on screen from Modula-2" — the macOS analogue of
   the Windows GDI/Direct2D drawing hosts. Captured via ObjC.SnapshotView. *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;
IMPORT CG;

VAR
  p: ADDRESS;
  gSend0: ObjC.Send0; sendFrame: ObjC.SendFrame;
  canvasCls, canvas: ObjC.Id;
  ok: BOOLEAN;

PROCEDURE Sel(name: ARRAY OF CHAR): ObjC.SEL;
BEGIN RETURN ObjC.Selector(name) END Sel;

(* -(void)drawRect:(NSRect)dirty  — the NSRect arrives as x,y,w,h in REAL regs *)
PROCEDURE DrawRect(self: ObjC.Id; cmd: ObjC.SEL; x, y, w, h: REAL);
VAR gc, cg: ObjC.Id;
BEGIN
  gc := gSend0(ObjC.GetClass("NSGraphicsContext"), Sel("currentContext"));
  cg := gSend0(gc, Sel("CGContext"));
  IF cg = NIL THEN RETURN END;

  (* dark background *)
  CG.SetRGBFillColor(cg, 0.11, 0.12, 0.18, 1.0);
  CG.FillRect(cg, 0.0, 0.0, w, h);

  (* blue square *)
  CG.SetRGBFillColor(cg, 0.20, 0.55, 0.92, 1.0);
  CG.FillRect(cg, 40.0, 40.0, 120.0, 120.0);

  (* orange disc *)
  CG.SetRGBFillColor(cg, 0.96, 0.62, 0.16, 1.0);
  CG.FillEllipseInRect(cg, 200.0, 40.0, 120.0, 120.0);

  (* a red 'X' drawn with strokes *)
  CG.SetRGBStrokeColor(cg, 0.93, 0.30, 0.40, 1.0);
  CG.SetLineWidth(cg, 5.0);
  CG.MoveToPoint(cg, 360.0, 40.0);   CG.AddLineToPoint(cg, 470.0, 160.0);
  CG.MoveToPoint(cg, 360.0, 160.0);  CG.AddLineToPoint(cg, 470.0, 40.0);
  CG.StrokePath(cg);
END DrawRect;

BEGIN
  p := ObjC.MsgSendPtr();
  gSend0    := CAST(ObjC.Send0, p);
  sendFrame := CAST(ObjC.SendFrame, p);

  (* a custom NSView subclass that draws itself in Modula-2 *)
  canvasCls := ObjC.AllocateClass(ObjC.GetClass("NSView"), "MacCanvas");
  ok := ObjC.AddMethod(canvasCls, Sel("drawRect:"), CAST(ADDRESS, DrawRect),
                       "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
  ObjC.RegisterClass(canvasCls);

  canvas := gSend0(ObjC.GetClass("MacCanvas"), Sel("alloc"));
  canvas := sendFrame(canvas, Sel("initWithFrame:"), 0.0, 0.0, 520.0, 200.0);

  ok := ObjC.SnapshotView(canvas, "/tmp/macmodula2_draw.png");
  IF ok THEN WriteString("drew via Core Graphics -> /tmp/macmodula2_draw.png")
        ELSE WriteString("snapshot FAILED") END;
  WriteLn
END macos_draw.
