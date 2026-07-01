MODULE t91037varinitializerreject;
(* `VAR x: T = expr;` (an ADW extension) was parsed and the initializer
   silently discarded: no AST field carried it, no error was raised, and the
   variable compiled as if declared with no initializer at all — the
   programmer had every reason to believe it worked. Must be a compile error,
   not silent data loss. *)
VAR x: INTEGER = 42;
BEGIN
END t91037varinitializerreject.
