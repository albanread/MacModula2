MODULE worms_cocoa;
(* Worms — a multi-worm "snake" as a native Cocoa app — the macOS port of
   demos/worms.mod (Terminal/TermRender on Windows). You are the GREEN worm
   (arrow keys); the RED and BLUE worms are the computer.

   THREE worker COROUTINES cooperate with the main loop, each resumed once per
   tick (TRANSFER in, decide, TRANSFER back):
     - a treat DISPENSER coroutine deposits treats ('*') onto empty cells;
     - the RED and BLUE worm coroutines each steer toward the nearest treat
       while dodging walls and bodies.
   The game logic — grid, worms, AI, and the ISO COROUTINES (NEWCOROUTINE /
   TRANSFER / CURRENT) cooperative multitasking — is ported verbatim. Only the
   host changes: a flipped NSView renders the cell grid with Core Graphics (the
   macOS analogue of TermRender's per-cell coloured text), and an NSTimer block
   drives one tick per frame.

     newm2-driver run --library library cocoademos/worms_cocoa.mod
   arrows steer the green worm   space pause   r restart   (close window to quit) *)
FROM SYSTEM IMPORT CAST, ADDRESS, ADR, SIZE;
FROM COROUTINES IMPORT NEWCOROUTINE, TRANSFER, CURRENT, COROUTINE;
FROM WholeStr IMPORT CardToStr;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;
IMPORT DemoHarness;

CONST
  GW = 70; GH = 38;                 (* board cells, incl. a 1-cell wall border *)
  CellPx = 14.0;
  StatusH = 22.0;
  WinW = 980.0;                     (* GW*CellPx *)
  WinH = 554.0;                     (* GH*CellPx + StatusH *)
  NW = 3;                           (* worms: 0 = player(green), 1 = red, 2 = blue *)
  MaxLen = 400;
  TargetFood = 6;
  GrowPerFood = 3;
  RespawnTicks = 18;

  EMPTY = 0; WALL = -1; FOOD = -2;  (* gCell values; worm body = id+1 (1..3) *)

  (* macOS virtual key codes *)
  KC_LEFT = 123; KC_RIGHT = 124; KC_DOWN = 125; KC_UP = 126;
  KC_SPACE = 49; KC_R = 15;

TYPE
  Worm = RECORD
    bx, by:  ARRAY [0..MaxLen-1] OF INTEGER;   (* body cells, head at index 0 *)
    len:     CARDINAL;
    dir:     CARDINAL;                         (* 0=up 1=right 2=down 3=left *)
    alive:   BOOLEAN;
    grow:    CARDINAL;                         (* pending growth segments *)
    score:   CARDINAL;
    respawn: CARDINAL;                         (* ticks until AI respawn *)
  END;

VAR
  gCell:   ARRAY [0..GW-1], [0..GH-1] OF INTEGER;
  worm:    ARRAY [0..NW-1] OF Worm;
  DX, DY:  ARRAY [0..3] OF INTEGER;
  gFood:   CARDINAL;
  gOver:   BOOLEAN;
  gPaused: BOOLEAN;
  gSeed:   CARDINAL;
  gView:   ObjC.Id;
  gTimer:  ObjC.Id;
  main, coRed, coBlue, coDisp: COROUTINE;
  wsRed, wsBlue, wsDisp: ARRAY [0..16383] OF CHAR;

(* deterministic LCG, [lo,hi] inclusive — matches RandomNumbers.Random semantics
   and keeps snapshot tests reproducible *)
PROCEDURE Random (lo, hi: CARDINAL): CARDINAL;
BEGIN
  gSeed := (gSeed * 1103515245 + 12345) MOD 2147483648;
  RETURN lo + (gSeed DIV 65536) MOD (hi - lo + 1)
END Random;

PROCEDURE IAbs (a: INTEGER): INTEGER;
BEGIN IF a < 0 THEN RETURN -a ELSE RETURN a END END IAbs;

(* ---- grid / spawning --------------------------------------------------- *)

PROCEDURE SpawnFood;
  VAR x, y, tries: CARDINAL;
BEGIN
  tries := 0;
  REPEAT
    x := Random(1, GW-2); y := Random(1, GH-2); INC(tries)
  UNTIL (gCell[x][y] = EMPTY) OR (tries > 400);
  IF gCell[x][y] = EMPTY THEN gCell[x][y] := FOOD; INC(gFood) END
END SpawnFood;

PROCEDURE EnsureFood;
BEGIN
  WHILE gFood < TargetFood DO SpawnFood END
END EnsureFood;

(* Place worm `k` with a length-3 body at a random clear spot. *)
PROCEDURE Spawn (k: CARDINAL);
  VAR hx, hy, x1, y1, x2, y2: INTEGER; d, tries: CARDINAL; placed: BOOLEAN;
BEGIN
  placed := FALSE; tries := 0;
  WHILE (NOT placed) AND (tries < 300) DO
    INC(tries);
    hx := VAL(INTEGER, Random(3, GW-4)); hy := VAL(INTEGER, Random(3, GH-4));
    d  := Random(0, 3);
    x1 := hx - DX[d]; y1 := hy - DY[d];
    x2 := hx - 2*DX[d]; y2 := hy - 2*DY[d];
    IF (gCell[hx][hy] = EMPTY) AND (gCell[x1][y1] = EMPTY) AND (gCell[x2][y2] = EMPTY) THEN
      worm[k].bx[0] := hx; worm[k].by[0] := hy;
      worm[k].bx[1] := x1; worm[k].by[1] := y1;
      worm[k].bx[2] := x2; worm[k].by[2] := y2;
      gCell[hx][hy] := VAL(INTEGER, k+1);
      gCell[x1][y1] := VAL(INTEGER, k+1);
      gCell[x2][y2] := VAL(INTEGER, k+1);
      worm[k].len := 3; worm[k].dir := d; worm[k].alive := TRUE;
      worm[k].grow := 0; worm[k].respawn := 0;
      placed := TRUE
    END
  END;
  IF NOT placed THEN worm[k].alive := FALSE; worm[k].respawn := RespawnTicks END
END Spawn;

PROCEDURE Kill (k: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO worm[k].len-1 DO
    gCell[worm[k].bx[i]][worm[k].by[i]] := EMPTY
  END;
  worm[k].alive := FALSE;
  IF k = 0 THEN gOver := TRUE ELSE worm[k].respawn := RespawnTicks END
END Kill;

PROCEDURE ResetGame;
  VAR x, y, k: CARDINAL;
BEGIN
  FOR x := 0 TO GW-1 DO
    FOR y := 0 TO GH-1 DO
      IF (x = 0) OR (x = GW-1) OR (y = 0) OR (y = GH-1) THEN gCell[x][y] := WALL
      ELSE gCell[x][y] := EMPTY END
    END
  END;
  gFood := 0; gOver := FALSE; gPaused := FALSE;
  FOR k := 0 TO NW-1 DO worm[k].score := 0; worm[k].alive := FALSE; worm[k].respawn := 0 END;
  FOR k := 0 TO NW-1 DO Spawn(k) END;
  EnsureFood
END ResetGame;

(* ---- movement / collision ---------------------------------------------- *)

PROCEDURE WouldReverse (k, nd: CARDINAL): BOOLEAN;
BEGIN
  IF worm[k].len < 2 THEN RETURN FALSE END;
  RETURN (worm[k].bx[0] + DX[nd] = worm[k].bx[1])
     AND (worm[k].by[0] + DY[nd] = worm[k].by[1])
END WouldReverse;

PROCEDURE Safe (k: CARDINAL; x, y: INTEGER): BOOLEAN;
BEGIN
  IF gCell[x][y] = WALL THEN RETURN FALSE END;
  IF gCell[x][y] >= 1 THEN
    IF (x = worm[k].bx[worm[k].len-1]) AND (y = worm[k].by[worm[k].len-1])
       AND (worm[k].grow = 0) THEN RETURN TRUE END;
    RETURN FALSE
  END;
  RETURN TRUE
END Safe;

PROCEDURE MoveWorm (k: CARDINAL);
  VAR hx, hy, tx, ty: INTEGER; i: CARDINAL; ate, growing, ownTail: BOOLEAN;
BEGIN
  IF NOT worm[k].alive THEN RETURN END;
  hx := worm[k].bx[0] + DX[worm[k].dir];
  hy := worm[k].by[0] + DY[worm[k].dir];
  growing := worm[k].grow > 0;
  ownTail := (hx = worm[k].bx[worm[k].len-1]) AND (hy = worm[k].by[worm[k].len-1]);
  IF gCell[hx][hy] = WALL THEN Kill(k); RETURN END;
  IF (gCell[hx][hy] >= 1) AND NOT (ownTail AND NOT growing) THEN Kill(k); RETURN END;
  ate := gCell[hx][hy] = FOOD;
  IF (growing OR ate) AND (worm[k].len < MaxLen) THEN
    FOR i := worm[k].len TO 1 BY -1 DO
      worm[k].bx[i] := worm[k].bx[i-1]; worm[k].by[i] := worm[k].by[i-1]
    END;
    INC(worm[k].len)
  ELSE
    tx := worm[k].bx[worm[k].len-1]; ty := worm[k].by[worm[k].len-1];
    gCell[tx][ty] := EMPTY;
    FOR i := worm[k].len-1 TO 1 BY -1 DO
      worm[k].bx[i] := worm[k].bx[i-1]; worm[k].by[i] := worm[k].by[i-1]
    END
  END;
  worm[k].bx[0] := hx; worm[k].by[0] := hy;
  gCell[hx][hy] := VAL(INTEGER, k+1);
  IF worm[k].grow > 0 THEN DEC(worm[k].grow) END;
  IF ate THEN
    DEC(gFood); INC(worm[k].score); INC(worm[k].grow, GrowPerFood)
  END
END MoveWorm;

PROCEDURE StepAll;
  VAR k: CARDINAL;
BEGIN
  FOR k := 0 TO NW-1 DO
    IF worm[k].alive THEN
      MoveWorm(k)
    ELSIF (k > 0) AND (worm[k].respawn > 0) THEN
      DEC(worm[k].respawn);
      IF worm[k].respawn = 0 THEN Spawn(k) END
    END
  END
END StepAll;

(* ---- AI (runs inside each worm's coroutine) ---------------------------- *)

PROCEDURE NearestFood (hx, hy: INTEGER; VAR fx, fy: INTEGER): BOOLEAN;
  VAR x, y: CARDINAL; best, d: INTEGER; found: BOOLEAN;
BEGIN
  found := FALSE; best := 0;
  FOR x := 1 TO GW-2 DO
    FOR y := 1 TO GH-2 DO
      IF gCell[x][y] = FOOD THEN
        d := IAbs(VAL(INTEGER, x) - hx) + IAbs(VAL(INTEGER, y) - hy);
        IF (NOT found) OR (d < best) THEN best := d; fx := VAL(INTEGER, x); fy := VAL(INTEGER, y); found := TRUE END
      END
    END
  END;
  RETURN found
END NearestFood;

PROCEDURE DecideAI (k: CARDINAL);
  VAR hx, hy, fx, fy, nhx, nhy, nd, bestd: INTEGER; dir, bestdir: CARDINAL;
      haveFood, chosen: BOOLEAN;
BEGIN
  IF NOT worm[k].alive THEN RETURN END;
  hx := worm[k].bx[0]; hy := worm[k].by[0];
  haveFood := NearestFood(hx, hy, fx, fy);
  chosen := FALSE; bestd := 0; bestdir := worm[k].dir;
  FOR dir := 0 TO 3 DO
    IF NOT WouldReverse(k, dir) THEN
      nhx := hx + DX[dir]; nhy := hy + DY[dir];
      IF Safe(k, nhx, nhy) THEN
        IF haveFood THEN nd := IAbs(nhx - fx) + IAbs(nhy - fy) ELSE nd := 0 END;
        IF (NOT chosen) OR (nd < bestd) THEN bestd := nd; bestdir := dir; chosen := TRUE END
      END
    END
  END;
  IF chosen THEN worm[k].dir := bestdir END
END DecideAI;

PROCEDURE AIRed;
BEGIN LOOP DecideAI(1); TRANSFER(coRed, main) END END AIRed;

PROCEDURE AIBlue;
BEGIN LOOP DecideAI(2); TRANSFER(coBlue, main) END END AIBlue;

PROCEDURE Dispenser;
BEGIN
  LOOP
    IF gFood < TargetFood THEN SpawnFood END;
    TRANSFER(coDisp, main)
  END
END Dispenser;

(* ---- rendering (Core Graphics cell grid, the TermRender analogue) ------- *)

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

PROCEDURE Pt (x, y: REAL): ObjC.NSPoint;
VAR p: ObjC.NSPoint;
BEGIN p.x := x; p.y := y; RETURN p END Pt;

(* draw a monospaced glyph string at pixel (x,y) in colour (r,g,b) *)
PROCEDURE DrawText (s: ARRAY OF CHAR; x, y, size, r, g, b: REAL);
VAR color, font, dict, ns: ObjC.Id;
BEGIN
  color := [Cls("NSColor") colorWithDeviceRed: r green: g blue: b alpha: 1.0];
  font  := [Cls("NSFont") userFixedPitchFontOfSize: size];
  dict  := [[Cls("NSMutableDictionary") alloc] init];
  [dict setObject: font  forKey: ObjC.NSString("NSFont")];
  [dict setObject: color forKey: ObjC.NSString("NSColor")];
  ns := ObjC.NSString(s);
  [ns drawAtPoint: Pt(x, y) withAttributes: dict]
END DrawText;

PROCEDURE Cell (cg: ObjC.Id; gx, gy: INTEGER; r, g, b: REAL);
BEGIN
  CG.SetRGBFillColor(cg, r, g, b, 1.0);
  CG.FillRect(cg, FLOAT(gx) * CellPx, FLOAT(gy) * CellPx, CellPx - 1.0, CellPx - 1.0)
END Cell;

PROCEDURE Glyph (gx, gy: INTEGER; ch: CHAR; r, g, b: REAL);
VAR s: ARRAY [0..1] OF CHAR;
BEGIN
  s[0] := ch; s[1] := 0C;
  DrawText(s, FLOAT(gx) * CellPx + 2.0, FLOAT(gy) * CellPx + 0.0, CellPx - 1.0, r, g, b)
END Glyph;

PROCEDURE WormRGB (id: CARDINAL; VAR r, g, b: REAL);
BEGIN
  IF    id = 0 THEN r := 0.35; g := 0.90; b := 0.30      (* lime  *)
  ELSIF id = 1 THEN r := 0.95; g := 0.30; b := 0.30      (* red   *)
  ELSE              r := 0.35; g := 0.55; b := 1.00       (* blue  *)
  END
END WormRGB;

PROCEDURE AppendStr (VAR dst: ARRAY OF CHAR; VAR pos: CARDINAL; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (src[i] # 0C) AND (pos < HIGH(dst)) DO
    dst[pos] := src[i]; INC(pos); INC(i)
  END;
  dst[pos] := 0C
END AppendStr;

PROCEDURE Steer (nd: CARDINAL);
BEGIN
  IF worm[0].alive AND NOT WouldReverse(0, nd) THEN worm[0].dir := nd END
END Steer;

PROCEDURE StatusText (VAR buf: ARRAY OF CHAR);
  VAR num: ARRAY [0..15] OF CHAR; pos: CARDINAL;
BEGIN
  pos := 0;
  AppendStr(buf, pos, " Green "); CardToStr(worm[0].score, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "  Red "); CardToStr(worm[1].score, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "  Blue "); CardToStr(worm[2].score, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "   ");
  IF gOver THEN AppendStr(buf, pos, "YOU DIED - R to restart")
  ELSIF gPaused THEN AppendStr(buf, pos, "paused")
  ELSE AppendStr(buf, pos, "arrows steer") END;
  AppendStr(buf, pos, "  | space pause  r restart")
END StatusText;

(* ---- the board: a Modula-2 CLASS that IS a flipped NSView -------------- *)
CLASS WormView;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;                 (* y grows down, like the grid *)

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (px, py, pw, ph: REAL);
    VAR cg: ObjC.Id; x, y, k: CARDINAL; v: INTEGER;
        r, g, b: REAL; buf: ARRAY [0..159] OF CHAR;
  BEGIN
    cg := [[Cls("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.04, 0.04, 0.05, 1.0);   (* whole view: near-black *)
    CG.FillRect(cg, 0.0, 0.0, WinW, WinH);
    FOR x := 0 TO GW-1 DO FOR y := 0 TO GH-1 DO
      v := gCell[x][y];
      IF v = WALL THEN
        Cell(cg, VAL(INTEGER, x), VAL(INTEGER, y), 0.35, 0.35, 0.40)
      ELSIF v = FOOD THEN
        Glyph(VAL(INTEGER, x), VAL(INTEGER, y), '*', 1.0, 0.85, 0.20)
      ELSIF v >= 1 THEN
        WormRGB(VAL(CARDINAL, v) - 1, r, g, b);
        Cell(cg, VAL(INTEGER, x), VAL(INTEGER, y), r, g, b)
      END
    END END;
    FOR k := 0 TO NW-1 DO                 (* heads drawn distinct, over the bodies *)
      IF worm[k].alive THEN
        Glyph(worm[k].bx[0], worm[k].by[0], 'O', 1.0, 1.0, 1.0)
      END
    END;
    (* status bar *)
    CG.SetRGBFillColor(cg, 0.10, 0.10, 0.13, 1.0);
    CG.FillRect(cg, 0.0, FLOAT(GH) * CellPx, WinW, StatusH);
    StatusText(buf);
    DrawText(buf, 8.0, FLOAT(GH) * CellPx + 4.0, 13.0, 0.85, 0.90, 0.95)
  END DrawRect;

  PROCEDURE KeyDown (event: ObjC.Id);
    VAR keyCode: ObjC.Send0I; kc: INTEGER;
  BEGIN
    keyCode := CAST(ObjC.Send0I, ObjC.MsgSendPtr());
    kc := keyCode(event, ObjC.Selector("keyCode"));
    IF    kc = KC_UP    THEN Steer(0)
    ELSIF kc = KC_RIGHT THEN Steer(1)
    ELSIF kc = KC_DOWN  THEN Steer(2)
    ELSIF kc = KC_LEFT  THEN Steer(3)
    ELSIF kc = KC_SPACE THEN gPaused := NOT gPaused
    ELSIF kc = KC_R     THEN ResetGame
    END;
    [CAST(ObjC.Id, SELF) setNeedsDisplay: TRUE]
  END KeyDown;
END WormView;

(* ---- ticks ------------------------------------------------------------- *)

(* one game tick: resume the three coroutines, then advance every worm *)
PROCEDURE Advance;
BEGIN
  IF (NOT gPaused) AND (NOT gOver) THEN
    TRANSFER(main, coDisp);         (* dispenser coroutine deposits a treat *)
    TRANSFER(main, coRed);          (* red worm's coroutine decides its move *)
    TRANSFER(main, coBlue);         (* blue worm's coroutine decides its move *)
    StepAll
  END
END Advance;

PROCEDURE Tick (block, timer: ObjC.Id);
BEGIN
  Advance;
  IF gView # NIL THEN [gView setNeedsDisplay: TRUE] END
END Tick;

(* ---- test-harness callbacks (Ptcl-driven, headless) -------------------- *)
PROCEDURE DoSteps (n: CARDINAL);
  VAR i: CARDINAL;
BEGIN FOR i := 1 TO n DO Advance END END DoSteps;

PROCEDURE NameIs (VAR name: ARRAY OF CHAR; lit: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL; ca, cb: CHAR;
BEGIN
  i := 0;
  LOOP
    IF i <= HIGH(name) THEN ca := name[i] ELSE ca := 0C END;
    IF i <= HIGH(lit)  THEN cb := lit[i]  ELSE cb := 0C END;
    IF ca # cb THEN RETURN FALSE END;
    IF ca = 0C THEN RETURN TRUE END;
    INC(i)
  END
END NameIs;

PROCEDURE DoKey (name: ARRAY OF CHAR);
BEGIN
  IF    NameIs(name, "up")      THEN Steer(0)
  ELSIF NameIs(name, "right")   THEN Steer(1)
  ELSIF NameIs(name, "down")    THEN Steer(2)
  ELSIF NameIs(name, "left")    THEN Steer(3)
  ELSIF NameIs(name, "space")   THEN gPaused := NOT gPaused
  ELSIF NameIs(name, "r")       THEN ResetGame
  ELSIF NameIs(name, "restart") THEN ResetGame
  END
END DoKey;

(* ---- main -------------------------------------------------------------- *)
VAR win: Cocoa.Window; content: Cocoa.View; view: WormView;
    spath: ARRAY [0..1023] OF CHAR; ignore: BOOLEAN;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

BEGIN
  gSeed := 20260627;
  DX[0] := 0; DY[0] := -1;  DX[1] := 1; DY[1] := 0;
  DX[2] := 0; DY[2] := 1;   DX[3] := -1; DY[3] := 0;
  ResetGame;
  main := CURRENT();
  NEWCOROUTINE(AIRed,     ADR(wsRed),  SIZE(wsRed),  coRed);
  NEWCOROUTINE(AIBlue,    ADR(wsBlue), SIZE(wsBlue), coBlue);
  NEWCOROUTINE(Dispenser, ADR(wsDisp), SIZE(wsDisp), coDisp);

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "NewM2 Worms (coroutine AI)");
  content := Cocoa.ContentView(win);
  NEW(view);
  [CAST(ObjC.Id, view) setFrame: Rct(0.0, 0.0, WinW, WinH)];
  Cocoa.AddSubview(content, CAST(Cocoa.View, view));
  gView := CAST(ObjC.Id, view);
  [CAST(ObjC.Id, win) makeFirstResponder: CAST(ObjC.Id, view)];
  IF DemoHarness.ScriptArg(spath) THEN
    ignore := DemoHarness.Drive(CAST(Cocoa.View, view), DoSteps, DoKey, spath)
  ELSE
    Cocoa.ShowWindow(win);
    gTimer := [Cls("NSTimer") scheduledTimerWithTimeInterval: 0.11
                              repeats: TRUE
                              block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
    Cocoa.RunApp
  END
END worms_cocoa.
