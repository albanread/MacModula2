MODULE macos_ide_m2;
(* The interactive MacM2 IDE, built on the native M2 object model. The whole
   controller is an ordinary Modula-2 class that IS a Cocoa object: its method
   `BuildRun` is wired directly as the button's AppKit action (target = the
   controller, action = selector "buildRun:") — no M2CocoaTrampoline. A real
   editable NSTextView is the editor; Build & Run writes the buffer, runs the
   compiler, and shows the captured output. Opens a live, usable window. *)
FROM SYSTEM IMPORT CAST;
FROM STextIO IMPORT WriteString, WriteLn;
FROM Strings IMPORT Append;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT Proc;

(* The IDE controller — a real NSObject; its methods are the AppKit actions. *)
CLASS IDEController;
  <* cocoa "NSObject" *>
  VAR editor, output, status: Cocoa.Object;
  PROCEDURE Wire (e, o, s: Cocoa.Object);
  BEGIN
    editor := e; output := o; status := s
  END Wire;
  PROCEDURE BuildRun (sender: ObjC.Id);          (* AppKit action: "buildRun:" *)
  VAR src, out: ARRAY [0..16383] OF CHAR; rc, ig: INTEGER;
  BEGIN
    Cocoa.SetText(status, "Building…");
    Cocoa.EditorText(editor, src);
    ig := Proc.WriteFile("/tmp/ide_buffer.mod", src);
    rc := Proc.RunCapture(
            "./target/debug/newm2-driver run --library library /tmp/ide_buffer.mod 2>&1", out);
    Cocoa.SetEditorText(output, out);
    IF rc = 0 THEN Cocoa.SetText(status, "Build & run succeeded (exit 0).")
    ELSE Cocoa.SetText(status, "Build/run reported errors.") END
  END BuildRun;
END IDEController;

VAR
  win, content, editor, output, status, button: Cocoa.Object;
  ctrl: IDEController;
  code, nl: ARRAY [0..2047] OF CHAR;
  s0: ObjC.Send0; sp: ObjC.SendP; sf: ObjC.SendFrame;
  ig: ObjC.Id;

PROCEDURE Line (s: ARRAY OF CHAR);
BEGIN Append(s, code); Append(nl, code) END Line;

BEGIN
  nl[0] := CHR(10); nl[1] := CHR(0); code[0] := CHR(0);
  Line("MODULE Hello;");
  Line("FROM STextIO IMPORT WriteString, WriteLn;");
  Line("VAR i: INTEGER;");
  Line("BEGIN");
  Line("  FOR i := 1 TO 3 DO");
  Line('    WriteString("Hello from a Modula-2 class IDE!"); WriteLn');
  Line("  END");
  Line("END Hello.");

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(720.0, 640.0, "MacM2 IDE — M2 classes");
  content := Cocoa.ContentView(win);

  editor := Cocoa.MakeEditor(10.0, 330.0, 700.0, 300.0);
  Cocoa.SetEditorText(editor, code);
  Cocoa.HighlightEditor(editor);
  Cocoa.AddSubview(content, editor);

  output := Cocoa.MakeEditor(10.0, 50.0, 700.0, 270.0);
  Cocoa.SetEditorText(output, "(program output appears here — click Build & Run)");
  Cocoa.AddSubview(content, output);

  status := Cocoa.MakeLabel(14.0, 16.0, 480.0, 22.0, "Ready.");
  Cocoa.AddSubview(content, status);

  (* the controller — an M2 object that IS an NSObject *)
  NEW(ctrl);
  ctrl.Wire(editor, output, status);

  (* a Build & Run button whose target/action is the controller's method *)
  s0 := CAST(ObjC.Send0, ObjC.MsgSendPtr());
  sp := CAST(ObjC.SendP, ObjC.MsgSendPtr());
  sf := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());
  button := s0(s0(ObjC.GetClass("NSButton"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  ig := sf(CAST(ObjC.Id, button), ObjC.Selector("setFrame:"), 586.0, 8.0, 124.0, 34.0);
  ig := sp(CAST(ObjC.Id, button), ObjC.Selector("setTitle:"), ObjC.NSString("Build & Run"));
  ig := sp(CAST(ObjC.Id, button), ObjC.Selector("setTarget:"), CAST(ObjC.Id, ctrl));
  ig := sp(CAST(ObjC.Id, button), ObjC.Selector("setAction:"), ObjC.Selector("buildRun:"));
  Cocoa.AddSubview(content, button);

  (* Build once on launch (the exact message the button sends), so the window
     opens already showing output — and snapshot it for verification. *)
  ig := sp(CAST(ObjC.Id, ctrl), ObjC.Selector("buildRun:"), CAST(ObjC.Id, button));
  IF Cocoa.Snapshot(content, "/tmp/macm2_ide_m2.png") THEN END;

  Cocoa.ShowWindow(win);
  Cocoa.RunApp;
  WriteString("MacM2 IDE (M2 classes) closed."); WriteLn
END macos_ide_m2.
