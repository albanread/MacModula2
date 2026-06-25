MODULE macos_ide_test;
(* Automated IDE testing with the in-repo Ptcl interpreter. The IDE's editor
   operations are registered as Ptcl verbs (settext / gettext / save / load /
   len / expect); a Ptcl script then drives them and asserts. Here it exercises a
   load/save round-trip through the rope-backed editor (RopeEditor) — set text,
   save to a file, clear, load it back, and assert the text matches. Headless
   (no RunApp): prints PASS/FAIL. This is the harness to grow IDE tests in. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Append, Equal;
FROM SWholeIO IMPORT WriteCard;
IMPORT Ptcl;
IMPORT Cocoa;
IMPORT RopeEditor;
IMPORT Proc;
IMPORT ObjC;

VAR
  gEditor: ObjC.Id;
  script, out: ARRAY [0..16383] OF CHAR;
  nl: ARRAY [0..1] OF CHAR;

(* ---- IDE verbs, operating on the rope-backed editor ---- *)
PROCEDURE CmdSetText (): BOOLEAN;
VAR t: ARRAY [0..16383] OF CHAR;
BEGIN Ptcl.Arg(1, t); Cocoa.SetEditorText(gEditor, t); RETURN TRUE END CmdSetText;

PROCEDURE CmdGetText (): BOOLEAN;
VAR t: ARRAY [0..16383] OF CHAR;
BEGIN Cocoa.EditorText(gEditor, t); Ptcl.Result(t); RETURN TRUE END CmdGetText;

PROCEDURE CmdSave (): BOOLEAN;
VAR path, t: ARRAY [0..16383] OF CHAR; rc: INTEGER;
BEGIN
  Ptcl.Arg(1, path); Cocoa.EditorText(gEditor, t); rc := Proc.WriteFile(path, t);
  IF rc = 0 THEN RETURN TRUE ELSE Ptcl.Fail("write failed"); RETURN FALSE END
END CmdSave;

PROCEDURE CmdLoad (): BOOLEAN;
VAR path, t: ARRAY [0..16383] OF CHAR; n: INTEGER;
BEGIN
  Ptcl.Arg(1, path); n := Proc.ReadFile(path, t);
  IF n >= 0 THEN Cocoa.SetEditorText(gEditor, t); RETURN TRUE
  ELSE Ptcl.Fail("read failed"); RETURN FALSE END
END CmdLoad;

PROCEDURE CmdExpect (): BOOLEAN;     (* expect <a> <b> : fail unless equal *)
VAR a, b: ARRAY [0..16383] OF CHAR;
BEGIN
  Ptcl.Arg(1, a); Ptcl.Arg(2, b);
  IF Equal(a, b) THEN Ptcl.Result("ok"); RETURN TRUE
  ELSE Ptcl.Fail("mismatch"); RETURN FALSE END
END CmdExpect;

PROCEDURE SC (s: ARRAY OF CHAR);     (* append a script line *)
BEGIN Append(s, script); Append(nl, script) END SC;

VAR sample: ARRAY [0..255] OF CHAR;
BEGIN
  Cocoa.InitApp;
  gEditor := RopeEditor.Make(0.0, 0.0, 500.0, 300.0);

  Ptcl.Register("settext", CmdSetText);
  Ptcl.Register("gettext", CmdGetText);
  Ptcl.Register("save", CmdSave);
  Ptcl.Register("load", CmdLoad);
  Ptcl.Register("expect", CmdExpect);

  sample := "MODULE Sample; (* c *) VAR x: INTEGER; BEGIN x := 42 END Sample.";

  script[0] := CHR(0); nl[0] := CHR(10); nl[1] := CHR(0);
  SC("settext {MODULE Sample; (* c *) VAR x: INTEGER; BEGIN x := 42 END Sample.}");
  SC("save /tmp/ide_sample.mod");
  SC("settext {}");                                          (* clear the editor *)
  SC("expect [gettext] {}");                                 (* assert it cleared *)
  SC("load /tmp/ide_sample.mod");                            (* read it back *)
  SC("expect [gettext] {MODULE Sample; (* c *) VAR x: INTEGER; BEGIN x := 42 END Sample.}");

  IF Ptcl.Eval(script, out) THEN
    WriteString("PASS — load/save round-trip through the rope editor"); WriteLn
  ELSE
    WriteString("FAIL — "); WriteString(out); WriteLn
  END
END macos_ide_test.
