MODULE t40095openarraystrassign;
(* Whole-array assignment of a string literal / string CONST to an OPEN
   `ARRAY OF CHAR` parameter must copy the characters (bounded by the param's
   runtime HIGH+1), not store the literal's pointer bits. Regression for the
   open-array string-assign codegen bug. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;

CONST Greet = "HELLO";

PROCEDURE Len (VAR s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END; RETURN i END Len;

PROCEDURE Lit (VAR s: ARRAY OF CHAR);
BEGIN s := "SINE" END Lit;

PROCEDURE FromConst (VAR s: ARRAY OF CHAR);
BEGIN s := Greet END FromConst;

VAR big:   ARRAY [0..15] OF CHAR;
    small: ARRAY [0..2] OF CHAR;            (* capacity 3 — too small for "SINE" *)
BEGIN
  Lit(big);       WriteString(big); WriteLn;             (* SINE  *)
  FromConst(big); WriteString(big); WriteLn;             (* HELLO *)
  Lit(small);     WriteString(small); WriteCard(Len(small), 0); WriteLn   (* SIN3, bounded, no overrun *)
END t40095openarraystrassign.
