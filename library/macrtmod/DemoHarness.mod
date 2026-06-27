IMPLEMENTATION MODULE DemoHarness;

FROM SYSTEM IMPORT ADR;
IMPORT NM2ProgramArgs;
IMPORT Ptcl;
IMPORT Cocoa;
IMPORT Proc;
FROM STextIO IMPORT WriteString, WriteLn;

VAR
  gView:     Cocoa.View;
  gStep:     StepProc;
  gKey:      KeyProc;
  gQuery:    QueryProc;
  gHasQuery: BOOLEAN;

PROCEDURE SetQuery (q: QueryProc);
BEGIN gQuery := q; gHasQuery := TRUE END SetQuery;

PROCEDURE IntToStr (n: INTEGER; VAR s: ARRAY OF CHAR);
  VAR dig: ARRAY [0..31] OF CHAR; k, p, m: CARDINAL; neg: BOOLEAN;
BEGIN
  neg := n < 0; IF neg THEN m := VAL(CARDINAL, -n) ELSE m := VAL(CARDINAL, n) END;
  IF m = 0 THEN s[0] := '0'; s[1] := 0C; RETURN END;
  k := 0; WHILE m > 0 DO dig[k] := CHR((m MOD 10) + ORD('0')); m := m DIV 10; INC(k) END;
  p := 0; IF neg THEN s[0] := '-'; p := 1 END;
  WHILE k > 0 DO DEC(k); s[p] := dig[k]; INC(p) END; s[p] := 0C
END IntToStr;

PROCEDURE StrEq (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL; ca, cb: CHAR;
BEGIN
  i := 0;
  LOOP
    IF i <= HIGH(a) THEN ca := a[i] ELSE ca := 0C END;  (* past end reads as NUL — a *)
    IF i <= HIGH(b) THEN cb := b[i] ELSE cb := 0C END;  (* string literal may have no NUL slot *)
    IF ca # cb THEN RETURN FALSE END;
    IF ca = 0C THEN RETURN TRUE END;
    INC(i)
  END
END StrEq;

PROCEDURE ScriptArg (VAR path: ARRAY OF CHAR): BOOLEAN;
  VAR i, n, got: CARDINAL; a: ARRAY [0..1023] OF CHAR;
BEGIN
  n := NM2ProgramArgs.Count();
  i := 1;
  WHILE i < n DO
    got := NM2ProgramArgs.Copy(i, ADR(a), 1024);
    a[got] := 0C;
    IF StrEq(a, "--script") AND (i + 1 < n) THEN
      got := NM2ProgramArgs.Copy(i + 1, ADR(path), VAL(CARDINAL, HIGH(path)) + 1);
      IF got <= VAL(CARDINAL, HIGH(path)) THEN path[got] := 0C END;
      RETURN TRUE
    END;
    INC(i)
  END;
  RETURN FALSE
END ScriptArg;

(* --- host verbs --------------------------------------------------------- *)
PROCEDURE VStep (): BOOLEAN;             (* step [n]  — advance n frames *)
  VAR n: INTEGER;
BEGIN
  IF Ptcl.Argc() >= 2 THEN n := Ptcl.ArgInt(1) ELSE n := 1 END;
  IF n <= 0 THEN n := 1 END;
  gStep(VAL(CARDINAL, n));
  RETURN TRUE
END VStep;

PROCEDURE VKey (): BOOLEAN;               (* key <name> *)
  VAR s: ARRAY [0..63] OF CHAR;
BEGIN
  Ptcl.Arg(1, s);
  gKey(s);
  RETURN TRUE
END VKey;

PROCEDURE VSnap (): BOOLEAN;              (* snap <path> *)
  VAR p: ARRAY [0..1023] OF CHAR;
BEGIN
  Ptcl.Arg(1, p);
  IF Cocoa.Snapshot(gView, p) THEN
    Ptcl.Result(p); RETURN TRUE
  ELSE
    Ptcl.Fail("snapshot failed"); RETURN FALSE
  END
END VSnap;

PROCEDURE VGet (): BOOLEAN;               (* get <name> [index] *)
  VAR name: ARRAY [0..63] OF CHAR; num: ARRAY [0..31] OF CHAR; idx: INTEGER;
BEGIN
  Ptcl.Arg(1, name);
  IF Ptcl.Argc() >= 3 THEN idx := Ptcl.ArgInt(2) ELSE idx := 0 END;
  IF gHasQuery THEN IntToStr(gQuery(name, idx), num) ELSE num := "0" END;
  Ptcl.Result(num);
  RETURN TRUE
END VGet;

PROCEDURE Drive (view: View; step: StepProc; key: KeyProc;
                 scriptPath: ARRAY OF CHAR): BOOLEAN;
  VAR script: ARRAY [0..16383] OF CHAR; out: ARRAY [0..1023] OF CHAR;
      rc: INTEGER; ok: BOOLEAN;
BEGIN
  gView := view; gStep := step; gKey := key;
  Ptcl.Register("step", VStep);
  Ptcl.Register("key",  VKey);
  Ptcl.Register("snap", VSnap);
  Ptcl.Register("get",  VGet);
  rc := Proc.ReadFile(scriptPath, script);
  IF rc <= 0 THEN
    WriteString("DemoHarness: cannot read script: "); WriteString(scriptPath); WriteLn;
    RETURN FALSE
  END;
  ok := Ptcl.Eval(script, out);
  IF NOT ok THEN WriteString("DemoHarness script error: ") END;
  WriteString(out); WriteLn;
  RETURN ok
END Drive;

BEGIN
  gHasQuery := FALSE
END DemoHarness.
