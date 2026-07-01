MODULE t91036methodrecordreturnreject;
(* A virtual method call (native vtable dispatch) is ALWAYS an indirect call —
   unlike a plain named-procedure call — so a method returning a record larger
   than 16 bytes by value has exactly the same arm64 sret/register-return ABI
   hazard as calling through a procedure VALUE (see t-91-035). This must be
   REJECTED by sema, not silently corrupted at runtime. *)
FROM STextIO IMPORT WriteString, WriteLn;

TYPE
  Big = RECORD a, b, c: CARDINAL END;   (* 24 bytes, not an HFA -> sret/indirect *)

CLASS T;
  PROCEDURE Compute (): Big;
    VAR r: Big;
  BEGIN
    r.a := 1; r.b := 2; r.c := 3; RETURN r
  END Compute;
END T;

VAR t: T; r: Big;
BEGIN
  NEW(t);
  r := t.Compute();                    (* <- the rejected virtual-method call *)
  WriteString("unreachable"); WriteLn
END t91036methodrecordreturnreject.
