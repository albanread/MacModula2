IMPLEMENTATION MODULE Sfx;
(* Live SFX via AVAudioEngine, driven from Modula-2 over the Obj-C bridge. *)
FROM SYSTEM IMPORT CAST, ADDRESS, ADR;
IMPORT ObjC;

CONST MAXSFX = 64;
TYPE
  ChanPtrs = POINTER TO ARRAY [0..1] OF ADDRESS;        (* float* const* : channels *)
  Floats   = POINTER TO ARRAY [0..441000] OF SHORTREAL;

VAR
  engine, player, fmt: ObjC.Id;
  buf: ARRAY [0..MAXSFX-1] OF ObjC.Id;
  started: BOOLEAN;

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

PROCEDURE Start (): BOOLEAN;
  VAR err, r: ObjC.Id; i: CARDINAL;
BEGIN
  IF started THEN RETURN TRUE END;
  FOR i := 0 TO MAXSFX-1 DO buf[i] := NIL END;
  ObjC.LoadFramework("AVFoundation");
  engine := [[Cls("AVAudioEngine") alloc] init];
  player := [[Cls("AVAudioPlayerNode") alloc] init];
  [engine attachNode: player];
  fmt := [[Cls("AVAudioFormat") alloc] initStandardFormatWithSampleRate: 44100.0 channels: 2];
  [engine connect: player to: [engine mainMixerNode] format: fmt];
  err := NIL;
  r := [engine startAndReturnError: ADR(err)];
  IF err # NIL THEN RETURN FALSE END;
  [player play];
  started := TRUE;
  RETURN TRUE
END Start;

PROCEDURE Define (id: CARDINAL; VAR s: Audio.Sound);
  VAR b, chd: ObjC.Id; chans: ChanPtrs; L, R: Floats; f, n: CARDINAL;
BEGIN
  IF (NOT started) OR (id >= MAXSFX) OR (s.count = 0) THEN RETURN END;
  n := s.count DIV 2;                                   (* frames = samples / 2ch *)
  b := [[Cls("AVAudioPCMBuffer") alloc] initWithPCMFormat: fmt frameCapacity: n];
  [b setFrameLength: n];
  chd := [b floatChannelData];
  chans := CAST(ChanPtrs, chd);
  L := CAST(Floats, chans^[0]); R := CAST(Floats, chans^[1]);
  FOR f := 0 TO n-1 DO
    L^[f] := VAL(SHORTREAL, s.samples^[f*2]);
    R^[f] := VAL(SHORTREAL, s.samples^[f*2 + 1])
  END;
  buf[id] := b
END Define;

PROCEDURE Play (id: CARDINAL);
BEGIN
  IF started AND (id < MAXSFX) AND (buf[id] # NIL) THEN
    [player scheduleBuffer: buf[id] completionHandler: NIL]
  END
END Play;

BEGIN
  started := FALSE
END Sfx.
