IMPLEMENTATION MODULE Sound;
(* Audio + MIDI playback in pure Modula-2, driving Cocoa / AVFoundation through the
   [recv sel: args] message-send syntax (extension 1) with selector-database typing
   (extension 3). No hand-cast Send* procedure types, no manual ObjC.Selector calls;
   [player duration] is REAL straight from the database. The only runtime primitive
   is ObjC.LoadFramework (to dlopen AVFoundation). *)
FROM SYSTEM IMPORT CAST;
IMPORT ObjC;

PROCEDURE Cls (name: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(name)) END Cls;

PROCEDURE PlayMidi (path: ARRAY OF CHAR);
VAR url, player: ObjC.Id; dur: REAL;
BEGIN
  ObjC.LoadFramework("AVFoundation");                       (* AVMIDIPlayer lives here *)
  url := [Cls("NSURL") fileURLWithPath: ObjC.NSString(path)];
  (* nil sound bank = built-in synth; nil error** = don't report errors *)
  player := [[Cls("AVMIDIPlayer") alloc] initWithContentsOfURL: url soundBankURL: NIL error: NIL];
  IF player = NIL THEN RETURN END;
  [player prepareToPlay];
  [player play: NIL];                                       (* nil completion handler *)
  dur := [player duration];                                 (* DB: duration -> REAL *)
  ObjC.Pump(dur + 0.5);                                     (* keep alive while it plays *)
  [player stop]
END PlayMidi;

PROCEDURE PlayWav (path: ARRAY OF CHAR);
VAR sound: ObjC.Id; dur: REAL;
BEGIN
  sound := [[Cls("NSSound") alloc] initWithContentsOfFile: ObjC.NSString(path) byReference: FALSE];
  IF sound = NIL THEN RETURN END;
  [sound play];
  dur := [sound duration];
  ObjC.Pump(dur + 0.3);
  [sound stop]
END PlayWav;

END Sound.
