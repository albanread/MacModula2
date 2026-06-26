MODULE macos_inherit_cocoa;
(* Metadata-resolved INHERIT: `INHERIT NSView` with NO pragma and NO import roots
   FlippedView at the Cocoa NSView, resolved straight from the Cocoa metadata —
   exactly equivalent to `<* cocoa "NSView" *>` (cf. macos_subclass.mod, the
   pragma control). Same three checks: the class registers, the instance is-a
   genuine NSView, and our derived `isFlipped` override wins. (Build AOT.) *)
FROM SYSTEM IMPORT CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;

CLASS FlippedView;
  INHERIT NSView;                       (* no pragma, no IMPORT — from Cocoa metadata *)
  PROCEDURE IsFlipped (): BOOLEAN;      (* -> selector "isFlipped" (derived) *)
  BEGIN
    RETURN TRUE                          (* NSView's default is FALSE *)
  END IsFlipped;
END FlippedView;

TYPE
  Send0B = PROCEDURE (ObjC.Id, ObjC.SEL): BOOLEAN;
  SendPB = PROCEDURE (ObjC.Id, ObjC.SEL, ObjC.Id): BOOLEAN;

VAR
  v: FlippedView;
  isKind: SendPB;
  flipped: Send0B;
BEGIN
  NEW(v);
  IF CAST(ObjC.Id, v) = NIL THEN
    WriteString("FAIL: NEW(v) was nil — class not registered"); WriteLn
  ELSE
    isKind := CAST(SendPB, ObjC.MsgSendPtr());
    IF isKind(CAST(ObjC.Id, v), ObjC.Selector("isKindOfClass:"), ObjC.GetClass("NSView")) THEN
      WriteString("OK: INHERIT NSView gives a genuine NSView subclass"); WriteLn
    ELSE
      WriteString("FAIL: not an NSView subclass"); WriteLn
    END;
    flipped := CAST(Send0B, ObjC.MsgSendPtr());
    IF flipped(CAST(ObjC.Id, v), ObjC.Selector("isFlipped")) THEN
      WriteString("OK: our M2 isFlipped override wins (NSView default is FALSE)"); WriteLn
    ELSE
      WriteString("FAIL: override not installed"); WriteLn
    END
  END
END macos_inherit_cocoa.
