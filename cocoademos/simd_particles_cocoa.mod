MODULE simd_particles_cocoa;
(* A SIMD particle swirl as a native Cocoa app — the macOS port of
   demos/simd_particles.mod (Canvas2D/Direct2D on Windows). NV*4 = 640 particles
   are pulled toward a moving attractor; the physics runs four particles at a time
   in REAL32X4 lane vectors (the first-class SIMD type — element-wise + - * / and
   scalar broadcast, one instruction per four particles). The kernel is ported
   verbatim from the Windows version; only the host changes: an NSView subclass
   draws each particle as a CG-filled disc, and an NSTimer *block* (a Modula-2
   procedure wrapped by ObjC.MakeBlock) integrates one step per tick and asks the
   view to redraw — so it animates itself with no message loop.

     newm2-driver run --library library cocoademos/simd_particles_cocoa.mod
   drag the mouse  the attractor follows the cursor
   space pause     r reseed       (close the window to quit) *)
FROM SYSTEM IMPORT CAST, ADDRESS;
FROM RealMath IMPORT sin, cos;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;
IMPORT DemoHarness;

CONST
  WinW = 940.0; WinH = 640.0;
  NV   = 160;                       (* REAL32X4 groups -> NV*4 = 640 particles *)
  G    = 1400.0;                    (* attractor strength *)
  Soft = 90.0;                      (* softening: keeps dist^2 from hitting 0 *)
  Damp = 0.965;                     (* velocity damping *)

VAR
  px, py, vx, vy: ARRAY [0..NV-1] OF REAL32X4;
  ax, ay:         SHORTREAL;        (* attractor position *)
  gT:             REAL;             (* orbit phase *)
  gFollow:        BOOLEAN;          (* mouse is dragging the attractor *)
  gRun:           BOOLEAN;
  gSeed:          CARDINAL;
  gWin, gView, gTimer: ObjC.Id;

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

PROCEDURE Rand (lo, hi: CARDINAL): CARDINAL;
BEGIN
  gSeed := (gSeed * 1103515245 + 12345) MOD 2147483648;
  RETURN lo + (gSeed DIV 65536) MOD (hi - lo + 1)
END Rand;

PROCEDURE Reseed;
  VAR i, j: CARDINAL;
BEGIN
  FOR i := 0 TO NV-1 DO
    FOR j := 0 TO 3 DO
      px[i][j] := VAL(SHORTREAL, VAL(REAL, Rand(0, TRUNC(WinW))));
      py[i][j] := VAL(SHORTREAL, VAL(REAL, Rand(0, TRUNC(WinH))));
      vx[i][j] := VAL(SHORTREAL, 0.0);
      vy[i][j] := VAL(SHORTREAL, 0.0)
    END
  END
END Reseed;

(* Advance every particle one step — four at a time, all element-wise. *)
PROCEDURE Step;
  VAR i: CARDINAL; dx, dy, dist2, invf: REAL32X4;
BEGIN
  FOR i := 0 TO NV-1 DO
    dx    := ax - px[i];                 (* scalar broadcast - vector *)
    dy    := ay - py[i];
    dist2 := dx*dx + dy*dy + Soft;       (* lane-wise squared distance + softening *)
    invf  := G / dist2;                  (* per-lane G / dist^2 *)
    vx[i] := (vx[i] + dx*invf) * Damp;   (* a = G*d/dist^2; v = (v + a)*damp *)
    vy[i] := (vy[i] + dy*invf) * Damp;
    px[i] := px[i] + vx[i];              (* integrate *)
    py[i] := py[i] + vy[i]
  END
END Step;

(* speed -> RGB (0..1 reals), ported from the Windows SpeedColor 0xRRGGBB table *)
PROCEDURE SpeedColor (sx, sy: SHORTREAL; VAR r, g, b: REAL);
  VAR s2: REAL;
BEGIN
  s2 := VAL(REAL, sx*sx + sy*sy);
  IF    s2 > 14.0 THEN r := 1.00; g := 1.00; b := 0.88       (* fastest: near-white *)
  ELSIF s2 >  5.0 THEN r := 1.00; g := 0.75; b := 0.31       (* hot amber *)
  ELSIF s2 >  1.2 THEN r := 0.31; g := 0.82; b := 1.00       (* cyan *)
  ELSE                 r := 0.17; g := 0.31; b := 0.56        (* slow: dim teal-blue *)
  END
END SpeedColor;

PROCEDURE Disc (cg: ObjC.Id; cx, cy, rad: REAL);
BEGIN CG.FillEllipseInRect(cg, cx - rad, cy - rad, rad * 2.0, rad * 2.0) END Disc;

PROCEDURE SetAttractor (view, event: ObjC.Id);
  VAR p, vp: ObjC.NSPoint;
BEGIN
  p  := [event locationInWindow];
  vp := [view convertPoint: p fromView: NIL];
  ax := VAL(SHORTREAL, vp.x); ay := VAL(SHORTREAL, vp.y)
END SetAttractor;

(* one tick of the world: drift the attractor (unless dragged), integrate once *)
PROCEDURE Advance;
BEGIN
  IF gRun THEN
    IF NOT gFollow THEN
      gT := gT + 0.013;                       (* attractor drifts a Lissajous path *)
      ax := VAL(SHORTREAL, WinW/2.0 + WinW/3.0 * cos(gT));
      ay := VAL(SHORTREAL, WinH/2.0 + WinH/3.0 * sin(gT*1.3))
    END;
    Step
  END
END Advance;

(* shared key handling — used by both interactive KeyDown and the test harness *)
PROCEDURE HandleKey (ch: CHAR);
BEGIN
  IF    ch = ' '                  THEN gRun := NOT gRun
  ELSIF (ch = 'r') OR (ch = 'R')  THEN Reseed
  END
END HandleKey;

(* --- the particle field: a Modula-2 CLASS that IS an NSView -------------- *)
CLASS ParticleView;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN FALSE END IsFlipped;             (* CG default: y up, like the math *)

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (x, y, w, h: REAL);
    VAR cg: ObjC.Id; i, j: CARDINAL; r, g, b: REAL;
  BEGIN
    cg := [[Cls("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.0, 0.01, 0.03, 1.0);   CG.FillRect(cg, 0.0, 0.0, w, h);
    CG.SetRGBFillColor(cg, 1.0, 0.31, 0.31, 1.0);                    (* the attractor *)
    Disc(cg, VAL(REAL, ax), VAL(REAL, ay), 7.0);
    FOR i := 0 TO NV-1 DO
      FOR j := 0 TO 3 DO
        SpeedColor(vx[i][j], vy[i][j], r, g, b);
        CG.SetRGBFillColor(cg, r, g, b, 1.0);
        Disc(cg, VAL(REAL, px[i][j]), VAL(REAL, py[i][j]), 1.7)
      END
    END
  END DrawRect;

  PROCEDURE MouseDown (event: ObjC.Id);
  BEGIN gFollow := TRUE; SetAttractor(CAST(ObjC.Id, SELF), event) END MouseDown;

  PROCEDURE MouseDragged (event: ObjC.Id);
  BEGIN gFollow := TRUE; SetAttractor(CAST(ObjC.Id, SELF), event) END MouseDragged;

  PROCEDURE MouseUp (event: ObjC.Id);
  BEGIN gFollow := FALSE END MouseUp;

  PROCEDURE KeyDown (event: ObjC.Id);
    VAR s: ObjC.Id; buf: ARRAY [0..15] OF CHAR; n: INTEGER; ch: CHAR;
  BEGIN
    s := [event charactersIgnoringModifiers];
    n := ObjC.GetString(s, buf);
    IF n <= 0 THEN RETURN END;
    HandleKey(buf[0])
  END KeyDown;
END ParticleView;

(* --- the timer block: a Modula-2 procedure Cocoa calls each tick -------- *)
PROCEDURE Tick (block, timer: ObjC.Id);    (* block invoke ABI: 1st param IS the block *)
BEGIN
  Advance;
  IF gView # NIL THEN [gView setNeedsDisplay: TRUE] END
END Tick;

(* --- test-harness callbacks (Ptcl-driven, headless) --------------------- *)
PROCEDURE DoSteps (n: CARDINAL);            (* `step <n>` verb *)
  VAR i: CARDINAL;
BEGIN FOR i := 1 TO n DO Advance END END DoSteps;

PROCEDURE DoKey (name: ARRAY OF CHAR);      (* `key <name>` verb *)
BEGIN IF name[0] # 0C THEN HandleKey(name[0]) END END DoKey;

(* --- main --------------------------------------------------------------- *)
VAR win: Cocoa.Window; content: Cocoa.View; view: ParticleView;
    spath: ARRAY [0..1023] OF CHAR; ignore: BOOLEAN;
BEGIN
  gSeed := 1234567; gT := 0.0; gFollow := FALSE; gRun := TRUE;
  ax := VAL(SHORTREAL, WinW / 2.0);
  ay := VAL(SHORTREAL, WinH / 2.0);
  Reseed;
  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "NewM2 SIMD particles (REAL32X4)");
  gWin := CAST(ObjC.Id, win);
  content := Cocoa.ContentView(win);
  NEW(view);
  [CAST(ObjC.Id, view) setFrame: Rct(0.0, 0.0, WinW, WinH)];
  Cocoa.AddSubview(content, CAST(Cocoa.View, view));
  gView := CAST(ObjC.Id, view);
  [gWin makeFirstResponder: CAST(ObjC.Id, view)];
  IF DemoHarness.ScriptArg(spath) THEN
    (* headless: a Ptcl script steps the sim and snapshots it — no event loop *)
    ignore := DemoHarness.Drive(CAST(Cocoa.View, view), DoSteps, DoKey, spath)
  ELSE
    Cocoa.ShowWindow(win);
    gTimer := [Cls("NSTimer") scheduledTimerWithTimeInterval: 0.012
                              repeats: TRUE
                              block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
    Cocoa.RunApp
  END
END simd_particles_cocoa.
