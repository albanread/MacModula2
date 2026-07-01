MODULE t91040withconstbypassreject;
(* is_readonly_target (used by WITH to decide whether the record's fields are
   read-only) never checked is_const_param_target, so `WITH r DO field := x
   END` inside `PROCEDURE P(CONST r: T)` was silently accepted with no
   diagnostic — unlike the equivalent `r.field := x` written directly (already
   correctly rejected). At runtime the write only lands in the callee's local
   by-value copy of the CONST record, silently discarding it. *)
TYPE Rec = RECORD field: INTEGER END;

PROCEDURE P(CONST r: Rec);
BEGIN
  WITH r DO field := 5 END
END P;

VAR r: Rec;
BEGIN
  r.field := 1;
  P(r)
END t91040withconstbypassreject.
