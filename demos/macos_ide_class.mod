MODULE macos_ide_class;
(* The macOS IDE, rebuilt on the native M2 object model. Instead of the
   hand-written Cocoa trampoline (`M2CocoaTrampoline` + a tag table routing
   clicks to parameterless procedures), the IDE's pieces are ordinary Modula-2
   classes that ARE Cocoa objects:

     * EditorView  — an NSView subclass that draws the code surface from its own
                     state (line count), via Core Graphics in an M2 drawRect:.
     * IDEController — an NSObject subclass whose methods ARE the AppKit
                     target/action handlers. A button's target is the controller
                     and its action is the method's selector, so a click is
                     dispatched straight into M2 — no trampoline.

   We build the window, wire a "Build" button to the controller, simulate three
   clicks (the exact objc_msgSend AppKit performs), and snapshot the result. *)
FROM SYSTEM IMPORT CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;
IMPORT CG;
IMPORT Cocoa;

(* ---- the editor surface: a real NSView, drawn in Modula-2 ---- *)
CLASS EditorView;
  <* cocoa "NSView" *>
  VAR lines: INTEGER;                       (* per-instance state, a real ivar *)
  ABSTRACT PROCEDURE SetNeedsDisplay (flag: BOOLEAN);   (* inherited NSView *)
  PROCEDURE SetLines (n: INTEGER);
  BEGIN
    lines := n;
    SELF.SetNeedsDisplay(TRUE)              (* typed inherited call *)
  END SetLines;
  PROCEDURE Lines (): INTEGER;
  BEGIN RETURN lines END Lines;
  PROCEDURE DrawRect (x, y, w, h: REAL);    (* AppKit's drawRect: *)
  VAR gc, cg: ObjC.Id; s0: ObjC.Send0; i: INTEGER; ry: REAL;
  BEGIN
    s0 := CAST(ObjC.Send0, ObjC.MsgSendPtr());
    gc := s0(ObjC.GetClass("NSGraphicsContext"), ObjC.Selector("currentContext"));
    cg := s0(gc, ObjC.Selector("CGContext"));
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.12, 0.13, 0.18, 1.0);  CG.FillRect(cg, 0.0, 0.0, w, h);
    CG.SetRGBFillColor(cg, 0.16, 0.17, 0.23, 1.0);  CG.FillRect(cg, 0.0, 0.0, 44.0, h);  (* gutter *)
    FOR i := 0 TO lines - 1 DO              (* one "code line" per build *)
      ry := h - 40.0 - FLOAT(i) * 34.0;     (* stack rows from the top, 34pt apart *)
      CG.SetRGBFillColor(cg, 0.45, 0.50, 0.62, 1.0);          (* line number *)
      CG.FillRect(cg, 14.0, ry, 22.0, 14.0);
      CG.SetRGBFillColor(cg, 0.40, 0.62, 0.95, 1.0);          (* a keyword token *)
      CG.FillRect(cg, 58.0, ry, 70.0, 16.0);
      CG.SetRGBFillColor(cg, 0.80, 0.82, 0.88, 1.0);          (* an identifier token *)
      CG.FillRect(cg, 140.0, ry, FLOAT(110 + (i*53) MOD 180), 16.0)
    END
  END DrawRect;
END EditorView;

(* ---- the controller: a real NSObject; its methods are AppKit actions ---- *)
CLASS IDEController;
  <* cocoa "NSObject" *>
  VAR editor: EditorView;                   (* an object-reference ivar *)
  PROCEDURE SetEditor (e: EditorView);
  BEGIN SELF.editor := e END SetEditor;
  PROCEDURE Build (sender: ObjC.Id);        (* target/action — selector "build:" *)
  BEGIN
    SELF.editor.SetLines(SELF.editor.Lines() + 1)   (* each click compiles one more line *)
  END Build;
END IDEController;

VAR
  win, content: Cocoa.Object;
  view: EditorView;
  ctrl: IDEController;
  button: ObjC.Id;
  s0: ObjC.Send0; sp: ObjC.SendP; sf: ObjC.SendFrame;
  i: INTEGER;
  ig: ObjC.Id;
  ok: BOOLEAN;
BEGIN
  s0 := CAST(ObjC.Send0, ObjC.MsgSendPtr());
  sp := CAST(ObjC.SendP, ObjC.MsgSendPtr());
  sf := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(560.0, 360.0, "MacM2 IDE (M2 classes)");
  content := Cocoa.ContentView(win);

  (* the editor view — an M2 object that IS an NSView *)
  NEW(view);
  ig := sf(CAST(ObjC.Id, view), ObjC.Selector("setFrame:"), 10.0, 50.0, 540.0, 300.0);
  Cocoa.AddSubview(content, CAST(Cocoa.Object, view));

  (* the controller — an M2 object that IS an NSObject *)
  NEW(ctrl);
  ctrl.SetEditor(view);

  (* a Build button whose target/action is the controller's method — no trampoline *)
  button := s0(s0(ObjC.GetClass("NSButton"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  ig := sf(button, ObjC.Selector("setFrame:"), 446.0, 10.0, 104.0, 32.0);
  ig := sp(button, ObjC.Selector("setTitle:"), ObjC.NSString("Build"));
  ig := sp(button, ObjC.Selector("setTarget:"), CAST(ObjC.Id, ctrl));
  ig := sp(button, ObjC.Selector("setAction:"), ObjC.Selector("build:"));
  Cocoa.AddSubview(content, CAST(Cocoa.Object, button));

  (* simulate three clicks — exactly what AppKit does: msgSend the action to the
     target. Each dispatches straight into IDEController.Build. *)
  FOR i := 1 TO 3 DO
    ig := sp(CAST(ObjC.Id, ctrl), ObjC.Selector("build:"), button)
  END;

  ok := Cocoa.Snapshot(content, "/tmp/macm2_ide.png");
  WriteString("IDE on M2 classes: editor has ");
  IF view.Lines() = 3 THEN WriteString("3 lines after 3 Build clicks (OK)")
  ELSE WriteString("WRONG line count") END;
  WriteLn
END macos_ide_class.
