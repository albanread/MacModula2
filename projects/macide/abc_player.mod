MODULE abc_player;
(* The ABC player, ported to macOS: parse ABC notation -> a timed MIDI event list
   (Abc), write a Standard MIDI File (SmfFile), and play it through the built-in
   macOS synth (Sound.PlayMidi -> AVMIDIPlayer). The playback is pure Modula-2 over
   the Cocoa/AVFoundation bridge. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
IMPORT Abc;
IMPORT SmfFile;
IMPORT Sound;

CONST
  (* "Twinkle, Twinkle" — uppercase = middle octave, "2" = a longer note.
     No header needed: the parser uses sensible defaults (C major, 120 bpm). *)
  tune = "C C G G A A G2 F F E E D D C2";

VAR t: Abc.Tune;
BEGIN
  IF NOT Abc.ParseTune(tune, t) THEN
    WriteString("parse failed"); WriteLn; HALT
  END;
  WriteString("parsed "); WriteCard(t.count, 1); WriteString(" MIDI events, ");
  WriteCard(t.bpm, 1); WriteString(" bpm"); WriteLn;

  IF NOT SmfFile.WriteSmf("/tmp/abc_demo.mid", t) THEN
    WriteString("write SMF failed"); WriteLn; HALT
  END;
  WriteString("wrote /tmp/abc_demo.mid — playing through the macOS synth..."); WriteLn;
  Sound.PlayMidi("/tmp/abc_demo.mid");
  WriteString("done"); WriteLn
END abc_player.
