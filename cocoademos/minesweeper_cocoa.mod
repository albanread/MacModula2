MODULE minesweeper_cocoa;
(* Minesweeper as a native Cocoa app — the macOS port of demos/minesweeper.mod
   (Direct2D/TermRender on Windows). The board is a Modula-2 CLASS that INHERITs
   NSView: DrawRect paints the covered/revealed cells, the count digits (drawn as
   real NSStrings with per-number colours), mines, and flags via Core Graphics;
   MouseDown reveals a cell and RightMouseDown flags it. The board logic — random
   mine placement (first click safe), neighbour counts, the recursive flood-fill
   reveal, win/lose — is ported verbatim from the Windows version.

     newm2-driver run --library library cocoademos/minesweeper_cocoa.mod
   Left-click reveal   Right-click flag   R: new game. *)
FROM SYSTEM IMPORT CAST;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;

CONST
  GRID = 16; MINES = 40;
  CellPx = 30.0; Margin = 18.0; BoardPx = 480.0;   (* GRID*CellPx *)
  WinW = 516.0; WinH = 516.0;                       (* 2*Margin + BoardPx *)

VAR
  mine, revealed, flagged: ARRAY [0..GRID-1], [0..GRID-1] OF BOOLEAN;
  count:     ARRAY [0..GRID-1], [0..GRID-1] OF CARDINAL;
  gFirst, gOver, gWon: BOOLEAN;
  gRevealed, gFlags: CARDINAL;
  gSeed: CARDINAL;
  gWin:  ObjC.Id;

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

PROCEDURE R (c: CARDINAL): REAL;
BEGIN RETURN FLOAT(VAL(INTEGER, c)) END R;

PROCEDURE Pt (x, y: REAL): ObjC.NSPoint;
VAR p: ObjC.NSPoint;
BEGIN p.x := x; p.y := y; RETURN p END Pt;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

(* a small LCG — fixed seed (first board reproducible), churns across games *)
PROCEDURE Rand (lo, hi: CARDINAL): CARDINAL;
BEGIN
  gSeed := (gSeed * 1103515245 + 12345) MOD 2147483648;
  RETURN lo + (gSeed DIV 65536) MOD (hi - lo + 1)
END Rand;

(* draw text at (x,y) in the current (flipped) context, in colour (r,g,b) *)
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

PROCEDURE NumRGB (n: CARDINAL; VAR r, g, b: REAL);
BEGIN
  CASE n OF
    1: r := 0.15; g := 0.30; b := 0.90
  | 2: r := 0.10; g := 0.55; b := 0.20
  | 3: r := 0.85; g := 0.12; b := 0.12
  | 4: r := 0.10; g := 0.10; b := 0.55
  | 5: r := 0.55; g := 0.10; b := 0.10
  | 6: r := 0.00; g := 0.50; b := 0.50
  | 7: r := 0.12; g := 0.12; b := 0.12
  ELSE r := 0.40; g := 0.40; b := 0.40
  END
END NumRGB;

(* --- game logic (ported from demos/minesweeper.mod) --------------------- *)
PROCEDURE Near (a, b: CARDINAL): BOOLEAN;
BEGIN IF a >= b THEN RETURN (a - b) <= 1 ELSE RETURN (b - a) <= 1 END END Near;

PROCEDURE PlaceMines (ax, ay: CARDINAL);
  VAR placed, mx, my: CARDINAL;
BEGIN
  placed := 0;
  WHILE placed < MINES DO
    mx := Rand(0, GRID-1); my := Rand(0, GRID-1);
    IF (NOT mine[mx][my]) AND NOT (Near(mx, ax) AND Near(my, ay)) THEN
      mine[mx][my] := TRUE; INC(placed)
    END
  END
END PlaceMines;

PROCEDURE ComputeCounts;
  VAR gx, gy, ddx, ddy, nx, ny, c: CARDINAL;
BEGIN
  FOR gx := 0 TO GRID-1 DO FOR gy := 0 TO GRID-1 DO
    c := 0;
    FOR ddx := 0 TO 2 DO FOR ddy := 0 TO 2 DO
      IF (ddx # 1) OR (ddy # 1) THEN
        IF (gx + ddx >= 1) AND (gy + ddy >= 1) THEN
          nx := gx + ddx - 1; ny := gy + ddy - 1;
          IF (nx < GRID) AND (ny < GRID) AND mine[nx][ny] THEN INC(c) END
        END
      END
    END END;
    count[gx][gy] := c
  END END
END ComputeCounts;

PROCEDURE RevealAt (gx, gy: CARDINAL);
  VAR ddx, ddy, nx, ny: CARDINAL;
BEGIN
  IF revealed[gx][gy] OR flagged[gx][gy] THEN RETURN END;
  revealed[gx][gy] := TRUE;
  IF mine[gx][gy] THEN gOver := TRUE; gWon := FALSE; RETURN END;
  INC(gRevealed);
  IF count[gx][gy] = 0 THEN
    FOR ddx := 0 TO 2 DO FOR ddy := 0 TO 2 DO
      IF (ddx # 1) OR (ddy # 1) THEN
        IF (gx + ddx >= 1) AND (gy + ddy >= 1) THEN
          nx := gx + ddx - 1; ny := gy + ddy - 1;
          IF (nx < GRID) AND (ny < GRID) THEN RevealAt(nx, ny) END
        END
      END
    END END
  END
END RevealAt;

PROCEDURE RevealAllMines;
  VAR gx, gy: CARDINAL;
BEGIN
  FOR gx := 0 TO GRID-1 DO FOR gy := 0 TO GRID-1 DO
    IF mine[gx][gy] THEN revealed[gx][gy] := TRUE END
  END END
END RevealAllMines;

PROCEDURE NewGame;
  VAR gx, gy: CARDINAL;
BEGIN
  FOR gx := 0 TO GRID-1 DO FOR gy := 0 TO GRID-1 DO
    mine[gx][gy] := FALSE; revealed[gx][gy] := FALSE;
    flagged[gx][gy] := FALSE; count[gx][gy] := 0
  END END;
  gFirst := TRUE; gOver := FALSE; gWon := FALSE; gRevealed := 0; gFlags := 0
END NewGame;

PROCEDURE LeftClick (gx, gy: CARDINAL);
BEGIN
  IF gOver OR flagged[gx][gy] OR revealed[gx][gy] THEN RETURN END;
  IF gFirst THEN PlaceMines(gx, gy); ComputeCounts; gFirst := FALSE END;
  RevealAt(gx, gy);
  IF gOver THEN RevealAllMines
  ELSIF gRevealed = GRID*GRID - MINES THEN gWon := TRUE; gOver := TRUE END
END LeftClick;

PROCEDURE RightClick (gx, gy: CARDINAL);
BEGIN
  IF gOver OR revealed[gx][gy] THEN RETURN END;
  IF flagged[gx][gy] THEN flagged[gx][gy] := FALSE; DEC(gFlags)
  ELSE flagged[gx][gy] := TRUE; INC(gFlags) END
END RightClick;

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
  VAR digs: ARRAY [0..7] OF CHAR; k: CARDINAL;
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
  VAR buf: ARRAY [0..127] OF CHAR; pos: CARDINAL;
BEGIN
  pos := 0;
  PutStr(buf, pos, "Minesweeper    ");
  IF gWon THEN PutStr(buf, pos, "You WIN!   (R: new game)")
  ELSIF gOver THEN PutStr(buf, pos, "BOOM  game over.   (R: new game)")
  ELSE
    PutStr(buf, pos, "Mines left: ");
    IF gFlags <= MINES THEN PutNum(buf, pos, MINES - gFlags) ELSE PutNum(buf, pos, 0) END;
    PutStr(buf, pos, "    L: reveal  R: flag  key R: new")
  END;
  IF gWin # NIL THEN [gWin setTitle: ObjC.NSString(buf)] END
END UpdateTitle;

(* map a click event to a board cell (in the flipped view's coords) *)
PROCEDURE HitCell (view, event: ObjC.Id; VAR gx, gy: CARDINAL): BOOLEAN;
  VAR p, vp: ObjC.NSPoint; fx, fy: REAL; ix, iy: INTEGER;
BEGIN
  p  := [event locationInWindow];
  vp := [view convertPoint: p fromView: NIL];
  fx := vp.x - Margin; fy := vp.y - Margin;
  IF (fx < 0.0) OR (fy < 0.0) OR (fx >= BoardPx) OR (fy >= BoardPx) THEN RETURN FALSE END;
  ix := TRUNC(fx / CellPx); iy := TRUNC(fy / CellPx);
  gx := VAL(CARDINAL, ix); gy := VAL(CARDINAL, iy);
  RETURN (gx < GRID) AND (gy < GRID)
END HitCell;

(* --- the board: a Modula-2 CLASS that IS an NSView ---------------------- *)
CLASS Board;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (x, y, w, h: REAL);
    VAR cg: ObjC.Id; gx, gy, n: CARDINAL; cx, cy, rr, gg, bb: REAL;
        d: ARRAY [0..1] OF CHAR;
  BEGIN
    cg := [[Cls("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.12, 0.13, 0.16, 1.0);  CG.FillRect(cg, 0.0, 0.0, w, h);

    FOR gx := 0 TO GRID-1 DO
      FOR gy := 0 TO GRID-1 DO
        cx := Margin + R(gx) * CellPx;
        cy := Margin + R(gy) * CellPx;
        IF revealed[gx][gy] THEN
          IF mine[gx][gy] THEN
            CG.SetRGBFillColor(cg, 0.80, 0.16, 0.16, 1.0);
            CG.FillRect(cg, cx, cy, CellPx, CellPx);
            CG.SetRGBFillColor(cg, 0.06, 0.06, 0.07, 1.0);
            CG.FillEllipseInRect(cg, cx + 7.0, cy + 7.0, CellPx - 14.0, CellPx - 14.0)
          ELSE
            CG.SetRGBFillColor(cg, 0.80, 0.80, 0.78, 1.0);     (* flat, revealed *)
            CG.FillRect(cg, cx, cy, CellPx, CellPx);
            n := count[gx][gy];
            IF n > 0 THEN
              NumRGB(n, rr, gg, bb);
              d[0] := CHR(ORD('0') + n); d[1] := 0C;
              DrawText(d, cx + 9.0, cy + 5.0, 17.0, rr, gg, bb)
            END
          END
        ELSE
          CG.SetRGBFillColor(cg, 0.55, 0.58, 0.62, 1.0);       (* covered, raised *)
          CG.FillRect(cg, cx, cy, CellPx, CellPx);
          CG.SetRGBFillColor(cg, 0.66, 0.69, 0.73, 1.0);       (* light bevel *)
          CG.FillRect(cg, cx, cy, CellPx - 2.0, CellPx - 2.0);
          IF flagged[gx][gy] THEN
            CG.SetRGBStrokeColor(cg, 0.15, 0.15, 0.15, 1.0); CG.SetLineWidth(cg, 1.5);
            CG.MoveToPoint(cg, cx + 11.0, cy + 6.0); CG.AddLineToPoint(cg, cx + 11.0, cy + 23.0);
            CG.StrokePath(cg);
            CG.SetRGBFillColor(cg, 0.85, 0.12, 0.12, 1.0);
            CG.MoveToPoint(cg, cx + 11.0, cy + 6.0);
            CG.AddLineToPoint(cg, cx + 23.0, cy + 11.0);
            CG.AddLineToPoint(cg, cx + 11.0, cy + 16.0);
            CG.FillPath(cg)
          END
        END;
        CG.SetRGBStrokeColor(cg, 0.20, 0.22, 0.25, 1.0); CG.SetLineWidth(cg, 1.0);
        CG.StrokeRect(cg, cx, cy, CellPx, CellPx)
      END
    END
  END DrawRect;

  PROCEDURE MouseDown (event: ObjC.Id);
    VAR gx, gy: CARDINAL;
  BEGIN
    IF HitCell(CAST(ObjC.Id, SELF), event, gx, gy) THEN
      LeftClick(gx, gy); UpdateTitle; [CAST(ObjC.Id, SELF) setNeedsDisplay: TRUE]
    END
  END MouseDown;

  PROCEDURE RightMouseDown (event: ObjC.Id);
    VAR gx, gy: CARDINAL;
  BEGIN
    IF HitCell(CAST(ObjC.Id, SELF), event, gx, gy) THEN
      RightClick(gx, gy); UpdateTitle; [CAST(ObjC.Id, SELF) setNeedsDisplay: TRUE]
    END
  END RightMouseDown;

  PROCEDURE KeyDown (event: ObjC.Id);
    VAR s: ObjC.Id; buf: ARRAY [0..15] OF CHAR; n: INTEGER;
  BEGIN
    s := [event charactersIgnoringModifiers];
    n := ObjC.GetString(s, buf);
    IF (n > 0) AND ((buf[0] = 'r') OR (buf[0] = 'R')) THEN
      NewGame; UpdateTitle; [CAST(ObjC.Id, SELF) setNeedsDisplay: TRUE]
    END
  END KeyDown;
END Board;

(* --- main --------------------------------------------------------------- *)
VAR win: Cocoa.Window; content: Cocoa.View; view: Board;
BEGIN
  gSeed := 123456789;
  NewGame;
  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "Minesweeper");
  gWin := CAST(ObjC.Id, win);
  content := Cocoa.ContentView(win);
  NEW(view);
  [CAST(ObjC.Id, view) setFrame: Rct(0.0, 0.0, WinW, WinH)];
  Cocoa.AddSubview(content, CAST(Cocoa.View, view));
  [gWin makeFirstResponder: CAST(ObjC.Id, view)];
  Cocoa.ShowWindow(win);
  UpdateTitle;
  Cocoa.RunApp
END minesweeper_cocoa.
