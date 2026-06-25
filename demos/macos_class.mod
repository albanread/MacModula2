MODULE macos_class;
(* M0 of the native M2-object-model-on-Cocoa work: an ordinary Modula-2 CLASS,
   with no Cocoa vocabulary in sight, that the macOS backend registers with the
   Objective-C runtime at image load. We then look the class up by its mangled
   Obj-C name and message it directly through the ObjC bridge — proving an M2
   object IS a real Obj-C object. See docs/design/cocoa-classes.md. *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;

(* M0 scope: nullary, field-free methods. The hidden Obj-C `_cmd` slot and real
   ivars (so methods can take arguments and use SELF.field) are the next stages
   — see docs/design/cocoa-classes.md, tasks M0-dispatch / M1-ivars. *)
CLASS Answers;
  PROCEDURE Answer (): INTEGER;
  BEGIN
    RETURN 42
  END Answer;
  PROCEDURE Half (): INTEGER;
  BEGIN
    RETURN 21
  END Half;
  (* A method that takes an argument: exercises the hidden Obj-C `_cmd` slot —
     without it, `x` would read the selector register instead of 14. *)
  PROCEDURE Triple (x: INTEGER): INTEGER;
  BEGIN
    RETURN x * 3
  END Triple;
END Answers;

TYPE SendI_I = PROCEDURE (ObjC.Id, ObjC.SEL, INTEGER): INTEGER;

VAR
  cls, obj: ObjC.Id;
  a: Answers;                 (* an M2 object reference *)
  send0: ObjC.Send0;
  send0I: ObjC.Send0I;
  sendiI: SendI_I;

BEGIN
  cls := ObjC.GetClass("M2.macos_class.Answers");
  IF cls = NIL THEN
    WriteString("FAIL: M2 class not registered with the Obj-C runtime"); WriteLn
  ELSE
    WriteString("OK: M2.macos_class.Answers is a live Obj-C class"); WriteLn;
    (* It is a real Obj-C class: alloc/init it and message its M2 methods. *)
    send0  := CAST(ObjC.Send0,  ObjC.MsgSendPtr());
    send0I := CAST(ObjC.Send0I, ObjC.MsgSendPtr());
    sendiI := CAST(SendI_I, ObjC.MsgSendPtr());
    obj := send0(send0(cls, ObjC.Selector("alloc")), ObjC.Selector("init"));
    IF (send0I(obj, ObjC.Selector("answer")) = 42)
       AND (send0I(obj, ObjC.Selector("half")) = 21) THEN
      WriteString("OK: nullary M2 methods dispatched via objc_msgSend (42, 21)"); WriteLn
    ELSE
      WriteString("FAIL: nullary method dispatch gave the wrong result"); WriteLn
    END;
    IF sendiI(obj, ObjC.Selector("triple:"), 14) = 42 THEN
      WriteString("OK: arg method dispatched (triple:(14) = 42 -> _cmd slot correct)"); WriteLn
    ELSE
      WriteString("FAIL: arg method dispatch wrong (_cmd misaligned?)"); WriteLn
    END;

    (* The M2 surface: plain `NEW` makes a real Obj-C instance of the class. *)
    NEW(a);
    IF CAST(ObjC.Id, a) = NIL THEN
      WriteString("FAIL: NEW(a) did not create an instance"); WriteLn
    ELSIF send0I(CAST(ObjC.Id, a), ObjC.Selector("answer")) = 42 THEN
      WriteString("OK: NEW(a) -> live Obj-C instance, a.answer = 42"); WriteLn;
      DISPOSE(a);                 (* [a release]; a := NIL *)
      IF a = NIL THEN WriteString("OK: DISPOSE(a) released and cleared the reference"); WriteLn END
    ELSE
      WriteString("FAIL: NEW(a) instance did not respond correctly"); WriteLn
    END
  END
END macos_class.
