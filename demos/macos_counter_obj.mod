MODULE macos_counter_obj;
(* M1: a stateful M2 class on the Cocoa object model. The field `n` is a real
   Obj-C ivar of the registered class; SELF.n inside the methods reads/writes it.
   Pure Modula-2 above the line, Objective-C below. (Build AOT.) *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;

CLASS Counter;
  VAR n: INTEGER;                 (* a real per-instance Obj-C ivar *)
  PROCEDURE Bump (by: INTEGER);
  BEGIN
    n := n + by                   (* implicit SELF.n *)
  END Bump;
  PROCEDURE Value (): INTEGER;
  BEGIN
    RETURN n
  END Value;
  PROCEDURE Reset;
  BEGIN
    n := 0
  END Reset;
END Counter;

VAR a, b: Counter;
BEGIN
  NEW(a); NEW(b);                 (* two independent Obj-C instances *)
  a.Bump(40); a.Bump(2);
  b.Bump(7);
  WriteString("a.Value() = "); WriteInt(a.Value(), 0); WriteLn;   (* 42 *)
  WriteString("b.Value() = "); WriteInt(b.Value(), 0); WriteLn;   (* 7  -> per-instance state *)
  a.Reset();
  WriteString("a after Reset = "); WriteInt(a.Value(), 0); WriteLn; (* 0 *)
  DISPOSE(a); DISPOSE(b)
END macos_counter_obj.
