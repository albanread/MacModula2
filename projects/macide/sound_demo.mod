MODULE sound_demo;
(* The sound player, ported to macOS: synthesize PCM in software (Audio), write a
   .wav (WavFile), and play it through NSSound (Sound.PlayWav). All pure Modula-2;
   the playback rides the Cocoa bridge. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
IMPORT Audio;
IMPORT WavFile;
IMPORT Sound;

VAR s: Audio.Sound;
BEGIN
  Audio.InitEngine(12345);
  Audio.Beep(s, 440.0, 0.6);                 (* a clean 440 Hz tone, 0.6s *)
  WriteString("rendered "); WriteCard(s.count, 1); WriteString(" samples, ");
  WriteCard(s.sampleRate, 1); WriteString(" Hz"); WriteLn;

  IF NOT WavFile.WriteWav("/tmp/sfx.wav", s, 0.8) THEN
    WriteString("write failed"); WriteLn; HALT
  END;
  WriteString("wrote /tmp/sfx.wav — playing through NSSound..."); WriteLn;
  Sound.PlayWav("/tmp/sfx.wav");
  Audio.FreeSound(s);
  WriteString("done"); WriteLn
END sound_demo.
