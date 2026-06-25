MODULE macos_inherited_calls;
(* Typed calls to inherited Cocoa methods. A Cocoa-rooted M2 class declares the
   NSView methods it wants to call as ABSTRACT (no M2 body — they are provided by
   the Cocoa superclass) and calls them as ordinary typed M2 methods; they
   dispatch straight to NSView via objc_msgSend. Here setHidden:/isHidden
   round-trips through real NSView state, all in M2 syntax. *)
FROM STextIO IMPORT WriteString, WriteLn;

CLASS Widget;
  <* cocoa "NSView" *>
  ABSTRACT PROCEDURE SetHidden (flag: BOOLEAN);   (* -> NSView setHidden: *)
  ABSTRACT PROCEDURE IsHidden (): BOOLEAN;          (* -> NSView isHidden  *)
  VAR tag: INTEGER;                                 (* our own ivar state  *)
  PROCEDURE Configure (t: INTEGER);
  BEGIN
    tag := t;
    SELF.SetHidden(TRUE)                            (* typed inherited call, with arg *)
  END Configure;
  PROCEDURE Tag (): INTEGER;
  BEGIN RETURN tag END Tag;
END Widget;

VAR w: Widget;
BEGIN
  NEW(w);
  w.Configure(99);
  IF w.IsHidden() THEN                              (* typed inherited query *)
    WriteString("OK: setHidden:(TRUE)/isHidden round-tripped through real NSView state")
  ELSE
    WriteString("FAIL: inherited Cocoa state not updated")
  END;
  WriteLn;
  WriteString("our own ivar tag = ");
  IF w.Tag() = 99 THEN WriteString("99 (OK)") ELSE WriteString("WRONG") END;
  WriteLn
END macos_inherited_calls.
