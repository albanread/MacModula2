MODULE macos_bars;
(* The full stack: a stateful native Cocoa view written as a Modula-2 class.
   BarChart is a real NSView subclass (`<* cocoa "NSView" *>`) that stores its
   own state (`n`, the bar count) in a real Obj-C ivar, set via an ordinary M2
   method, and reads it back inside DrawRect (selector drawRect:) to draw with
   Core Graphics. AppKit drives the M2 object; the M2 object draws itself from
   its own state. Rendered to a PNG via ObjC.SnapshotView. (Build AOT.) *)
FROM SYSTEM IMPORT CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;
IMPORT CG;

CLASS BarChart;
  <* cocoa "NSView" *>
  VAR n: INTEGER;                          (* bar count — real per-instance ivar *)
  PROCEDURE SetBars (count: INTEGER);
  BEGIN n := count END SetBars;
  PROCEDURE DrawRect (x, y, w, h: REAL);
  VAR gc, cg: ObjC.Id; s0: ObjC.Send0; i: INTEGER; bw, bx, bh: REAL;
  BEGIN
    s0 := CAST(ObjC.Send0, ObjC.MsgSendPtr());
    gc := s0(ObjC.GetClass("NSGraphicsContext"), ObjC.Selector("currentContext"));
    cg := s0(gc, ObjC.Selector("CGContext"));
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.10, 0.11, 0.16, 1.0);   CG.FillRect(cg, 0.0, 0.0, w, h);
    IF n <= 0 THEN RETURN END;
    bw := w / FLOAT(n);                     (* read our own ivar state *)
    FOR i := 0 TO n - 1 DO
      bh := h * (0.20 + 0.75 * FLOAT(((i * 7) MOD 9) + 1) / 9.0);
      bx := FLOAT(i) * bw;
      CG.SetRGBFillColor(cg, 0.25 + 0.6 * FLOAT(i) / FLOAT(n), 0.62, 0.92, 1.0);
      CG.FillRect(cg, bx + 5.0, 0.0, bw - 10.0, bh)
    END
  END DrawRect;
END BarChart;

VAR
  chart: BarChart;
  sf: ObjC.SendFrame;
  ok: BOOLEAN;
  ig: ObjC.Id;
BEGIN
  sf := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());
  NEW(chart);                               (* a real NSView instance *)
  chart.SetBars(9);                         (* M2 method writes the M2 ivar *)
  ig := sf(CAST(ObjC.Id, chart), ObjC.Selector("setFrame:"), 0.0, 0.0, 540.0, 200.0);
  ok := ObjC.SnapshotView(CAST(ObjC.Id, chart), "/tmp/macm2_bars.png");
  IF ok THEN WriteString("stateful M2 NSView drew 9 bars from its ivar -> /tmp/macm2_bars.png")
        ELSE WriteString("snapshot FAILED") END;
  WriteLn
END macos_bars.
