MODULE life_cocoa;
(* Conway's Game of Life as a native Cocoa app — the macOS port of demos/life.mod
   (Direct2D/TermRender on Windows). The grid is a Modula-2 CLASS that INHERITs
   NSView; an NSTimer *block* (a Modula-2 procedure wrapped by ObjC.MakeBlock)
   steps the B3/S23 rule on a torus and asks the view to redraw, so the whole
   thing animates itself with no message loop. Click toggles a cell. The board
   logic is ported verbatim from the Windows version.

     newm2-driver run --library library cocoademos/life_cocoa.mod
   space run/pause   s step   r random soup   c clear   g glider   click toggle *)
FROM SYSTEM IMPORT CAST, ADDRESS;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;

CONST
  GW = 78; GH = 42;                       (* torus grid *)
  CellPx = 10.0; Margin = 12.0;
  BoardW = 780.0; BoardH = 420.0;         (* GW*CellPx, GH*CellPx *)
  WinW = 804.0; WinH = 444.0;             (* 2*Margin + board *)

VAR
  cur, nxt: ARRAY [0..GW-1], [0..GH-1] OF BOOLEAN;
  gRunning: BOOLEAN;
  gGen, gPop, gSeed: CARDINAL;
  gWin, gView, gTimer: ObjC.Id;

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

PROCEDURE R (c: CARDINAL): REAL;
BEGIN RETURN FLOAT(VAL(INTEGER, c)) END R;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

PROCEDURE Rand (lo, hi: CARDINAL): CARDINAL;
BEGIN
  gSeed := (gSeed * 1103515245 + 12345) MOD 2147483648;
  RETURN lo + (gSeed DIV 65536) MOD (hi - lo + 1)
END Rand;

(* --- board logic (ported from demos/life.mod) --------------------------- *)
PROCEDURE Step;
  VAR x, y, ddx, ddy, nx, ny, n, pop: CARDINAL;
BEGIN
  pop := 0;
  FOR x := 0 TO GW-1 DO FOR y := 0 TO GH-1 DO
    n := 0;
    FOR ddx := 0 TO 2 DO FOR ddy := 0 TO 2 DO
      IF (ddx # 1) OR (ddy # 1) THEN
        nx := (x + ddx + GW - 1) MOD GW;
        ny := (y + ddy + GH - 1) MOD GH;
        IF cur[nx][ny] THEN INC(n) END
      END
    END END;
    IF (n = 3) OR (cur[x][y] AND (n = 2)) THEN nxt[x][y] := TRUE; INC(pop)
    ELSE nxt[x][y] := FALSE END
  END END;
  FOR x := 0 TO GW-1 DO FOR y := 0 TO GH-1 DO cur[x][y] := nxt[x][y] END END;
  gPop := pop; INC(gGen)
END Step;

PROCEDURE ClearBoard;
  VAR x, y: CARDINAL;
BEGIN
  FOR x := 0 TO GW-1 DO FOR y := 0 TO GH-1 DO cur[x][y] := FALSE END END;
  gGen := 0; gPop := 0
END ClearBoard;

PROCEDURE RandomSoup;
  VAR x, y: CARDINAL;
BEGIN
  gPop := 0;
  FOR x := 0 TO GW-1 DO FOR y := 0 TO GH-1 DO
    IF Rand(0, 99) < 28 THEN cur[x][y] := TRUE; INC(gPop) ELSE cur[x][y] := FALSE END
  END END;
  gGen := 0
END RandomSoup;

PROCEDURE SetCell (x, y: CARDINAL; on: BOOLEAN);
BEGIN IF (x < GW) AND (y < GH) THEN cur[x][y] := on END END SetCell;

PROCEDURE Glider (ox, oy: CARDINAL);
BEGIN
  SetCell(ox+1, oy+0, TRUE); SetCell(ox+2, oy+1, TRUE);
  SetCell(ox+0, oy+2, TRUE); SetCell(ox+1, oy+2, TRUE); SetCell(ox+2, oy+2, TRUE)
END Glider;

PROCEDURE CountPop;
  VAR x, y, p: CARDINAL;
BEGIN p := 0;
  FOR x := 0 TO GW-1 DO FOR y := 0 TO GH-1 DO IF cur[x][y] THEN INC(p) END END END;
  gPop := p
END CountPop;

(* --- status in the window title ----------------------------------------- *)
PROCEDURE PutStr (VAR dst: ARRAY OF CHAR; VAR pos: CARDINAL; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i := 0;
  WHILE (i <= HIGH(src)) AND (src[i] # 0C) AND (pos < HIGH(dst)) DO
    dst[pos] := src[i]; INC(pos); INC(i)
  END;
  dst[pos] := 0C
END PutStr;

PROCEDURE PutNum (VAR dst: ARRAY OF CHAR; VAR pos: CARDINAL; n: CARDINAL);
  VAR digs: ARRAY [0..15] OF CHAR; k: CARDINAL;
BEGIN
  IF n = 0 THEN IF pos < HIGH(dst) THEN dst[pos] := '0'; INC(pos) END
  ELSE
    k := 0;
    WHILE n > 0 DO digs[k] := CHR(ORD('0') + (n MOD 10)); INC(k); n := n DIV 10 END;
    WHILE k > 0 DO DEC(k); IF pos < HIGH(dst) THEN dst[pos] := digs[k]; INC(pos) END END
  END;
  dst[pos] := 0C
END PutNum;

PROCEDURE UpdateTitle;
  VAR buf: ARRAY [0..159] OF CHAR; pos: CARDINAL;
BEGIN
  pos := 0;
  PutStr(buf, pos, "Life of Modula-2    Gen "); PutNum(buf, pos, gGen);
  PutStr(buf, pos, "   Pop "); PutNum(buf, pos, gPop);
  PutStr(buf, pos, "    ");
  IF gRunning THEN PutStr(buf, pos, "running") ELSE PutStr(buf, pos, "paused") END;
  PutStr(buf, pos, "   (space run  s step  r soup  c clear  g glider  click toggle)");
  IF gWin # NIL THEN [gWin setTitle: ObjC.NSString(buf)] END
END UpdateTitle;

(* --- the timer block: a Modula-2 procedure Cocoa calls each tick -------- *)
PROCEDURE Tick (block, timer: ObjC.Id);    (* block invoke ABI: 1st param IS the block *)
BEGIN
  IF gRunning THEN
    Step; UpdateTitle;
    IF gView # NIL THEN [gView setNeedsDisplay: TRUE] END
  END
END Tick;

(* map a click to a cell in the flipped view's coords *)
PROCEDURE HitCell (view, event: ObjC.Id; VAR gx, gy: CARDINAL): BOOLEAN;
  VAR p, vp: ObjC.NSPoint; fx, fy: REAL; ix, iy: INTEGER;
BEGIN
  p  := [event locationInWindow];
  vp := [view convertPoint: p fromView: NIL];
  fx := vp.x - Margin; fy := vp.y - Margin;
  IF (fx < 0.0) OR (fy < 0.0) OR (fx >= BoardW) OR (fy >= BoardH) THEN RETURN FALSE END;
  ix := TRUNC(fx / CellPx); iy := TRUNC(fy / CellPx);
  gx := VAL(CARDINAL, ix); gy := VAL(CARDINAL, iy);
  RETURN (gx < GW) AND (gy < GH)
END HitCell;

(* --- the grid: a Modula-2 CLASS that IS an NSView ----------------------- *)
CLASS LifeView;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (x, y, w, h: REAL);
    VAR cg: ObjC.Id; gx, gy: CARDINAL; cx, cy: REAL;
  BEGIN
    cg := [[Cls("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.07, 0.08, 0.10, 1.0);  CG.FillRect(cg, 0.0, 0.0, w, h);
    CG.SetRGBFillColor(cg, 0.05, 0.06, 0.07, 1.0);  CG.FillRect(cg, Margin, Margin, BoardW, BoardH);
    CG.SetRGBFillColor(cg, 0.45, 0.92, 0.40, 1.0);                 (* live cells *)
    FOR gx := 0 TO GW-1 DO FOR gy := 0 TO GH-1 DO
      IF cur[gx][gy] THEN
        cx := Margin + R(gx) * CellPx;
        cy := Margin + R(gy) * CellPx;
        CG.FillRect(cg, cx, cy, CellPx - 1.0, CellPx - 1.0)
      END
    END END
  END DrawRect;

  PROCEDURE MouseDown (event: ObjC.Id);
    VAR gx, gy: CARDINAL;
  BEGIN
    IF HitCell(CAST(ObjC.Id, SELF), event, gx, gy) THEN
      cur[gx][gy] := NOT cur[gx][gy]; CountPop; UpdateTitle;
      [CAST(ObjC.Id, SELF) setNeedsDisplay: TRUE]
    END
  END MouseDown;

  PROCEDURE KeyDown (event: ObjC.Id);
    VAR s: ObjC.Id; buf: ARRAY [0..15] OF CHAR; n: INTEGER; ch: CHAR;
  BEGIN
    s := [event charactersIgnoringModifiers];
    n := ObjC.GetString(s, buf);
    IF n <= 0 THEN RETURN END;
    ch := buf[0];
    IF    ch = ' '                  THEN gRunning := NOT gRunning
    ELSIF (ch = 's') OR (ch = 'S')  THEN Step
    ELSIF (ch = 'r') OR (ch = 'R')  THEN RandomSoup
    ELSIF (ch = 'c') OR (ch = 'C')  THEN ClearBoard
    ELSIF (ch = 'g') OR (ch = 'G')  THEN Glider(GW DIV 2, GH DIV 2); CountPop
    END;
    UpdateTitle; [CAST(ObjC.Id, SELF) setNeedsDisplay: TRUE]
  END KeyDown;
END LifeView;

(* --- main --------------------------------------------------------------- *)
VAR win: Cocoa.Window; content: Cocoa.View; view: LifeView;
BEGIN
  gSeed := 88172645; gGen := 0; gRunning := TRUE;
  RandomSoup;
  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "Life");
  gWin := CAST(ObjC.Id, win);
  content := Cocoa.ContentView(win);
  NEW(view);
  [CAST(ObjC.Id, view) setFrame: Rct(0.0, 0.0, WinW, WinH)];
  Cocoa.AddSubview(content, CAST(Cocoa.View, view));
  gView := CAST(ObjC.Id, view);
  [gWin makeFirstResponder: CAST(ObjC.Id, view)];
  Cocoa.ShowWindow(win);
  UpdateTitle;
  (* drive the generations from an NSTimer that calls Tick (a Cocoa block) *)
  gTimer := [Cls("NSTimer") scheduledTimerWithTimeInterval: 0.06
                            repeats: TRUE
                            block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
  Cocoa.RunApp
END life_cocoa.
