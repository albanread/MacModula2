MODULE t91038typedconstreject;
(* `CONST x: type = value;` (an ADW extension) was parsed and the declared
   type silently discarded: no AST field carried it, and sema always derives
   the constant's type purely from the value's own shape — so a declared type
   that disagreed with the literal (e.g. REAL here, but the literal `1` infers
   INTEGER) was silently accepted and silently ignored. Must be a compile
   error, not a silently wrong type. *)
CONST x: REAL = 1;
BEGIN
END t91038typedconstreject.
