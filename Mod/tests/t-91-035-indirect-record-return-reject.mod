MODULE t91035indirectrecordreturnreject;
(* An indirect call (through a procedure VALUE — here a procedure parameter) that
   returns a record larger than 16 bytes by value must be REJECTED by sema: the
   arm64 indirect-call ABI passes such a record via sret, which does not match the
   register return an M2 procedure definition uses, so it would silently corrupt
   the result. (A direct call by name is fine; so is a <=16-byte or HFA record.) *)
FROM STextIO IMPORT WriteString, WriteLn;

TYPE
  Big = RECORD a, b, c: CARDINAL END;     (* 24 bytes, not an HFA -> sret/indirect *)
  PB  = PROCEDURE (): Big;

PROCEDURE Mk (): Big;
  VAR r: Big;
BEGIN r.a := 1; r.b := 2; r.c := 3; RETURN r END Mk;

PROCEDURE Call (p: PB): Big;
BEGIN RETURN p() END Call;                 (* <- the rejected indirect call *)

VAR r: Big;
BEGIN
  r := Call(Mk);
  WriteString("unreachable"); WriteLn
END t91035indirectrecordreturnreject.
