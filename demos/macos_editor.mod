MODULE macos_editor;
(* The heart of an IDE: a scrollable NSTextView showing Modula-2 source in a
   monospaced font — built from Modula-2 through the Objective-C bridge and
   captured with ObjC.SnapshotView. *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Append;
IMPORT ObjC;

VAR
  p: ADDRESS;
  send0: ObjC.Send0; sendI: ObjC.SendI; sendP: ObjC.SendP;
  sendB: ObjC.SendB; sendFrame: ObjC.SendFrame; sendF: ObjC.SendF;
  scroll, tv, font, ignore: ObjC.Id;
  code, nl: ARRAY [0..2047] OF CHAR;
  ok: BOOLEAN;

PROCEDURE Sel(name: ARRAY OF CHAR): ObjC.SEL;
BEGIN RETURN ObjC.Selector(name) END Sel;

PROCEDURE Line(s: ARRAY OF CHAR);
BEGIN Append(s, code); Append(nl, code) END Line;

BEGIN
  nl[0] := CHR(10); nl[1] := CHR(0);
  code[0] := CHR(0);
  Line("MODULE Hello;");
  Line("(* A Modula-2 program, shown in a native NSTextView. *)");
  Line("FROM STextIO IMPORT WriteString, WriteLn;");
  Line("");
  Line("VAR i: INTEGER;");
  Line("");
  Line("BEGIN");
  Line("  FOR i := 1 TO 3 DO");
  Line('    WriteString("Hello from MacModula2!"); WriteLn');
  Line("  END");
  Line("END Hello.");

  p := ObjC.MsgSendPtr();
  send0 := CAST(ObjC.Send0,p); sendI := CAST(ObjC.SendI,p); sendP := CAST(ObjC.SendP,p);
  sendB := CAST(ObjC.SendB,p); sendFrame := CAST(ObjC.SendFrame,p); sendF := CAST(ObjC.SendF,p);

  scroll := send0(ObjC.GetClass("NSScrollView"), Sel("alloc"));
  scroll := sendFrame(scroll, Sel("initWithFrame:"), 0.0, 0.0, 560.0, 300.0);
  ignore := sendB(scroll, Sel("setHasVerticalScroller:"), TRUE);

  tv := send0(ObjC.GetClass("NSTextView"), Sel("alloc"));
  tv := sendFrame(tv, Sel("initWithFrame:"), 0.0, 0.0, 560.0, 300.0);
  font := sendF(ObjC.GetClass("NSFont"), Sel("userFixedPitchFontOfSize:"), 13.0);
  ignore := sendP(tv, Sel("setFont:"), font);
  ignore := sendP(tv, Sel("setString:"), ObjC.NSString(code));
  ignore := sendP(scroll, Sel("setDocumentView:"), tv);

  ok := ObjC.SnapshotView(scroll, "/tmp/macmodula2_editor.png");
  IF ok THEN WriteString("editor snapshot -> /tmp/macmodula2_editor.png")
        ELSE WriteString("snapshot FAILED") END;
  WriteLn
END macos_editor.
