MODULE macos_subclass;
(* M3: an M2 class that subclasses a real Cocoa class. The `<* cocoa "NSView" *>`
   pragma registers FlippedView as a subclass of NSView, so AppKit sees a genuine
   NSView; the M2 method IsFlipped (selector `isFlipped`, derived) OVERRIDES
   NSView's. We verify the instance is-a NSView and that our override wins over
   NSView's default. Pure M2 above, Cocoa below. (Build AOT.) *)
FROM SYSTEM IMPORT CAST;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;

CLASS FlippedView;
  <* cocoa "NSView" *>
  PROCEDURE IsFlipped (): BOOLEAN;      (* -> selector "isFlipped" *)
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
      WriteString("OK: M2 FlippedView is a genuine NSView subclass"); WriteLn
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
END macos_subclass.
