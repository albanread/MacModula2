IMPLEMENTATION MODULE Sound;
(* Audio + MIDI playback in pure Modula-2, driving Cocoa / AVFoundation through
   the ObjC message-send bridge. The only runtime primitive is ObjC.LoadFramework
   (to dlopen AVFoundation); everything else is ordinary [obj msg] sends. *)
FROM SYSTEM IMPORT CAST;
IMPORT ObjC;

TYPE
  (* msgSend shapes not in ObjC's stock list: a 3-object init, an obj+bool init,
     and a no-arg call that returns a REAL (NSTimeInterval duration). *)
  SendPPP = PROCEDURE (ObjC.Id, ObjC.SEL, ObjC.Id, ObjC.Id, ObjC.Id): ObjC.Id;
  SendPB  = PROCEDURE (ObjC.Id, ObjC.SEL, ObjC.Id, BOOLEAN): ObjC.Id;
  SendF0  = PROCEDURE (ObjC.Id, ObjC.SEL): REAL;

VAR s0: ObjC.Send0; sp: ObjC.SendP; sppp: SendPPP; spb: SendPB; sf0: SendF0;

PROCEDURE Cls (name: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(name)) END Cls;

PROCEDURE PlayMidi (path: ARRAY OF CHAR);
VAR url, player, ig: ObjC.Id; dur: REAL;
BEGIN
  ObjC.LoadFramework("AVFoundation");                     (* AVMIDIPlayer lives here *)
  url := sp(Cls("NSURL"), ObjC.Selector("fileURLWithPath:"), ObjC.NSString(path));
  player := s0(Cls("AVMIDIPlayer"), ObjC.Selector("alloc"));
  (* initWithContentsOfURL:soundBankURL:error: — nil sound bank = built-in synth,
     nil error** = don't report errors *)
  player := sppp(player, ObjC.Selector("initWithContentsOfURL:soundBankURL:error:"),
                 url, NIL, NIL);
  IF player = NIL THEN RETURN END;
  ig := s0(player, ObjC.Selector("prepareToPlay"));
  ig := sp(player, ObjC.Selector("play:"), NIL);          (* nil completion handler *)
  dur := sf0(player, ObjC.Selector("duration"));
  ObjC.Pump(dur + 0.5);                                   (* keep alive while it plays *)
  ig := s0(player, ObjC.Selector("stop"))
END PlayMidi;

PROCEDURE PlayWav (path: ARRAY OF CHAR);
VAR sound, ig: ObjC.Id; dur: REAL;
BEGIN
  sound := s0(Cls("NSSound"), ObjC.Selector("alloc"));    (* NSSound is in AppKit *)
  sound := spb(sound, ObjC.Selector("initWithContentsOfFile:byReference:"),
               ObjC.NSString(path), FALSE);
  IF sound = NIL THEN RETURN END;
  ig := s0(sound, ObjC.Selector("play"));
  dur := sf0(sound, ObjC.Selector("duration"));
  ObjC.Pump(dur + 0.3);
  ig := s0(sound, ObjC.Selector("stop"))
END PlayWav;

BEGIN
  s0   := CAST(ObjC.Send0, ObjC.MsgSendPtr());
  sp   := CAST(ObjC.SendP, ObjC.MsgSendPtr());
  sppp := CAST(SendPPP, ObjC.MsgSendPtr());
  spb  := CAST(SendPB, ObjC.MsgSendPtr());
  sf0  := CAST(SendF0, ObjC.MsgSendPtr())
END Sound.
