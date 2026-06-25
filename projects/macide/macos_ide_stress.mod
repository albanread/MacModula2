MODULE macos_ide_stress;
(* Load/save/autosave stress test for the rope-backed editor — all on /tmp files,
   never live demos. Loads a large file, round-trips it through save+load N times,
   then triggers the REAL autosave path (wires textDidChange: on the text view and
   makes a net-zero edit). The shell harness (run_stress) hashes the inputs and
   outputs and compares; this driver also prints the editor length at each stage
   so a truncation shows up immediately. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM Strings IMPORT Length, Assign;
FROM SYSTEM IMPORT CAST;
IMPORT Cocoa;
IMPORT RopeEditor;
IMPORT Proc;
IMPORT ObjC;

CONST Cycles = 10;

VAR
  gEditor, tv, ig: ObjC.Id;
  gBuf: ARRAY [0..524287] OF CHAR;            (* 512K chars, module-global (not stack) *)
  gAutosave: ARRAY [0..255] OF CHAR;
  s0, sp: ObjC.SendP;                          (* (Send0 is shape-compatible for documentView) *)

(* The autosave controller: textDidChange: writes the editor to the target file,
   exactly like the IDE's autosave. *)
CLASS Saver;
  <* cocoa "NSObject" *>
  PROCEDURE TextDidChange (note: ObjC.Id) <* selector "textDidChange:" *>;
  VAR rc: INTEGER;
  BEGIN
    Cocoa.EditorText(gEditor, gBuf);
    rc := Proc.WriteFile(gAutosave, gBuf)
  END TextDidChange;
END Saver;

PROCEDURE ReportLen (label: ARRAY OF CHAR);
BEGIN
  Cocoa.EditorText(gEditor, gBuf);
  WriteString(label); WriteCard(Length(gBuf), 1); WriteString(" chars"); WriteLn
END ReportLen;

VAR saver: Saver; i, n, rc: INTEGER;
BEGIN
  s0 := CAST(ObjC.SendP, ObjC.MsgSendPtr());
  sp := CAST(ObjC.SendP, ObjC.MsgSendPtr());
  Cocoa.InitApp;
  gEditor := RopeEditor.Make(0.0, 0.0, 600.0, 400.0);
  tv := s0(gEditor, ObjC.Selector("documentView"), NIL);   (* documentView ignores the 3rd arg *)
  Assign("/tmp/stress_autosave.mod", gAutosave);
  NEW(saver);
  ig := sp(tv, ObjC.Selector("setDelegate:"), CAST(ObjC.Id, saver));   (* wire autosave *)

  (* 1. load the large file *)
  n := Proc.ReadFile("/tmp/stress.mod", gBuf);
  Cocoa.SetEditorText(gEditor, gBuf);
  ReportLen("after load:           ");

  (* 2. round-trip save->load Cycles times *)
  FOR i := 1 TO Cycles DO
    Cocoa.EditorText(gEditor, gBuf);
    rc := Proc.WriteFile("/tmp/stress_copy.mod", gBuf);
    n := Proc.ReadFile("/tmp/stress_copy.mod", gBuf);
    Cocoa.SetEditorText(gEditor, gBuf)
  END;
  ReportLen("after 10x save/load:  ");
  Cocoa.EditorText(gEditor, gBuf);
  rc := Proc.WriteFile("/tmp/stress_out.mod", gBuf);

  (* 3. trigger the real autosave path with a net-zero edit (insert + backspace) *)
  ig := sp(tv, ObjC.Selector("insertText:"), ObjC.NSString("X"));   (* textDidChange -> autosave *)
  ig := sp(tv, ObjC.Selector("deleteBackward:"), NIL);             (* textDidChange -> autosave (back to original) *)
  ReportLen("after autosave edit:  ");
  WriteString("done"); WriteLn
END macos_ide_stress.
