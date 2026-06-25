MODULE macos_class;
(* The MacM2 native object model, "everything Cocoa below, M2 above": this whole
   module is ordinary Modula-2 — a CLASS, NEW, a dotted method call, DISPOSE —
   with no Cocoa vocabulary anywhere. Underneath, the class is registered with
   the Objective-C runtime, NEW does [[Answers alloc] init], each method call is
   an objc_msgSend, and DISPOSE is [release]. The object IS a Cocoa object.
   See docs/design/cocoa-classes.md. (Build AOT: registration runs at load.) *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;

CLASS Answers;
  PROCEDURE Answer (): INTEGER;
  BEGIN
    RETURN 42
  END Answer;
  (* takes an argument: exercises the hidden Obj-C `_cmd` slot under msgSend *)
  PROCEDURE Triple (x: INTEGER): INTEGER;
  BEGIN
    RETURN x * 3
  END Triple;
END Answers;

VAR a: Answers;
BEGIN
  NEW(a);                                   (* -> [[Answers alloc] init] *)
  WriteString("a.Answer()     = "); WriteInt(a.Answer(), 0); WriteLn;       (* -> objc_msgSend(a, "answer") *)
  WriteString("a.Triple(14)   = "); WriteInt(a.Triple(14), 0); WriteLn;     (* -> objc_msgSend(a, "triple:", 14) *)
  DISPOSE(a)                                (* -> [a release] *)
END macos_class.
