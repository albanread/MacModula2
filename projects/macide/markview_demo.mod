MODULE markview_demo;
(* Render a real docs/m2-guide page through MarkView and snapshot it, so the
   help-pane / topics presentation can be eyeballed without driving the IDE.
     ./target/debug/newm2-driver run --library library projects/macide/markview_demo.mod *)
FROM SYSTEM IMPORT CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT Cocoa; IMPORT ObjC; IMPORT MarkView; IMPORT Proc;

VAR win, content, editor: Cocoa.Object; md: ARRAY [0..262143] OF CHAR; ok: BOOLEAN; n: INTEGER;

BEGIN
  n := Proc.ReadFile("docs/m2-guide/getting-started.md", md);
  IF n < 0 THEN md[0] := CHR(0); WriteString("could not read guide page"); WriteLn END;
  Cocoa.InitApp;
  win := Cocoa.MakeWindow(620.0, 720.0, "MarkView — getting-started.md");
  content := Cocoa.ContentView(win);
  editor := Cocoa.MakeEditor(10.0, 10.0, 600.0, 700.0);
  Cocoa.AddSubview(content, editor);
  MarkView.Render(CAST(ObjC.Id, editor), md);
  ok := Cocoa.Snapshot(content, "/tmp/markview_topic.png");
  IF ok THEN WriteString("snapshot written: /tmp/markview_topic.png") ELSE WriteString("snapshot FAILED") END;
  WriteLn
END markview_demo.
