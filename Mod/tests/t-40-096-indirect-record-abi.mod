MODULE t40096indirectrecordabi;
(* arm64 indirect-call (proc-pointer) struct-ABI classifier. A record of three
   32-bit fields is 12 bytes (<=16) and must be passed/returned in REGISTERS, not
   indirectly. Regression for the classifier over-approximating every scalar to 8
   bytes (12 -> 24 -> wrongly classed indirect). The call goes through a procedure
   PARAMETER, so it is an IndCall that routes through record_indirect_type — the
   same classifier the Cocoa objc_msgSend path relies on. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
FROM SYSTEM IMPORT CARDINAL32;

TYPE
  R3 = RECORD a, b, c: CARDINAL32 END;     (* 12 bytes -> registers *)
  P3 = PROCEDURE (): R3;

PROCEDURE Mk (): R3;
  VAR r: R3;
BEGIN r.a := 111; r.b := 222; r.c := 333; RETURN r END Mk;

PROCEDURE Call (p: P3): R3;                 (* p() is an indirect call *)
BEGIN RETURN p() END Call;

VAR r: R3;
BEGIN
  r := Call(Mk);
  WriteInt(VAL(INTEGER, r.a), 0); WriteString(" ");
  WriteInt(VAL(INTEGER, r.b), 0); WriteString(" ");
  WriteInt(VAL(INTEGER, r.c), 0); WriteLn
END t40096indirectrecordabi.
