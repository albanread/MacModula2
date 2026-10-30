(* Declaritive over SWI: see boxdef/Declaritive.def. The spec, the poll
   block and the strings handed to the module are global variables, so they
   are in the run's dynamic area and RISC OS can read them. *)
IMPLEMENTATION MODULE Declaritive;

IMPORT SWI;
FROM SYSTEM IMPORT ADR, ADDRESS;

CONST
  DInitialise = 0C0380H; DCloseDown = 0C0381H; DCreate = 0C0382H;
  DOpen = 0C0384H; DClose = 0C0385H; DDispatch = 0C0386H; DSet = 0C0387H;
  DGet = 0C0388H; DUpdate = 0C0389H; DPatch = 0C038AH;
  WimpPoll = 400C7H; WimpPollIdle = 400E1H;
  SpecMax = 65535;

VAR
  spec: ARRAY [0..SpecMax] OF ACHAR;
  specLen: CARDINAL;
  s1, s2, s3: ARRAY [0..1023] OF ACHAR;
  block: ARRAY [0..63] OF CARDINAL32;
  mask, pollword, next: CARDINAL32;

(* A string into an ACHAR buffer, 0-terminated, as RISC OS reads it *)
PROCEDURE Put (s: ARRAY OF CHAR; VAR b: ARRAY OF ACHAR): CARDINAL32;
VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) & (i < HIGH(b)) & (s[i] # 0C) DO
    IF ORD(s[i]) < 256 THEN b[i] := VAL(ACHAR, ORD(s[i])) ELSE b[i] := VAL(ACHAR, 63) END;
    INC(i)
  END;
  b[i] := VAL(ACHAR, 0);
  RETURN SWI.Addr(ADR(b))
END Put;

PROCEDURE Init (taskName: ARRAY OF CHAR);
VAR r: SWI.Regs;
BEGIN
  r[0] := 1; r[1] := Put(taskName, s1);
  SWI.Call(DInitialise, r);
  mask := r[1]; pollword := r[2]; next := 0
END Init;

PROCEDURE Add (text: ARRAY OF CHAR);
VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(text)) & (text[i] # 0C) & (specLen < SpecMax) DO
    IF ORD(text[i]) < 256 THEN spec[specLen] := VAL(ACHAR, ORD(text[i])) ELSE spec[specLen] := VAL(ACHAR, 63) END;
    INC(specLen); INC(i)
  END;
  spec[specLen] := VAL(ACHAR, 0)
END Add;

PROCEDURE Taken (): CARDINAL32;
BEGIN
  spec[specLen] := VAL(ACHAR, 0);
  specLen := 0;
  RETURN SWI.Addr(ADR(spec))
END Taken;

PROCEDURE Create (): Window;
VAR r: SWI.Regs;
BEGIN
  r[0] := 0; r[1] := Taken();
  SWI.Call(DCreate, r);
  RETURN r[0]
END Create;

PROCEDURE Set (w: Window; id, prop, value: ARRAY OF CHAR);
VAR r: SWI.Regs;
BEGIN
  r[0] := w; r[1] := Put(id, s1); r[2] := Put(prop, s2); r[3] := Put(value, s3);
  SWI.Call(DSet, r)
END Set;

PROCEDURE Get (w: Window; id, prop: ARRAY OF CHAR; VAR value: ARRAY OF CHAR);
VAR r: SWI.Regs;
BEGIN
  r[0] := w; r[1] := Put(id, s1); r[2] := Put(prop, s2);
  SWI.Call(DGet, r);
  SWI.GetStr(r[0], value)
END Get;

PROCEDURE Patch (w: Window);
VAR r: SWI.Regs;
BEGIN
  r[0] := w; r[1] := Taken(); SWI.Call(DPatch, r)
END Patch;

PROCEDURE Update (w: Window);
VAR r: SWI.Regs;
BEGIN
  r[0] := w; r[1] := Taken(); SWI.Call(DUpdate, r)
END Update;

PROCEDURE Open (w: Window);
VAR r: SWI.Regs;
BEGIN
  r[0] := w; r[1] := 1; SWI.Call(DOpen, r)
END Open;

PROCEDURE CloseWindow (w: Window);
VAR r: SWI.Regs;
BEGIN
  r[0] := w; SWI.Call(DClose, r)
END CloseWindow;

PROCEDURE Poll (VAR e: Event): BOOLEAN;
VAR r: SWI.Regs; ev: CARDINAL32; reason: CARDINAL32;
  PROCEDURE Word (i: CARDINAL): CARDINAL32;
  VAR p: POINTER TO ARRAY [0..9] OF CARDINAL32;
  BEGIN
    p := VAL(ADDRESS, VAL(CARDINAL, ev)); RETURN p^[i]
  END Word;
BEGIN
  r[0] := mask; r[1] := SWI.Addr(ADR(block)); r[3] := pollword;
  IF next # 0 THEN r[2] := next; SWI.Call(WimpPollIdle, r)
  ELSE r[2] := 0; SWI.Call(WimpPoll, r) END;
  reason := r[0];
  r[0] := reason; r[1] := SWI.Addr(ADR(block));
  SWI.Call(DDispatch, r);
  e.kind := VAL(INTEGER, r[0]);
  ev := r[1];
  mask := Word(8); next := Word(9);
  IF e.kind <= 0 THEN e.kind := 0; RETURN FALSE END;
  e.window := Word(1);
  SWI.GetStr(Word(2), e.name);
  SWI.GetStr(Word(3), e.id);
  SWI.GetStr(Word(4), e.value);
  e.number := VAL(INTEGER, VAL(INTEGER32, Word(5)));
  e.x := VAL(INTEGER, VAL(INTEGER32, Word(6)));
  e.y := VAL(INTEGER, VAL(INTEGER32, Word(7)));
  RETURN TRUE
END Poll;

PROCEDURE Is (a, b: ARRAY OF CHAR): BOOLEAN;
VAR i: CARDINAL;
BEGIN
  i := 0;
  LOOP
    IF (i > HIGH(a)) OR (a[i] = 0C) THEN RETURN (i > HIGH(b)) OR (b[i] = 0C) END;
    IF (i > HIGH(b)) OR (a[i] # b[i]) THEN RETURN FALSE END;
    INC(i)
  END
END Is;

PROCEDURE CloseDown;
VAR r: SWI.Regs;
BEGIN
  SWI.Call(DCloseDown, r)
END CloseDown;

BEGIN
  specLen := 0; next := 0
END Declaritive.
