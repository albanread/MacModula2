MODULE swi;
(* SWIs from Modula-2: by name and number, registers in and out, the X
   form's error, an exception from Call, buffers in globals and NEW'd. *)
IMPORT SWI, EXCEPTIONS;
FROM SYSTEM IMPORT ADR, ADDRESS;
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard, WriteInt;

TYPE Buf = ARRAY [0..255] OF ACHAR;
VAR r: SWI.Regs;
    e: ADDRESS;
    s: ARRAY [0..255] OF CHAR;
    buf: Buf;
    pb: POINTER TO Buf;
    t0, i: CARDINAL32;

PROCEDURE Bad;
VAR q: SWI.Regs;
    m: ARRAY [0..127] OF CHAR;
BEGIN
  q[0] := 255; q[1] := SWI.Str("NoSuchFile$$");
  SWI.CallName("OS_File", q);
  WriteString("not reached"); WriteLn
EXCEPT
  IF EXCEPTIONS.IsExceptionalExecution() THEN
    EXCEPTIONS.GetMessage(m);
    WriteString("caught: "); WriteString(m); WriteLn;
    RETURN
  END
END Bad;

BEGIN
  r[0] := SWI.Str("OS_Write0 says hello"); SWI.CallName("OS_Write0", r);
  SWI.CallName("OS_NewLine", r);
  WriteString("OS_Write0 is &"); WriteCard(SWI.Number("OS_Write0"), 1); WriteLn;
  SWI.Call(42H, r);   (* OS_ReadMonotonicTime by number *)
  t0 := r[0];
  WriteString("time > 0: "); IF t0 > 0 THEN WriteString("yes") ELSE WriteString("no") END; WriteLn;
  (* OS_ReadVarVal into a global ACHAR buffer *)
  r[0] := SWI.Str("Sys$ReturnCode"); r[1] := SWI.Addr(ADR(buf)); r[2] := 255; r[3] := 0; r[4] := 3;
  e := SWI.XCallName("OS_ReadVarVal", r);
  IF e = NIL THEN
    buf[r[2]] := 0C;
    SWI.GetStr(SWI.Addr(ADR(buf)), s);
    WriteString("Sys$ReturnCode = "); WriteString(s); WriteLn
  END;
  (* the X form: an error block back, V set *)
  r[0] := 255; r[1] := SWI.Str("NoSuchFile$$");
  e := SWI.XCallName("OS_File", r);
  IF e # NIL THEN
    SWI.ErrorText(e, s);
    WriteString("XCall error &"); WriteCard(SWI.ErrorNumber(e), 1);
    WriteString(" V="); WriteCard(SWI.Flags() MOD 2, 1);
    WriteString(": "); WriteString(s); WriteLn
  END;
  Bad;
  (* a NEW'd buffer: OS_ConvertCardinal4 *)
  NEW(pb);
  r[0] := 123456; r[1] := SWI.Addr(pb); r[2] := 64;
  SWI.CallName("OS_ConvertCardinal4", r);
  SWI.GetStr(r[0], s);
  WriteString("converted: "); WriteString(s); WriteLn;
  DISPOSE(pb);
  WriteString("done"); WriteLn
END swi.
