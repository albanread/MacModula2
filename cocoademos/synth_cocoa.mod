MODULE synth_cocoa;
(* Synth Lab — a software synthesizer written in Modula-2, native on Cocoa. Every
   note is rendered by the pure-M2 Audio engine (Audio.Tone: a real oscillator in
   one of six waveforms) into a PCM Sound buffer; that exact buffer is then drawn
   two ways by a Core Graphics NSView — a live OSCILLOSCOPE (the waveform trace)
   and a SPECTRUM analyser (a bank of Goertzel filters over the samples, so you SEE
   a sine as one peak and a saw as a comb of harmonics). Play it on the computer
   keyboard, or hit space and let it auto-play an ABC tune through the current
   voice (Abc.ParseTune -> timed note events) while the scope and bars dance.

     newm2-driver run --library library cocoademos/synth_cocoa.mod
   keys A W S E D F T G Y H U J K  = a piano octave (C .. C)
   Z / X  octave down / up     Tab  cycle waveform     space  auto-play ABC
   p pause   (close the window to quit)

   Headless under the Ptcl test harness (no live sound, but the scope + spectrum
   still render from the rendered samples):
     newm2-driver run --library library cocoademos/synth_cocoa.mod -- --script cocoademos/test/synth.tcl *)
FROM SYSTEM IMPORT CAST, ADDRESS;
FROM RealMath IMPORT sin, cos, sqrt;
FROM WholeStr IMPORT CardToStr;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;
IMPORT Audio;
IMPORT Sfx;
IMPORT Abc;
IMPORT DemoHarness;

CONST
  WinW = 900.0; WinH = 640.0;
  NWaves = 6; NVoices = 6;
  NBINS = 32; BinHz = 170.0; GoertzelN = 2048;
  NoteDur = 0.34; FrameMs = 20;
  TwoPi = 6.28318530718;

  (* macOS virtual key codes — a tracker-style piano *)
  KC_A=0; KC_S=1; KC_D=2; KC_F=3; KC_H=4; KC_G=5; KC_J=38; KC_K=40;
  KC_W=13; KC_E=14; KC_T=17; KC_Y=16; KC_U=32;
  KC_Z=6; KC_X=7; KC_TAB=48; KC_SPACE=49; KC_P=35;

VAR
  gVoice: Audio.Sound; gVoiceValid: BOOLEAN;
  spec: ARRAY [0..NBINS-1] OF REAL; specMax: REAL;
  waveTab: ARRAY [0..NWaves-1] OF Audio.Waveform;
  gWave, gOctave, voiceRR: CARDINAL;
  gLastMidi: INTEGER; gLitTimer: INTEGER;
  scopeOff: CARDINAL;
  gAuto, gPaused, gAudio: BOOLEAN;
  tune: Abc.Tune; gAutoMs, gEvIdx: CARDINAL;
  gView, gTimer: ObjC.Id;
  abcBuf: ARRAY [0..511] OF CHAR; abcN: CARDINAL;

PROCEDURE Cls0 (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls0;

(* ---- synthesis --------------------------------------------------------- *)
PROCEDURE ComputeSpectrum;
  VAR k, n, N: CARDINAL; f, w, c, s, sp1, sp2, x, mag: REAL;
BEGIN
  specMax := 0.0001;
  IF (NOT gVoiceValid) OR (gVoice.count = 0) THEN
    FOR k := 0 TO NBINS-1 DO spec[k] := 0.0 END; RETURN
  END;
  N := gVoice.count DIV gVoice.channels; IF N > GoertzelN THEN N := GoertzelN END;
  FOR k := 0 TO NBINS-1 DO
    f := FLOAT(VAL(INTEGER,k+1)) * BinHz; w := TwoPi * f / 44100.0; c := 2.0 * cos(w);
    sp1 := 0.0; sp2 := 0.0;
    FOR n := 0 TO N-1 DO
      x := gVoice.samples^[n * gVoice.channels];     (* left channel *)
      s := x + c * sp1 - sp2; sp2 := sp1; sp1 := s
    END;
    mag := sqrt(sp1*sp1 + sp2*sp2 - c*sp1*sp2) / FLOAT(VAL(INTEGER,N));
    spec[k] := mag; IF mag > specMax THEN specMax := mag END
  END
END ComputeSpectrum;

PROCEDURE PlayNote (midi: INTEGER);
  VAR freq: REAL;
BEGIN
  IF (midi < 0) OR (midi > 127) THEN RETURN END;
  freq := Audio.NoteToFrequency(midi);
  IF gVoiceValid THEN Audio.FreeSound(gVoice) END;
  Audio.Tone(gVoice, freq, NoteDur, waveTab[gWave]); gVoiceValid := TRUE;
  ComputeSpectrum;
  IF gAudio THEN voiceRR := (voiceRR + 1) MOD NVoices; Sfx.Define(voiceRR, gVoice); Sfx.Play(voiceRR) END;
  gLastMidi := midi; gLitTimer := 16; scopeOff := 0
END PlayNote;

PROCEDURE CycleWave;
BEGIN gWave := (gWave + 1) MOD NWaves; IF gVoiceValid THEN PlayNote(gLastMidi) END END CycleWave;

PROCEDURE ToggleAuto;
BEGIN gAuto := NOT gAuto; gAutoMs := 0; gEvIdx := 0 END ToggleAuto;

PROCEDURE BaseMidi (): INTEGER;
BEGIN RETURN 36 + VAL(INTEGER, gOctave) * 12 END BaseMidi;

(* keycode -> semitone offset within the octave, or -100 if not a piano key *)
PROCEDURE KeyOffset (kc: INTEGER): INTEGER;
BEGIN
  IF    kc = KC_A THEN RETURN 0  ELSIF kc = KC_W THEN RETURN 1
  ELSIF kc = KC_S THEN RETURN 2  ELSIF kc = KC_E THEN RETURN 3
  ELSIF kc = KC_D THEN RETURN 4  ELSIF kc = KC_F THEN RETURN 5
  ELSIF kc = KC_T THEN RETURN 6  ELSIF kc = KC_G THEN RETURN 7
  ELSIF kc = KC_Y THEN RETURN 8  ELSIF kc = KC_H THEN RETURN 9
  ELSIF kc = KC_U THEN RETURN 10 ELSIF kc = KC_J THEN RETURN 11
  ELSIF kc = KC_K THEN RETURN 12 END;
  RETURN -100
END KeyOffset;

(* ---- per-frame update (auto-play + timers) ----------------------------- *)
PROCEDURE Advance;
BEGIN
  IF gPaused THEN RETURN END;
  IF gLitTimer > 0 THEN DEC(gLitTimer) END;
  scopeOff := (scopeOff + 37) MOD 4096;
  IF gAuto AND (tune.count > 0) THEN
    gAutoMs := gAutoMs + FrameMs;
    WHILE (gEvIdx < tune.count) AND (tune.ev[gEvIdx].timeMs <= gAutoMs) DO
      IF (tune.ev[gEvIdx].status = 90H) AND (tune.ev[gEvIdx].d2 > 0) THEN
        PlayNote(VAL(INTEGER, tune.ev[gEvIdx].d1))
      END;
      INC(gEvIdx)
    END;
    IF gAutoMs > tune.endMs + 500 THEN gAutoMs := 0; gEvIdx := 0 END
  END
END Advance;

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

PROCEDURE Panel (cg: ObjC.Id; x, y, w, h: REAL);
BEGIN
  CG.SetRGBFillColor(cg, 0.06, 0.08, 0.07, 1.0); CG.FillRect(cg, x, y, w, h);
  CG.SetRGBStrokeColor(cg, 0.18, 0.30, 0.24, 1.0); CG.SetLineWidth(cg, 1.0); CG.StrokeRect(cg, x, y, w, h)
END Panel;

PROCEDURE DrawScope (cg: ObjC.Id; px, py, pw, ph: REAL);
  VAR i, idx, N, frames, step: CARDINAL; mid, amp, sx, sy, v: REAL; first: BOOLEAN;
BEGIN
  Panel(cg, px, py, pw, ph);
  mid := py + ph/2.0;
  CG.SetRGBStrokeColor(cg, 0.12, 0.22, 0.18, 1.0); CG.SetLineWidth(cg, 1.0);   (* centre line *)
  CG.BeginPath(cg); CG.MoveToPoint(cg, px, mid); CG.AddLineToPoint(cg, px+pw, mid); CG.StrokePath(cg);
  IF (NOT gVoiceValid) OR (gVoice.count = 0) THEN RETURN END;
  frames := gVoice.count DIV gVoice.channels;
  N := 760; IF N > frames THEN N := frames END; step := 2;
  amp := ph * 0.46;
  CG.SetRGBStrokeColor(cg, 0.35, 1.0, 0.55, 1.0); CG.SetLineWidth(cg, 1.6);
  CG.BeginPath(cg); first := TRUE;
  FOR i := 0 TO N-1 DO
    idx := (scopeOff + i * step) MOD frames;
    v := gVoice.samples^[idx * gVoice.channels];
    sx := px + FLOAT(VAL(INTEGER,i)) / FLOAT(VAL(INTEGER,N)) * pw;
    sy := mid - v * amp;
    IF first THEN CG.MoveToPoint(cg, sx, sy); first := FALSE ELSE CG.AddLineToPoint(cg, sx, sy) END
  END;
  CG.StrokePath(cg)
END DrawScope;

PROCEDURE DrawSpectrum (cg: ObjC.Id; px, py, pw, ph: REAL);
  VAR k: CARDINAL; bw, gap, x, h, t: REAL;
BEGIN
  Panel(cg, px, py, pw, ph);
  gap := 2.0; bw := (pw - FLOAT(NBINS+1) * gap) / FLOAT(NBINS);
  FOR k := 0 TO NBINS-1 DO
    h := spec[k] / specMax * (ph - 8.0); IF h < 1.0 THEN h := 1.0 END;
    x := px + gap + FLOAT(VAL(INTEGER,k)) * (bw + gap);
    t := FLOAT(VAL(INTEGER,k)) / FLOAT(NBINS);
    CG.SetRGBFillColor(cg, 0.25 + t*0.6, 0.95 - t*0.4, 0.85 - t*0.5, 1.0);
    CG.FillRect(cg, x, py + 4.0, bw, h)
  END
END DrawSpectrum;

PROCEDURE DrawKeyboard (cg: ObjC.Id; px, py, pw, ph: REAL);
  VAR i: CARDINAL; kw, x: REAL; midiBase, m: INTEGER;
      isBlack: ARRAY [0..11] OF BOOLEAN; wcount: CARDINAL;
BEGIN
  isBlack[0]:=FALSE; isBlack[1]:=TRUE; isBlack[2]:=FALSE; isBlack[3]:=TRUE; isBlack[4]:=FALSE;
  isBlack[5]:=FALSE; isBlack[6]:=TRUE; isBlack[7]:=FALSE; isBlack[8]:=TRUE; isBlack[9]:=FALSE;
  isBlack[10]:=TRUE; isBlack[11]:=FALSE;
  midiBase := BaseMidi();
  kw := pw / 8.0;                       (* 8 white keys across, C..C *)
  (* white keys: indices 0,2,4,5,7,9,11,12 over the span are exactly 8 keys *)
  wcount := 0;
  FOR i := 0 TO 12 DO
    IF NOT isBlack[i MOD 12] THEN
      x := px + FLOAT(VAL(INTEGER,wcount)) * kw;
      m := midiBase + VAL(INTEGER, i);
      IF (gLitTimer > 0) AND (m = gLastMidi) THEN CG.SetRGBFillColor(cg, 0.45, 1.0, 0.6, 1.0)
      ELSE CG.SetRGBFillColor(cg, 0.88, 0.90, 0.92, 1.0) END;
      CG.FillRect(cg, x+1.0, py, kw-2.0, ph);
      INC(wcount)
    END
  END;
  (* black keys, drawn over the seams *)
  wcount := 0;
  FOR i := 0 TO 11 DO
    IF NOT isBlack[i MOD 12] THEN INC(wcount) END;
    IF isBlack[i MOD 12] AND (wcount >= 1) THEN
      x := px + FLOAT(VAL(INTEGER,wcount)) * kw - kw*0.32;
      m := midiBase + VAL(INTEGER, i);
      IF (gLitTimer > 0) AND (m = gLastMidi) THEN CG.SetRGBFillColor(cg, 0.30, 0.85, 0.5, 1.0)
      ELSE CG.SetRGBFillColor(cg, 0.10, 0.12, 0.14, 1.0) END;
      CG.FillRect(cg, x, py + ph*0.42, kw*0.64, ph*0.58)
    END
  END
END DrawKeyboard;

PROCEDURE WaveName (VAR s: ARRAY OF CHAR);
BEGIN
  IF    gWave = 0 THEN s := "SINE"
  ELSIF gWave = 1 THEN s := "SQUARE"
  ELSIF gWave = 2 THEN s := "SAW"
  ELSIF gWave = 3 THEN s := "TRIANGLE"
  ELSIF gWave = 4 THEN s := "NOISE"
  ELSE                 s := "PULSE" END
END WaveName;

(* ---- the rack: a Modula-2 CLASS that IS a flipped NSView -------------- *)
CLASS SynthView;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (rx, ry, rw, rh: REAL);
    VAR cg: ObjC.Id; wn: ARRAY [0..15] OF CHAR; oct: ARRAY [0..15] OF CHAR;
  BEGIN
    cg := [[Cls0("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.03, 0.04, 0.05, 1.0); CG.FillRect(cg, 0.0, 0.0, WinW, WinH);
    DrawText("NewM2 SYNTH LAB", 20.0, 14.0, 18.0, 0.5, 0.95, 0.7);
    DrawScope(cg, 20.0, 48.0, 860.0, 196.0);
    DrawText("OSCILLOSCOPE", 28.0, 52.0, 11.0, 0.4, 0.7, 0.55);
    DrawSpectrum(cg, 20.0, 262.0, 860.0, 150.0);
    DrawText("SPECTRUM (Goertzel)", 28.0, 266.0, 11.0, 0.4, 0.7, 0.55);
    (* readouts *)
    WaveName(wn);
    DrawText("WAVE", 24.0, 430.0, 12.0, 0.45, 0.6, 0.55); DrawText(wn, 90.0, 428.0, 16.0, 0.6, 1.0, 0.75);
    CardToStr(gOctave, oct);
    DrawText("OCT", 300.0, 430.0, 12.0, 0.45, 0.6, 0.55); DrawText(oct, 350.0, 428.0, 16.0, 0.6, 1.0, 0.75);
    IF gAuto THEN DrawText("AUTO-PLAY: ON  (space)", 460.0, 428.0, 14.0, 0.5, 1.0, 0.6)
    ELSE DrawText("space: auto-play ABC   tab: waveform   Z/X octave", 460.0, 430.0, 12.0, 0.5, 0.6, 0.6) END;
    DrawKeyboard(cg, 20.0, 470.0, 860.0, 150.0);
    IF gPaused THEN DrawText("PAUSED", WinW/2.0 - 40.0, 250.0, 22.0, 0.95, 0.85, 0.3) END
  END DrawRect;

  PROCEDURE KeyDown (event: ObjC.Id);
    VAR getCode: ObjC.Send0I; kc, off: INTEGER;
  BEGIN
    getCode := CAST(ObjC.Send0I, ObjC.MsgSendPtr());
    kc := getCode(event, ObjC.Selector("keyCode"));
    IF    kc = KC_TAB   THEN CycleWave
    ELSIF kc = KC_SPACE THEN ToggleAuto
    ELSIF kc = KC_Z     THEN IF gOctave > 0 THEN DEC(gOctave) END
    ELSIF kc = KC_X     THEN IF gOctave < 5 THEN INC(gOctave) END
    ELSIF kc = KC_P     THEN gPaused := NOT gPaused
    ELSE
      off := KeyOffset(kc);
      IF off > -100 THEN PlayNote(BaseMidi() + off) END
    END;
    [CAST(ObjC.Id, SELF) setNeedsDisplay: TRUE]
  END KeyDown;
END SynthView;

(* ---- timer + harness --------------------------------------------------- *)
PROCEDURE Tick (block, timer: ObjC.Id);
BEGIN
  Advance;
  IF gView # NIL THEN [gView setNeedsDisplay: TRUE] END
END Tick;

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

PROCEDURE DoKey (name: ARRAY OF CHAR);    (* note letters c..b, or controls *)
BEGIN
  IF    NameIs(name, "c")      THEN PlayNote(BaseMidi() + 0)
  ELSIF NameIs(name, "d")      THEN PlayNote(BaseMidi() + 2)
  ELSIF NameIs(name, "e")      THEN PlayNote(BaseMidi() + 4)
  ELSIF NameIs(name, "f")      THEN PlayNote(BaseMidi() + 5)
  ELSIF NameIs(name, "g")      THEN PlayNote(BaseMidi() + 7)
  ELSIF NameIs(name, "a")      THEN PlayNote(BaseMidi() + 9)
  ELSIF NameIs(name, "b")      THEN PlayNote(BaseMidi() + 11)
  ELSIF NameIs(name, "wave")   THEN CycleWave
  ELSIF NameIs(name, "auto")   THEN ToggleAuto
  ELSIF NameIs(name, "up")     THEN IF gOctave < 5 THEN INC(gOctave) END
  ELSIF NameIs(name, "down")   THEN IF gOctave > 0 THEN DEC(gOctave) END
  ELSIF NameIs(name, "pause")  THEN gPaused := NOT gPaused
  END
END DoKey;

PROCEDURE Bit (b: BOOLEAN): INTEGER;
BEGIN IF b THEN RETURN 1 ELSE RETURN 0 END END Bit;

PROCEDURE GameState (name: ARRAY OF CHAR; idx: INTEGER): INTEGER;
BEGIN
  IF    NameIs(name, "wave")   THEN RETURN VAL(INTEGER, gWave)
  ELSIF NameIs(name, "octave") THEN RETURN VAL(INTEGER, gOctave)
  ELSIF NameIs(name, "auto")   THEN RETURN Bit(gAuto)
  ELSIF NameIs(name, "note")   THEN RETURN gLastMidi
  ELSIF NameIs(name, "events") THEN RETURN VAL(INTEGER, tune.count)
  END;
  RETURN 0
END GameState;

(* ---- tune + audio + main ----------------------------------------------- *)
PROCEDURE ALn (s: ARRAY OF CHAR);          (* append a line + newline to abcBuf *)
  VAR i: CARDINAL;
BEGIN
  i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) AND (abcN < HIGH(abcBuf)-1) DO abcBuf[abcN] := s[i]; INC(abcN); INC(i) END;
  abcBuf[abcN] := CHR(10); INC(abcN); abcBuf[abcN] := 0C
END ALn;

PROCEDURE BuildTune;
  VAR ok: BOOLEAN;
BEGIN
  abcN := 0; abcBuf[0] := 0C;
  ALn("X:1"); ALn("L:1/4"); ALn("Q:1/4=132"); ALn("K:C");
  ALn("E E F G | G F E D | C C D E | E3/2 D1/2 D2 |");
  ALn("E E F G | G F E D | C C D E | D3/2 C1/2 C2 |");
  ok := Abc.ParseTune(abcBuf, tune)
END BuildTune;

PROCEDURE InitAudio;
BEGIN
  IF Sfx.Start() THEN gAudio := TRUE END
END InitAudio;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

VAR win: Cocoa.Window; content: Cocoa.View; view: SynthView;
    spath: ARRAY [0..1023] OF CHAR; ignore, scriptMode: BOOLEAN;
BEGIN
  Audio.InitEngine(2024);
  waveTab[0] := Audio.WSine; waveTab[1] := Audio.WSquare; waveTab[2] := Audio.WSaw;
  waveTab[3] := Audio.WTriangle; waveTab[4] := Audio.WNoise; waveTab[5] := Audio.WPulse;
  gWave := 0; gOctave := 2; voiceRR := 0; gLastMidi := 60; gLitTimer := 0; scopeOff := 0;
  gAuto := FALSE; gPaused := FALSE; gAudio := FALSE; gVoiceValid := FALSE;
  gAutoMs := 0; gEvIdx := 0;
  BuildTune;
  PlayNote(BaseMidi());                    (* seed the scope/spectrum with a note *)

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "NewM2 Synth Lab");
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
    IF gAudio THEN PlayNote(BaseMidi()) END;
    Cocoa.ShowWindow(win);
    gTimer := [Cls0("NSTimer") scheduledTimerWithTimeInterval: 0.02
                               repeats: TRUE
                               block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
    Cocoa.RunApp
  END
END synth_cocoa.
