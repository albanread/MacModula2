MODULE macos_mark_test;
(* Verify that Cocoa.MarkErrors renders a red background on the rope-backed editor,
   via the layout manager's temporary attributes (RopeStore.SetAttrs is a no-op, so
   text-storage attributes wouldn't show). Renders offscreen to /tmp/marktest.png. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM Strings IMPORT Append;
FROM SYSTEM IMPORT CAST;
IMPORT Cocoa;
IMPORT RopeEditor;
IMPORT ObjC;

VAR
  gEditor, tv: ObjC.Id; s0: ObjC.Send0;
  src, nl: ARRAY [0..255] OF CHAR; marked: INTEGER; ok: BOOLEAN;
BEGIN
  Cocoa.InitApp;
  s0 := CAST(ObjC.Send0, ObjC.MsgSendPtr());
  gEditor := RopeEditor.Make(0.0, 0.0, 480.0, 150.0);

  nl[0] := CHR(10); nl[1] := CHR(0); src[0] := CHR(0);
  Append("MODULE T;", src);       Append(nl, src);
  Append("VAR x: INTEGER;", src); Append(nl, src);
  Append("BEGIN y := 1", src);    Append(nl, src);   (* line 3: the error *)
  Append("END T.", src);
  Cocoa.SetEditorText(gEditor, src);

  marked := Cocoa.MarkErrors(gEditor, "t.mod:3: error: unknown identifier 'y'");
  WriteString("marked "); WriteCard(VAL(CARDINAL, marked), 1); WriteString(" error line(s)"); WriteLn;

  ObjC.Pump(0.4);                                     (* let it lay out *)
  tv := s0(gEditor, ObjC.Selector("documentView"));
  ok := ObjC.SnapshotView(tv, "/tmp/marktest.png");
  WriteString("snapshot "); IF ok THEN WriteString("ok -> /tmp/marktest.png") ELSE WriteString("FAILED") END;
  WriteLn
END macos_mark_test.
