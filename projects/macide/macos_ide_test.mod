MODULE macos_ide_test;
(* Automated IDE testing with the in-repo Ptcl interpreter. IDE/editor operations
   are registered as Ptcl verbs; scripts drive them and assert. Covers a load/save
   round-trip, auto-indent (Enter copies the line's indent), and a build-&-run of a
   program typed into the editor — all headless, printing PASS/FAIL per test.

   Verbs:  settext {t}   gettext   save <p>   load <p>   len
           setcursor <n>  enter     buildrun   expect <a> <b>                      *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Append, Equal, Length;
FROM SYSTEM IMPORT CAST;
IMPORT Ptcl;
IMPORT Cocoa;
IMPORT RopeEditor;
IMPORT Proc;
IMPORT ObjC;

TYPE SendRange = PROCEDURE (ObjC.Id, ObjC.SEL, CARDINAL, CARDINAL): ObjC.Id;
     NSRangeR  = RECORD location, length: CARDINAL END;
     SendRR    = PROCEDURE (ObjC.Id, ObjC.SEL): NSRangeR;

VAR
  gEditor: ObjC.Id;
  script, out, big: ARRAY [0..262143] OF CHAR;
  nl: ARRAY [0..1] OF CHAR;
  k: CARDINAL; ixx: INTEGER;
  s0: ObjC.Send0; sp: ObjC.SendP; srange: SendRange; srr2: SendRR;

PROCEDURE Tv (): ObjC.Id;                      (* the editor's text view *)
BEGIN RETURN s0(gEditor, ObjC.Selector("documentView")) END Tv;

PROCEDURE CardToStr (n: CARDINAL; VAR s: ARRAY OF CHAR);
VAR d: ARRAY [0..31] OF CHAR; i, j: CARDINAL;
BEGIN
  IF n = 0 THEN s[0] := '0'; s[1] := CHR(0); RETURN END;
  i := 0; WHILE n > 0 DO d[i] := CHR(ORD('0') + (n MOD 10)); n := n DIV 10; INC(i) END;
  j := 0; WHILE i > 0 DO DEC(i); s[j] := d[i]; INC(j) END; s[j] := CHR(0)
END CardToStr;

PROCEDURE CmdSetText (): BOOLEAN; VAR t: ARRAY [0..262143] OF CHAR;
BEGIN Ptcl.Arg(1, t); Cocoa.SetEditorText(gEditor, t); RETURN TRUE END CmdSetText;

PROCEDURE CmdGetText (): BOOLEAN; VAR t: ARRAY [0..262143] OF CHAR;
BEGIN Cocoa.EditorText(gEditor, t); Ptcl.Result(t); RETURN TRUE END CmdGetText;

PROCEDURE CmdSave (): BOOLEAN; VAR path, t: ARRAY [0..262143] OF CHAR; rc: INTEGER;
BEGIN
  Ptcl.Arg(1, path); Cocoa.EditorText(gEditor, t); rc := Proc.WriteFile(path, t);
  IF rc = 0 THEN RETURN TRUE ELSE Ptcl.Fail("write failed"); RETURN FALSE END
END CmdSave;

PROCEDURE CmdLoad (): BOOLEAN; VAR path, t: ARRAY [0..262143] OF CHAR; n: INTEGER;
BEGIN
  Ptcl.Arg(1, path); n := Proc.ReadFile(path, t);
  IF n >= 0 THEN Cocoa.SetEditorText(gEditor, t); RETURN TRUE
  ELSE Ptcl.Fail("read failed"); RETURN FALSE END
END CmdLoad;

PROCEDURE CmdLen (): BOOLEAN; VAR t: ARRAY [0..262143] OF CHAR; s: ARRAY [0..31] OF CHAR;
BEGIN Cocoa.EditorText(gEditor, t); CardToStr(Length(t), s); Ptcl.Result(s); RETURN TRUE END CmdLen;

PROCEDURE CmdFileLen (): BOOLEAN;   (* filelen <path> : character count of a file on disk *)
VAR path, t: ARRAY [0..262143] OF CHAR; n: INTEGER; s: ARRAY [0..31] OF CHAR;
BEGIN Ptcl.Arg(1, path); n := Proc.ReadFile(path, t); CardToStr(Length(t), s); Ptcl.Result(s); RETURN TRUE END CmdFileLen;

PROCEDURE CmdSetCursor (): BOOLEAN; VAR ig: ObjC.Id;
BEGIN ig := srange(Tv(), ObjC.Selector("setSelectedRange:"), VAL(CARDINAL, Ptcl.ArgInt(1)), 0); RETURN TRUE END CmdSetCursor;

PROCEDURE CmdEnter (): BOOLEAN; VAR ig: ObjC.Id;
BEGIN ig := sp(Tv(), ObjC.Selector("insertNewline:"), NIL); RETURN TRUE END CmdEnter;

PROCEDURE CmdSelectRange (): BOOLEAN; VAR ig: ObjC.Id;   (* selectrange <loc> <len> *)
BEGIN ig := srange(Tv(), ObjC.Selector("setSelectedRange:"),
                   VAL(CARDINAL, Ptcl.ArgInt(1)), VAL(CARDINAL, Ptcl.ArgInt(2))); RETURN TRUE END CmdSelectRange;

PROCEDURE CmdSend (): BOOLEAN; VAR sel: ARRAY [0..127] OF CHAR; ig: ObjC.Id;   (* send <selector> *)
BEGIN Ptcl.Arg(1, sel); ig := sp(Tv(), ObjC.Selector(sel), NIL); RETURN TRUE END CmdSend;

PROCEDURE CmdSelLen (): BOOLEAN; VAR r: NSRangeR; s: ARRAY [0..31] OF CHAR;   (* sellen : selection length *)
BEGIN r := srr2(Tv(), ObjC.Selector("selectedRange")); CardToStr(r.length, s); Ptcl.Result(s); RETURN TRUE END CmdSelLen;

PROCEDURE CmdCharAt (): BOOLEAN;   (* charat <n> : the editor character at index n *)
VAR t: ARRAY [0..262143] OF CHAR; n: CARDINAL; r: ARRAY [0..1] OF CHAR;
BEGIN Cocoa.EditorText(gEditor, t); n := VAL(CARDINAL, Ptcl.ArgInt(1)); r[0] := t[n]; r[1] := CHR(0); Ptcl.Result(r); RETURN TRUE END CmdCharAt;

PROCEDURE CmdBuildRun (): BOOLEAN;
VAR src, outp: ARRAY [0..262143] OF CHAR; s: ARRAY [0..31] OF CHAR; rc, ix: INTEGER;
BEGIN
  Cocoa.EditorText(gEditor, src);
  ix := Proc.WriteFile("/tmp/ide_test_build.mod", src);
  rc := Proc.RunCapture("./target/debug/newm2-driver run --library library /tmp/ide_test_build.mod 2>&1", outp);
  CardToStr(VAL(CARDINAL, rc), s); Ptcl.Result(s); RETURN TRUE
END CmdBuildRun;

PROCEDURE CmdExpect (): BOOLEAN; VAR a, b: ARRAY [0..262143] OF CHAR;
BEGIN
  Ptcl.Arg(1, a); Ptcl.Arg(2, b);
  IF Equal(a, b) THEN Ptcl.Result("ok"); RETURN TRUE ELSE Ptcl.Fail("mismatch"); RETURN FALSE END
END CmdExpect;

PROCEDURE SC (s: ARRAY OF CHAR);
BEGIN Append(s, script); Append(nl, script) END SC;

PROCEDURE Run (title: ARRAY OF CHAR);
BEGIN
  IF Ptcl.Eval(script, out) THEN WriteString("PASS  "); WriteString(title)
  ELSE WriteString("FAIL  "); WriteString(title); WriteString("  ->  "); WriteString(out) END;
  WriteLn; script[0] := CHR(0)
END Run;

BEGIN
  Cocoa.InitApp;
  s0 := CAST(ObjC.Send0, ObjC.MsgSendPtr());
  sp := CAST(ObjC.SendP, ObjC.MsgSendPtr());
  srange := CAST(SendRange, ObjC.MsgSendPtr());
  srr2 := CAST(SendRR, ObjC.MsgSendPtr());
  gEditor := RopeEditor.Make(0.0, 0.0, 500.0, 300.0);
  nl[0] := CHR(10); nl[1] := CHR(0); script[0] := CHR(0);

  Ptcl.Register("settext", CmdSetText);   Ptcl.Register("gettext", CmdGetText);
  Ptcl.Register("save", CmdSave);         Ptcl.Register("load", CmdLoad);
  Ptcl.Register("len", CmdLen);           Ptcl.Register("setcursor", CmdSetCursor);
  Ptcl.Register("enter", CmdEnter);       Ptcl.Register("buildrun", CmdBuildRun);
  Ptcl.Register("expect", CmdExpect);     Ptcl.Register("filelen", CmdFileLen);
  Ptcl.Register("selectrange", CmdSelectRange);  Ptcl.Register("send", CmdSend);
  Ptcl.Register("sellen", CmdSelLen);            Ptcl.Register("charat", CmdCharAt);

  SC("settext {MODULE Sample; (* c *) VAR x: INTEGER; BEGIN x := 42 END Sample.}");
  SC("save /tmp/ide_sample.mod");
  SC("settext {}");
  SC("expect [gettext] {}");
  SC("load /tmp/ide_sample.mod");
  SC("expect [gettext] {MODULE Sample; (* c *) VAR x: INTEGER; BEGIN x := 42 END Sample.}");
  Run("load/save round-trip");

  SC("settext {    BEGIN}");        (* 4 spaces + BEGIN = 9 chars *)
  SC("setcursor 9");
  SC("enter");                      (* auto-indent: newline + 4 spaces -> 14 chars *)
  SC("expect [len] 14");
  Run("auto-indent");

  SC('settext {MODULE H; FROM STextIO IMPORT WriteString; BEGIN WriteString("hi") END H.}');
  SC("expect [buildrun] 0");
  Run("build & run a typed program");

  (* large-file truncation regression: a ~86K-char file (>> the old 4096 cap) must
     load into the rope editor with every character intact (editor len == file len) *)
  big[0] := CHR(0); k := 0;
  WHILE k < 2000 DO
    Append("  x := 0; (* a line of filler text here *)", big); Append(nl, big); INC(k)
  END;
  ixx := Proc.WriteFile("/tmp/ide_big.mod", big);
  SC("load /tmp/ide_big.mod");
  SC("expect [len] [filelen /tmp/ide_big.mod]");
  Run("large-file load: no truncation");

  (* standard editor behaviours: indent / outdent / comment toggle *)
  SC("settext {ABCD}"); SC("selectrange 1 2"); SC("send insertTab:");
  SC("expect [gettext] {  ABCD}");
  Run("indent selection (Tab)");

  SC("settext {    ABCD}"); SC("selectrange 4 4"); SC("send insertBacktab:");
  SC("expect [gettext] {  ABCD}");
  Run("outdent selection (Shift-Tab)");

  SC("settext {XY}"); SC("selectrange 0 2"); SC("send toggleComment:");
  SC("expect [gettext] {(* XY *)}");
  Run("comment toggle on");

  SC("settext {(* XY *)}"); SC("selectrange 0 8"); SC("send toggleComment:");
  SC("expect [gettext] {XY}");
  Run("comment toggle off");

  (* line manipulation: duplicate / delete / select / move *)
  SC("settext {AB}"); SC("setcursor 0"); SC("send duplicateLine:");
  SC("expect [len] 5");                                   (* AB\nAB *)
  Run("duplicate line");

  SC("settext {ABCD}"); SC("setcursor 2"); SC("send deleteLine:");
  SC("expect [len] 0");                                   (* whole line gone, not just cursor *)
  Run("delete line");

  SC("settext {ABCD}"); SC("setcursor 2"); SC("send selectLine:");
  SC("expect [sellen] 4");
  Run("select line");

  big[0] := CHR(0);
  Append("AX", big); Append(nl, big); Append("BY", big); Append(nl, big); Append("CZ", big);
  ixx := Proc.WriteFile("/tmp/ide_lines.mod", big);       (* AX / BY / CZ *)
  SC("load /tmp/ide_lines.mod"); SC("setcursor 0"); SC("send moveLineDown:");
  SC("expect [charat 0] B");                              (* now BY / AX / CZ *)
  Run("move line down");

  SC("load /tmp/ide_lines.mod"); SC("setcursor 3"); SC("send moveLineUp:");
  SC("expect [charat 0] B");                              (* line 2 (BY) moved above AX *)
  Run("move line up");
END macos_ide_test.
