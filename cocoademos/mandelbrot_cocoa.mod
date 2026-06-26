MODULE mandelbrot_cocoa;
(* A Mandelbrot zoomer as a native Cocoa app — the macOS port of demos/mandelbrot.mod
   (Direct2D/TermRender on Windows). The canvas is a Modula-2 CLASS that INHERITs
   NSView: DrawRect runs the LONGREAL escape-time loop per cell and paints it with
   Core Graphics; arrows pan, +/- zoom, [ ] change the iteration cap, A toggles a
   self-running "dive" driven by an NSTimer block. Maths ported verbatim.

     newm2-driver run --library library cocoademos/mandelbrot_cocoa.mod
   arrows pan   +/- zoom   [ ] iter   A auto-dive   R reset *)
FROM SYSTEM IMPORT CAST, ADDRESS;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;

CONST
  NCols = 180; NRows = 135;               (* compute grid = pixel canvas *)
  CellPx = 4.0;                            (* device points per cell *)
  HalfC = NCols DIV 2; HalfR = NRows DIV 2;
  WinW = 720.0; WinH = 540.0;             (* NCols*CellPx, NRows*CellPx *)
  IterMin = 50; IterMax = 2000;

VAR
  cenX, cenY, span: LONGREAL;
  maxIter, zoomLevel: CARDINAL;
  gAuto: BOOLEAN;
  gWin, gView, gTimer: ObjC.Id;

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

(* --- palette (ported from demos/mandelbrot.mod) ------------------------- *)
PROCEDURE Band (iter, phase: CARDINAL): CARDINAL;
  VAR n: CARDINAL;
BEGIN
  n := (iter * 9 + phase) MOD 512;
  IF n >= 256 THEN n := 511 - n END;
  RETURN n
END Band;

PROCEDURE Colour (iter: CARDINAL): CARDINAL;
BEGIN
  IF iter >= maxIter THEN RETURN 0 END;
  RETURN Band(iter, 0) * 65536 + Band(iter, 160) * 256 + Band(iter, 320)
END Colour;

PROCEDURE Reset;
BEGIN cenX := -0.5; cenY := 0.0; span := 3.0; maxIter := 100; zoomLevel := 0 END Reset;

PROCEDURE ZoomIn;
BEGIN span := span * 0.7; INC(zoomLevel); IF maxIter < IterMax THEN INC(maxIter, 12) END END ZoomIn;

PROCEDURE ZoomOut;
BEGIN
  span := span / 0.7;
  IF zoomLevel > 0 THEN DEC(zoomLevel) END;
  IF maxIter > IterMin + 12 THEN DEC(maxIter, 12) END
END ZoomOut;

PROCEDURE AutoStep;
BEGIN
  cenX := cenX + (-0.743643887037151 - cenX) * 0.04;
  cenY := cenY + ( 0.131825904205330 - cenY) * 0.04;
  span := span * 0.97; INC(zoomLevel);
  IF maxIter < IterMax THEN INC(maxIter, 3) END;
  IF span < 3.0E-13 THEN cenX := -0.5; cenY := 0.0; span := 3.0; maxIter := 100; zoomLevel := 0 END
END AutoStep;

PROCEDURE Tick (block, timer: ObjC.Id);
BEGIN
  IF gAuto THEN AutoStep; IF gView # NIL THEN [gView setNeedsDisplay: TRUE] END END
END Tick;

(* --- the canvas: a Modula-2 CLASS that IS an NSView --------------------- *)
CLASS Fractal;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (vx, vy, vw, vh: REAL);
    VAR cg: ObjC.Id; col, row, iter, c: CARDINAL;
        step, x0, y0, x, y, x2, y2: LONGREAL; rr, gg, bb, px, py: REAL;
  BEGIN
    cg := [[Cls("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    step := span / VAL(LONGREAL, NCols);
    FOR row := 0 TO NRows-1 DO
      y0 := cenY + VAL(LONGREAL, VAL(INTEGER, row) - VAL(INTEGER, HalfR)) * step;
      FOR col := 0 TO NCols-1 DO
        x0 := cenX + VAL(LONGREAL, VAL(INTEGER, col) - VAL(INTEGER, HalfC)) * step;
        x := 0.0; y := 0.0; x2 := 0.0; y2 := 0.0; iter := 0;
        WHILE (x2 + y2 <= 4.0) AND (iter < maxIter) DO
          y := 2.0 * x * y + y0; x := x2 - y2 + x0; x2 := x * x; y2 := y * y; INC(iter)
        END;
        c := Colour(iter);
        rr := FLOAT(VAL(INTEGER, (c DIV 65536) MOD 256)) / 255.0;
        gg := FLOAT(VAL(INTEGER, (c DIV 256) MOD 256)) / 255.0;
        bb := FLOAT(VAL(INTEGER, c MOD 256)) / 255.0;
        px := FLOAT(VAL(INTEGER, col)) * CellPx;
        py := FLOAT(VAL(INTEGER, row)) * CellPx;
        CG.SetRGBFillColor(cg, rr, gg, bb, 1.0);
        CG.FillRect(cg, px, py, CellPx, CellPx)
      END
    END
  END DrawRect;

  PROCEDURE KeyDown (event: ObjC.Id);
    VAR s: ObjC.Id; buf: ARRAY [0..15] OF CHAR; n: INTEGER; ch: CHAR; kc: CARDINAL;
  BEGIN
    kc := [event keyCode];
    IF    kc = 123 THEN cenX := cenX - span * 0.12          (* left  *)
    ELSIF kc = 124 THEN cenX := cenX + span * 0.12          (* right *)
    ELSIF kc = 125 THEN cenY := cenY + span * 0.12          (* down (flipped) *)
    ELSIF kc = 126 THEN cenY := cenY - span * 0.12          (* up *)
    ELSE
      s := [event charactersIgnoringModifiers];
      n := ObjC.GetString(s, buf);
      IF n > 0 THEN
        ch := buf[0];
        IF    (ch = '+') OR (ch = '=') THEN ZoomIn
        ELSIF (ch = '-') OR (ch = '_') THEN ZoomOut
        ELSIF  ch = '['                THEN IF maxIter > IterMin + 20 THEN DEC(maxIter, 20) END
        ELSIF  ch = ']'                THEN IF maxIter < IterMax THEN INC(maxIter, 20) END
        ELSIF (ch = 'r') OR (ch = 'R') THEN Reset
        ELSIF (ch = 'a') OR (ch = 'A') THEN gAuto := NOT gAuto
        END
      END
    END;
    [CAST(ObjC.Id, SELF) setNeedsDisplay: TRUE]
  END KeyDown;
END Fractal;

(* --- main --------------------------------------------------------------- *)
VAR win: Cocoa.Window; content: Cocoa.View; view: Fractal;
BEGIN
  Reset; gAuto := FALSE;
  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "Mandelbrot");
  gWin := CAST(ObjC.Id, win);
  content := Cocoa.ContentView(win);
  NEW(view);
  [CAST(ObjC.Id, view) setFrame: Rct(0.0, 0.0, WinW, WinH)];
  Cocoa.AddSubview(content, CAST(Cocoa.View, view));
  gView := CAST(ObjC.Id, view);
  [gWin makeFirstResponder: CAST(ObjC.Id, view)];
  Cocoa.ShowWindow(win);
  gTimer := [Cls("NSTimer") scheduledTimerWithTimeInterval: 0.06
                            repeats: TRUE
                            block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
  Cocoa.RunApp
END mandelbrot_cocoa.
