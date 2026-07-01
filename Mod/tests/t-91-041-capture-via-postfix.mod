MODULE t91041captureviapostfix;
(* collect_refs_expr — the sole mechanism deciding which enclosing-scope
   variables a nested procedure needs lambda-lifted as hidden VAR parameters —
   only matched Designator/Call/Binary/Unary/Set; a variable referenced ONLY
   inside a Postfix expression (`Func(x).field`, `CAST(...)^`, ...) or an
   ObjcSend fell into the catch-all and was silently never captured. The
   nested procedure then found no binding for it and read garbage instead of
   the enclosing variable.
 *
 * EXPECTED:
 * 42
 *)
FROM SWholeIO IMPORT WriteInt;
FROM STextIO IMPORT WriteLn;

TYPE Rec = RECORD field: INTEGER END;

PROCEDURE MakeRec(v: INTEGER): Rec;
  VAR r: Rec;
BEGIN r.field := v; RETURN r END MakeRec;

PROCEDURE Outer;
  VAR captured: INTEGER;

  (* `captured` appears ONLY inside this Postfix expression (a field access on
     a function-call result) — nowhere else in Inner's body. *)
  PROCEDURE Inner(): INTEGER;
  BEGIN
    RETURN MakeRec(captured).field
  END Inner;

BEGIN
  captured := 42;
  WriteInt(Inner(), 0); WriteLn
END Outer;

BEGIN
  Outer
END t91041captureviapostfix.
