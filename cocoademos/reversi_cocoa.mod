MODULE reversi_cocoa;
(* Reversi / Othello as a native Cocoa app — the macOS port of demos/reversi_gui.mod
   (which draws via Direct2D / Canvas2D on Windows). The board is a Modula-2 CLASS
   that INHERITs NSView: it draws the green grid, the black/white discs, and the
   small dots marking your legal moves with Core Graphics, and handles the clicks.
   You play Black; the computer plays White (greedy, corner-preferring). The board
   logic is identical to the Windows version — only the rendering and input differ.

     newm2-driver run --library library demos/reversi_cocoa.mod
   Click a dotted square to play.  R: new game. *)
FROM SYSTEM IMPORT CAST;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;
IMPORT DemoHarness;

VAR gGalleryPath: ARRAY [0..1023] OF CHAR; gGalleryIgnore: BOOLEAN;

CONST
  N = 8;
  EMPTY = 0; BLACK = 1; WHITE = 2;
  Margin = 24.0; CellPx = 60.0; BoardPx = 480.0;   (* device-point geometry *)
  WinW = 528.0; WinH = 528.0;                       (* 2*Margin + BoardPx *)

VAR
  board:  ARRAY [0..N-1], [0..N-1] OF CARDINAL;
  DX, DY: ARRAY [0..7] OF INTEGER;
  gTurn:  CARDINAL;
  gOver:  BOOLEAN;
  gWin:   ObjC.Id;                                  (* the NSWindow — status title *)

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

PROCEDURE R (c: CARDINAL): REAL;                    (* CARDINAL -> REAL *)
BEGIN RETURN FLOAT(VAL(INTEGER, c)) END R;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

(* --- board logic (ported from demos/reversi_gui.mod) -------------------- *)
PROCEDURE Opp (p: CARDINAL): CARDINAL;
BEGIN IF p = BLACK THEN RETURN WHITE ELSE RETURN BLACK END END Opp;

PROCEDURE InBounds (x, y: INTEGER): BOOLEAN;
BEGIN RETURN (x >= 0) AND (x < N) AND (y >= 0) AND (y < N) END InBounds;

PROCEDURE CellAt (x, y: INTEGER): CARDINAL;
BEGIN RETURN board[VAL(CARDINAL, x)][VAL(CARDINAL, y)] END CellAt;

PROCEDURE WouldFlip (x, y, player: CARDINAL): CARDINAL;
  VAR d, cnt, total, opp: CARDINAL; cx, cy: INTEGER;
BEGIN
  IF board[x][y] # EMPTY THEN RETURN 0 END;
  opp := Opp(player); total := 0;
  FOR d := 0 TO 7 DO
    cx := VAL(INTEGER, x) + DX[d]; cy := VAL(INTEGER, y) + DY[d]; cnt := 0;
    WHILE InBounds(cx, cy) AND (CellAt(cx, cy) = opp) DO
      INC(cnt); cx := cx + DX[d]; cy := cy + DY[d]
    END;
    IF InBounds(cx, cy) AND (CellAt(cx, cy) = player) AND (cnt > 0) THEN total := total + cnt END
  END;
  RETURN total
END WouldFlip;

PROCEDURE ApplyMove (x, y, player: CARDINAL);
  VAR d, cnt, k, opp: CARDINAL; cx, cy: INTEGER;
BEGIN
  board[x][y] := player; opp := Opp(player);
  FOR d := 0 TO 7 DO
    cx := VAL(INTEGER, x) + DX[d]; cy := VAL(INTEGER, y) + DY[d]; cnt := 0;
    WHILE InBounds(cx, cy) AND (CellAt(cx, cy) = opp) DO
      INC(cnt); cx := cx + DX[d]; cy := cy + DY[d]
    END;
    IF InBounds(cx, cy) AND (CellAt(cx, cy) = player) AND (cnt > 0) THEN
      cx := VAL(INTEGER, x) + DX[d]; cy := VAL(INTEGER, y) + DY[d];
      FOR k := 1 TO cnt DO
        board[VAL(CARDINAL, cx)][VAL(CARDINAL, cy)] := player;
        cx := cx + DX[d]; cy := cy + DY[d]
      END
    END
  END
END ApplyMove;

PROCEDURE HasMove (player: CARDINAL): BOOLEAN;
  VAR x, y: CARDINAL;
BEGIN
  FOR x := 0 TO N-1 DO FOR y := 0 TO N-1 DO
    IF WouldFlip(x, y, player) > 0 THEN RETURN TRUE END
  END END;
  RETURN FALSE
END HasMove;

PROCEDURE Score (player: CARDINAL): CARDINAL;
  VAR x, y, s: CARDINAL;
BEGIN s := 0;
  FOR x := 0 TO N-1 DO FOR y := 0 TO N-1 DO IF board[x][y] = player THEN INC(s) END END END;
  RETURN s
END Score;

PROCEDURE Weight (x, y: CARDINAL): CARDINAL;
  VAR corner, edge: BOOLEAN;
BEGIN
  corner := ((x = 0) OR (x = N-1)) AND ((y = 0) OR (y = N-1));
  edge   := (x = 0) OR (x = N-1) OR (y = 0) OR (y = N-1);
  IF corner THEN RETURN 50 ELSIF edge THEN RETURN 3 ELSE RETURN 1 END
END Weight;

PROCEDURE AIMove;
  VAR x, y, f, sc, best, bx, by: CARDINAL; found: BOOLEAN;
BEGIN
  best := 0; bx := 0; by := 0; found := FALSE;
  FOR x := 0 TO N-1 DO FOR y := 0 TO N-1 DO
    f := WouldFlip(x, y, WHITE);
    IF f > 0 THEN
      sc := f + Weight(x, y) * 2;
      IF (NOT found) OR (sc > best) THEN best := sc; bx := x; by := y; found := TRUE END
    END
  END END;
  IF found THEN ApplyMove(bx, by, WHITE) END
END AIMove;

PROCEDURE AdvanceTurn;
BEGIN
  gTurn := Opp(gTurn);
  IF NOT HasMove(gTurn) THEN
    gTurn := Opp(gTurn);
    IF NOT HasMove(gTurn) THEN gOver := TRUE END
  END
END AdvanceTurn;

PROCEDURE RunAI;
BEGIN WHILE (NOT gOver) AND (gTurn = WHITE) DO AIMove; AdvanceTurn END END RunAI;

PROCEDURE NewGame;
  VAR x, y: CARDINAL;
BEGIN
  FOR x := 0 TO N-1 DO FOR y := 0 TO N-1 DO board[x][y] := EMPTY END END;
  board[3][3] := WHITE; board[4][4] := WHITE;
  board[3][4] := BLACK; board[4][3] := BLACK;
  gTurn := BLACK; gOver := FALSE
END NewGame;

PROCEDURE InitDirs;
BEGIN
  DX[0]:=-1; DY[0]:=-1;  DX[1]:= 0; DY[1]:=-1;  DX[2]:= 1; DY[2]:=-1;
  DX[3]:=-1; DY[3]:= 0;                          DX[4]:= 1; DY[4]:= 0;
  DX[5]:=-1; DY[5]:= 1;  DX[6]:= 0; DY[6]:= 1;  DX[7]:= 1; DY[7]:= 1
END InitDirs;

(* --- status line in the window title ------------------------------------ *)
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
  IF n = 0 THEN
    IF pos < HIGH(dst) THEN dst[pos] := '0'; INC(pos) END
  ELSE
    k := 0;
    WHILE n > 0 DO digs[k] := CHR(ORD('0') + (n MOD 10)); INC(k); n := n DIV 10 END;
    WHILE k > 0 DO DEC(k); IF pos < HIGH(dst) THEN dst[pos] := digs[k]; INC(pos) END END
  END;
  dst[pos] := 0C
END PutNum;

PROCEDURE UpdateTitle;
  VAR buf: ARRAY [0..127] OF CHAR; pos, b, w: CARDINAL;
BEGIN
  b := Score(BLACK); w := Score(WHITE); pos := 0;
  PutStr(buf, pos, "Reversi   Black ");  PutNum(buf, pos, b);
  PutStr(buf, pos, "   White ");         PutNum(buf, pos, w);
  PutStr(buf, pos, "    ");
  IF gOver THEN
    IF b > w THEN PutStr(buf, pos, "Black wins!")
    ELSIF w > b THEN PutStr(buf, pos, "White wins!")
    ELSE PutStr(buf, pos, "Draw.") END;
    PutStr(buf, pos, "   (R: new game)")
  ELSIF gTurn = BLACK THEN PutStr(buf, pos, "your move   (R: new game)")
  ELSE PutStr(buf, pos, "White thinking") END;
  IF gWin # NIL THEN [gWin setTitle: ObjC.NSString(buf)] END
END UpdateTitle;

(* --- the board: a Modula-2 CLASS that IS an NSView ---------------------- *)
CLASS BoardView;
  INHERIT NSView;                         (* superclass resolved from Cocoa metadata *)

  PROCEDURE IsFlipped (): BOOLEAN;        (* top-left origin: row 0 at the top *)
  BEGIN RETURN TRUE END IsFlipped;

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;   (* so it receives the R key *)
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (x, y, w, h: REAL);   (* drawRect: — NSRect as four REALs *)
    VAR cg: ObjC.Id; col, row, i: CARDINAL; cellX, cellY, lx, ly, cd: REAL;
  BEGIN
    cg := [[Cls("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;

    (* backdrop + felt board *)
    CG.SetRGBFillColor(cg, 0.12, 0.13, 0.16, 1.0);  CG.FillRect(cg, 0.0, 0.0, w, h);
    CG.SetRGBFillColor(cg, 0.18, 0.50, 0.31, 1.0);  CG.FillRect(cg, Margin, Margin, BoardPx, BoardPx);

    (* grid lines *)
    CG.SetRGBStrokeColor(cg, 0.10, 0.29, 0.20, 1.0);  CG.SetLineWidth(cg, 1.0);
    FOR i := 0 TO N DO
      lx := Margin + R(i) * CellPx;
      CG.MoveToPoint(cg, lx, Margin);  CG.AddLineToPoint(cg, lx, Margin + BoardPx);
      ly := Margin + R(i) * CellPx;
      CG.MoveToPoint(cg, Margin, ly);  CG.AddLineToPoint(cg, Margin + BoardPx, ly)
    END;
    CG.StrokePath(cg);
    cd := CellPx - 12.0;                    (* disc diameter *)

    (* discs, and the small dots for your legal moves *)
    FOR col := 0 TO N-1 DO
      FOR row := 0 TO N-1 DO
        cellX := Margin + R(col) * CellPx;
        cellY := Margin + R(row) * CellPx;
        IF board[col][row] = BLACK THEN
          CG.SetRGBFillColor(cg, 0.07, 0.07, 0.08, 1.0);
          CG.FillEllipseInRect(cg, cellX + 6.0, cellY + 6.0, cd, cd)
        ELSIF board[col][row] = WHITE THEN
          CG.SetRGBFillColor(cg, 0.95, 0.95, 0.90, 1.0);
          CG.FillEllipseInRect(cg, cellX + 6.0, cellY + 6.0, cd, cd)
        ELSIF (NOT gOver) AND (gTurn = BLACK) AND (WouldFlip(col, row, BLACK) > 0) THEN
          CG.SetRGBFillColor(cg, 0.85, 0.92, 0.70, 0.55);
          CG.FillEllipseInRect(cg, cellX + CellPx/2.0 - 5.0, cellY + CellPx/2.0 - 5.0, 10.0, 10.0)
        END
      END
    END
  END DrawRect;

  PROCEDURE MouseDown (event: ObjC.Id);    (* mouseDown: — play the clicked square *)
    VAR me: ObjC.Id; p, vp: ObjC.NSPoint; fx, fy: REAL; igx, igy: INTEGER; gx, gy: CARDINAL;
  BEGIN
    IF gOver OR (gTurn # BLACK) THEN RETURN END;
    me := CAST(ObjC.Id, SELF);
    p  := [event locationInWindow];
    vp := [me convertPoint: p fromView: NIL];
    fx := vp.x - Margin; fy := vp.y - Margin;
    IF (fx < 0.0) OR (fy < 0.0) OR (fx >= BoardPx) OR (fy >= BoardPx) THEN RETURN END;
    igx := TRUNC(fx / CellPx); igy := TRUNC(fy / CellPx);
    gx := VAL(CARDINAL, igx); gy := VAL(CARDINAL, igy);
    IF (gx >= N) OR (gy >= N) THEN RETURN END;
    IF WouldFlip(gx, gy, BLACK) = 0 THEN RETURN END;
    ApplyMove(gx, gy, BLACK); AdvanceTurn; RunAI;
    UpdateTitle;
    [me setNeedsDisplay: TRUE]
  END MouseDown;

  PROCEDURE KeyDown (event: ObjC.Id);      (* keyDown: — R starts a new game *)
    VAR s: ObjC.Id; buf: ARRAY [0..15] OF CHAR; n: INTEGER;
  BEGIN
    s := [event charactersIgnoringModifiers];
    n := ObjC.GetString(s, buf);
    IF (n > 0) AND ((buf[0] = 'r') OR (buf[0] = 'R')) THEN
      NewGame; UpdateTitle; [CAST(ObjC.Id, SELF) setNeedsDisplay: TRUE]
    END
  END KeyDown;
END BoardView;

(* --- main --------------------------------------------------------------- *)
VAR win: Cocoa.Window; content: Cocoa.View; view: BoardView;
BEGIN
  InitDirs; NewGame;
  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "Reversi");
  gWin := CAST(ObjC.Id, win);
  content := Cocoa.ContentView(win);
  NEW(view);
  [CAST(ObjC.Id, view) setFrame: Rct(0.0, 0.0, WinW, WinH)];
  Cocoa.AddSubview(content, CAST(Cocoa.View, view));
  [gWin makeFirstResponder: CAST(ObjC.Id, view)];
  IF DemoHarness.ScriptArg(gGalleryPath) THEN
    gGalleryIgnore := Cocoa.Snapshot(content, gGalleryPath)
  ELSE
    Cocoa.ShowWindow(win);
  UpdateTitle;
  Cocoa.RunApp
  END
END reversi_cocoa.
