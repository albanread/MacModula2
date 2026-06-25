MODULE macos_ide;
(* A working native macOS Modula-2 IDE skeleton: a code editor, an output pane,
   a status line, and a Build&Run button whose Modula-2 action reads the editor
   buffer, writes it to a file, runs the compiler as a subprocess, and shows the
   captured output — all through the ergonomic Cocoa + Proc runtime modules. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Append;
IMPORT Cocoa;
IMPORT Proc;

VAR
  win, content, editor, output, status, runBtn: Cocoa.Object;
  code, nl: ARRAY [0..2047] OF CHAR;
  ok: BOOLEAN;

PROCEDURE Line(s: ARRAY OF CHAR);
BEGIN Append(s, code); Append(nl, code) END Line;

(* The Build & Run action — pure Modula-2. *)
PROCEDURE OnRun;
VAR src, out: ARRAY [0..8191] OF CHAR; rc, ig: INTEGER;
BEGIN
  Cocoa.SetText(status, "Building...");
  Cocoa.EditorText(editor, src);
  ig := Proc.WriteFile("/tmp/ide_buffer.mod", src);
  rc := Proc.RunCapture(
          "./target/debug/newm2-driver run --library library /tmp/ide_buffer.mod 2>&1",
          out);
  Cocoa.SetEditorText(output, out);
  IF rc = 0 THEN Cocoa.SetText(status, "Build & run succeeded (exit 0).")
  ELSE Cocoa.SetText(status, "Build/run reported errors.") END
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
  win := Cocoa.MakeWindow(700.0, 620.0, "MacModula2 IDE");
  content := Cocoa.ContentView(win);

  editor := Cocoa.MakeEditor(10.0, 320.0, 680.0, 286.0);
  Cocoa.SetEditorText(editor, code);
  Cocoa.AddSubview(content, editor);

  output := Cocoa.MakeEditor(10.0, 50.0, 680.0, 256.0);
  Cocoa.SetEditorText(output, "(program output appears here)");
  Cocoa.AddSubview(content, output);

  status := Cocoa.MakeLabel(14.0, 16.0, 420.0, 22.0, "Ready.");
  Cocoa.AddSubview(content, status);

  runBtn := Cocoa.MakeButton(576.0, 10.0, 114.0, 34.0, "Build & Run", OnRun);
  Cocoa.AddSubview(content, runBtn);

  ok := Cocoa.Snapshot(content, "/tmp/ide_run_before.png");
  Cocoa.Click(runBtn);
  ok := Cocoa.Snapshot(content, "/tmp/ide_run_after.png");
  WriteString("IDE build&run demo complete"); WriteLn
END macos_ide.
