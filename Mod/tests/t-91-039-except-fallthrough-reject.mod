MODULE t91039exceptfallthroughreject;
(* Definite-return analysis only checked the protected body, never the EXCEPT
   handler — but the handler is a REAL control-flow path (a runtime exception
   mid-body reaches it), and if it falls through without RETURN the function
   completes with no result. Must be a compile error, not silently reachable
   undefined-return control flow. *)
FROM SWholeIO IMPORT WriteInt;
FROM STextIO IMPORT WriteLn;

PROCEDURE F(): INTEGER;
BEGIN
  RETURN 1
EXCEPT
  (* falls through: no RETURN here *)
END F;

BEGIN
  WriteInt(F(), 0); WriteLn
END t91039exceptfallthroughreject.
