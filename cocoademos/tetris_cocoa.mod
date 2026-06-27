MODULE tetris_cocoa;
(* Tetris — a native Cocoa app written in Modula-2. A 10x20 well of cells is a
   Modula-2 CLASS that INHERITs NSView and draws itself with Core Graphics; an
   NSTimer *block* (a Modula-2 procedure wrapped by ObjC.MakeBlock) applies
   gravity, so the game animates itself with no message loop.

   Features: the seven tetrominoes with four rotations + wall kicks, a 7-bag
   randomiser (each batch of 7 is a shuffled permutation — no droughts), a HOLD
   slot, a ghost-drop preview, a line-clear flash, scoring + levels, and live
   sound effects synthesised in Modula-2 (Audio) and played non-blocking through
   CoreAudio (Sfx) — all plain Modula-2.

     newm2-driver run --library library cocoademos/tetris_cocoa.mod
   left / right move   up rotate   down soft-drop   space hard-drop
   c / tab hold        p pause     r restart        (close the window to quit)

   It also runs headless under the Ptcl test harness (sound is off there):
     newm2-driver run --library library cocoademos/tetris_cocoa.mod -- --script cocoademos/test/tetris.tcl *)
FROM SYSTEM IMPORT CAST, ADDRESS;
FROM WholeStr IMPORT CardToStr;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;
IMPORT Audio;
IMPORT Sfx;
IMPORT DemoHarness;

CONST
  W = 10; H = 20;                       (* well, in cells *)
  CellPx = 26.0; Margin = 24.0;
  WellW = 260.0; WellH = 520.0;         (* W*CellPx, H*CellPx *)
  SideX = 312.0;                        (* Margin + WellW + 28 *)
  WinW = 500.0; WinH = 568.0;
  FlashFrames = 8;

  (* macOS virtual key codes *)
  KC_LEFT = 123; KC_RIGHT = 124; KC_DOWN = 125; KC_UP = 126;
  KC_SPACE = 49; KC_P = 35; KC_R = 15; KC_C = 8; KC_TAB = 48;

  (* sound-effect ids *)
  S_MOVE = 0; S_ROTATE = 1; S_LOCK = 2; S_LINE = 3;
  S_TETRIS = 4; S_LEVEL = 5; S_OVER = 6; S_HOLD = 7;

TYPE Cells = ARRAY [0..3] OF INTEGER;

VAR
  board: ARRAY [0..W-1], [0..H-1] OF CARDINAL;   (* 0 = empty, else colour 1..7 *)
  shapes: ARRAY [0..6], [0..3] OF ARRAY [0..16] OF CHAR;  (* 4x4 grid per rotation *)
  palR, palG, palB: ARRAY [0..7] OF REAL;

  bag: ARRAY [0..6] OF CARDINAL; bagPos: CARDINAL;     (* 7-bag randomiser *)

  curType, curRot: CARDINAL;
  curX, curY:      INTEGER;
  nextType:        CARDINAL;
  holdType:        INTEGER;             (* -1 = empty *)
  holdUsed:        BOOLEAN;             (* one hold per piece *)

  gScore, gLines, gLevel, gFrames: CARDINAL;
  gOver, gPaused:  BOOLEAN;

  gFlash:          BOOLEAN;             (* line-clear flash in progress *)
  flashTimer:      CARDINAL;
  flashRows:       Cells;               (* up to 4 full rows being flashed *)
  flashN:          CARDINAL;

  gSeed:           CARDINAL;
  gAudio:          BOOLEAN;
  gView, gTimer:   ObjC.Id;

PROCEDURE Cls0 (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls0;

PROCEDURE Rnd (n: CARDINAL): CARDINAL;
BEGIN gSeed := (gSeed * 1103515245 + 12345) MOD 2147483648; RETURN (gSeed DIV 65536) MOD n END Rnd;

PROCEDURE Snd (id: CARDINAL);
BEGIN IF gAudio THEN Sfx.Play(id) END END Snd;

(* ---- 7-bag randomiser -------------------------------------------------- *)
PROCEDURE RefillBag;
  VAR i, j, t: CARDINAL;
BEGIN
  FOR i := 0 TO 6 DO bag[i] := i END;
  FOR i := 6 TO 1 BY -1 DO                 (* Fisher-Yates shuffle *)
    j := Rnd(i+1); t := bag[i]; bag[i] := bag[j]; bag[j] := t
  END;
  bagPos := 0
END RefillBag;

PROCEDURE NextPiece (): CARDINAL;
BEGIN
  IF bagPos > 6 THEN RefillBag END;
  INC(bagPos); RETURN bag[bagPos-1]
END NextPiece;

(* ---- piece geometry ---------------------------------------------------- *)
PROCEDURE PieceCells (p, r: CARDINAL; VAR cx, cy: Cells);
  VAR i, k: CARDINAL;
BEGIN
  k := 0;
  FOR i := 0 TO 15 DO
    IF shapes[p][r][i] = 'X' THEN
      IF k <= 3 THEN cx[k] := VAL(INTEGER, i MOD 4); cy[k] := VAL(INTEGER, i DIV 4); INC(k) END
    END
  END
END PieceCells;

PROCEDURE Valid (p, r: CARDINAL; ox, oy: INTEGER): BOOLEAN;
  VAR cx, cy: Cells; i: CARDINAL; bx, by: INTEGER;
BEGIN
  PieceCells(p, r, cx, cy);
  FOR i := 0 TO 3 DO
    bx := ox + cx[i]; by := oy + cy[i];
    IF (bx < 0) OR (bx >= W) OR (by >= H) THEN RETURN FALSE END;
    IF (by >= 0) AND (board[bx][by] # 0) THEN RETURN FALSE END
  END;
  RETURN TRUE
END Valid;

PROCEDURE GhostY (): INTEGER;
  VAR y: INTEGER;
BEGIN
  y := curY;
  WHILE Valid(curType, curRot, curX, y+1) DO INC(y) END;
  RETURN y
END GhostY;

(* ---- spawn / lock / clear ---------------------------------------------- *)
PROCEDURE Spawn;
BEGIN
  curType := nextType; nextType := NextPiece();
  curRot := 0; curX := 3; curY := 0;
  holdUsed := FALSE;
  IF NOT Valid(curType, curRot, curX, curY) THEN gOver := TRUE; Snd(S_OVER) END
END Spawn;

PROCEDURE CollapseFlash;          (* remove the flagged rows, score, level up *)
  VAR x: CARDINAL; src, dst: INTEGER; i, oldLevel: CARDINAL; clear: BOOLEAN;
BEGIN
  dst := H-1;
  FOR src := H-1 TO 0 BY -1 DO
    clear := FALSE;
    FOR i := 0 TO flashN-1 DO IF flashRows[i] = src THEN clear := TRUE END END;
    IF NOT clear THEN
      IF dst # src THEN FOR x := 0 TO W-1 DO board[x][dst] := board[x][src] END END;
      DEC(dst)
    END
  END;
  WHILE dst >= 0 DO FOR x := 0 TO W-1 DO board[x][dst] := 0 END; DEC(dst) END;
  oldLevel := gLevel;
  INC(gLines, flashN);
  IF    flashN = 1 THEN INC(gScore, 100 * gLevel)
  ELSIF flashN = 2 THEN INC(gScore, 300 * gLevel)
  ELSIF flashN = 3 THEN INC(gScore, 500 * gLevel)
  ELSE                  INC(gScore, 800 * gLevel) END;
  gLevel := gLines DIV 10 + 1;
  IF flashN >= 4 THEN Snd(S_TETRIS) ELSE Snd(S_LINE) END;
  IF gLevel > oldLevel THEN Snd(S_LEVEL) END
END CollapseFlash;

PROCEDURE ResolveFlash;
BEGIN CollapseFlash; gFlash := FALSE; flashN := 0; Spawn END ResolveFlash;

PROCEDURE LockPiece;
  VAR cx, cy: Cells; i: CARDINAL; bx, by: INTEGER; x, y: CARDINAL; full: BOOLEAN;
BEGIN
  PieceCells(curType, curRot, cx, cy);
  FOR i := 0 TO 3 DO
    bx := curX + cx[i]; by := curY + cy[i];
    IF (bx >= 0) AND (bx < W) AND (by >= 0) AND (by < H) THEN board[bx][by] := curType + 1 END
  END;
  Snd(S_LOCK);
  flashN := 0;                       (* find full rows -> flash, collapse later *)
  FOR y := 0 TO H-1 DO
    full := TRUE;
    FOR x := 0 TO W-1 DO IF board[x][y] = 0 THEN full := FALSE END END;
    IF full THEN flashRows[flashN] := VAL(INTEGER, y); INC(flashN) END
  END;
  IF flashN > 0 THEN gFlash := TRUE; flashTimer := FlashFrames ELSE Spawn END
END LockPiece;

(* ---- moves ------------------------------------------------------------- *)
PROCEDURE Busy (): BOOLEAN;
BEGIN RETURN gOver OR gPaused OR gFlash END Busy;

PROCEDURE MoveH (d: INTEGER);
BEGIN
  IF Busy() THEN RETURN END;
  IF Valid(curType, curRot, curX+d, curY) THEN curX := curX + d; Snd(S_MOVE) END
END MoveH;

PROCEDURE Rotate;
  VAR nr: CARDINAL;
BEGIN
  IF Busy() THEN RETURN END;
  nr := (curRot + 1) MOD 4;
  IF    Valid(curType, nr, curX,   curY) THEN curRot := nr; Snd(S_ROTATE)
  ELSIF Valid(curType, nr, curX+1, curY) THEN curRot := nr; curX := curX+1; Snd(S_ROTATE)
  ELSIF Valid(curType, nr, curX-1, curY) THEN curRot := nr; curX := curX-1; Snd(S_ROTATE)
  ELSIF Valid(curType, nr, curX+2, curY) THEN curRot := nr; curX := curX+2; Snd(S_ROTATE)
  ELSIF Valid(curType, nr, curX-2, curY) THEN curRot := nr; curX := curX-2; Snd(S_ROTATE)
  END
END Rotate;

PROCEDURE Hold;
  VAR t: CARDINAL;
BEGIN
  IF Busy() OR holdUsed THEN RETURN END;
  IF holdType < 0 THEN
    holdType := VAL(INTEGER, curType); Spawn
  ELSE
    t := curType; curType := VAL(CARDINAL, holdType); holdType := VAL(INTEGER, t);
    curRot := 0; curX := 3; curY := 0
  END;
  holdUsed := TRUE; Snd(S_HOLD)
END Hold;

PROCEDURE Gravity;                       (* one cell down, or lock / resolve flash *)
BEGIN
  IF gOver OR gPaused THEN RETURN END;
  IF gFlash THEN ResolveFlash; RETURN END;
  IF Valid(curType, curRot, curX, curY+1) THEN INC(curY) ELSE LockPiece END
END Gravity;

PROCEDURE SoftDrop;
BEGIN
  IF Busy() THEN RETURN END;
  IF Valid(curType, curRot, curX, curY+1) THEN INC(curY); INC(gScore) ELSE LockPiece END
END SoftDrop;

PROCEDURE HardDrop;
BEGIN
  IF Busy() THEN RETURN END;
  WHILE Valid(curType, curRot, curX, curY+1) DO INC(curY); INC(gScore, 2) END;
  LockPiece
END HardDrop;

PROCEDURE NewGame;
  VAR x, y: CARDINAL;
BEGIN
  FOR x := 0 TO W-1 DO FOR y := 0 TO H-1 DO board[x][y] := 0 END END;
  gScore := 0; gLines := 0; gLevel := 1; gFrames := 0;
  gOver := FALSE; gPaused := FALSE; gFlash := FALSE; flashN := 0;
  holdType := -1; holdUsed := FALSE;
  RefillBag; nextType := NextPiece(); Spawn
END NewGame;

(* ---- rendering --------------------------------------------------------- *)
PROCEDURE Pt (x, y: REAL): ObjC.NSPoint;
VAR p: ObjC.NSPoint;
BEGIN p.x := x; p.y := y; RETURN p END Pt;

PROCEDURE DrawText (s: ARRAY OF CHAR; x, y, size, r, g, b: REAL);
VAR color, font, dict, ns: ObjC.Id;
BEGIN
  color := [Cls0("NSColor") colorWithDeviceRed: r green: g blue: b alpha: 1.0];
  font  := [Cls0("NSFont") boldSystemFontOfSize: size];
  dict  := [[Cls0("NSMutableDictionary") alloc] init];
  [dict setObject: font  forKey: ObjC.NSString("NSFont")];
  [dict setObject: color forKey: ObjC.NSString("NSColor")];
  ns := ObjC.NSString(s);
  [ns drawAtPoint: Pt(x, y) withAttributes: dict]
END DrawText;

PROCEDURE Block (cg: ObjC.Id; px, py, size: REAL; col: CARDINAL; alpha: REAL);
BEGIN
  CG.SetRGBFillColor(cg, palR[col], palG[col], palB[col], alpha);
  CG.FillRect(cg, px + 1.0, py + 1.0, size - 2.0, size - 2.0)
END Block;

PROCEDURE WhiteBlock (cg: ObjC.Id; px, py, size: REAL);
BEGIN
  CG.SetRGBFillColor(cg, 0.95, 0.96, 1.0, 1.0);
  CG.FillRect(cg, px + 1.0, py + 1.0, size - 2.0, size - 2.0)
END WhiteBlock;

PROCEDURE LabelValue (label: ARRAY OF CHAR; y: REAL; n: CARDINAL);
  VAR num: ARRAY [0..15] OF CHAR;
BEGIN
  DrawText(label, SideX, y, 13.0, 0.55, 0.60, 0.68);
  CardToStr(n, num);
  DrawText(num, SideX, y + 18.0, 22.0, 0.92, 0.94, 0.98)
END LabelValue;

PROCEDURE DrawMini (cg: ObjC.Id; p: CARDINAL; ox, oy: REAL; on: BOOLEAN);
  VAR cx, cy: Cells; i: CARDINAL; a: REAL;
BEGIN
  PieceCells(p, 0, cx, cy);
  IF on THEN a := 1.0 ELSE a := 0.30 END;
  FOR i := 0 TO 3 DO
    Block(cg, ox + FLOAT(cx[i]) * 20.0, oy + FLOAT(cy[i]) * 20.0, 20.0, p + 1, a)
  END
END DrawMini;

PROCEDURE IsFlashRow (y: INTEGER): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  IF NOT gFlash THEN RETURN FALSE END;
  FOR i := 0 TO flashN-1 DO IF flashRows[i] = y THEN RETURN TRUE END END;
  RETURN FALSE
END IsFlashRow;

(* ---- the well: a Modula-2 CLASS that IS a flipped NSView --------------- *)
CLASS TetrisView;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (rx, ry, rw, rh: REAL);
    VAR cg: ObjC.Id; x, y: CARDINAL; i: CARDINAL;
        cx, cy: Cells; gy: INTEGER; bx, by, cellx, celly: REAL;
  BEGIN
    cg := [[Cls0("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.06, 0.07, 0.09, 1.0); CG.FillRect(cg, 0.0, 0.0, WinW, WinH);
    CG.SetRGBFillColor(cg, 0.10, 0.11, 0.14, 1.0); CG.FillRect(cg, Margin, Margin, WellW, WellH);
    (* settled blocks (flash rows drawn white) *)
    FOR x := 0 TO W-1 DO FOR y := 0 TO H-1 DO
      cellx := Margin + FLOAT(VAL(INTEGER,x)) * CellPx;
      celly := Margin + FLOAT(VAL(INTEGER,y)) * CellPx;
      IF IsFlashRow(VAL(INTEGER,y)) THEN WhiteBlock(cg, cellx, celly, CellPx)
      ELSIF board[x][y] # 0 THEN Block(cg, cellx, celly, CellPx, board[x][y], 1.0) END
    END END;
    IF (NOT gOver) AND (NOT gFlash) THEN
      gy := GhostY();
      PieceCells(curType, curRot, cx, cy);
      FOR i := 0 TO 3 DO                       (* ghost: where a hard-drop lands *)
        Block(cg, Margin + FLOAT(curX + cx[i]) * CellPx, Margin + FLOAT(gy + cy[i]) * CellPx,
              CellPx, curType + 1, 0.22)
      END;
      FOR i := 0 TO 3 DO                       (* current piece *)
        IF curY + cy[i] >= 0 THEN
          Block(cg, Margin + FLOAT(curX + cx[i]) * CellPx, Margin + FLOAT(curY + cy[i]) * CellPx,
                CellPx, curType + 1, 1.0)
        END
      END
    END;
    CG.SetRGBStrokeColor(cg, 0.35, 0.38, 0.45, 1.0); CG.SetLineWidth(cg, 2.0);
    CG.StrokeRect(cg, Margin, Margin, WellW, WellH);
    (* sidebar *)
    DrawText("TETRIS", SideX, Margin, 26.0, 0.40, 0.80, 0.90);
    DrawText("HOLD", SideX, Margin + 42.0, 13.0, 0.55, 0.60, 0.68);
    IF holdType >= 0 THEN DrawMini(cg, VAL(CARDINAL, holdType), SideX, Margin + 60.0, NOT holdUsed) END;
    DrawText("NEXT", SideX, Margin + 130.0, 13.0, 0.55, 0.60, 0.68);
    DrawMini(cg, nextType, SideX, Margin + 148.0, TRUE);
    LabelValue("SCORE", Margin + 216.0, gScore);
    LabelValue("LINES", Margin + 270.0, gLines);
    LabelValue("LEVEL", Margin + 324.0, gLevel);
    IF gOver THEN
      DrawText("GAME OVER", SideX, Margin + 392.0, 18.0, 0.95, 0.35, 0.35);
      DrawText("r restart", SideX, Margin + 416.0, 13.0, 0.55, 0.60, 0.68)
    ELSIF gPaused THEN
      DrawText("PAUSED", SideX, Margin + 392.0, 18.0, 0.95, 0.85, 0.30)
    END
  END DrawRect;

  PROCEDURE KeyDown (event: ObjC.Id);
    VAR getCode: ObjC.Send0I; kc: INTEGER;
  BEGIN
    getCode := CAST(ObjC.Send0I, ObjC.MsgSendPtr());
    kc := getCode(event, ObjC.Selector("keyCode"));
    IF gOver THEN
      IF kc = KC_R THEN NewGame END
    ELSIF kc = KC_LEFT  THEN MoveH(-1)
    ELSIF kc = KC_RIGHT THEN MoveH(1)
    ELSIF kc = KC_UP    THEN Rotate
    ELSIF kc = KC_DOWN  THEN SoftDrop
    ELSIF kc = KC_SPACE THEN HardDrop
    ELSIF (kc = KC_C) OR (kc = KC_TAB) THEN Hold
    ELSIF kc = KC_P     THEN gPaused := NOT gPaused
    ELSIF kc = KC_R     THEN NewGame
    END;
    [CAST(ObjC.Id, SELF) setNeedsDisplay: TRUE]
  END KeyDown;
END TetrisView;

(* ---- timer + harness --------------------------------------------------- *)
PROCEDURE FramesPerDrop (): CARDINAL;     (* gravity speed by level (~33 fps timer) *)
  VAR f: INTEGER;
BEGIN
  f := 30 - VAL(INTEGER, (gLevel - 1)) * 3;
  IF f < 3 THEN f := 3 END;
  RETURN VAL(CARDINAL, f)
END FramesPerDrop;

PROCEDURE Tick (block, timer: ObjC.Id);
BEGIN
  IF (NOT gOver) AND (NOT gPaused) THEN
    IF gFlash THEN
      IF flashTimer > 0 THEN DEC(flashTimer) END;
      IF flashTimer = 0 THEN ResolveFlash END
    ELSE
      INC(gFrames);
      IF gFrames >= FramesPerDrop() THEN gFrames := 0; Gravity END
    END
  END;
  IF gView # NIL THEN [gView setNeedsDisplay: TRUE] END
END Tick;

PROCEDURE DoSteps (n: CARDINAL);          (* `step <n>` — n gravity ticks *)
  VAR i: CARDINAL;
BEGIN FOR i := 1 TO n DO Gravity END END DoSteps;

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

PROCEDURE DoKey (name: ARRAY OF CHAR);    (* `key <name>` *)
BEGIN
  IF    NameIs(name, "left")    THEN MoveH(-1)
  ELSIF NameIs(name, "right")   THEN MoveH(1)
  ELSIF NameIs(name, "rotate")  THEN Rotate
  ELSIF NameIs(name, "up")      THEN Rotate
  ELSIF NameIs(name, "down")    THEN SoftDrop
  ELSIF NameIs(name, "drop")    THEN HardDrop
  ELSIF NameIs(name, "space")   THEN HardDrop
  ELSIF NameIs(name, "hold")    THEN Hold
  ELSIF NameIs(name, "pause")   THEN gPaused := NOT gPaused
  ELSIF NameIs(name, "restart") THEN NewGame
  END
END DoKey;

PROCEDURE ColHeight (c: INTEGER): INTEGER;     (* filled height of column c, 0..H *)
  VAR y: INTEGER;
BEGIN
  IF (c < 0) OR (c >= W) THEN RETURN 0 END;
  FOR y := 0 TO H-1 DO IF board[c][y] # 0 THEN RETURN H - y END END;
  RETURN 0
END ColHeight;

PROCEDURE Bit (b: BOOLEAN): INTEGER;
BEGIN IF b THEN RETURN 1 ELSE RETURN 0 END END Bit;

(* state the Ptcl test harness can read via the `get <name> [index]` verb *)
PROCEDURE GameState (name: ARRAY OF CHAR; idx: INTEGER): INTEGER;
BEGIN
  IF    NameIs(name, "lines")    THEN RETURN VAL(INTEGER, gLines)
  ELSIF NameIs(name, "score")    THEN RETURN VAL(INTEGER, gScore)
  ELSIF NameIs(name, "level")    THEN RETURN VAL(INTEGER, gLevel)
  ELSIF NameIs(name, "gameover") THEN RETURN Bit(gOver)
  ELSIF NameIs(name, "flashing") THEN RETURN Bit(gFlash)
  ELSIF NameIs(name, "height")   THEN RETURN ColHeight(idx)
  END;
  RETURN 0
END GameState;

(* ---- tables + audio ---------------------------------------------------- *)
PROCEDURE InitShapes;
BEGIN
  (* I *)
  shapes[0][0] := "....XXXX........"; shapes[0][1] := "..X...X...X...X.";
  shapes[0][2] := "........XXXX...."; shapes[0][3] := ".X...X...X...X..";
  (* O *)
  shapes[1][0] := ".XX..XX........."; shapes[1][1] := ".XX..XX.........";
  shapes[1][2] := ".XX..XX........."; shapes[1][3] := ".XX..XX.........";
  (* T *)
  shapes[2][0] := ".X..XXX........."; shapes[2][1] := ".X...XX..X......";
  shapes[2][2] := "....XXX..X......"; shapes[2][3] := ".X..XX...X......";
  (* S *)
  shapes[3][0] := ".XX.XX.........."; shapes[3][1] := ".X...XX...X.....";
  shapes[3][2] := "....XX..XX......"; shapes[3][3] := "X...XX...X......";
  (* Z *)
  shapes[4][0] := "XX...XX........."; shapes[4][1] := "..X..XX..X......";
  shapes[4][2] := "....XX...XX....."; shapes[4][3] := ".X..XX..X.......";
  (* J *)
  shapes[5][0] := "X...XXX........."; shapes[5][1] := ".XX..X...X......";
  shapes[5][2] := "....XXX...X....."; shapes[5][3] := ".X...X..XX......";
  (* L *)
  shapes[6][0] := "..X.XXX........."; shapes[6][1] := ".X...X...XX.....";
  shapes[6][2] := "....XXX.X......."; shapes[6][3] := "XX...X...X......"
END InitShapes;

PROCEDURE SetPal (i: CARDINAL; r, g, b: REAL);
BEGIN palR[i] := r; palG[i] := g; palB[i] := b END SetPal;

PROCEDURE InitPalette;
BEGIN
  SetPal(0, 0.10,0.11,0.14);                             (* empty *)
  SetPal(1, 0.20,0.82,0.90); SetPal(2, 0.95,0.85,0.25);  (* I cyan, O yellow *)
  SetPal(3, 0.70,0.40,0.88); SetPal(4, 0.40,0.82,0.40);  (* T purple, S green *)
  SetPal(5, 0.92,0.32,0.34); SetPal(6, 0.32,0.48,0.92);  (* Z red, J blue *)
  SetPal(7, 0.95,0.60,0.22)                              (* L orange *)
END InitPalette;

PROCEDURE InitAudio;
  VAR s: Audio.Sound;
BEGIN
  Audio.InitEngine(20260627);
  IF Sfx.Start() THEN
    Audio.Click(s, 0.03);        Sfx.Define(S_MOVE, s);   Audio.FreeSound(s);
    Audio.Blip(s, 1.4, 0.05);    Sfx.Define(S_ROTATE, s); Audio.FreeSound(s);
    Audio.Bang(s, 0.08);         Sfx.Define(S_LOCK, s);   Audio.FreeSound(s);
    Audio.Coin(s, 0.18);         Sfx.Define(S_LINE, s);   Audio.FreeSound(s);
    Audio.Explode(s, 0.6, 0.45); Sfx.Define(S_TETRIS, s); Audio.FreeSound(s);
    Audio.Powerup(s, 0.3);       Sfx.Define(S_LEVEL, s);  Audio.FreeSound(s);
    Audio.Hurt(s, 0.5);          Sfx.Define(S_OVER, s);   Audio.FreeSound(s);
    Audio.Blip(s, 0.8, 0.05);    Sfx.Define(S_HOLD, s);   Audio.FreeSound(s);
    gAudio := TRUE
  END
END InitAudio;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

(* ---- main -------------------------------------------------------------- *)
VAR win: Cocoa.Window; content: Cocoa.View; view: TetrisView;
    spath: ARRAY [0..1023] OF CHAR; ignore, scriptMode: BOOLEAN;
BEGIN
  gSeed := 20260627; gAudio := FALSE;
  InitShapes; InitPalette;
  NewGame;

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "NewM2 Tetris");
  content := Cocoa.ContentView(win);
  NEW(view);
  [CAST(ObjC.Id, view) setFrame: Rct(0.0, 0.0, WinW, WinH)];
  Cocoa.AddSubview(content, CAST(Cocoa.View, view));
  gView := CAST(ObjC.Id, view);
  [CAST(ObjC.Id, win) makeFirstResponder: CAST(ObjC.Id, view)];
  scriptMode := DemoHarness.ScriptArg(spath);
  IF scriptMode THEN
    DemoHarness.SetQuery(GameState);
    ignore := DemoHarness.Drive(CAST(Cocoa.View, view), DoSteps, DoKey, spath)
  ELSE
    InitAudio;                          (* live SFX only in interactive mode *)
    Cocoa.ShowWindow(win);
    gTimer := [Cls0("NSTimer") scheduledTimerWithTimeInterval: 0.03
                               repeats: TRUE
                               block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
    Cocoa.RunApp
  END
END tetris_cocoa.
