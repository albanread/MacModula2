MODULE galaxigans;
(* Galaxigans — a swarming-formation space shooter, on the native macOS Metal game
   pane (IndexedPane) with synthesised SFX (Sfx + Audio) and ABC music cues
   (AVMIDIPlayer). Ported from demos/galaga.mod (Windows GameViewGpu); the game
   logic is unchanged — only the window/loop/input bind to IndexedPane, the shot &
   explosion play through the live Audio synth, and the music plays non-blocking.

     newm2-driver run --library library cocoademos/galaxigans.mod
   left / right move    space fire *)
FROM SYSTEM IMPORT CAST, ADDRESS;
FROM IndexedPane IMPORT
  Create, Run, KeyHeld, KeyLeft, KeyRight, KeySpace,
  LoadDefaultPalette, Cls, Text, DefineSprite, AddFrame, SpriteRGB,
  Place, MoveTo, SpriteX, SpriteY, Hit, SetScale, SetRotation, SetAlpha,
  Animate, Show, Hide, Present;
FROM NM2Math IMPORT sin;
FROM WholeStr IMPORT CardToStr;
IMPORT ObjC;
IMPORT Audio;
IMPORT Sfx;
FROM Abc IMPORT Tune, ParseTune;
IMPORT SmfFile;

CONST
  VW = 640; VH = 480;
  NEnemies = 60; NBullets = 3; NBombs = 10; NExpl = 5; NStars = 24; NSBombs = 4; MaxDivers = 6;
  PlayerI = 0; EBase = 1; BulBase = 61; ExpBase = 64; BombBase = 70; SBombBase = 80; SaucerI = 100; StarBase = 110;
  DPlayer=0; DBee=1; DBoss=2; DBullet=3; DBomb=4; DStar=5; DExpl=6; DBfly=7; DMoth=8; DSaucer=11;
  StIntro = 0; StPlay = 1; StOver = 2; StWin = 3;
  SH_SHOOT = 0; SH_BOOM = 1;            (* live synth SFX ids *)

VAR
  gLeft, gRight, gFire, gFireEdge, gFirePrev: BOOLEAN;
  px: REAL;
  alive: ARRAY [0..NEnemies] OF BOOLEAN;
  diveT, retT: ARRAY [0..NEnemies] OF REAL;
  bAct: ARRAY [0..NBullets] OF BOOLEAN;
  bx, by: ARRAY [0..NBullets] OF REAL;
  bombAct: ARRAY [0..NBombs] OF BOOLEAN;
  bombx, bomby: ARRAY [0..NBombs] OF REAL;
  expT: ARRAY [0..NExpl] OF REAL;
  starY: ARRAY [0..NStars] OF REAL;
  fx, fdir: REAL;
  score, lives, frame, state, stateTimer: CARDINAL;
  pAlive: BOOLEAN; pRespawn, fireCd, saucerActive: CARDINAL;
  saucerX, saucerDx, saucerY: REAL; saucerTimer: CARDINAL;
  sbombAct: ARRAY [0..NSBombs] OF BOOLEAN;
  sbombx, sbomby: ARRAY [0..NSBombs] OF REAL;
  ok: BOOLEAN;
  gSeed: CARDINAL;
  pIntro, pWin, pOver, pDrone: ObjC.Id;

PROCEDURE Rnd (n: CARDINAL): CARDINAL;
BEGIN gSeed := (gSeed*1103515245 + 12345) MOD 2147483648; IF n=0 THEN RETURN 0 END; RETURN (gSeed DIV 65536) MOD n END Rnd;

(* ---- sound: synth SFX (live) + ABC music cues (non-blocking AVMIDIPlayer) ---- *)
VAR abc: ARRAY [0..511] OF CHAR; an: CARDINAL;
PROCEDURE Cls0 (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls0;
PROCEDURE ALn (s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i:=0; WHILE (i<=HIGH(s)) AND (s[i]#0C) DO abc[an]:=s[i]; INC(an); INC(i) END; abc[an]:=CHR(10); INC(an); abc[an]:=0C END ALn;
PROCEDURE MakePlayer (path: ARRAY OF CHAR): ObjC.Id;
  VAR url, p: ObjC.Id;
BEGIN
  url := [Cls0("NSURL") fileURLWithPath: ObjC.NSString(path)];
  p := [[Cls0("AVMIDIPlayer") alloc] initWithContentsOfURL: url soundBankURL: NIL error: NIL];
  IF p # NIL THEN [p prepareToPlay] END;
  RETURN p
END MakePlayer;
PROCEDURE PlayMusic (p: ObjC.Id);
BEGIN IF p # NIL THEN [p setCurrentPosition: 0.0]; [p play: NIL] END END PlayMusic;

PROCEDURE BuildSounds;
  VAR s: Audio.Sound; t: Tune;
BEGIN
  (* live SFX: a laser for the shot, a boom for explosions *)
  Audio.InitEngine(777);
  IF Sfx.Start() THEN
    Audio.Shoot(s, 0.18);        Sfx.Define(SH_SHOOT, s); Audio.FreeSound(s);
    Audio.Explode(s, 0.7, 0.5);  Sfx.Define(SH_BOOM, s);  Audio.FreeSound(s)
  END;
  ObjC.LoadFramework("AVFoundation");
  an:=0; ALn("X:1"); ALn("M:4/4"); ALn("L:1/16"); ALn("Q:1/4=84"); ALn("%%MIDI program 52"); ALn("K:Am");
  ALn("z8 A,4 E4|A4 c4 e4 d4|c8 B8|A16|");
  IF ParseTune(abc, t) THEN ok := SmfFile.WriteSmf("/tmp/gx_intro.mid", t); pIntro := MakePlayer("/tmp/gx_intro.mid") END;
  an:=0; ALn("X:1"); ALn("M:4/4"); ALn("L:1/16"); ALn("Q:1/4=234"); ALn("%%MIDI program 9"); ALn("K:C");
  ALn("c2e2g2c'2 e'2c'2b2a2|g2e2c2G2 c4 z4|");
  IF ParseTune(abc, t) THEN ok := SmfFile.WriteSmf("/tmp/gx_win.mid", t); pWin := MakePlayer("/tmp/gx_win.mid") END;
  an:=0; ALn("X:1"); ALn("M:4/4"); ALn("L:1/16"); ALn("Q:1/4=210"); ALn("%%MIDI program 80"); ALn("K:Cm");
  ALn("G,8 _B,8|c8 _e8|_e4d4c4_B4|G,16|");
  IF ParseTune(abc, t) THEN ok := SmfFile.WriteSmf("/tmp/gx_over.mid", t); pOver := MakePlayer("/tmp/gx_over.mid") END;
  an:=0; ALn("X:1"); ALn("M:4/4"); ALn("L:1/16"); ALn("Q:1/4=90"); ALn("%%MIDI program 89"); ALn("K:C");
  ALn("C,,32 _E,,32|F,,32 C,,32|");
  IF ParseTune(abc, t) THEN ok := SmfFile.WriteSmf("/tmp/gx_drone.mid", t); pDrone := MakePlayer("/tmp/gx_drone.mid") END
END BuildSounds;

(* ---- sprite art -------------------------------------------------------- *)
PROCEDURE DefineSprites;
BEGIN
  ok := DefineSprite(DPlayer, "0000000110000000/0000001111000000/0000001111000000/0000011111100000/0000011441100000/0000011331100000/0000011331100000/0000211111120000/0002211111122000/0022221111222200/0222221111222220/2222221111222222/2222221111222222/2220022552200222/0200002552000020/0000000660000000");
  SpriteRGB(DPlayer,1,255,255,255); SpriteRGB(DPlayer,2,220,20,20); SpriteRGB(DPlayer,3,20,60,220);
  SpriteRGB(DPlayer,4,0,255,255); SpriteRGB(DPlayer,5,100,100,100); SpriteRGB(DPlayer,6,255,200,0);
  ok := DefineSprite(DBee, "..1..1../.122221./31222213/31222213/.122221./.1.22.1./..3..3../........");
  SpriteRGB(DBee,1,0,0,0); SpriteRGB(DBee,2,255,230,0); SpriteRGB(DBee,3,220,60,60);
  ok := DefineSprite(DBoss, "...22.../..2222../3222 2223/32222223/.322223./.3.22.3./..3..3../........");
  SpriteRGB(DBoss,2,60,220,60); SpriteRGB(DBoss,3,180,60,180);
  ok := DefineSprite(DBullet, "0110/0220/0220/0220/0330/0330/0440/0440");
  SpriteRGB(DBullet,1,255,255,255); SpriteRGB(DBullet,2,255,255,0); SpriteRGB(DBullet,3,255,128,0); SpriteRGB(DBullet,4,255,0,0);
  ok := DefineSprite(DBomb, ".11./1221/1221/.11.");
  SpriteRGB(DBomb,1,255,120,0); SpriteRGB(DBomb,2,255,60,60);
  ok := DefineSprite(DStar, "11/11"); SpriteRGB(DStar,1,200,200,255);
  ok := DefineSprite(DExpl, "...11.../..1221../.123321./11233211/11233211/.123321./..1221../...11...");
  SpriteRGB(DExpl,1,200,50,50); SpriteRGB(DExpl,2,255,120,0); SpriteRGB(DExpl,3,255,255,80);
  ok := DefineSprite(DBfly, "2......2/.2....2./.2.33.2./.233332./.233332./.2.33.2./.2....2./2......2");
  SpriteRGB(DBfly,2,220,60,220); SpriteRGB(DBfly,3,255,255,255);
  ok := DefineSprite(DMoth, ".3....3./.33..33./.333333./.322223./.322223./..3333../...22.../........");
  ok := AddFrame(DMoth, "........./..3333../.333333./.322223./.322223./.333333./.33..33./.3....3.");
  SpriteRGB(DMoth,2,180,180,180); SpriteRGB(DMoth,3,100,255,100);
  ok := DefineSprite(DSaucer, "....222222....../...33333333..../..3333333333.../.333555533333../..4.4.4.4.4.4..");
  SpriteRGB(DSaucer,2,200,200,255); SpriteRGB(DSaucer,3,120,150,255); SpriteRGB(DSaucer,4,255,120,60); SpriteRGB(DSaucer,5,255,255,255)
END DefineSprites;

PROCEDURE RowDef (row: CARDINAL): CARDINAL;
BEGIN CASE row OF 0: RETURN DBoss | 1: RETURN DBfly | 2: RETURN DBee | 3: RETURN DMoth | 4: RETURN DBee ELSE RETURN DBfly END END RowDef;
PROCEDURE SlotX (i: CARDINAL): REAL;
  VAR col: CARDINAL;
BEGIN col := (i-1) MOD 10; RETURN VAL(REAL, 70 + col*52) + fx END SlotX;
PROCEDURE SlotY (i: CARDINAL): REAL;
  VAR row: CARDINAL;
BEGIN row := (i-1) DIV 10; RETURN VAL(REAL, 90 + row*34) END SlotY;

PROCEDURE Boom (x, y: REAL);
  VAR k: CARDINAL;
BEGIN
  FOR k := 0 TO NExpl-1 DO
    IF expT[k] <= 0.0 THEN
      expT[k] := 1.0; Place(ExpBase+k, DExpl, x, y); SetScale(ExpBase+k, 0.7); SetAlpha(ExpBase+k, 1.0); Show(ExpBase+k);
      RETURN
    END
  END
END Boom;

PROCEDURE UpdateExpl;
  VAR k: CARDINAL;
BEGIN
  FOR k := 0 TO NExpl-1 DO
    IF expT[k] > 0.0 THEN
      expT[k] := expT[k] - 0.07;
      SetScale(ExpBase+k, 0.7 + (1.0-expT[k])*2.2); SetAlpha(ExpBase+k, expT[k]);
      IF expT[k] <= 0.0 THEN Hide(ExpBase+k) END
    END
  END
END UpdateExpl;

PROCEDURE PlaceFormation;
  VAR i, row: CARDINAL;
BEGIN
  FOR i := 1 TO NEnemies DO
    row := (i-1) DIV 10;
    alive[i] := TRUE; diveT[i] := 0.0; retT[i] := 0.0;
    Place(i, RowDef(row), SlotX(i), SlotY(i)); SetScale(i, 2.6); Animate(i, 4.0); Show(i)
  END
END PlaceFormation;

PROCEDURE ResetGame;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO NBullets-1 DO bAct[i] := FALSE; Hide(BulBase+i) END;
  FOR i := 0 TO NBombs-1 DO bombAct[i] := FALSE; Hide(BombBase+i) END;
  FOR i := 0 TO NSBombs-1 DO sbombAct[i] := FALSE; Hide(SBombBase+i) END;
  FOR i := 0 TO NExpl-1 DO expT[i] := 0.0; Hide(ExpBase+i) END;
  px := 308.0; pAlive := TRUE; pRespawn := 0; fireCd := 0;
  score := 0; lives := 3; frame := 0; fx := 0.0; fdir := 1.0;
  saucerActive := 0; saucerTimer := 240; saucerY := 40.0;
  Place(PlayerI, DPlayer, px, 440.0); SetScale(PlayerI, 1.7); Show(PlayerI);
  PlaceFormation; Hide(SaucerI)
END ResetGame;

PROCEDURE KillPlayer;
BEGIN
  pAlive := FALSE; pRespawn := 0; Hide(PlayerI); Boom(px, 440.0); Sfx.Play(SH_BOOM);
  IF lives > 0 THEN DEC(lives) END
END KillPlayer;

PROCEDURE UpdatePlayer;
  VAR i: CARDINAL; ang: REAL;
BEGIN
  IF NOT pAlive THEN
    INC(pRespawn);
    IF (pRespawn > 90) AND (lives > 0) THEN
      pAlive := TRUE; pRespawn := 0; px := 308.0;
      Place(PlayerI, DPlayer, px, 440.0); SetScale(PlayerI, 1.7); Show(PlayerI)
    END;
    RETURN
  END;
  ang := 0.0;
  IF gLeft  THEN px := px - 4.0; ang := -12.0 END;
  IF gRight THEN px := px + 4.0; ang := 12.0 END;
  IF px < 12.0 THEN px := 12.0 END; IF px > 628.0 THEN px := 628.0 END;
  MoveTo(PlayerI, px, 440.0); SetRotation(PlayerI, ang);
  IF fireCd > 0 THEN DEC(fireCd) END;
  IF gFireEdge AND (fireCd = 0) THEN
    gFireEdge := FALSE;
    FOR i := 0 TO NBullets-1 DO
      IF NOT bAct[i] THEN
        bAct[i] := TRUE; bx[i] := px; by[i] := 424.0;
        Place(BulBase+i, DBullet, bx[i], by[i]); SetScale(BulBase+i, 1.6); Show(BulBase+i);
        fireCd := 14; Sfx.Play(SH_SHOOT); RETURN
      END
    END
  END;
  gFireEdge := FALSE
END UpdatePlayer;

PROCEDURE UpdateEnemies;
  VAR i, k, nd, attempts: CARDINAL; ex, ey, t: REAL; placed: BOOLEAN;
BEGIN
  fx := fx + 0.6 * fdir;
  IF fx > 60.0 THEN fdir := -1.0 ELSIF fx < -60.0 THEN fdir := 1.0 END;
  IF frame MOD 18 = 0 THEN
    nd := 0;
    FOR i := 1 TO NEnemies DO IF (diveT[i] > 0.0) OR (retT[i] > 0.0) THEN INC(nd) END END;
    attempts := 0;
    WHILE (nd < MaxDivers) AND (attempts < 4) DO
      k := 1 + Rnd(NEnemies);
      IF (k <= NEnemies) AND alive[k] AND (diveT[k] = 0.0) AND (retT[k] = 0.0) THEN diveT[k] := 0.001; INC(nd) END;
      INC(attempts)
    END
  END;
  IF (frame MOD 30 = 0) AND pAlive THEN
    k := 1 + Rnd(NEnemies);
    IF (k <= NEnemies) AND alive[k] THEN
      placed := FALSE; i := 0;
      WHILE (i < NBombs) AND (NOT placed) DO
        IF NOT bombAct[i] THEN
          bombAct[i] := TRUE; bombx[i] := SpriteX(k); bomby[i] := SpriteY(k)+10.0;
          Place(BombBase+i, DBomb, bombx[i], bomby[i]); SetScale(BombBase+i, 2.2); Show(BombBase+i); placed := TRUE
        END;
        INC(i)
      END
    END
  END;
  FOR i := 1 TO NEnemies DO
    IF alive[i] THEN
      ex := SlotX(i); ey := SlotY(i);
      IF diveT[i] > 0.0 THEN
        diveT[i] := diveT[i] + 0.006; t := diveT[i];
        ex := ex + sin(t*2.5)*180.0; ey := ey + t*460.0;
        SetRotation(i, 180.0 + sin(t*2.5)*25.0);
        IF ey > 520.0 THEN diveT[i] := 0.0; retT[i] := 0.001; SetRotation(i, 180.0) END
      ELSIF retT[i] > 0.0 THEN
        retT[i] := retT[i] + 0.006; t := retT[i];
        IF t >= 1.0 THEN retT[i] := 0.0; SetRotation(i, 0.0)
        ELSE ex := ex + sin(t*3.14159)*70.0; ey := -30.0 + t*(ey + 30.0); SetRotation(i, 180.0*(1.0-t)) END
      END;
      MoveTo(i, ex, ey);
      IF pAlive AND (diveT[i] > 0.0) AND Hit(i, PlayerI) THEN alive[i] := FALSE; Hide(i); Boom(ex, ey); KillPlayer END
    END
  END
END UpdateEnemies;

PROCEDURE UpdateBullets;
  VAR i, j: CARDINAL;
BEGIN
  FOR i := 0 TO NBullets-1 DO
    IF bAct[i] THEN
      by[i] := by[i] - 7.0; MoveTo(BulBase+i, bx[i], by[i]);
      IF by[i] < -10.0 THEN bAct[i] := FALSE; Hide(BulBase+i) END;
      IF bAct[i] THEN
        FOR j := 1 TO NEnemies DO
          IF alive[j] AND bAct[i] AND Hit(BulBase+i, j) THEN
            alive[j] := FALSE; bAct[i] := FALSE; INC(score, 10);
            Hide(j); Hide(BulBase+i); Boom(SpriteX(j), SpriteY(j)); Sfx.Play(SH_BOOM)
          END
        END
      END;
      IF bAct[i] AND (saucerActive = 1) AND Hit(BulBase+i, SaucerI) THEN
        bAct[i] := FALSE; Hide(BulBase+i); saucerActive := 0; Hide(SaucerI);
        saucerTimer := 320; INC(score, 100); Boom(saucerX, saucerY); Boom(saucerX+18.0, saucerY+4.0); Sfx.Play(SH_BOOM)
      END
    END
  END
END UpdateBullets;

PROCEDURE UpdateBombs;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO NBombs-1 DO
    IF bombAct[i] THEN
      bomby[i] := bomby[i] + 4.5; MoveTo(BombBase+i, bombx[i], bomby[i]);
      IF bomby[i] > 490.0 THEN bombAct[i] := FALSE; Hide(BombBase+i) END;
      IF bombAct[i] AND pAlive AND Hit(BombBase+i, PlayerI) THEN bombAct[i] := FALSE; Hide(BombBase+i); KillPlayer END
    END
  END
END UpdateBombs;

PROCEDURE UpdateSaucer;
  VAR i: CARDINAL; dxb: REAL; placed: BOOLEAN;
BEGIN
  IF saucerActive = 0 THEN
    IF saucerTimer > 0 THEN DEC(saucerTimer) END;
    IF saucerTimer = 0 THEN
      saucerActive := 1; saucerY := 40.0;
      IF Rnd(2) = 0 THEN saucerX := -40.0; saucerDx := 2.6 ELSE saucerX := 680.0; saucerDx := -2.6 END;
      Place(SaucerI, DSaucer, saucerX, saucerY); SetScale(SaucerI, 2.2); Show(SaucerI)
    END;
    RETURN
  END;
  FOR i := 0 TO NBullets-1 DO
    IF bAct[i] THEN
      dxb := bx[i] - saucerX; IF dxb < 0.0 THEN dxb := -dxb END;
      IF (dxb < 34.0) AND (by[i] > saucerY) AND (by[i] < saucerY + 170.0) THEN
        IF bx[i] < saucerX THEN saucerX := saucerX + 3.2 ELSE saucerX := saucerX - 3.2 END;
        IF saucerY < 64.0 THEN saucerY := saucerY + 4.0 ELSE saucerY := saucerY - 3.0 END
      END
    END
  END;
  IF saucerY < 30.0 THEN saucerY := 30.0 END; IF saucerY > 84.0 THEN saucerY := 84.0 END;
  saucerX := saucerX + saucerDx; MoveTo(SaucerI, saucerX, saucerY);
  IF (saucerX > 0.0) AND (saucerX < VAL(REAL, VW)) AND (frame MOD 22 = 0) THEN
    placed := FALSE; i := 0;
    WHILE (i < NSBombs) AND (NOT placed) DO
      IF NOT sbombAct[i] THEN
        sbombAct[i] := TRUE; sbombx[i] := saucerX; sbomby[i] := saucerY + 14.0;
        Place(SBombBase+i, DBomb, sbombx[i], sbomby[i]); SetScale(SBombBase+i, 2.4); Show(SBombBase+i); placed := TRUE
      END;
      INC(i)
    END
  END;
  IF (saucerX < -80.0) OR (saucerX > 720.0) THEN saucerActive := 0; saucerTimer := 300 + Rnd(360); Hide(SaucerI) END
END UpdateSaucer;

PROCEDURE UpdateSaucerBombs;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO NSBombs-1 DO
    IF sbombAct[i] THEN
      sbomby[i] := sbomby[i] + 4.0; MoveTo(SBombBase+i, sbombx[i], sbomby[i]);
      IF sbomby[i] > 490.0 THEN sbombAct[i] := FALSE; Hide(SBombBase+i) END;
      IF sbombAct[i] AND pAlive AND Hit(SBombBase+i, PlayerI) THEN sbombAct[i] := FALSE; Hide(SBombBase+i); KillPlayer END
    END
  END
END UpdateSaucerBombs;

PROCEDURE UpdateStars;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO NStars-1 DO
    starY[i] := starY[i] + 1.5; IF starY[i] > VAL(REAL,VH) THEN starY[i] := -4.0 END;
    MoveTo(StarBase+i, SpriteX(StarBase+i), starY[i])
  END
END UpdateStars;

PROCEDURE AllDead (): BOOLEAN;
  VAR i: CARDINAL;
BEGIN FOR i := 1 TO NEnemies DO IF alive[i] THEN RETURN FALSE END END; RETURN TRUE END AllDead;

PROCEDURE DrawHud;
  VAR s: ARRAY [0..15] OF CHAR;
BEGIN
  Cls(0);
  Text(8, 8, "SCORE", 15); CardToStr(score, s); Text(56, 8, s, 14);
  Text(560, 8, "SHIPS", 15); CardToStr(lives, s); Text(610, 8, s, 12)
END DrawHud;

PROCEDURE Frame;                                          (* one game tick (~60 Hz) *)
BEGIN
  gLeft := KeyHeld(KeyLeft); gRight := KeyHeld(KeyRight);
  gFire := KeyHeld(KeySpace); gFireEdge := gFire AND (NOT gFirePrev); gFirePrev := gFire;
  IF frame MOD 540 = 0 THEN PlayMusic(pDrone) END;
  DrawHud; UpdateStars;
  IF state = StIntro THEN
    Text(250, 220, "PLAYER ONE READY", 9 + (stateTimer DIV 10) MOD 6);
    INC(stateTimer);
    IF (stateTimer > 150) OR gFire THEN state := StPlay; frame := 0 END
  ELSIF state = StPlay THEN
    UpdatePlayer; UpdateEnemies; UpdateBombs; UpdateSaucer; UpdateSaucerBombs; UpdateBullets; UpdateExpl;
    INC(frame);
    IF (lives = 0) AND (NOT pAlive) THEN state := StOver; stateTimer := 0; PlayMusic(pOver)
    ELSIF AllDead() THEN state := StWin; stateTimer := 0; PlayMusic(pWin) END
  ELSIF state = StOver THEN
    UpdateExpl; Text(270, 220, "GAME OVER", 9 + (stateTimer DIV 8) MOD 6);
    INC(stateTimer); IF stateTimer > 300 THEN ResetGame; state := StIntro; stateTimer := 0; PlayMusic(pIntro) END
  ELSE
    UpdateExpl; Text(258, 220, "YOU WIN", 9 + (stateTimer DIV 6) MOD 6);
    INC(stateTimer); IF stateTimer > 200 THEN ResetGame; state := StIntro; stateTimer := 0; PlayMusic(pIntro) END
  END;
  Present
END Frame;

VAR i: CARDINAL;
BEGIN
  gSeed := 1234567;
  gLeft := FALSE; gRight := FALSE; gFire := FALSE; gFireEdge := FALSE; gFirePrev := FALSE;
  IF NOT Create("Galaxigans (Metal pane, pure Modula-2)", VW, VH, 1) THEN HALT END;
  LoadDefaultPalette;
  DefineSprites;
  BuildSounds;
  FOR i := 0 TO NStars-1 DO
    starY[i] := VAL(REAL, Rnd(VH));
    Place(StarBase+i, DStar, VAL(REAL, 4 + Rnd(VW-8)), starY[i]); Show(StarBase+i)
  END;
  ResetGame;
  state := StIntro; stateTimer := 0;
  PlayMusic(pIntro);
  Run(Frame)
END galaxigans.
