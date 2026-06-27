MODULE breakout_cocoa;
(* Breakout — a native Cocoa app written in Modula-2. A flipped NSView CLASS draws
   the brick wall, paddle and ball with Core Graphics; an NSTimer block runs the
   ball physics ~60x/s. The ball bounces off the side/top walls, the bricks (which
   break and score), and the paddle — where the bounce angle depends on WHERE the
   ball strikes the paddle, so you steer it. Clear the wall for the next level;
   miss the ball and lose a life. Paddle, brick, wall and loss SFX are synthesised
   in Modula-2 (Audio) and played non-blocking through CoreAudio (Sfx).

     newm2-driver run --library library cocoademos/breakout_cocoa.mod
   left / right move paddle   space launch / serve
   p pause   r restart   (close the window to quit)

   Headless under the Ptcl test harness (sound off there):
     newm2-driver run --library library cocoademos/breakout_cocoa.mod -- --script cocoademos/test/breakout.tcl *)
FROM SYSTEM IMPORT CAST, ADDRESS;
FROM RealMath IMPORT sqrt;
FROM WholeStr IMPORT CardToStr;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;
IMPORT Audio;
IMPORT Sfx;
IMPORT DemoHarness;

CONST
  WinW = 726.0; WinH = 600.0;
  Wall = 13.0;
  BCols = 11; BRows = 6;
  BrickTop = 78.0; BrickH = 24.0; BrickGap = 2.0;
  PaddleW = 100.0; PaddleH = 14.0; PaddleY = 548.0;   (* flipped: near the bottom *)
  PaddleStep = 9.0;                                    (* px / frame while held *)
  BallR = 7.0; Speed = 6.3;
  KC_LEFT = 123; KC_RIGHT = 124; KC_SPACE = 49; KC_P = 35; KC_R = 15;

  S_PADDLE = 0; S_BRICK = 1; S_WALL = 2; S_LOSE = 3; S_WIN = 4;

VAR
  brick:  ARRAY [0..BRows-1], [0..BCols-1] OF BOOLEAN;
  brickW: REAL;
  px:     REAL;                         (* paddle left x *)
  bx, by, vx, vy: REAL;                 (* ball *)
  launched: BOOLEAN;
  gScore, gLevel, gBricks: CARDINAL; gLives: INTEGER;
  gOver, gPaused: BOOLEAN;
  kLeft, kRight: BOOLEAN;
  gSeed: CARDINAL; gAudio: BOOLEAN;
  gView, gTimer: ObjC.Id;
  rowR, rowG, rowB: ARRAY [0..BRows-1] OF REAL;

PROCEDURE Cls0 (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls0;

PROCEDURE Snd (id: CARDINAL);
BEGIN IF gAudio THEN Sfx.Play(id) END END Snd;

PROCEDURE RowPoints (r: CARDINAL): CARDINAL;     (* top rows worth more *)
BEGIN RETURN (BRows - r) * 10 END RowPoints;

(* ---- setup ------------------------------------------------------------- *)
PROCEDURE FillWall;
  VAR r, c: CARDINAL;
BEGIN
  gBricks := 0;
  FOR r := 0 TO BRows-1 DO FOR c := 0 TO BCols-1 DO brick[r][c] := TRUE; INC(gBricks) END END
END FillWall;

PROCEDURE ResetBall;                              (* stick to the paddle, unlaunched *)
BEGIN
  bx := px + PaddleW/2.0; by := PaddleY - BallR - 1.0;
  vx := 0.0; vy := 0.0; launched := FALSE
END ResetBall;

PROCEDURE NewLevel;
BEGIN FillWall; px := WinW/2.0 - PaddleW/2.0; ResetBall END NewLevel;

PROCEDURE NewGame;
BEGIN
  gScore := 0; gLevel := 1; gLives := 3; gOver := FALSE; gPaused := FALSE;
  NewLevel
END NewGame;

PROCEDURE Launch;
BEGIN
  IF (NOT launched) AND (NOT gOver) AND (NOT gPaused) THEN
    vx := 2.2; vy := -sqrt(Speed*Speed - vx*vx); launched := TRUE
  END
END Launch;

(* ---- paddle ------------------------------------------------------------ *)
PROCEDURE MovePaddle (d: REAL);
BEGIN
  px := px + d;
  IF px < Wall THEN px := Wall END;
  IF px > WinW - Wall - PaddleW THEN px := WinW - Wall - PaddleW END;
  IF NOT launched THEN bx := px + PaddleW/2.0 END
END MovePaddle;

(* ---- ball physics ------------------------------------------------------ *)
PROCEDURE BrickX (c: CARDINAL): REAL;
BEGIN RETURN Wall + FLOAT(VAL(INTEGER,c)) * brickW END BrickX;

PROCEDURE BrickYr (r: CARDINAL): REAL;
BEGIN RETURN BrickTop + FLOAT(VAL(INTEGER,r)) * BrickH END BrickYr;

PROCEDURE BouncePaddle;
  VAR offset: REAL;
BEGIN
  offset := (bx - (px + PaddleW/2.0)) / (PaddleW/2.0);
  IF offset < -1.0 THEN offset := -1.0 ELSIF offset > 1.0 THEN offset := 1.0 END;
  vx := offset * Speed * 0.82;
  vy := -sqrt(Speed*Speed - vx*vx);             (* always up *)
  Snd(S_PADDLE)
END BouncePaddle;

PROCEDURE HitBricks;                              (* break at most one brick / frame *)
  VAR r, c: CARDINAL; bxL, bxR, byT, byB, prevY: REAL; hit: BOOLEAN;
BEGIN
  FOR r := 0 TO BRows-1 DO
    FOR c := 0 TO BCols-1 DO
      IF brick[r][c] THEN
        bxL := BrickX(c); bxR := bxL + brickW - BrickGap;
        byT := BrickYr(r); byB := byT + BrickH - BrickGap;
        hit := (bx + BallR > bxL) AND (bx - BallR < bxR)
           AND (by + BallR > byT) AND (by - BallR < byB);
        IF hit THEN
          brick[r][c] := FALSE; DEC(gBricks);
          INC(gScore, RowPoints(r)); Snd(S_BRICK);
          prevY := by - vy;                       (* where the ball was last frame *)
          IF (prevY <= byT) OR (prevY >= byB) THEN vy := -vy ELSE vx := -vx END;
          RETURN
        END
      END
    END
  END
END HitBricks;

PROCEDURE LoseBall;
BEGIN
  Snd(S_LOSE); DEC(gLives);
  IF gLives < 0 THEN gOver := TRUE ELSE ResetBall END
END LoseBall;

PROCEDURE UpdateWorld;                            (* one physics frame *)
BEGIN
  IF gOver OR gPaused THEN RETURN END;
  IF NOT launched THEN RETURN END;
  bx := bx + vx; by := by + vy;
  (* side + top walls *)
  IF (bx - BallR < Wall) THEN bx := Wall + BallR; vx := -vx; Snd(S_WALL) END;
  IF (bx + BallR > WinW - Wall) THEN bx := WinW - Wall - BallR; vx := -vx; Snd(S_WALL) END;
  IF (by - BallR < Wall) THEN by := Wall + BallR; vy := -vy; Snd(S_WALL) END;
  (* paddle (ball moving down onto it) *)
  IF (vy > 0.0) AND (by + BallR >= PaddleY) AND (by + BallR <= PaddleY + PaddleH + 6.0)
     AND (bx >= px - BallR) AND (bx <= px + PaddleW + BallR) THEN
    by := PaddleY - BallR; BouncePaddle
  END;
  HitBricks;
  IF gBricks = 0 THEN INC(gLevel); Snd(S_WIN); NewLevel; RETURN END;
  IF by - BallR > WinH THEN LoseBall END
END UpdateWorld;

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

PROCEDURE PutNum (label: ARRAY OF CHAR; n: CARDINAL; x, y: REAL);
  VAR buf: ARRAY [0..47] OF CHAR; num: ARRAY [0..15] OF CHAR; i, p: CARDINAL;
BEGIN
  p := 0; i := 0;
  WHILE (i <= HIGH(label)) AND (label[i] # 0C) DO buf[p] := label[i]; INC(p); INC(i) END;
  CardToStr(n, num); i := 0;
  WHILE (num[i] # 0C) AND (p < HIGH(buf)) DO buf[p] := num[i]; INC(p); INC(i) END;
  buf[p] := 0C;
  DrawText(buf, x, y, 15.0, 0.88, 0.90, 0.95)
END PutNum;

(* ---- the court: a Modula-2 CLASS that IS a flipped NSView -------------- *)
CLASS BreakoutView;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (qx, qy, qw, qh: REAL);
    VAR cg: ObjC.Id; r, c: CARDINAL; k: INTEGER;
  BEGIN
    cg := [[Cls0("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.05, 0.06, 0.08, 1.0); CG.FillRect(cg, 0.0, 0.0, WinW, WinH);
    (* side walls *)
    CG.SetRGBFillColor(cg, 0.16, 0.18, 0.22, 1.0);
    CG.FillRect(cg, 0.0, 0.0, Wall, WinH); CG.FillRect(cg, WinW - Wall, 0.0, Wall, WinH);
    CG.FillRect(cg, 0.0, 0.0, WinW, Wall);
    (* bricks *)
    FOR r := 0 TO BRows-1 DO
      CG.SetRGBFillColor(cg, rowR[r], rowG[r], rowB[r], 1.0);
      FOR c := 0 TO BCols-1 DO
        IF brick[r][c] THEN
          CG.FillRect(cg, BrickX(c), BrickYr(r), brickW - BrickGap, BrickH - BrickGap)
        END
      END
    END;
    (* paddle *)
    CG.SetRGBFillColor(cg, 0.85, 0.88, 0.95, 1.0);
    CG.FillRect(cg, px, PaddleY, PaddleW, PaddleH);
    (* ball *)
    CG.SetRGBFillColor(cg, 1.0, 0.95, 0.55, 1.0);
    CG.FillEllipseInRect(cg, bx - BallR, by - BallR, BallR * 2.0, BallR * 2.0);
    (* HUD *)
    PutNum("SCORE ", gScore, 20.0, 24.0);
    PutNum("LEVEL ", gLevel, WinW/2.0 - 36.0, 24.0);
    FOR k := 0 TO gLives-1 DO
      CG.SetRGBFillColor(cg, 0.85, 0.88, 0.95, 1.0);
      CG.FillRect(cg, WinW - 40.0 - FLOAT(k) * 30.0, 22.0, 22.0, 8.0)
    END;
    IF NOT launched THEN
      DrawText("press space to serve", WinW/2.0 - 96.0, PaddleY - 40.0, 14.0, 0.7, 0.74, 0.8)
    END;
    IF gOver THEN
      DrawText("GAME OVER", WinW/2.0 - 78.0, WinH/2.0 - 16.0, 30.0, 0.95, 0.4, 0.4);
      DrawText("press r to restart", WinW/2.0 - 80.0, WinH/2.0 + 24.0, 14.0, 0.7, 0.72, 0.78)
    ELSIF gPaused THEN
      DrawText("PAUSED", WinW/2.0 - 48.0, WinH/2.0, 26.0, 0.95, 0.85, 0.3)
    END
  END DrawRect;

  PROCEDURE KeyDown (event: ObjC.Id);
    VAR getCode: ObjC.Send0I; kc: INTEGER;
  BEGIN
    getCode := CAST(ObjC.Send0I, ObjC.MsgSendPtr());
    kc := getCode(event, ObjC.Selector("keyCode"));
    IF    kc = KC_LEFT  THEN kLeft := TRUE
    ELSIF kc = KC_RIGHT THEN kRight := TRUE
    ELSIF kc = KC_SPACE THEN Launch
    ELSIF kc = KC_P     THEN gPaused := NOT gPaused
    ELSIF kc = KC_R     THEN NewGame
    END
  END KeyDown;

  PROCEDURE KeyUp (event: ObjC.Id);
    VAR getCode: ObjC.Send0I; kc: INTEGER;
  BEGIN
    getCode := CAST(ObjC.Send0I, ObjC.MsgSendPtr());
    kc := getCode(event, ObjC.Selector("keyCode"));
    IF    kc = KC_LEFT  THEN kLeft := FALSE
    ELSIF kc = KC_RIGHT THEN kRight := FALSE
    END
  END KeyUp;
END BreakoutView;

(* ---- timer + harness --------------------------------------------------- *)
PROCEDURE Tick (block, timer: ObjC.Id);
BEGIN
  IF (NOT gOver) AND (NOT gPaused) THEN
    IF kLeft  THEN MovePaddle(-PaddleStep) END;
    IF kRight THEN MovePaddle(PaddleStep) END;
    UpdateWorld
  END;
  IF gView # NIL THEN [gView setNeedsDisplay: TRUE] END
END Tick;

PROCEDURE DoSteps (n: CARDINAL);
  VAR i: CARDINAL;
BEGIN FOR i := 1 TO n DO UpdateWorld END END DoSteps;

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
  IF    NameIs(name, "left")    THEN MovePaddle(-26.0)
  ELSIF NameIs(name, "right")   THEN MovePaddle(26.0)
  ELSIF NameIs(name, "launch")  THEN Launch
  ELSIF NameIs(name, "space")   THEN Launch
  ELSIF NameIs(name, "pause")   THEN gPaused := NOT gPaused
  ELSIF NameIs(name, "restart") THEN NewGame
  END
END DoKey;

PROCEDURE Bit (b: BOOLEAN): INTEGER;
BEGIN IF b THEN RETURN 1 ELSE RETURN 0 END END Bit;

PROCEDURE GameState (name: ARRAY OF CHAR; idx: INTEGER): INTEGER;
BEGIN
  IF    NameIs(name, "score")    THEN RETURN VAL(INTEGER, gScore)
  ELSIF NameIs(name, "level")    THEN RETURN VAL(INTEGER, gLevel)
  ELSIF NameIs(name, "lives")    THEN RETURN gLives
  ELSIF NameIs(name, "bricks")   THEN RETURN VAL(INTEGER, gBricks)
  ELSIF NameIs(name, "launched") THEN RETURN Bit(launched)
  ELSIF NameIs(name, "gameover") THEN RETURN Bit(gOver)
  END;
  RETURN 0
END GameState;

(* ---- palette + audio + main -------------------------------------------- *)
PROCEDURE SetRow (r: CARDINAL; rr, gg, bb: REAL);
BEGIN rowR[r] := rr; rowG[r] := gg; rowB[r] := bb END SetRow;

PROCEDURE InitRows;
BEGIN
  SetRow(0, 0.92,0.30,0.32); SetRow(1, 0.95,0.58,0.24);   (* red, orange *)
  SetRow(2, 0.93,0.83,0.28); SetRow(3, 0.40,0.82,0.40);   (* yellow, green *)
  SetRow(4, 0.30,0.78,0.86); SetRow(5, 0.40,0.55,0.92)    (* cyan, blue *)
END InitRows;

PROCEDURE InitAudio;
  VAR s: Audio.Sound;
BEGIN
  Audio.InitEngine(73108);
  IF Sfx.Start() THEN
    Audio.Blip(s, 0.7, 0.05);  Sfx.Define(S_PADDLE, s); Audio.FreeSound(s);
    Audio.Blip(s, 1.6, 0.04);  Sfx.Define(S_BRICK, s);  Audio.FreeSound(s);
    Audio.Click(s, 0.03);      Sfx.Define(S_WALL, s);   Audio.FreeSound(s);
    Audio.Hurt(s, 0.4);        Sfx.Define(S_LOSE, s);   Audio.FreeSound(s);
    Audio.Powerup(s, 0.35);    Sfx.Define(S_WIN, s);    Audio.FreeSound(s);
    gAudio := TRUE
  END
END InitAudio;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

VAR win: Cocoa.Window; content: Cocoa.View; view: BreakoutView;
    spath: ARRAY [0..1023] OF CHAR; ignore, scriptMode: BOOLEAN;
BEGIN
  gSeed := 13579; gAudio := FALSE;
  kLeft := FALSE; kRight := FALSE;
  brickW := (WinW - 2.0 * Wall) / FLOAT(BCols);
  InitRows; NewGame;

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "NewM2 Breakout");
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
    InitAudio;
    Cocoa.ShowWindow(win);
    gTimer := [Cls0("NSTimer") scheduledTimerWithTimeInterval: 0.016
                               repeats: TRUE
                               block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
    Cocoa.RunApp
  END
END breakout_cocoa.
