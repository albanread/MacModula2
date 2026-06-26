MODULE chart_cocoa;
(* A business-graphics dashboard as a native Cocoa app — the macOS port of
   demos/chart_demo.mod (RasterView + Chart on Windows). A Modula-2 CLASS that
   INHERITs NSView draws a bar chart, a line chart, a pie chart (Core Graphics
   arcs via the CG.AddArc binding added for this), a legend, and labels — all with
   Core Graphics + NSString text. A static dashboard; nothing to click.

     newm2-driver run --library library cocoademos/chart_cocoa.mod *)
FROM SYSTEM IMPORT CAST;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;

CONST
  WinW = 900.0; WinH = 560.0;
  PI = 3.14159265358979;

VAR
  rev:   ARRAY [0..5] OF REAL;
  trend: ARRAY [0..11] OF REAL;
  share: ARRAY [0..3] OF REAL;
  cols:  ARRAY [0..3] OF CARDINAL;
  gWin:  ObjC.Id;

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

PROCEDURE Pt (x, y: REAL): ObjC.NSPoint;
VAR p: ObjC.NSPoint;
BEGIN p.x := x; p.y := y; RETURN p END Pt;

PROCEDURE HexRGB (c: CARDINAL; VAR r, g, b: REAL);
BEGIN
  r := FLOAT(VAL(INTEGER, (c DIV 65536) MOD 256)) / 255.0;
  g := FLOAT(VAL(INTEGER, (c DIV 256) MOD 256)) / 255.0;
  b := FLOAT(VAL(INTEGER, c MOD 256)) / 255.0
END HexRGB;

PROCEDURE DrawText (s: ARRAY OF CHAR; x, y, size, r, g, b: REAL);
VAR color, font, dict, ns: ObjC.Id;
BEGIN
  color := [Cls("NSColor") colorWithDeviceRed: r green: g blue: b alpha: 1.0];
  font  := [Cls("NSFont") boldSystemFontOfSize: size];
  dict  := [[Cls("NSMutableDictionary") alloc] init];
  [dict setObject: font  forKey: ObjC.NSString("NSFont")];
  [dict setObject: color forKey: ObjC.NSString("NSColor")];
  ns := ObjC.NSString(s);
  [ns drawAtPoint: Pt(x, y) withAttributes: dict]
END DrawText;

PROCEDURE Panel (cg: ObjC.Id; x, y, w, h: REAL);
BEGIN
  CG.SetRGBFillColor(cg, 1.0, 1.0, 1.0, 1.0);  CG.FillRect(cg, x, y, w, h);
  CG.SetRGBStrokeColor(cg, 0.80, 0.83, 0.86, 1.0); CG.SetLineWidth(cg, 1.0);
  CG.StrokeRect(cg, x, y, w, h)
END Panel;

PROCEDURE MaxOf (VAR a: ARRAY OF REAL; n: CARDINAL): REAL;
  VAR i: CARDINAL; m: REAL;
BEGIN
  m := a[0];
  FOR i := 1 TO n-1 DO IF a[i] > m THEN m := a[i] END END;
  RETURN m
END MaxOf;

(* --- the dashboard: a Modula-2 CLASS that IS an NSView ------------------ *)
CLASS Dashboard;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;

  PROCEDURE DrawRect (vx, vy, vw, vh: REAL);
    VAR cg: ObjC.Id; i: CARDINAL;
        m, bx, by, bw, bh, barW, gap, hgt, px, py, lx, ly, cx, cy, rad, a0, a1, total: REAL;
        rr, gg, bb: REAL; lab: ARRAY [0..3] OF CHAR;
  BEGIN
    cg := [[Cls("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.95, 0.96, 0.97, 1.0); CG.FillRect(cg, 0.0, 0.0, vw, vh);
    DrawText("NewM2 Business Dashboard", 28.0, 16.0, 22.0, 0.10, 0.16, 0.22);

    (* ---- bar chart: revenue by quarter ---- *)
    Panel(cg, 28.0, 60.0, 410.0, 250.0);
    DrawText("REVENUE BY QUARTER", 44.0, 72.0, 14.0, 0.25, 0.25, 0.25);
    bx := 70.0; by := 280.0; bw := 350.0; bh := 180.0;
    m := MaxOf(rev, 6); gap := bw / 6.0; barW := gap * 0.6;
    HexRGB(cols[0], rr, gg, bb);
    FOR i := 0 TO 5 DO
      hgt := rev[i] / m * bh;
      px := bx + FLOAT(VAL(INTEGER, i)) * gap;
      CG.SetRGBFillColor(cg, 0.18, 0.55, 0.34, 1.0);
      CG.FillRect(cg, px, by - hgt, barW, hgt);
      lab[0] := 'Q'; lab[1] := CHR(ORD('1') + i); lab[2] := 0C;
      DrawText(lab, px + barW/2.0 - 6.0, by + 6.0, 12.0, 0.3, 0.3, 0.3)
    END;

    (* ---- line chart: monthly trend ---- *)
    Panel(cg, 462.0, 60.0, 410.0, 250.0);
    DrawText("MONTHLY TREND", 478.0, 72.0, 14.0, 0.25, 0.25, 0.25);
    bx := 500.0; by := 280.0; bw := 350.0; bh := 180.0;
    m := MaxOf(trend, 12);
    CG.SetRGBStrokeColor(cg, 0.78, 0.31, 0.12, 1.0); CG.SetLineWidth(cg, 2.5);
    FOR i := 0 TO 11 DO
      px := bx + FLOAT(VAL(INTEGER, i)) * (bw / 11.0);
      py := by - trend[i] / m * bh;
      IF i = 0 THEN CG.MoveToPoint(cg, px, py) ELSE CG.AddLineToPoint(cg, px, py) END
    END;
    CG.StrokePath(cg);
    CG.SetRGBFillColor(cg, 0.78, 0.31, 0.12, 1.0);
    FOR i := 0 TO 11 DO
      px := bx + FLOAT(VAL(INTEGER, i)) * (bw / 11.0);
      py := by - trend[i] / m * bh;
      CG.FillEllipseInRect(cg, px - 3.0, py - 3.0, 6.0, 6.0)
    END;

    (* ---- pie chart: market share (CG arcs) ---- *)
    DrawText("MARKET SHARE", 96.0, 350.0, 14.0, 0.25, 0.25, 0.25);
    cx := 160.0; cy := 450.0; rad := 80.0; total := 100.0; a0 := 0.0;
    FOR i := 0 TO 3 DO
      a1 := a0 + share[i] / total * 2.0 * PI;
      HexRGB(cols[i], rr, gg, bb);
      CG.SetRGBFillColor(cg, rr, gg, bb, 1.0);
      CG.BeginPath(cg);
      CG.MoveToPoint(cg, cx, cy);
      CG.AddArc(cg, cx, cy, rad, a0, a1, 0);
      CG.ClosePath(cg);
      CG.FillPath(cg);
      a0 := a1
    END;

    (* ---- legend ---- *)
    lx := 380.0; ly := 380.0;
    DrawLegend(cg, lx, ly + 0.0,  cols[0], "Product A   45%");
    DrawLegend(cg, lx, ly + 30.0, cols[1], "Product B   25%");
    DrawLegend(cg, lx, ly + 60.0, cols[2], "Product C   18%");
    DrawLegend(cg, lx, ly + 90.0, cols[3], "Other       12%")
  END DrawRect;
END Dashboard;

(* a legend row: a colour swatch + a label (module proc — called from DrawRect) *)
PROCEDURE DrawLegend (cg: ObjC.Id; x, y: REAL; c: CARDINAL; text: ARRAY OF CHAR);
  VAR r, g, b: REAL;
BEGIN
  HexRGB(c, r, g, b);
  CG.SetRGBFillColor(cg, r, g, b, 1.0);
  CG.FillRect(cg, x, y, 18.0, 18.0);
  DrawText(text, x + 26.0, y + 1.0, 13.0, 0.20, 0.22, 0.25)
END DrawLegend;

(* --- main --------------------------------------------------------------- *)
VAR win: Cocoa.Window; content: Cocoa.View; view: Dashboard;
BEGIN
  rev[0] := 42.0; rev[1] := 55.0; rev[2] := 38.0; rev[3] := 61.0; rev[4] := 70.0; rev[5] := 48.0;
  trend[0] := 12.0; trend[1] := 18.0; trend[2] := 15.0; trend[3] := 22.0;
  trend[4] := 30.0; trend[5] := 28.0; trend[6] := 35.0; trend[7] := 41.0;
  trend[8] := 38.0; trend[9] := 46.0; trend[10] := 52.0; trend[11] := 60.0;
  share[0] := 45.0; share[1] := 25.0; share[2] := 18.0; share[3] := 12.0;
  cols[0] := 02E8B57H; cols[1] := 01E6EC8H; cols[2] := 0E0A020H; cols[3] := 0C81E1EH;
  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "Business Dashboard");
  gWin := CAST(ObjC.Id, win);
  content := Cocoa.ContentView(win);
  NEW(view);
  [CAST(ObjC.Id, view) setFrame: Rct(0.0, 0.0, WinW, WinH)];
  Cocoa.AddSubview(content, CAST(Cocoa.View, view));
  Cocoa.ShowWindow(win);
  Cocoa.RunApp
END chart_cocoa.
