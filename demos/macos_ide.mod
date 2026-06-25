MODULE macos_ide;
(* A native macOS IDE skeleton written with the ergonomic Cocoa runtime module —
   no raw objc_msgSend in sight. A code editor, a status label, and a Build&Run
   button whose action is an ordinary Modula-2 procedure. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Append;
IMPORT Cocoa;

VAR
  win, content, editor, status, runBtn: Cocoa.Object;
  code, nl: ARRAY [0..2047] OF CHAR;
  ok: BOOLEAN;

PROCEDURE Line(s: ARRAY OF CHAR);
BEGIN Append(s, code); Append(nl, code) END Line;

(* the Build & Run button's action — pure Modula-2 *)
PROCEDURE OnRun;
BEGIN
  Cocoa.SetText(status, "Build succeeded: 0 errors.  (the Modula-2 action ran)")
END OnRun;

BEGIN
  nl[0] := CHR(10); nl[1] := CHR(0); code[0] := CHR(0);
  Line("MODULE Hello;");
  Line("FROM STextIO IMPORT WriteString, WriteLn;");
  Line("VAR i: INTEGER;");
  Line("BEGIN");
  Line("  FOR i := 1 TO 3 DO");
  Line('    WriteString("Hello from MacModula2!"); WriteLn');
  Line("  END");
  Line("END Hello.");

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(640.0, 420.0, "MacModula2 IDE");
  content := Cocoa.ContentView(win);

  editor := Cocoa.MakeEditor(10.0, 70.0, 620.0, 338.0);
  Cocoa.SetEditorText(editor, code);
  Cocoa.AddSubview(content, editor);

  status := Cocoa.MakeLabel(14.0, 30.0, 480.0, 22.0, "Ready.");
  Cocoa.AddSubview(content, status);

  runBtn := Cocoa.MakeButton(516.0, 22.0, 116.0, 36.0, "Build & Run", OnRun);
  Cocoa.AddSubview(content, runBtn);

  Cocoa.ShowWindow(win);

  ok := Cocoa.Snapshot(content, "/tmp/ide_before.png");
  Cocoa.Click(runBtn);                      (* fire the button through the trampoline *)
  ok := Cocoa.Snapshot(content, "/tmp/ide_after.png");
  WriteString("IDE skeleton: snapshots written to /tmp/ide_before.png and /tmp/ide_after.png");
  WriteLn
END macos_ide.
