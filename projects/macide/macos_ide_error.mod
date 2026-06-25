MODULE macos_ide_error;
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Append;
IMPORT Cocoa; IMPORT Proc;
VAR win, content, editor, output, status, runBtn: Cocoa.Object;
    code, nl: ARRAY [0..2047] OF CHAR; ok: BOOLEAN;
PROCEDURE Line(s: ARRAY OF CHAR); BEGIN Append(s, code); Append(nl, code) END Line;
PROCEDURE OnRun;
VAR src, out: ARRAY [0..8191] OF CHAR; rc, n, ig: INTEGER;
BEGIN
  Cocoa.EditorText(editor, src);
  ig := Proc.WriteFile("/tmp/ide_err_buf.mod", src);
  rc := Proc.RunCapture("./target/debug/newm2-driver run --library library /tmp/ide_err_buf.mod 2>&1", out);
  Cocoa.SetEditorText(output, out);
  n := Cocoa.MarkErrors(editor, out);
  IF n > 0 THEN Cocoa.SetText(status, "errors found (see red lines)")
  ELSE Cocoa.SetText(status, "no errors") END
END OnRun;
BEGIN
  nl[0] := CHR(10); nl[1] := CHR(0); code[0] := CHR(0);
  Line("MODULE Bad;");
  Line("FROM STextIO IMPORT WriteString, WriteLn;");
  Line("VAR i: INTEGER;");
  Line("BEGIN");
  Line("  i := undeclaredName;");
  Line("  WriteString(i)");
  Line("END Bad.");
  Cocoa.InitApp;
  win := Cocoa.MakeWindow(700.0, 460.0, "MacModula2 IDE");
  content := Cocoa.ContentView(win);
  editor := Cocoa.MakeEditor(10.0, 200.0, 680.0, 250.0);
  Cocoa.SetEditorText(editor, code); Cocoa.HighlightEditor(editor);
  Cocoa.AddSubview(content, editor);
  output := Cocoa.MakeEditor(10.0, 50.0, 680.0, 140.0);
  Cocoa.SetEditorText(output, "(output)"); Cocoa.AddSubview(content, output);
  status := Cocoa.MakeLabel(14.0, 16.0, 420.0, 22.0, "Ready."); Cocoa.AddSubview(content, status);
  runBtn := Cocoa.MakeButton(576.0, 10.0, 114.0, 34.0, "Build & Run", OnRun); Cocoa.AddSubview(content, runBtn);
  ok := Cocoa.Snapshot(content, "/tmp/ide_err_before.png");
  Cocoa.Click(runBtn);
  ok := Cocoa.Snapshot(content, "/tmp/ide_err_after.png");
  WriteString("error-highlight demo done"); WriteLn
END macos_ide_error.
