MODULE asteroids_cocoa;
(* Asteroids — a native Cocoa app written in Modula-2, drawn as classic white
   vector graphics with Core Graphics stroked paths. A CLASS that INHERITs NSView
   renders the ship, rocks, bullets, a lurking saucer and explosion debris; an
   NSTimer block runs the physics ~33x/s. The ship rotates and thrusts with
   momentum and wraps around the screen; bullets wrap and expire; rocks drift,
   spin and split (large -> 2 medium -> 2 small -> gone) when shot.

   True-to-the-original touches: a UFO that drifts in and shoots at you (200 pts),
   the ship bursting into flying line fragments when hit, and the two-tone
   background heartbeat that quickens as the wave wears on. Fire / thrust /
   explosion / beat SFX are synthesised (Audio) and played non-blocking (Sfx).

     newm2-driver run --library library cocoademos/asteroids_cocoa.mod
   left / right rotate   up thrust   space fire   down hyperspace
   p pause   r restart   (close the window to quit)

   Headless under the Ptcl test harness (sound off there):
     newm2-driver run --library library cocoademos/asteroids_cocoa.mod -- --script cocoademos/test/asteroids.tcl *)
FROM SYSTEM IMPORT CAST, ADDRESS;
FROM RealMath IMPORT sin, cos, sqrt;
FROM WholeStr IMPORT CardToStr;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;
IMPORT Audio;
IMPORT Sfx;
IMPORT DemoHarness;

CONST
  WinW = 820.0; WinH = 620.0;
  TwoPi = 6.28318530718;
  NV = 10;                              (* vertices per asteroid *)
  MaxAst = 64; MaxBul = 8; MaxSBul = 4; MaxDebris = 10;
  ShipR = 13.0;
  RotStep = 0.075; Accel = 0.22; Friction = 0.992;
  BulletSpeed = 8.5; BulletLife = 56; FireCool = 7;
  InvulnFrames = 90; DeathFrames = 55;
  SaucerR = 16.0; SaucerSpeed = 2.1; SaucerBullet = 4.6;

  KC_LEFT = 123; KC_RIGHT = 124; KC_UP = 126; KC_DOWN = 125;
  KC_SPACE = 49; KC_P = 35; KC_R = 15;

  S_FIRE = 0; S_THRUST = 1; S_BANGBIG = 2; S_BANGSMALL = 3; S_OVER = 4;
  S_BEATLO = 5; S_BEATHI = 6; S_SAUCER = 7;

TYPE
  Asteroid = RECORD
    x, y, vx, vy, r, rot, spin: REAL;
    shp:  ARRAY [0..NV-1] OF REAL;
    size: CARDINAL;                     (* 3 large, 2 med, 1 small, 0 dead *)
  END;
  Bullet = RECORD x, y, vx, vy: REAL; life: INTEGER; alive: BOOLEAN; END;
  Debris = RECORD x, y, vx, vy, ang, spin: REAL; life: INTEGER; alive: BOOLEAN; END;

VAR
  ast:  ARRAY [0..MaxAst-1] OF Asteroid;
  bul:  ARRAY [0..MaxBul-1] OF Bullet;        (* player bullets *)
  sbul: ARRAY [0..MaxSBul-1] OF Bullet;       (* saucer bullets *)
  deb:  ARRAY [0..MaxDebris-1] OF Debris;     (* explosion fragments *)
  sx, sy, svx, svy, sa: REAL;
  invuln, fireCd, deathTimer: INTEGER;
  gScore, gLevel: CARDINAL; gLives: INTEGER;
  gOver, gPaused, thrustOn, gDead: BOOLEAN;
  kLeft, kRight, kThrust, kFire: BOOLEAN;
  gSeed, gThrustSnd, gWaveFrames: CARDINAL;
  ufoOn: BOOLEAN; ufoX, ufoY, ufoVx, ufoVy: REAL; ufoFire, ufoLife, ufoZig, saucerTimer: INTEGER;
  beatTimer: INTEGER; beatHi: BOOLEAN;
  gAudio: BOOLEAN;
  gView, gTimer: ObjC.Id;

PROCEDURE Cls0 (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls0;

PROCEDURE Rnd (n: CARDINAL): CARDINAL;
BEGIN gSeed := (gSeed * 1103515245 + 12345) MOD 2147483648; RETURN (gSeed DIV 65536) MOD n END Rnd;

PROCEDURE Frnd (): REAL;
BEGIN RETURN FLOAT(VAL(INTEGER, Rnd(10000))) / 10000.0 END Frnd;

PROCEDURE Snd (id: CARDINAL);
BEGIN IF gAudio THEN Sfx.Play(id) END END Snd;

PROCEDURE Wrap (VAR v: REAL; hi: REAL);
BEGIN IF v < 0.0 THEN v := v + hi ELSIF v >= hi THEN v := v - hi END END Wrap;

PROCEDURE Dist2 (ax, ay, bx, by: REAL): REAL;
  VAR dx, dy: REAL;
BEGIN dx := ax - bx; dy := ay - by; RETURN dx*dx + dy*dy END Dist2;

(* ---- asteroids --------------------------------------------------------- *)
PROCEDURE AstRadius (size: CARDINAL): REAL;
BEGIN IF size >= 3 THEN RETURN 40.0 ELSIF size = 2 THEN RETURN 22.0 ELSE RETURN 12.0 END END AstRadius;

PROCEDURE InitAst (i: CARDINAL; x, y: REAL; size: CARDINAL);
  VAR k: CARDINAL; ang, spd: REAL;
BEGIN
  ast[i].x := x; ast[i].y := y; ast[i].size := size; ast[i].r := AstRadius(size);
  ang := Frnd() * TwoPi; spd := 0.6 + Frnd() * 1.4 + FLOAT(VAL(INTEGER,size)) * 0.2;
  ast[i].vx := cos(ang) * spd; ast[i].vy := sin(ang) * spd;
  ast[i].rot := Frnd() * TwoPi; ast[i].spin := (Frnd() - 0.5) * 0.08;
  FOR k := 0 TO NV-1 DO ast[i].shp[k] := 0.72 + Frnd() * 0.32 END
END InitAst;

PROCEDURE Spawn (x, y: REAL; size: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO MaxAst-1 DO IF ast[i].size = 0 THEN InitAst(i, x, y, size); RETURN END END
END Spawn;

PROCEDURE CountAst (): CARDINAL;
  VAR i, n: CARDINAL;
BEGIN n := 0; FOR i := 0 TO MaxAst-1 DO IF ast[i].size > 0 THEN INC(n) END END; RETURN n END CountAst;

PROCEDURE NewWave;
  VAR i, n: CARDINAL; x, y: REAL;
BEGIN
  n := 4 + gLevel; IF n > 11 THEN n := 11 END;
  FOR i := 1 TO n DO
    IF (i MOD 2) = 0 THEN x := Frnd() * WinW; y := 0.0 ELSE x := 0.0; y := Frnd() * WinH END;
    Spawn(x, y, 3)
  END;
  gWaveFrames := 0
END NewWave;

PROCEDURE ResetShip;
BEGIN sx := WinW/2.0; sy := WinH/2.0; svx := 0.0; svy := 0.0; sa := 1.5707963; invuln := InvulnFrames END ResetShip;

PROCEDURE NewGame;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO MaxAst-1 DO ast[i].size := 0 END;
  FOR i := 0 TO MaxBul-1 DO bul[i].alive := FALSE END;
  FOR i := 0 TO MaxSBul-1 DO sbul[i].alive := FALSE END;
  FOR i := 0 TO MaxDebris-1 DO deb[i].alive := FALSE END;
  gScore := 0; gLevel := 1; gLives := 3; gOver := FALSE; gPaused := FALSE;
  gDead := FALSE; deathTimer := 0; fireCd := 0;
  ufoOn := FALSE; saucerTimer := 360; beatTimer := 0; beatHi := FALSE;
  ResetShip; NewWave
END NewGame;

(* ---- actions ----------------------------------------------------------- *)
PROCEDURE RotateShip (d: REAL);
BEGIN sa := sa + d; IF sa < 0.0 THEN sa := sa + TwoPi ELSIF sa >= TwoPi THEN sa := sa - TwoPi END END RotateShip;

PROCEDURE Thrust;
BEGIN IF NOT gDead THEN svx := svx + cos(sa) * Accel; svy := svy + sin(sa) * Accel; thrustOn := TRUE END END Thrust;

PROCEDURE Fire;
  VAR i: CARDINAL;
BEGIN
  IF gDead THEN RETURN END;
  FOR i := 0 TO MaxBul-1 DO
    IF NOT bul[i].alive THEN
      bul[i].x := sx + cos(sa) * ShipR; bul[i].y := sy + sin(sa) * ShipR;
      bul[i].vx := svx + cos(sa) * BulletSpeed; bul[i].vy := svy + sin(sa) * BulletSpeed;
      bul[i].life := BulletLife; bul[i].alive := TRUE; Snd(S_FIRE); RETURN
    END
  END
END Fire;

PROCEDURE Hyperspace;
BEGIN IF NOT gDead THEN sx := Frnd() * WinW; sy := Frnd() * WinH; svx := 0.0; svy := 0.0; invuln := 40 END END Hyperspace;

(* ---- explosion debris -------------------------------------------------- *)
PROCEDURE SpawnDebris (x, y: REAL; count: CARDINAL);
  VAR i, made: CARDINAL; ang, spd: REAL;
BEGIN
  made := 0;
  FOR i := 0 TO MaxDebris-1 DO
    IF (NOT deb[i].alive) AND (made < count) THEN
      ang := Frnd() * TwoPi; spd := 0.8 + Frnd() * 2.2;
      deb[i].x := x; deb[i].y := y; deb[i].vx := cos(ang) * spd; deb[i].vy := sin(ang) * spd;
      deb[i].ang := Frnd() * TwoPi; deb[i].spin := (Frnd() - 0.5) * 0.3;
      deb[i].life := 42 + VAL(INTEGER, Rnd(18)); deb[i].alive := TRUE; INC(made)
    END
  END
END SpawnDebris;

PROCEDURE UpdateDebris;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO MaxDebris-1 DO
    IF deb[i].alive THEN
      deb[i].x := deb[i].x + deb[i].vx; deb[i].y := deb[i].y + deb[i].vy;
      Wrap(deb[i].x, WinW); Wrap(deb[i].y, WinH);
      deb[i].ang := deb[i].ang + deb[i].spin;
      DEC(deb[i].life); IF deb[i].life <= 0 THEN deb[i].alive := FALSE END
    END
  END
END UpdateDebris;

PROCEDURE ShipDie;
BEGIN
  Snd(S_BANGBIG); SpawnDebris(sx, sy, 6);
  DEC(gLives); gDead := TRUE; deathTimer := DeathFrames;
  IF gLives < 0 THEN gOver := TRUE; Snd(S_OVER) END
END ShipDie;

(* ---- saucer ------------------------------------------------------------ *)
PROCEDURE SpawnSaucer;
BEGIN
  ufoOn := TRUE; ufoY := 60.0 + Frnd() * (WinH - 120.0);
  IF Rnd(2) = 0 THEN ufoX := 0.0; ufoVx := SaucerSpeed ELSE ufoX := WinW; ufoVx := -SaucerSpeed END;
  ufoVy := 0.0; ufoFire := 60; ufoLife := TRUNC(WinW / SaucerSpeed) + 50; ufoZig := 40
END SpawnSaucer;

PROCEDURE UfoFire;                       (* aimed at the ship, with a little spread *)
  VAR i: CARDINAL; dx, dy, len: REAL;
BEGIN
  IF gDead THEN RETURN END;
  FOR i := 0 TO MaxSBul-1 DO
    IF NOT sbul[i].alive THEN
      dx := sx - ufoX; dy := sy - ufoY; len := sqrt(dx*dx + dy*dy) + 0.01;
      sbul[i].x := ufoX; sbul[i].y := ufoY;
      sbul[i].vx := dx/len * SaucerBullet + (Frnd() - 0.5) * 1.6;
      sbul[i].vy := dy/len * SaucerBullet + (Frnd() - 0.5) * 1.6;
      sbul[i].life := 70; sbul[i].alive := TRUE; Snd(S_SAUCER); RETURN
    END
  END
END UfoFire;

PROCEDURE UpdateSaucer;
  VAR i: CARDINAL;
BEGIN
  IF ufoOn THEN
    ufoX := ufoX + ufoVx; ufoY := ufoY + ufoVy; Wrap(ufoY, WinH);
    DEC(ufoZig); IF ufoZig <= 0 THEN ufoVy := (FLOAT(VAL(INTEGER, Rnd(3))) - 1.0) * 1.3; ufoZig := 30 + VAL(INTEGER, Rnd(40)) END;
    DEC(ufoFire); IF ufoFire <= 0 THEN UfoFire; ufoFire := 55 + VAL(INTEGER, Rnd(40)) END;
    DEC(ufoLife);
    IF (ufoLife <= 0) OR (ufoX < -24.0) OR (ufoX > WinW + 24.0) THEN ufoOn := FALSE END
  END;
  FOR i := 0 TO MaxSBul-1 DO
    IF sbul[i].alive THEN
      sbul[i].x := sbul[i].x + sbul[i].vx; sbul[i].y := sbul[i].y + sbul[i].vy;
      Wrap(sbul[i].x, WinW); Wrap(sbul[i].y, WinH);
      DEC(sbul[i].life); IF sbul[i].life <= 0 THEN sbul[i].alive := FALSE END
    END
  END
END UpdateSaucer;

(* ---- collisions / physics ---------------------------------------------- *)
PROCEDURE SplitAst (i: CARDINAL);
  VAR sz: CARDINAL;
BEGIN
  sz := ast[i].size;
  IF    sz >= 3 THEN INC(gScore, 20) ELSIF sz = 2 THEN INC(gScore, 50) ELSE INC(gScore, 100) END;
  IF sz > 1 THEN Snd(S_BANGBIG); Spawn(ast[i].x, ast[i].y, sz-1); Spawn(ast[i].x, ast[i].y, sz-1)
  ELSE Snd(S_BANGSMALL) END;
  ast[i].size := 0
END SplitAst;

PROCEDURE UpdateWorld;
  VAR i, j: CARDINAL; rr: REAL;
BEGIN
  IF gOver OR gPaused THEN RETURN END;
  INC(gWaveFrames);
  (* ship or death pause *)
  IF NOT gDead THEN
    svx := svx * Friction; svy := svy * Friction;
    sx := sx + svx; sy := sy + svy; Wrap(sx, WinW); Wrap(sy, WinH);
    IF invuln > 0 THEN DEC(invuln) END
  ELSE
    IF deathTimer > 0 THEN DEC(deathTimer) END;
    IF (deathTimer <= 0) AND (NOT gOver) THEN ResetShip; gDead := FALSE END
  END;
  IF fireCd > 0 THEN DEC(fireCd) END;
  (* player bullets *)
  FOR i := 0 TO MaxBul-1 DO
    IF bul[i].alive THEN
      bul[i].x := bul[i].x + bul[i].vx; bul[i].y := bul[i].y + bul[i].vy;
      Wrap(bul[i].x, WinW); Wrap(bul[i].y, WinH);
      DEC(bul[i].life); IF bul[i].life <= 0 THEN bul[i].alive := FALSE END
    END
  END;
  (* asteroids *)
  FOR i := 0 TO MaxAst-1 DO
    IF ast[i].size > 0 THEN
      ast[i].x := ast[i].x + ast[i].vx; ast[i].y := ast[i].y + ast[i].vy;
      Wrap(ast[i].x, WinW); Wrap(ast[i].y, WinH); ast[i].rot := ast[i].rot + ast[i].spin
    END
  END;
  UpdateDebris; UpdateSaucer;
  (* player bullet vs asteroid + saucer *)
  FOR j := 0 TO MaxBul-1 DO
    IF bul[j].alive THEN
      FOR i := 0 TO MaxAst-1 DO
        IF (ast[i].size > 0) AND bul[j].alive THEN
          rr := ast[i].r;
          IF Dist2(bul[j].x, bul[j].y, ast[i].x, ast[i].y) < rr*rr THEN bul[j].alive := FALSE; SplitAst(i) END
        END
      END;
      IF bul[j].alive AND ufoOn THEN
        rr := SaucerR + 3.0;
        IF Dist2(bul[j].x, bul[j].y, ufoX, ufoY) < rr*rr THEN
          bul[j].alive := FALSE; ufoOn := FALSE; INC(gScore, 200);
          Snd(S_BANGBIG); SpawnDebris(ufoX, ufoY, 6)
        END
      END
    END
  END;
  (* hazards vs ship *)
  IF (NOT gOver) AND (NOT gDead) AND (invuln = 0) THEN
    FOR i := 0 TO MaxAst-1 DO
      IF ast[i].size > 0 THEN
        rr := ast[i].r + ShipR;
        IF Dist2(sx, sy, ast[i].x, ast[i].y) < rr*rr THEN ShipDie END
      END
    END;
    IF (NOT gDead) THEN
      FOR i := 0 TO MaxSBul-1 DO
        IF sbul[i].alive AND (Dist2(sbul[i].x, sbul[i].y, sx, sy) < (ShipR+2.0)*(ShipR+2.0)) THEN
          sbul[i].alive := FALSE; ShipDie
        END
      END;
      IF ufoOn AND (NOT gDead) AND (Dist2(ufoX, ufoY, sx, sy) < (SaucerR+ShipR)*(SaucerR+ShipR)) THEN
        ufoOn := FALSE; SpawnDebris(ufoX, ufoY, 5); ShipDie
      END
    END
  END;
  (* next wave *)
  IF CountAst() = 0 THEN INC(gLevel); NewWave END;
  (* saucer scheduling *)
  IF (NOT ufoOn) AND (saucerTimer > 0) THEN DEC(saucerTimer) END;
  IF (NOT ufoOn) AND (saucerTimer <= 0) AND (CountAst() > 0) THEN
    SpawnSaucer; saucerTimer := 320 + VAL(INTEGER, Rnd(360))
  END
END UpdateWorld;

(* ---- rendering --------------------------------------------------------- *)
PROCEDURE Pt (x, y: REAL): ObjC.NSPoint;
VAR p: ObjC.NSPoint;
BEGIN p.x := x; p.y := y; RETURN p END Pt;

PROCEDURE DrawText (s: ARRAY OF CHAR; x, y, size, r, g, b: REAL);
VAR color, font, dict, ns: ObjC.Id;
BEGIN
  color := [Cls0("NSColor") colorWithDeviceRed: r green: g blue: b alpha: 1.0];
  font  := [Cls0("NSFont") userFixedPitchFontOfSize: size];
  dict  := [[Cls0("NSMutableDictionary") alloc] init];
  [dict setObject: font  forKey: ObjC.NSString("NSFont")];
  [dict setObject: color forKey: ObjC.NSString("NSColor")];
  ns := ObjC.NSString(s);
  [ns drawAtPoint: Pt(x, y) withAttributes: dict]
END DrawText;

PROCEDURE StrokeShipAt (cg: ObjC.Id; px, py, ang, g: REAL);
BEGIN
  CG.SetRGBStrokeColor(cg, g, g, g, 1.0); CG.SetLineWidth(cg, 1.6);
  CG.BeginPath(cg);
  CG.MoveToPoint   (cg, px + cos(ang) * ShipR,           py + sin(ang) * ShipR);
  CG.AddLineToPoint(cg, px + cos(ang + 2.5) * ShipR,     py + sin(ang + 2.5) * ShipR);
  CG.AddLineToPoint(cg, px + cos(ang) * (ShipR * 0.4),   py + sin(ang) * (ShipR * 0.4));
  CG.AddLineToPoint(cg, px + cos(ang - 2.5) * ShipR,     py + sin(ang - 2.5) * ShipR);
  CG.ClosePath(cg); CG.StrokePath(cg)
END StrokeShipAt;

PROCEDURE DrawShip (cg: ObjC.Id);
  VAR g, fx, fy: REAL;
BEGIN
  IF gOver OR gDead THEN RETURN END;
  g := 1.0; IF (invuln > 0) AND ((invuln DIV 4) MOD 2 = 0) THEN g := 0.4 END;
  StrokeShipAt(cg, sx, sy, sa, g);
  IF thrustOn THEN
    CG.SetRGBStrokeColor(cg, 1.0, 0.6, 0.2, 1.0); CG.SetLineWidth(cg, 1.4);
    CG.BeginPath(cg);
    CG.MoveToPoint   (cg, sx + cos(sa + 2.9) * (ShipR*0.8), sy + sin(sa + 2.9) * (ShipR*0.8));
    fx := sx - cos(sa) * (ShipR + 7.0 + Frnd()*5.0); fy := sy - sin(sa) * (ShipR + 7.0 + Frnd()*5.0);
    CG.AddLineToPoint(cg, fx, fy);
    CG.AddLineToPoint(cg, sx + cos(sa - 2.9) * (ShipR*0.8), sy + sin(sa - 2.9) * (ShipR*0.8));
    CG.StrokePath(cg)
  END
END DrawShip;

PROCEDURE DrawAsteroid (cg: ObjC.Id; i: CARDINAL);
  VAR k: CARDINAL; ang, rad, vx, vy: REAL;
BEGIN
  CG.SetRGBStrokeColor(cg, 0.82, 0.84, 0.88, 1.0); CG.SetLineWidth(cg, 1.4);
  CG.BeginPath(cg);
  FOR k := 0 TO NV-1 DO
    ang := ast[i].rot + FLOAT(VAL(INTEGER,k)) * (TwoPi / FLOAT(NV));
    rad := ast[i].r * ast[i].shp[k];
    vx := ast[i].x + cos(ang) * rad; vy := ast[i].y + sin(ang) * rad;
    IF k = 0 THEN CG.MoveToPoint(cg, vx, vy) ELSE CG.AddLineToPoint(cg, vx, vy) END
  END;
  CG.ClosePath(cg); CG.StrokePath(cg)
END DrawAsteroid;

PROCEDURE DrawSaucer (cg: ObjC.Id);
  VAR w, h: REAL;
BEGIN
  IF NOT ufoOn THEN RETURN END;
  w := SaucerR; h := SaucerR * 0.42;
  CG.SetRGBStrokeColor(cg, 0.75, 0.95, 0.80, 1.0); CG.SetLineWidth(cg, 1.5);
  CG.BeginPath(cg);                       (* hull hexagon *)
  CG.MoveToPoint   (cg, ufoX - w,       ufoY);
  CG.AddLineToPoint(cg, ufoX - w*0.45,  ufoY - h);
  CG.AddLineToPoint(cg, ufoX + w*0.45,  ufoY - h);
  CG.AddLineToPoint(cg, ufoX + w,       ufoY);
  CG.AddLineToPoint(cg, ufoX + w*0.45,  ufoY + h);
  CG.AddLineToPoint(cg, ufoX - w*0.45,  ufoY + h);
  CG.ClosePath(cg); CG.StrokePath(cg);
  CG.BeginPath(cg);                       (* dome *)
  CG.MoveToPoint   (cg, ufoX - w*0.45, ufoY - h);
  CG.AddLineToPoint(cg, ufoX - w*0.22, ufoY - h*2.0);
  CG.AddLineToPoint(cg, ufoX + w*0.22, ufoY - h*2.0);
  CG.AddLineToPoint(cg, ufoX + w*0.45, ufoY - h);
  CG.StrokePath(cg)
END DrawSaucer;

PROCEDURE DrawDebris (cg: ObjC.Id);
  VAR i: CARDINAL; g, hl: REAL;
BEGIN
  FOR i := 0 TO MaxDebris-1 DO
    IF deb[i].alive THEN
      g := FLOAT(deb[i].life) / 60.0; IF g > 1.0 THEN g := 1.0 END; hl := 6.0;
      CG.SetRGBStrokeColor(cg, g, g, g, 1.0); CG.SetLineWidth(cg, 1.4);
      CG.BeginPath(cg);
      CG.MoveToPoint   (cg, deb[i].x - cos(deb[i].ang)*hl, deb[i].y - sin(deb[i].ang)*hl);
      CG.AddLineToPoint(cg, deb[i].x + cos(deb[i].ang)*hl, deb[i].y + sin(deb[i].ang)*hl);
      CG.StrokePath(cg)
    END
  END
END DrawDebris;

PROCEDURE PutNum (label: ARRAY OF CHAR; n: CARDINAL; x, y: REAL);
  VAR buf: ARRAY [0..47] OF CHAR; num: ARRAY [0..15] OF CHAR; i, p: CARDINAL;
BEGIN
  p := 0; i := 0;
  WHILE (i <= HIGH(label)) AND (label[i] # 0C) DO buf[p] := label[i]; INC(p); INC(i) END;
  CardToStr(n, num); i := 0;
  WHILE (num[i] # 0C) AND (p < HIGH(buf)) DO buf[p] := num[i]; INC(p); INC(i) END;
  buf[p] := 0C;
  DrawText(buf, x, y, 15.0, 0.90, 0.92, 0.96)
END PutNum;

(* ---- the field: a Modula-2 CLASS that IS an NSView (y-up) -------------- *)
CLASS AsteroidsView;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN FALSE END IsFlipped;

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (rx, ry, rw, rh: REAL);
    VAR cg: ObjC.Id; i: CARDINAL; k: INTEGER;
  BEGIN
    cg := [[Cls0("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.02, 0.02, 0.04, 1.0); CG.FillRect(cg, 0.0, 0.0, WinW, WinH);
    FOR i := 0 TO MaxAst-1 DO IF ast[i].size > 0 THEN DrawAsteroid(cg, i) END END;
    DrawSaucer(cg); DrawDebris(cg);
    CG.SetRGBFillColor(cg, 1.0, 1.0, 1.0, 1.0);
    FOR i := 0 TO MaxBul-1 DO IF bul[i].alive THEN CG.FillRect(cg, bul[i].x-1.5, bul[i].y-1.5, 3.0, 3.0) END END;
    CG.SetRGBFillColor(cg, 0.7, 1.0, 0.75, 1.0);
    FOR i := 0 TO MaxSBul-1 DO IF sbul[i].alive THEN CG.FillRect(cg, sbul[i].x-1.5, sbul[i].y-1.5, 3.0, 3.0) END END;
    DrawShip(cg);
    PutNum("SCORE ", gScore, 18.0, WinH - 28.0);
    PutNum("WAVE ",  gLevel, 18.0, WinH - 50.0);
    FOR k := 0 TO gLives-1 DO StrokeShipAt(cg, WinW - 30.0 - FLOAT(k) * 26.0, WinH - 28.0, 1.5707963, 1.0) END;
    IF gOver THEN
      DrawText("GAME OVER", WinW/2.0 - 70.0, WinH/2.0 + 10.0, 28.0, 0.95, 0.4, 0.4);
      DrawText("press r to restart", WinW/2.0 - 80.0, WinH/2.0 - 24.0, 14.0, 0.7, 0.72, 0.78)
    ELSIF gPaused THEN
      DrawText("PAUSED", WinW/2.0 - 45.0, WinH/2.0, 24.0, 0.95, 0.85, 0.3)
    END
  END DrawRect;

  PROCEDURE KeyDown (event: ObjC.Id);
    VAR getCode: ObjC.Send0I; kc: INTEGER;
  BEGIN
    getCode := CAST(ObjC.Send0I, ObjC.MsgSendPtr());
    kc := getCode(event, ObjC.Selector("keyCode"));
    IF    kc = KC_LEFT  THEN kLeft := TRUE
    ELSIF kc = KC_RIGHT THEN kRight := TRUE
    ELSIF kc = KC_UP    THEN kThrust := TRUE
    ELSIF kc = KC_SPACE THEN kFire := TRUE
    ELSIF kc = KC_DOWN  THEN IF NOT gOver THEN Hyperspace END
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
    ELSIF kc = KC_UP    THEN kThrust := FALSE
    ELSIF kc = KC_SPACE THEN kFire := FALSE
    END
  END KeyUp;
END AsteroidsView;

(* ---- timer + harness --------------------------------------------------- *)
PROCEDURE BeatInterval (): INTEGER;       (* heartbeat quickens through the wave *)
  VAR f: INTEGER;
BEGIN
  f := 44 - VAL(INTEGER, gWaveFrames DIV 26);
  IF f < 15 THEN f := 15 END;
  RETURN f
END BeatInterval;

PROCEDURE Tick (block, timer: ObjC.Id);
BEGIN
  thrustOn := FALSE;
  IF (NOT gOver) AND (NOT gPaused) THEN
    IF kLeft  THEN RotateShip(RotStep) END;
    IF kRight THEN RotateShip(-RotStep) END;
    IF kThrust THEN Thrust; INC(gThrustSnd); IF gThrustSnd MOD 5 = 0 THEN Snd(S_THRUST) END END;
    IF kFire AND (fireCd = 0) THEN Fire; fireCd := FireCool END;
    UpdateWorld;
    IF gAudio THEN                         (* two-tone background heartbeat *)
      IF beatTimer > 0 THEN DEC(beatTimer) END;
      IF beatTimer <= 0 THEN
        IF beatHi THEN Snd(S_BEATHI) ELSE Snd(S_BEATLO) END;
        beatHi := NOT beatHi; beatTimer := BeatInterval()
      END
    END
  END;
  IF gView # NIL THEN [gView setNeedsDisplay: TRUE] END
END Tick;

PROCEDURE DoSteps (n: CARDINAL);
  VAR i: CARDINAL;
BEGIN FOR i := 1 TO n DO IF fireCd > 0 THEN DEC(fireCd) END; UpdateWorld END END DoSteps;

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
  IF    NameIs(name, "left")    THEN RotateShip(0.35)
  ELSIF NameIs(name, "right")   THEN RotateShip(-0.35)
  ELSIF NameIs(name, "thrust")  THEN Thrust
  ELSIF NameIs(name, "up")      THEN Thrust
  ELSIF NameIs(name, "fire")    THEN Fire
  ELSIF NameIs(name, "space")   THEN Fire
  ELSIF NameIs(name, "hyper")   THEN Hyperspace
  ELSIF NameIs(name, "saucer")  THEN SpawnSaucer
  ELSIF NameIs(name, "pause")   THEN gPaused := NOT gPaused
  ELSIF NameIs(name, "restart") THEN NewGame
  END
END DoKey;

PROCEDURE Bit (b: BOOLEAN): INTEGER;
BEGIN IF b THEN RETURN 1 ELSE RETURN 0 END END Bit;

PROCEDURE GameState (name: ARRAY OF CHAR; idx: INTEGER): INTEGER;
BEGIN
  IF    NameIs(name, "score")     THEN RETURN VAL(INTEGER, gScore)
  ELSIF NameIs(name, "wave")      THEN RETURN VAL(INTEGER, gLevel)
  ELSIF NameIs(name, "lives")     THEN RETURN gLives
  ELSIF NameIs(name, "asteroids") THEN RETURN VAL(INTEGER, CountAst())
  ELSIF NameIs(name, "saucer")    THEN RETURN Bit(ufoOn)
  ELSIF NameIs(name, "gameover")  THEN RETURN Bit(gOver)
  END;
  RETURN 0
END GameState;

(* ---- audio + main ------------------------------------------------------ *)
PROCEDURE InitAudio;
  VAR s: Audio.Sound;
BEGIN
  Audio.InitEngine(424242);
  IF Sfx.Start() THEN
    Audio.Shoot(s, 0.12);        Sfx.Define(S_FIRE, s);      Audio.FreeSound(s);
    Audio.Noise(s, 1, 0.10);     Sfx.Define(S_THRUST, s);    Audio.FreeSound(s);
    Audio.Explode(s, 0.8, 0.5);  Sfx.Define(S_BANGBIG, s);   Audio.FreeSound(s);
    Audio.Explode(s, 0.3, 0.3);  Sfx.Define(S_BANGSMALL, s); Audio.FreeSound(s);
    Audio.Hurt(s, 0.6);          Sfx.Define(S_OVER, s);      Audio.FreeSound(s);
    Audio.Beep(s, 70.0, 0.10);   Sfx.Define(S_BEATLO, s);    Audio.FreeSound(s);
    Audio.Beep(s, 102.0, 0.10);  Sfx.Define(S_BEATHI, s);    Audio.FreeSound(s);
    Audio.Blip(s, 0.6, 0.05);    Sfx.Define(S_SAUCER, s);    Audio.FreeSound(s);
    gAudio := TRUE
  END
END InitAudio;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

VAR win: Cocoa.Window; content: Cocoa.View; view: AsteroidsView;
    spath: ARRAY [0..1023] OF CHAR; ignore, scriptMode: BOOLEAN;
BEGIN
  gSeed := 987654321; gAudio := FALSE; gThrustSnd := 0;
  kLeft := FALSE; kRight := FALSE; kThrust := FALSE; kFire := FALSE;
  NewGame;

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "NewM2 Asteroids");
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
    gTimer := [Cls0("NSTimer") scheduledTimerWithTimeInterval: 0.03
                               repeats: TRUE
                               block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
    Cocoa.RunApp
  END
END asteroids_cocoa.
