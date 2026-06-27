MODULE sfxlive;
(* Live audio synthesis from pure Modula-2: synthesise SFX with the Audio module,
   play them live through the speakers with the Sfx module (Cocoa AVAudioEngine
   under the hood) — non-blocking, overlapping, no .wav files. Plays a short demo
   sequence. In a real game, Sfx.Play(id) is a fire-and-forget call in the loop.

     newm2-driver run --library library cocoademos/sfxlive.mod *)
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;
IMPORT Audio;
IMPORT Sfx;

CONST COIN = 0; ZAP = 1; SHOOT = 2; EXPL = 3; POW = 4;
VAR s: Audio.Sound;
BEGIN
  Audio.InitEngine(12345);
  IF NOT Sfx.Start() THEN WriteString("audio engine failed to start"); WriteLn; HALT END;
  WriteString("AVAudioEngine started — synthesising + playing SFX live from Modula-2"); WriteLn;

  Audio.Coin(s, 0.4);           Sfx.Define(COIN, s);  Audio.FreeSound(s);
  Audio.Zap(s, 0.3);            Sfx.Define(ZAP, s);   Audio.FreeSound(s);
  Audio.Shoot(s, 0.2);          Sfx.Define(SHOOT, s); Audio.FreeSound(s);
  Audio.Explode(s, 0.8, 0.6);   Sfx.Define(EXPL, s);  Audio.FreeSound(s);
  Audio.Powerup(s, 0.5);        Sfx.Define(POW, s);   Audio.FreeSound(s);

  WriteString("coin");    WriteLn; Sfx.Play(COIN);  ObjC.Pump(0.6);
  WriteString("zap");     WriteLn; Sfx.Play(ZAP);   ObjC.Pump(0.5);
  WriteString("shoot");   WriteLn; Sfx.Play(SHOOT); ObjC.Pump(0.4);
  WriteString("explode"); WriteLn; Sfx.Play(EXPL);  ObjC.Pump(1.0);
  WriteString("powerup"); WriteLn; Sfx.Play(POW);   ObjC.Pump(0.8);
  WriteString("overlap (coin+zap+shoot at once)"); WriteLn;
  Sfx.Play(COIN); Sfx.Play(ZAP); Sfx.Play(SHOOT); ObjC.Pump(1.2)
END sfxlive.
