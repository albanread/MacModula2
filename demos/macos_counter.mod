MODULE macos_counter;
(* A complete little Cocoa app in Modula-2: a custom NSView draws state, and a
   button's action (Modula-2) mutates that state and the view redraws. Combines
   runtime-defined Obj-C classes, M2 method IMPs, Core Graphics drawing, and
   event dispatch — verified visually via snapshots. *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;
IMPORT CG;

VAR
  p: ADDRESS;
  gSend0: ObjC.Send0; sendP: ObjC.SendP; sendFrame: ObjC.SendFrame;
  canvasCls, handlerCls, canvas, handler, ignore: ObjC.Id;
  gCount: INTEGER;
  i: INTEGER;
  ok: BOOLEAN;

PROCEDURE Sel(name: ARRAY OF CHAR): ObjC.SEL;
BEGIN RETURN ObjC.Selector(name) END Sel;

(* drawRect: — render gCount orange discs on a dark field, in Modula-2 *)
PROCEDURE DrawRect(self: ObjC.Id; cmd: ObjC.SEL; x, y, w, h: REAL);
VAR cg: ObjC.Id; k: INTEGER; fx: REAL;
BEGIN
  cg := gSend0(gSend0(ObjC.GetClass("NSGraphicsContext"), Sel("currentContext")),
               Sel("CGContext"));
  IF cg = NIL THEN RETURN END;
  CG.SetRGBFillColor(cg, 0.11, 0.12, 0.18, 1.0);
  CG.FillRect(cg, 0.0, 0.0, w, h);
  CG.SetRGBFillColor(cg, 0.96, 0.62, 0.16, 1.0);
  k := 0;
  WHILE k < gCount DO
    fx := FLOAT(k) * 70.0 + 24.0;
    CG.FillEllipseInRect(cg, fx, 70.0, 56.0, 56.0);
    INC(k)
  END
END DrawRect;

(* the button action, in Modula-2: bump the counter *)
PROCEDURE OnClick(self, cmd, sender: ObjC.Id);
BEGIN
  INC(gCount)
END OnClick;

PROCEDURE Snap(path: ARRAY OF CHAR);
BEGIN
  ok := ObjC.SnapshotView(canvas, path)
END Snap;

BEGIN
  gCount := 0;
  p := ObjC.MsgSendPtr();
  gSend0 := CAST(ObjC.Send0, p); sendP := CAST(ObjC.SendP, p);
  sendFrame := CAST(ObjC.SendFrame, p);

  canvasCls := ObjC.AllocateClass(ObjC.GetClass("NSView"), "CounterView");
  ok := ObjC.AddMethod(canvasCls, Sel("drawRect:"), CAST(ADDRESS, DrawRect),
                       "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
  ObjC.RegisterClass(canvasCls);
  canvas := gSend0(ObjC.GetClass("CounterView"), Sel("alloc"));
  canvas := sendFrame(canvas, Sel("initWithFrame:"), 0.0, 0.0, 520.0, 200.0);

  handlerCls := ObjC.AllocateClass(ObjC.GetClass("NSObject"), "CounterHandler");
  ok := ObjC.AddMethod(handlerCls, Sel("onClick:"), CAST(ADDRESS, OnClick), "v@:@");
  ObjC.RegisterClass(handlerCls);
  handler := gSend0(gSend0(handlerCls, Sel("alloc")), Sel("init"));

  Snap("/tmp/counter_0.png");                 (* count = 0 *)
  FOR i := 1 TO 5 DO
    ignore := sendP(handler, Sel("onClick:"), canvas)   (* fire the action 5x *)
  END;
  Snap("/tmp/counter_5.png");                 (* count = 5 *)
  WriteString("counter app: snapshots at 0 and 5 discs written"); WriteLn
END macos_counter.
