MODULE macos_complete;
(* IDE autocomplete: place the cursor after `Strings.`, ask the compiler's
   `complete` command for the members in scope, and show them. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Append, FindNext, Length;
IMPORT Cocoa; IMPORT Proc;

VAR
  win, content, editor, listView, status, btn: Cocoa.Object;
  code, nl: ARRAY [0..2047] OF CHAR;
  found: BOOLEAN; pos: CARDINAL; ok: BOOLEAN;

PROCEDURE Line(s: ARRAY OF CHAR);
BEGIN Append(s, code); Append(nl, code) END Line;

PROCEDURE OnComplete;
VAR src, cand: ARRAY [0..16383] OF CHAR; line, col, n, ig: INTEGER;
BEGIN
  Cocoa.EditorText(editor, src);
  Cocoa.EditorCursor(editor, line, col);
  ig := Proc.WriteFile("/tmp/complete_buf.mod", src);
  n := Proc.Complete("/tmp/complete_buf.mod", line, col, cand);
  Cocoa.SetEditorText(listView, cand);
  IF n > 0 THEN Cocoa.SetText(status, "completions at cursor (see list below)")
  ELSE Cocoa.SetText(status, "no completions") END
END OnComplete;

BEGIN
  nl[0] := CHR(10); nl[1] := CHR(0); code[0] := CHR(0);
  Line("MODULE T;");
  Line("IMPORT Strings;");
  Line("VAR s: ARRAY [0..20] OF CHAR;");
  Line("BEGIN");
  Line("  Strings.");
  Line("END T.");

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(720.0, 540.0, "MacModula2 IDE - autocomplete");
  content := Cocoa.ContentView(win);

  editor := Cocoa.MakeEditor(10.0, 360.0, 700.0, 168.0);
  Cocoa.SetEditorText(editor, code);
  Cocoa.HighlightEditor(editor);
  Cocoa.AddSubview(content, editor);

  listView := Cocoa.MakeEditor(10.0, 50.0, 700.0, 300.0);
  Cocoa.SetEditorText(listView, "(completions appear here)");
  Cocoa.AddSubview(content, listView);

  status := Cocoa.MakeLabel(14.0, 16.0, 440.0, 22.0, "Ready.");
  Cocoa.AddSubview(content, status);

  btn := Cocoa.MakeButton(580.0, 10.0, 130.0, 34.0, "Complete", OnComplete);
  Cocoa.AddSubview(content, btn);

  (* place the cursor right after "Strings." *)
  FindNext("Strings.", code, 0, found, pos);
  IF found THEN Cocoa.SetEditorCursor(editor, INTEGER(pos) + INTEGER(Length("Strings."))) END;

  Cocoa.Click(btn);
  ok := Cocoa.Snapshot(content, "/tmp/ide_complete.png");
  WriteString("autocomplete demo done"); WriteLn
END macos_complete.
