MODULE starturret_cocoa;
(* Star Turret — a native Cocoa app written in Modula-2: the view from a capital
   ship's forward gun turret, warping through space. Everything is vector graphics
   drawn with Core Graphics, and everything is 3-D — a perspective projection
   (sx = cx + (x-camX)*f/z) turns a cloud of points into a starfield that streaks
   past at warp speed, enemy fighters that grow as they close, and the asterisk
   bolts they fire at you. Steer the turret with the arrow keys to line a fighter
   up in the reticle (space fires twin hitscan lasers) and to dodge incoming
   fire — a bolt that reaches you flashes the screen and costs a life.

     newm2-driver run --library library cocoademos/starturret_cocoa.mod
   arrows steer / aim   space fire   p pause   r restart   (close window to quit)

   Headless under the Ptcl test harness (sound off there):
     newm2-driver run --library library cocoademos/starturret_cocoa.mod -- --script cocoademos/test/starturret.tcl *)
FROM SYSTEM IMPORT CAST, ADDRESS;
FROM RealMath IMPORT sin, cos;
FROM WholeStr IMPORT CardToStr;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;
IMPORT Audio;
IMPORT Sfx;
IMPORT DemoHarness;

CONST
  WinW = 860.0; WinH = 640.0;
  CX = 430.0; CY = 320.0;               (* screen centre = where the gun points *)
  Focal = 340.0;
  Zfar = 950.0; Znear = 20.0;
  WarpSpeed = 15.0; StreakZ = 30.0;
  NStars = 220; MaxEnemy = 5; MaxProj = 14;
  PanStep = 6.0; PanLimit = 300.0;
  EnemyZSpeed = 1.5; ProjZSpeed = 9.0;
  ReticleR = 54.0; HitR2 = 1600.0;      (* (40 world units)^2 dodge radius *)
  FlashFrames = 13; FireCool = 6;

  KC_LEFT = 123; KC_RIGHT = 124; KC_UP = 126; KC_DOWN = 125;
  KC_SPACE = 49; KC_P = 35; KC_R = 15;

  S_LASER = 0; S_BOOM = 1; S_EFIRE = 2; S_HIT = 3; S_OVER = 4;

TYPE
  Star    = RECORD x, y, z: REAL; END;
  Enemy   = RECORD x, y, z, vx: REAL; fire: INTEGER; alive: BOOLEAN; END;
  Proj    = RECORD x, y, z, vx, vy: REAL; alive: BOOLEAN; END;

VAR
  star: ARRAY [0..NStars-1] OF Star;
  enemy: ARRAY [0..MaxEnemy-1] OF Enemy;
  proj: ARRAY [0..MaxProj-1] OF Proj;
  camX, camY: REAL;
  gScore: CARDINAL; gLives: INTEGER;
  gOver, gPaused: BOOLEAN;
  kLeft, kRight, kUp, kDown: BOOLEAN;
  flashTimer, fireCd, laserTimer, enemyTimer: INTEGER;
  gSeed: CARDINAL; gAudio: BOOLEAN;
  gView, gTimer: ObjC.Id;

PROCEDURE Cls0 (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls0;

PROCEDURE Rnd (n: CARDINAL): CARDINAL;
BEGIN gSeed := (gSeed * 1103515245 + 12345) MOD 2147483648; RETURN (gSeed DIV 65536) MOD n END Rnd;

PROCEDURE Frnd (): REAL;                 (* 0..1 *)
BEGIN RETURN FLOAT(VAL(INTEGER, Rnd(10000))) / 10000.0 END Frnd;

PROCEDURE Sym (range: REAL): REAL;       (* -range..range *)
BEGIN RETURN (Frnd() * 2.0 - 1.0) * range END Sym;

PROCEDURE Snd (id: CARDINAL);
BEGIN IF gAudio THEN Sfx.Play(id) END END Snd;

(* ---- perspective projection -------------------------------------------- *)
PROCEDURE Project (x, y, z: REAL; VAR sx, sy, scale: REAL);
BEGIN
  IF z < 0.5 THEN z := 0.5 END;
  scale := Focal / z;
  sx := CX + (x - camX) * scale;
  sy := CY + (y - camY) * scale
END Project;

(* ---- spawning ---------------------------------------------------------- *)
PROCEDURE NewStar (i: CARDINAL; z: REAL);
BEGIN star[i].x := Sym(520.0); star[i].y := Sym(420.0); star[i].z := z END NewStar;

PROCEDURE SpawnEnemy;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO MaxEnemy-1 DO
    IF NOT enemy[i].alive THEN
      enemy[i].x := Sym(220.0); enemy[i].y := Sym(170.0); enemy[i].z := Zfar * 0.8;
      enemy[i].vx := Sym(0.8); enemy[i].fire := 40 + VAL(INTEGER, Rnd(50)); enemy[i].alive := TRUE;
      RETURN
    END
  END
END SpawnEnemy;

PROCEDURE EnemyFire (i: CARDINAL);        (* aim an asterisk bolt at the turret *)
  VAR j: CARDINAL; frames: REAL;
BEGIN
  FOR j := 0 TO MaxProj-1 DO
    IF NOT proj[j].alive THEN
      frames := enemy[i].z / ProjZSpeed; IF frames < 1.0 THEN frames := 1.0 END;
      proj[j].x := enemy[i].x; proj[j].y := enemy[i].y; proj[j].z := enemy[i].z;
      proj[j].vx := (camX - enemy[i].x) / frames; proj[j].vy := (camY - enemy[i].y) / frames;
      proj[j].alive := TRUE; Snd(S_EFIRE); RETURN
    END
  END
END EnemyFire;

PROCEDURE CountEnemies (): CARDINAL;
  VAR i, n: CARDINAL;
BEGIN n := 0; FOR i := 0 TO MaxEnemy-1 DO IF enemy[i].alive THEN INC(n) END END; RETURN n END CountEnemies;

PROCEDURE NewGame;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO NStars-1 DO NewStar(i, Znear + Frnd() * (Zfar - Znear)) END;
  FOR i := 0 TO MaxEnemy-1 DO enemy[i].alive := FALSE END;
  FOR i := 0 TO MaxProj-1 DO proj[i].alive := FALSE END;
  camX := 0.0; camY := 0.0;
  gScore := 0; gLives := 3; gOver := FALSE; gPaused := FALSE;
  flashTimer := 0; fireCd := 0; laserTimer := 0; enemyTimer := 60
END NewGame;

(* ---- actions ----------------------------------------------------------- *)
PROCEDURE Pan (dx, dy: REAL);
BEGIN
  camX := camX + dx; camY := camY + dy;
  IF camX < -PanLimit THEN camX := -PanLimit ELSIF camX > PanLimit THEN camX := PanLimit END;
  IF camY < -PanLimit THEN camY := -PanLimit ELSIF camY > PanLimit THEN camY := PanLimit END
END Pan;

PROCEDURE Fire;                           (* twin hitscan lasers straight ahead *)
  VAR i, best: CARDINAL; sx, sy, sc, d2, bestz: REAL; found: BOOLEAN;
BEGIN
  IF gOver OR gPaused THEN RETURN END;
  Snd(S_LASER); laserTimer := 4;
  found := FALSE; best := 0; bestz := Zfar * 2.0;
  FOR i := 0 TO MaxEnemy-1 DO
    IF enemy[i].alive THEN
      Project(enemy[i].x, enemy[i].y, enemy[i].z, sx, sy, sc);
      d2 := (sx - CX)*(sx - CX) + (sy - CY)*(sy - CY);
      IF (d2 < ReticleR*ReticleR) AND (enemy[i].z < bestz) THEN found := TRUE; best := i; bestz := enemy[i].z END
    END
  END;
  IF found THEN enemy[best].alive := FALSE; INC(gScore, 100); Snd(S_BOOM) END
END Fire;

PROCEDURE HitTurret;
BEGIN
  flashTimer := FlashFrames; Snd(S_HIT); DEC(gLives);
  IF gLives < 0 THEN gOver := TRUE; Snd(S_OVER) END
END HitTurret;

(* ---- world update ------------------------------------------------------ *)
PROCEDURE UpdateWorld;
  VAR i: CARDINAL; dx, dy: REAL;
BEGIN
  IF gOver OR gPaused THEN RETURN END;
  IF fireCd > 0 THEN DEC(fireCd) END;
  IF laserTimer > 0 THEN DEC(laserTimer) END;
  IF flashTimer > 0 THEN DEC(flashTimer) END;
  (* stars stream past *)
  FOR i := 0 TO NStars-1 DO
    star[i].z := star[i].z - WarpSpeed;
    IF star[i].z <= Znear THEN NewStar(i, Zfar) END
  END;
  (* enemies approach + weave + fire *)
  FOR i := 0 TO MaxEnemy-1 DO
    IF enemy[i].alive THEN
      enemy[i].z := enemy[i].z - EnemyZSpeed;
      enemy[i].x := enemy[i].x + enemy[i].vx;
      IF (enemy[i].x < -240.0) OR (enemy[i].x > 240.0) THEN enemy[i].vx := -enemy[i].vx END;
      DEC(enemy[i].fire);
      IF enemy[i].fire <= 0 THEN EnemyFire(i); enemy[i].fire := 70 + VAL(INTEGER, Rnd(60)) END;
      IF enemy[i].z <= Znear THEN enemy[i].alive := FALSE END       (* flew past *)
    END
  END;
  (* incoming bolts *)
  FOR i := 0 TO MaxProj-1 DO
    IF proj[i].alive THEN
      proj[i].x := proj[i].x + proj[i].vx; proj[i].y := proj[i].y + proj[i].vy;
      proj[i].z := proj[i].z - ProjZSpeed;
      IF proj[i].z <= Znear THEN
        dx := proj[i].x - camX; dy := proj[i].y - camY;
        IF dx*dx + dy*dy < HitR2 THEN HitTurret END;          (* didn't dodge *)
        proj[i].alive := FALSE
      END
    END
  END;
  (* spawn waves of fighters *)
  IF enemyTimer > 0 THEN DEC(enemyTimer) END;
  IF (enemyTimer <= 0) AND (CountEnemies() < MaxEnemy) THEN
    SpawnEnemy; enemyTimer := 90 + VAL(INTEGER, Rnd(120))
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

PROCEDURE Line (cg: ObjC.Id; x0, y0, x1, y1: REAL);
BEGIN CG.BeginPath(cg); CG.MoveToPoint(cg, x0, y0); CG.AddLineToPoint(cg, x1, y1); CG.StrokePath(cg) END Line;

PROCEDURE DrawStars (cg: ObjC.Id);
  VAR i: CARDINAL; hx, hy, tx, ty, sc, b: REAL;
BEGIN
  FOR i := 0 TO NStars-1 DO
    Project(star[i].x, star[i].y, star[i].z, hx, hy, sc);
    Project(star[i].x, star[i].y, star[i].z + StreakZ, tx, ty, sc);
    b := 1.0 - star[i].z / Zfar; IF b < 0.15 THEN b := 0.15 END;
    CG.SetRGBStrokeColor(cg, b, b, b * 1.05, 1.0);
    CG.SetLineWidth(cg, 0.6 + (1.0 - star[i].z / Zfar) * 1.8);
    Line(cg, tx, ty, hx, hy)
  END
END DrawStars;

PROCEDURE DrawEnemy (cg: ObjC.Id; i: CARDINAL);
  VAR sx, sy, sc, s, k: REAL; j: CARDINAL;
BEGIN
  Project(enemy[i].x, enemy[i].y, enemy[i].z, sx, sy, sc);
  s := 26.0 * sc; IF s < 2.0 THEN RETURN END;
  CG.SetRGBStrokeColor(cg, 0.55, 0.95, 0.65, 1.0); CG.SetLineWidth(cg, 1.5);
  (* cockpit hexagon *)
  CG.BeginPath(cg);
  FOR j := 0 TO 6 DO
    k := FLOAT(VAL(INTEGER,j)) * 1.0471976;
    IF j = 0 THEN CG.MoveToPoint(cg, sx + cos(k)*s*0.42, sy + sin(k)*s*0.42)
    ELSE CG.AddLineToPoint(cg, sx + cos(k)*s*0.42, sy + sin(k)*s*0.42) END
  END;
  CG.StrokePath(cg);
  (* struts + twin wing panels *)
  Line(cg, sx - s*0.42, sy, sx - s, sy);
  Line(cg, sx + s*0.42, sy, sx + s, sy);
  Line(cg, sx - s, sy - s*0.9, sx - s, sy + s*0.9);
  Line(cg, sx + s, sy - s*0.9, sx + s, sy + s*0.9)
END DrawEnemy;

PROCEDURE DrawProj (cg: ObjC.Id; i: CARDINAL);
  VAR sx, sy, sc, s, a: REAL; k: CARDINAL;
BEGIN
  Project(proj[i].x, proj[i].y, proj[i].z, sx, sy, sc);
  s := 9.0 * sc; IF s < 1.5 THEN s := 1.5 END; IF s > 60.0 THEN s := 60.0 END;
  CG.SetRGBStrokeColor(cg, 1.0, 0.45, 0.30, 1.0); CG.SetLineWidth(cg, 1.6);
  FOR k := 0 TO 3 DO                       (* 8-point asterisk *)
    a := FLOAT(VAL(INTEGER,k)) * 0.7853982;
    Line(cg, sx - cos(a)*s, sy - sin(a)*s, sx + cos(a)*s, sy + sin(a)*s)
  END
END DrawProj;

PROCEDURE DrawReticle (cg: ObjC.Id);
  VAR n: REAL;
BEGIN
  n := 14.0;
  CG.SetRGBStrokeColor(cg, 0.30, 0.85, 0.95, 0.9); CG.SetLineWidth(cg, 1.5);
  (* four corner brackets *)
  Line(cg, CX-ReticleR, CY-ReticleR+n, CX-ReticleR, CY-ReticleR); Line(cg, CX-ReticleR, CY-ReticleR, CX-ReticleR+n, CY-ReticleR);
  Line(cg, CX+ReticleR, CY-ReticleR+n, CX+ReticleR, CY-ReticleR); Line(cg, CX+ReticleR, CY-ReticleR, CX+ReticleR-n, CY-ReticleR);
  Line(cg, CX-ReticleR, CY+ReticleR-n, CX-ReticleR, CY+ReticleR); Line(cg, CX-ReticleR, CY+ReticleR, CX-ReticleR+n, CY+ReticleR);
  Line(cg, CX+ReticleR, CY+ReticleR-n, CX+ReticleR, CY+ReticleR); Line(cg, CX+ReticleR, CY+ReticleR, CX+ReticleR-n, CY+ReticleR);
  CG.SetRGBFillColor(cg, 0.30, 0.85, 0.95, 1.0); CG.FillRect(cg, CX-1.5, CY-1.5, 3.0, 3.0)
END DrawReticle;

PROCEDURE PutNum (label: ARRAY OF CHAR; n: CARDINAL; x, y: REAL);
  VAR buf: ARRAY [0..47] OF CHAR; num: ARRAY [0..15] OF CHAR; i, p: CARDINAL;
BEGIN
  p := 0; i := 0;
  WHILE (i <= HIGH(label)) AND (label[i] # 0C) DO buf[p] := label[i]; INC(p); INC(i) END;
  CardToStr(n, num); i := 0;
  WHILE (num[i] # 0C) AND (p < HIGH(buf)) DO buf[p] := num[i]; INC(p); INC(i) END;
  buf[p] := 0C;
  DrawText(buf, x, y, 15.0, 0.85, 0.92, 0.96)
END PutNum;

(* ---- the cockpit: a Modula-2 CLASS that IS an NSView ------------------- *)
CLASS TurretView;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN FALSE END IsFlipped;

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (rx, ry, rw, rh: REAL);
    VAR cg: ObjC.Id; i: CARDINAL; k: INTEGER; fa: REAL;
  BEGIN
    cg := [[Cls0("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.01, 0.01, 0.03, 1.0); CG.FillRect(cg, 0.0, 0.0, WinW, WinH);
    DrawStars(cg);
    FOR i := 0 TO MaxEnemy-1 DO IF enemy[i].alive THEN DrawEnemy(cg, i) END END;
    FOR i := 0 TO MaxProj-1 DO IF proj[i].alive THEN DrawProj(cg, i) END END;
    IF laserTimer > 0 THEN                  (* twin turret lasers converging on the reticle *)
      CG.SetRGBStrokeColor(cg, 0.4, 1.0, 0.5, 1.0); CG.SetLineWidth(cg, 2.2);
      Line(cg, 70.0, 0.0, CX, CY); Line(cg, WinW - 70.0, 0.0, CX, CY)
    END;
    DrawReticle(cg);
    PutNum("SCORE ", gScore, 18.0, WinH - 28.0);
    FOR k := 0 TO gLives-1 DO
      CG.SetRGBFillColor(cg, 0.4, 1.0, 0.5, 1.0); CG.FillRect(cg, WinW - 36.0 - FLOAT(k) * 26.0, WinH - 30.0, 16.0, 10.0)
    END;
    IF flashTimer > 0 THEN                   (* hit flash *)
      fa := FLOAT(flashTimer) / FLOAT(FlashFrames) * 0.6;
      CG.SetRGBFillColor(cg, 1.0, 0.5, 0.3, fa); CG.FillRect(cg, 0.0, 0.0, WinW, WinH)
    END;
    IF gOver THEN
      DrawText("YOU WERE HIT", CX - 96.0, CY + 70.0, 30.0, 0.95, 0.4, 0.4);
      DrawText("press r to restart", CX - 80.0, CY + 36.0, 14.0, 0.7, 0.72, 0.78)
    ELSIF gPaused THEN
      DrawText("PAUSED", CX - 45.0, CY + 60.0, 24.0, 0.95, 0.85, 0.3)
    END
  END DrawRect;

  PROCEDURE KeyDown (event: ObjC.Id);
    VAR getCode: ObjC.Send0I; kc: INTEGER;
  BEGIN
    getCode := CAST(ObjC.Send0I, ObjC.MsgSendPtr());
    kc := getCode(event, ObjC.Selector("keyCode"));
    IF    kc = KC_LEFT  THEN kLeft := TRUE
    ELSIF kc = KC_RIGHT THEN kRight := TRUE
    ELSIF kc = KC_UP    THEN kUp := TRUE
    ELSIF kc = KC_DOWN  THEN kDown := TRUE
    ELSIF kc = KC_SPACE THEN IF fireCd = 0 THEN Fire; fireCd := FireCool END
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
    ELSIF kc = KC_UP    THEN kUp := FALSE
    ELSIF kc = KC_DOWN  THEN kDown := FALSE
    END
  END KeyUp;
END TurretView;

(* ---- timer + harness --------------------------------------------------- *)
PROCEDURE Tick (block, timer: ObjC.Id);
BEGIN
  IF (NOT gOver) AND (NOT gPaused) THEN
    IF kLeft  THEN Pan(-PanStep, 0.0) END;
    IF kRight THEN Pan(PanStep, 0.0) END;
    IF kUp    THEN Pan(0.0, PanStep) END;
    IF kDown  THEN Pan(0.0, -PanStep) END;
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
  IF    NameIs(name, "left")    THEN Pan(-40.0, 0.0)
  ELSIF NameIs(name, "right")   THEN Pan(40.0, 0.0)
  ELSIF NameIs(name, "up")      THEN Pan(0.0, 40.0)
  ELSIF NameIs(name, "down")    THEN Pan(0.0, -40.0)
  ELSIF NameIs(name, "fire")    THEN Fire
  ELSIF NameIs(name, "space")   THEN Fire
  ELSIF NameIs(name, "enemy")   THEN SpawnEnemy
  ELSIF NameIs(name, "pause")   THEN gPaused := NOT gPaused
  ELSIF NameIs(name, "restart") THEN NewGame
  END
END DoKey;

PROCEDURE Bit (b: BOOLEAN): INTEGER;
BEGIN IF b THEN RETURN 1 ELSE RETURN 0 END END Bit;

PROCEDURE GameState (name: ARRAY OF CHAR; idx: INTEGER): INTEGER;
BEGIN
  IF    NameIs(name, "score")    THEN RETURN VAL(INTEGER, gScore)
  ELSIF NameIs(name, "lives")    THEN RETURN gLives
  ELSIF NameIs(name, "enemies")  THEN RETURN VAL(INTEGER, CountEnemies())
  ELSIF NameIs(name, "flash")    THEN RETURN flashTimer
  ELSIF NameIs(name, "gameover") THEN RETURN Bit(gOver)
  END;
  RETURN 0
END GameState;

(* ---- audio + main ------------------------------------------------------ *)
PROCEDURE InitAudio;
  VAR s: Audio.Sound;
BEGIN
  Audio.InitEngine(50515);
  IF Sfx.Start() THEN
    Audio.Zap(s, 0.16);          Sfx.Define(S_LASER, s); Audio.FreeSound(s);
    Audio.Explode(s, 0.6, 0.45); Sfx.Define(S_BOOM, s);  Audio.FreeSound(s);
    Audio.Blip(s, 1.3, 0.06);    Sfx.Define(S_EFIRE, s); Audio.FreeSound(s);
    Audio.Bang(s, 0.30);         Sfx.Define(S_HIT, s);   Audio.FreeSound(s);
    Audio.Hurt(s, 0.6);          Sfx.Define(S_OVER, s);  Audio.FreeSound(s);
    gAudio := TRUE
  END
END InitAudio;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

VAR win: Cocoa.Window; content: Cocoa.View; view: TurretView;
    spath: ARRAY [0..1023] OF CHAR; ignore, scriptMode: BOOLEAN;
BEGIN
  gSeed := 1234509; gAudio := FALSE;
  kLeft := FALSE; kRight := FALSE; kUp := FALSE; kDown := FALSE;
  NewGame;

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "NewM2 Star Turret");
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
    gTimer := [Cls0("NSTimer") scheduledTimerWithTimeInterval: 0.022
                               repeats: TRUE
                               block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
    Cocoa.RunApp
  END
END starturret_cocoa.
