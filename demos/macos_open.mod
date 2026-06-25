MODULE macos_open;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT Cocoa; IMPORT Proc;
VAR win, content, editor: Cocoa.Object;
    text: ARRAY [0..16383] OF CHAR; n: INTEGER; ok: BOOLEAN;
BEGIN
  Cocoa.InitApp;
  win := Cocoa.MakeWindow(680.0, 420.0, "Open File");
  content := Cocoa.ContentView(win);
  editor := Cocoa.MakeEditor(10.0, 10.0, 660.0, 400.0);
  Cocoa.AddSubview(content, editor);
  (* Proc.ReadFile loads a file from disk (what File>Open does after the panel) *)
  n := Proc.ReadFile("demos/heap_guard_test.mod", text);
  IF n >= 0 THEN
    Cocoa.SetEditorText(editor, text);
    Cocoa.HighlightEditor(editor);
    WriteString("loaded "); WriteLn
  ELSE WriteString("read failed"); WriteLn END;
  ok := Cocoa.Snapshot(editor, "/tmp/ide_open.png")
END macos_open.
