MODULE glimmer;
(* Glimmer — created by claude - a firefly tending its light on a drifting night — running on the
   native macOS Metal indexed pane (library/macrtdef/IndexedPane), the GPU game
   surface written in pure Modula-2. Ported from demos/glimmer.mod (Windows
   GameViewGpu); the game logic is unchanged — only the window/loop/input bind to
   IndexedPane instead. Steer the firefly with the arrows; fly onto soft motes to
   catch them (glow grows); avoid the dark embers.

     newm2-driver run --library library cocoademos/glimmer.mod *)
FROM IndexedPane IMPORT
  Create, Run, KeyHeld, KeyLeft, KeyRight, KeyUp, KeyDown,
  SetRGB, SetLineRGB, LoadDefaultPalette, Cls, Pset, Circle, Text,
  DefineSprite, SpriteRGB, Place, MoveTo, SetScale, SetAlpha, SetRotation,
  Hit, Show, Hide, Present;
FROM NM2Math IMPORT sin;
FROM WholeStr IMPORT CardToStr;
FROM SYSTEM IMPORT CAST;
IMPORT ObjC;
FROM Abc IMPORT Tune, ParseTune;
IMPORT SmfFile;

VAR gSeed: CARDINAL;
PROCEDURE Randomize (s: CARDINAL); BEGIN gSeed := 22695477 END Randomize;
PROCEDURE Rnd (n: CARDINAL): CARDINAL;
BEGIN
  gSeed := (gSeed*1103515245 + 12345) MOD 2147483648;
  IF n = 0 THEN RETURN 0 END;
  RETURN (gSeed DIV 65536) MOD n
END Rnd;

CONST
  VW = 640; VH = 480;
  NMotes = 24; NEmbers = 8; NStars = 72; NFlash = 10;
  DFly = 0; DCyan = 1; DGold = 2; DRose = 3; DEmber = 4;
  FlyI = 0; MoteBase = 10; EmberBase = 40;
  CText = 15; CStarLo = 16; CStarMid = 17; CStarHi = 18; CHalo = 19; CFlash = 20;

VAR
  ok: BOOLEAN;
  fx, fy, glow: REAL;
  combo, score, frame: CARDINAL;
  mAct: ARRAY [0..NMotes-1] OF BOOLEAN;
  mBaseX, mY, mPhase, mAmp, mSpeed: ARRAY [0..NMotes-1] OF REAL;
  mCol: ARRAY [0..NMotes-1] OF CARDINAL;
  eAct: ARRAY [0..NEmbers-1] OF BOOLEAN;
  eBaseX, eY, ePhase, eAmp, eSpeed: ARRAY [0..NEmbers-1] OF REAL;
  sx, sy, sTw: ARRAY [0..NStars-1] OF CARDINAL;
  fAct: ARRAY [0..NFlash-1] OF BOOLEAN;
  fX, fY, fT: ARRAY [0..NFlash-1] OF CARDINAL;

(* ---- sound: a bell per catch + a warm drone, via Abc -> SMF -> AVMIDIPlayer,
   each played non-blocking (no Pump) and held so ARC keeps it alive ---- *)
VAR bellPlayer: ARRAY [0..4] OF ObjC.Id; emberPlayer, dronePlayer: ObjC.Id;
    abc: ARRAY [0..255] OF CHAR; an: CARDINAL;

PROCEDURE Cls0 (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls0;

PROCEDURE ALn (s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i:=0; WHILE (i<=HIGH(s)) AND (s[i]#0C) DO abc[an]:=s[i]; INC(an); INC(i) END;
  abc[an]:=CHR(10); INC(an); abc[an]:=0C END ALn;

PROCEDURE MakePlayer (path: ARRAY OF CHAR): ObjC.Id;
  VAR url, p: ObjC.Id;
BEGIN
  url := [Cls0("NSURL") fileURLWithPath: ObjC.NSString(path)];
  p := [[Cls0("AVMIDIPlayer") alloc] initWithContentsOfURL: url soundBankURL: NIL error: NIL];
  IF p # NIL THEN [p prepareToPlay] END;
  RETURN p
END MakePlayer;

PROCEDURE BuildTune (q, prog, note, path: ARRAY OF CHAR): ObjC.Id;
  VAR t: Tune;
BEGIN
  an := 0; ALn("X:1"); ALn("M:4/4"); ALn("L:1/16"); ALn(q); ALn(prog); ALn("K:C"); ALn(note);
  IF ParseTune(abc, t) THEN IF SmfFile.WriteSmf(path, t) THEN RETURN MakePlayer(path) END END;
  RETURN NIL
END BuildTune;

PROCEDURE BuildSounds;
BEGIN
  ObjC.LoadFramework("AVFoundation");
  bellPlayer[0] := BuildTune("Q:1/4=220","%%MIDI program 10","c4 z12|",  "/tmp/glim_b0.mid");
  bellPlayer[1] := BuildTune("Q:1/4=220","%%MIDI program 10","e4 z12|",  "/tmp/glim_b1.mid");
  bellPlayer[2] := BuildTune("Q:1/4=220","%%MIDI program 10","g4 z12|",  "/tmp/glim_b2.mid");
  bellPlayer[3] := BuildTune("Q:1/4=220","%%MIDI program 10","c'4 z12|", "/tmp/glim_b3.mid");
  bellPlayer[4] := BuildTune("Q:1/4=220","%%MIDI program 10","e'4 z12|", "/tmp/glim_b4.mid");
  emberPlayer   := BuildTune("Q:1/4=160","%%MIDI program 89","E,,4 C,,8 z4|","/tmp/glim_e.mid");
  dronePlayer   := BuildTune("Q:1/4=90", "%%MIDI program 89","C,,64 E,,64 C,,64 G,,64|","/tmp/glim_d.mid")
END BuildSounds;

PROCEDURE PlaySfx (p: ObjC.Id);
BEGIN IF p # NIL THEN [p setCurrentPosition: 0.0]; [p play: NIL] END END PlaySfx;

PROCEDURE DefineSprites;
BEGIN
  ok := DefineSprite(DFly, "...1111.../.12222221./1223333221/1233444321/1234444321/1234444321/1233444321/1223333221/.12222221./...1111...");
  SpriteRGB(DFly,1, 90,70,20); SpriteRGB(DFly,2, 200,160,40);
  SpriteRGB(DFly,3, 255,225,90); SpriteRGB(DFly,4, 255,255,235);
  ok := DefineSprite(DCyan, "..2222../.233332./23344332/23444432/23444432/23344332/.233332./..2222..");
  SpriteRGB(DCyan,2, 0,120,160); SpriteRGB(DCyan,3, 0,200,220); SpriteRGB(DCyan,4, 190,255,255);
  ok := DefineSprite(DGold, "..2222../.233332./23344332/23444432/23444432/23344332/.233332./..2222..");
  SpriteRGB(DGold,2, 180,120,0); SpriteRGB(DGold,3, 240,200,40); SpriteRGB(DGold,4, 255,250,200);
  ok := DefineSprite(DRose, "..2222../.233332./23344332/23444432/23444432/23344332/.233332./..2222..");
  SpriteRGB(DRose,2, 170,40,90); SpriteRGB(DRose,3, 240,90,140); SpriteRGB(DRose,4, 255,205,225);
  ok := DefineSprite(DEmber, "..2222../.233332./23344332/23444432/23444432/23344332/.233332./..2222..");
  SpriteRGB(DEmber,2, 35,18,28); SpriteRGB(DEmber,3, 80,38,48); SpriteRGB(DEmber,4, 120,55,60)
END DefineSprites;

PROCEDURE Frnd (n: CARDINAL): REAL;
BEGIN RETURN VAL(REAL, Rnd(n)) END Frnd;

PROCEDURE UpdateSky;
  VAR y: CARDINAL; t, br: REAL; r, g, b: CARDINAL;
BEGIN
  br := 6.0 * sin(VAL(REAL, frame) * 0.012);
  y := 0;
  WHILE y < VH DO
    t := VAL(REAL, y) / VAL(REAL, VH);
    r := VAL(CARDINAL, 10.0 + 22.0 * t + br);
    g := VAL(CARDINAL, 10.0 + 12.0 * t + br);
    b := VAL(CARDINAL, 34.0 + 20.0 * t + br);
    SetLineRGB(y, 1, r, g, b);
    INC(y)
  END
END UpdateSky;

PROCEDURE DrawStars;
  VAR i, idx: CARDINAL; tw: REAL;
BEGIN
  i := 0;
  WHILE i < NStars DO
    tw := sin(VAL(REAL, frame) * 0.05 + VAL(REAL, sTw[i]));
    IF tw > 0.6 THEN idx := CStarHi ELSIF tw > 0.0 THEN idx := CStarMid ELSE idx := CStarLo END;
    Pset(VAL(INTEGER, sx[i]), VAL(INTEGER, sy[i]), idx);
    INC(i)
  END
END DrawStars;

PROCEDURE AddFlash (px, py: REAL);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE i < NFlash DO
    IF NOT fAct[i] THEN fAct[i]:=TRUE; fX[i]:=VAL(CARDINAL,px); fY[i]:=VAL(CARDINAL,py); fT[i]:=9; RETURN END;
    INC(i)
  END
END AddFlash;

PROCEDURE DrawFlashes;
  VAR i, rad: CARDINAL;
BEGIN
  i := 0;
  WHILE i < NFlash DO
    IF fAct[i] THEN
      rad := (10 - fT[i]) * 2;
      Circle(VAL(INTEGER, fX[i]), VAL(INTEGER, fY[i]), VAL(INTEGER, rad), CFlash);
      DEC(fT[i]); IF fT[i] = 0 THEN fAct[i] := FALSE END
    END;
    INC(i)
  END
END DrawFlashes;

PROCEDURE SpawnMote;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE i < NMotes DO
    IF NOT mAct[i] THEN
      mAct[i]:=TRUE; mCol[i]:=Rnd(3);
      mBaseX[i]:=30.0+Frnd(VW-60); mY[i]:=-10.0;
      mPhase[i]:=Frnd(628)/100.0; mAmp[i]:=12.0+Frnd(46); mSpeed[i]:=0.7+Frnd(70)/100.0;
      Place(MoteBase+i, DCyan+mCol[i], mBaseX[i], mY[i]); Show(MoteBase+i);
      RETURN
    END;
    INC(i)
  END
END SpawnMote;

PROCEDURE SpawnEmber;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE i < NEmbers DO
    IF NOT eAct[i] THEN
      eAct[i]:=TRUE;
      eBaseX[i]:=30.0+Frnd(VW-60); eY[i]:=-10.0;
      ePhase[i]:=Frnd(628)/100.0; eAmp[i]:=8.0+Frnd(36); eSpeed[i]:=1.1+Frnd(80)/100.0;
      Place(EmberBase+i, DEmber, eBaseX[i], eY[i]); Show(EmberBase+i);
      RETURN
    END;
    INC(i)
  END
END SpawnEmber;

PROCEDURE Catch (col: CARDINAL; px, py: REAL);
  VAR tier: CARDINAL;
BEGIN
  INC(combo); tier := combo-1; IF tier > 4 THEN tier := 4 END;
  score := score + (col+1)*5 + combo*2;
  glow := glow + 0.07; IF glow > 1.0 THEN glow := 1.0 END;
  PlaySfx(bellPlayer[tier]);
  AddFlash(px, py)
END Catch;

PROCEDURE Hurt;
BEGIN combo := 0; glow := glow - 0.22; IF glow < 0.25 THEN glow := 0.25 END; PlaySfx(emberPlayer) END Hurt;

PROCEDURE UpdateMotes;
  VAR i: CARDINAL; dx: REAL;
BEGIN
  IF (frame MOD 34 = 0) THEN SpawnMote END;
  i := 0;
  WHILE i < NMotes DO
    IF mAct[i] THEN
      mY[i] := mY[i] + mSpeed[i];
      dx := mBaseX[i] + sin(mY[i]*0.018 + mPhase[i]) * mAmp[i];
      MoveTo(MoteBase+i, dx, mY[i]);
      SetScale(MoteBase+i, 1.0 + sin(VAL(REAL,frame)*0.1 + mPhase[i]) * 0.14);
      IF Hit(FlyI, MoteBase+i) THEN
        Catch(mCol[i], dx, mY[i]); mAct[i] := FALSE; Hide(MoteBase+i)
      ELSIF mY[i] > VAL(REAL,VH) + 12.0 THEN mAct[i] := FALSE; Hide(MoteBase+i) END
    END;
    INC(i)
  END
END UpdateMotes;

PROCEDURE UpdateEmbers;
  VAR i: CARDINAL; dx: REAL;
BEGIN
  IF (frame MOD 95 = 0) THEN SpawnEmber END;
  i := 0;
  WHILE i < NEmbers DO
    IF eAct[i] THEN
      eY[i] := eY[i] + eSpeed[i];
      dx := eBaseX[i] + sin(eY[i]*0.02 + ePhase[i]) * eAmp[i];
      MoveTo(EmberBase+i, dx, eY[i]);
      SetRotation(EmberBase+i, VAL(REAL,frame)*1.5);
      IF Hit(FlyI, EmberBase+i) THEN Hurt; eAct[i] := FALSE; Hide(EmberBase+i)
      ELSIF eY[i] > VAL(REAL,VH) + 12.0 THEN eAct[i] := FALSE; Hide(EmberBase+i) END
    END;
    INC(i)
  END
END UpdateEmbers;

PROCEDURE UpdateFly;
BEGIN
  IF KeyHeld(KeyLeft)  THEN fx := fx - 3.6 END;
  IF KeyHeld(KeyRight) THEN fx := fx + 3.6 END;
  IF KeyHeld(KeyUp)    THEN fy := fy - 3.6 END;
  IF KeyHeld(KeyDown)  THEN fy := fy + 3.6 END;
  IF fx < 14.0 THEN fx := 14.0 END; IF fx > VAL(REAL,VW)-14.0 THEN fx := VAL(REAL,VW)-14.0 END;
  IF fy < 14.0 THEN fy := 14.0 END; IF fy > VAL(REAL,VH)-14.0 THEN fy := VAL(REAL,VH)-14.0 END;
  glow := glow - 0.0007; IF glow < 0.25 THEN glow := 0.25 END;
  MoveTo(FlyI, fx, fy);
  SetAlpha(FlyI, 0.55 + glow*0.45);
  SetScale(FlyI, 1.0 + glow*1.1)
END UpdateFly;

PROCEDURE DrawHalo;
  VAR r: INTEGER;
BEGIN
  r := VAL(INTEGER, 10.0 + glow*26.0);
  Circle(VAL(INTEGER,fx), VAL(INTEGER,fy), r, CHalo);
  Circle(VAL(INTEGER,fx), VAL(INTEGER,fy), r+6, CHalo)
END DrawHalo;

PROCEDURE DrawHud;
  VAR s: ARRAY [0..15] OF CHAR;
BEGIN
  CardToStr(score, s);
  Text(10, 10, "glimmer", CText); Text(VW-70, 10, s, CText)
END DrawHud;

PROCEDURE Frame;                                   (* one game tick (~60 Hz) *)
BEGIN
  IF frame MOD 600 = 0 THEN PlaySfx(dronePlayer) END;   (* keep the warm pad going *)
  Cls(1);
  DrawStars; DrawHalo; UpdateFly; UpdateMotes; UpdateEmbers; DrawFlashes; UpdateSky; DrawHud;
  Present;
  INC(frame)
END Frame;

VAR i: CARDINAL;
BEGIN
  Randomize(0);
  fx := VAL(REAL,VW)/2.0; fy := VAL(REAL,VH)-80.0; glow := 0.4;
  combo := 0; score := 0; frame := 0;
  FOR i := 0 TO NMotes-1 DO mAct[i] := FALSE END;
  FOR i := 0 TO NEmbers-1 DO eAct[i] := FALSE END;
  FOR i := 0 TO NFlash-1 DO fAct[i] := FALSE END;
  FOR i := 0 TO NStars-1 DO sx[i]:=4+Rnd(VW-8); sy[i]:=4+Rnd(VH-8); sTw[i]:=Rnd(628) END;

  IF NOT Create("Glimmer (Metal pane, pure Modula-2)", VW, VH, 1) THEN HALT END;
  LoadDefaultPalette;
  SetRGB(CText, 230,230,255);
  SetRGB(CStarLo, 110,110,150); SetRGB(CStarMid, 175,175,205); SetRGB(CStarHi, 235,235,255);
  SetRGB(CHalo, 70,58,28); SetRGB(CFlash, 255,240,180);
  DefineSprites;
  Place(FlyI, DFly, fx, fy); Show(FlyI);
  BuildSounds;                                   (* the drone starts on frame 0 (see Frame) *)
  Run(Frame)
END glimmer.
