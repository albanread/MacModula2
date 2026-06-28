MODULE calculator_cocoa;
(* A scientific calculator as a native Cocoa app — the macOS port of
   demos/calculator.mod (Canvas2D on Windows). The UI is real Cocoa controls: a
   grid of NSButtons and two NSTextField displays, wired to a Modula-2 controller
   CLASS that INHERITs NSObject — one onButton: action identifies the pressed key
   by its title and drives the engine. The engine — a recursive-descent evaluator
   over the typed expression (precedence, unary minus, parens, sin/cos/tan/ln/log/
   sqrt/exp/abs, pi/e) — is ported verbatim; it uses ISO RealMath + RealStr.

     newm2-driver run --library library cocoademos/calculator_cocoa.mod
   Click keys to build an expression; = evaluates, C clears, <- deletes. *)
FROM SYSTEM IMPORT CAST;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT DemoHarness;
FROM RealMath IMPORT sqrt, sin, cos, tan, ln, exp, power;
IMPORT RealStr;

CONST
  WinW = 384.0; WinH = 560.0;
  PI = 3.14159265358979; EE = 2.71828182845905;
  ActIns = 0; ActClear = 1; ActBack = 2; ActEval = 3;

TYPE
  Btn = RECORD col, row: CARDINAL; label, ins: ARRAY [0..7] OF CHAR; act: CARDINAL END;

VAR
  gExpr:   ARRAY [0..127] OF CHAR;
  gResult: ARRAY [0..63] OF CHAR;
  cur:     CARDINAL;
  ok:      BOOLEAN;
  btn:     ARRAY [0..31] OF Btn;
  nBtn:    CARDINAL;
  Mrg, Gap, DH, GX, GY, BW, BH: REAL;
  gExprLabel, gResultLabel: Cocoa.View;
  gCalc:   ObjC.Id;

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

PROCEDURE R (c: CARDINAL): REAL;
BEGIN RETURN FLOAT(VAL(INTEGER, c)) END R;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

(* --- string helpers + engine (ported verbatim from demos/calculator.mod) - *)
PROCEDURE SCopy (VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (i < HIGH(dst)) AND (src[i] # 0C) DO dst[i] := src[i]; INC(i) END;
  dst[i] := 0C
END SCopy;

PROCEDURE SLen (VAR s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END; RETURN i END SLen;

PROCEDURE StrEq (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  LOOP
    IF (i > HIGH(a)) OR (i > HIGH(b)) THEN RETURN TRUE END;
    IF a[i] # b[i] THEN RETURN FALSE END;
    IF a[i] = 0C THEN RETURN TRUE END;
    INC(i)
  END
END StrEq;

PROCEDURE AppendIns (s: ARRAY OF CHAR);
  VAR n, i: CARDINAL;
BEGIN
  n := SLen(gExpr); i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) AND (n < HIGH(gExpr)) DO gExpr[n] := s[i]; INC(n); INC(i) END;
  gExpr[n] := 0C
END AppendIns;

PROCEDURE Backspace;
  VAR n: CARDINAL;
BEGIN n := SLen(gExpr); IF n > 0 THEN gExpr[n-1] := 0C END END Backspace;

PROCEDURE Trim (VAR s: ARRAY OF CHAR);
  VAR i, dot, last: CARDINAL; hasDot: BOOLEAN;
BEGIN
  i := 0; hasDot := FALSE; dot := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO IF s[i] = '.' THEN hasDot := TRUE; dot := i END; INC(i) END;
  IF NOT hasDot THEN RETURN END;
  last := i;
  WHILE (last > dot + 1) AND (s[last-1] = '0') DO DEC(last) END;
  IF last = dot + 1 THEN last := dot END;
  s[last] := 0C
END Trim;

PROCEDURE Peek (): CHAR;
BEGIN IF cur <= HIGH(gExpr) THEN RETURN gExpr[cur] ELSE RETURN 0C END END Peek;
PROCEDURE Skip; BEGIN WHILE Peek() = ' ' DO INC(cur) END END Skip;

PROCEDURE ParseExpr (): REAL; FORWARD;

PROCEDURE ParseNumber (): REAL;
  VAR buf: ARRAY [0..31] OF CHAR; i: CARDINAL; v: REAL; res: RealStr.ConvResults; dig: BOOLEAN;
BEGIN
  i := 0; dig := FALSE;
  WHILE ((Peek() >= '0') AND (Peek() <= '9')) OR (Peek() = '.') DO
    IF Peek() # '.' THEN dig := TRUE END;
    IF i <= HIGH(buf)-1 THEN buf[i] := Peek(); INC(i) END; INC(cur)
  END;
  IF (Peek() = 'e') OR (Peek() = 'E') THEN
    IF i <= HIGH(buf)-1 THEN buf[i] := Peek(); INC(i) END; INC(cur);
    IF (Peek() = '+') OR (Peek() = '-') THEN
      IF i <= HIGH(buf)-1 THEN buf[i] := Peek(); INC(i) END; INC(cur)
    END;
    WHILE (Peek() >= '0') AND (Peek() <= '9') DO
      IF i <= HIGH(buf)-1 THEN buf[i] := Peek(); INC(i) END; INC(cur)
    END
  END;
  buf[i] := 0C;
  IF NOT dig THEN ok := FALSE; RETURN 0.0 END;
  RealStr.StrToReal(buf, v, res);
  RETURN v
END ParseNumber;

PROCEDURE ApplyFunc (VAR name: ARRAY OF CHAR; a: REAL): REAL;
BEGIN
  IF    StrEq(name, "sqrt") THEN RETURN sqrt(a)
  ELSIF StrEq(name, "sin")  THEN RETURN sin(a)
  ELSIF StrEq(name, "cos")  THEN RETURN cos(a)
  ELSIF StrEq(name, "tan")  THEN RETURN tan(a)
  ELSIF StrEq(name, "ln")   THEN RETURN ln(a)
  ELSIF StrEq(name, "exp")  THEN RETURN exp(a)
  ELSIF StrEq(name, "log")  THEN RETURN ln(a) / ln(10.0)
  ELSIF StrEq(name, "abs")  THEN IF a < 0.0 THEN RETURN -a ELSE RETURN a END
  ELSE ok := FALSE; RETURN 0.0 END
END ApplyFunc;

PROCEDURE ParseIdent (): REAL;
  VAR name: ARRAY [0..15] OF CHAR; i: CARDINAL; arg: REAL;
BEGIN
  i := 0;
  WHILE ((Peek() >= 'a') AND (Peek() <= 'z')) OR ((Peek() >= 'A') AND (Peek() <= 'Z')) DO
    IF i <= HIGH(name)-1 THEN name[i] := Peek(); INC(i) END; INC(cur)
  END;
  name[i] := 0C; Skip;
  IF Peek() = '(' THEN
    INC(cur); arg := ParseExpr(); Skip;
    IF Peek() = ')' THEN INC(cur) ELSE ok := FALSE END;
    RETURN ApplyFunc(name, arg)
  ELSIF StrEq(name, "pi") THEN RETURN PI
  ELSIF StrEq(name, "e")  THEN RETURN EE
  ELSE ok := FALSE; RETURN 0.0 END
END ParseIdent;

PROCEDURE ParsePrimary (): REAL;
  VAR v: REAL; c: CHAR;
BEGIN
  Skip; c := Peek();
  IF c = '(' THEN
    INC(cur); v := ParseExpr(); Skip;
    IF Peek() = ')' THEN INC(cur) ELSE ok := FALSE END; RETURN v
  ELSIF ((c >= '0') AND (c <= '9')) OR (c = '.') THEN RETURN ParseNumber()
  ELSIF ((c >= 'a') AND (c <= 'z')) OR ((c >= 'A') AND (c <= 'Z')) THEN RETURN ParseIdent()
  ELSE ok := FALSE; RETURN 0.0 END
END ParsePrimary;

PROCEDURE ParseUnary (): REAL;
BEGIN
  Skip;
  IF Peek() = '-' THEN INC(cur); RETURN -ParseUnary()
  ELSIF Peek() = '+' THEN INC(cur); RETURN ParseUnary()
  ELSE RETURN ParsePrimary() END
END ParseUnary;

PROCEDURE ParsePower (): REAL;
  VAR b: REAL;
BEGIN
  b := ParseUnary(); Skip;
  IF Peek() = '^' THEN INC(cur); RETURN power(b, ParsePower()) ELSE RETURN b END
END ParsePower;

PROCEDURE ParseTerm (): REAL;
  VAR v, d: REAL;
BEGIN
  v := ParsePower();
  LOOP
    Skip;
    IF Peek() = '*' THEN INC(cur); v := v * ParsePower()
    ELSIF Peek() = '/' THEN INC(cur); d := ParsePower();
      IF d = 0.0 THEN ok := FALSE; RETURN 0.0 ELSE v := v / d END
    ELSE EXIT END
  END;
  RETURN v
END ParseTerm;

PROCEDURE ParseExpr (): REAL;
  VAR v: REAL;
BEGIN
  v := ParseTerm();
  LOOP
    Skip;
    IF Peek() = '+' THEN INC(cur); v := v + ParseTerm()
    ELSIF Peek() = '-' THEN INC(cur); v := v - ParseTerm()
    ELSE EXIT END
  END;
  RETURN v
END ParseExpr;

PROCEDURE Eval;
  VAR v: REAL;
BEGIN
  IF gExpr[0] = 0C THEN RETURN END;
  cur := 0; ok := TRUE;
  v := ParseExpr(); Skip;
  IF Peek() # 0C THEN ok := FALSE END;
  IF ok THEN RealStr.RealToFixed(v, 10, gResult); Trim(gResult)
  ELSE SCopy(gResult, "Error") END
END Eval;

(* --- button table (ported from InitButtons) ----------------------------- *)
PROCEDURE AddBtn (c, r: CARDINAL; label, ins: ARRAY OF CHAR; act: CARDINAL);
BEGIN
  btn[nBtn].col := c; btn[nBtn].row := r;
  SCopy(btn[nBtn].label, label); SCopy(btn[nBtn].ins, ins); btn[nBtn].act := act;
  INC(nBtn)
END AddBtn;

PROCEDURE InitButtons;
BEGIN
  Mrg := 10.0; Gap := 8.0; DH := 104.0;
  GX := Mrg; GY := DH + Mrg;
  BW := (WinW - 2.0*Mrg - 4.0*Gap) / 5.0;
  BH := (WinH - DH - 2.0*Mrg - 5.0*Gap) / 6.0;
  nBtn := 0;
  AddBtn(0,0,"sin","sin(",ActIns);  AddBtn(1,0,"cos","cos(",ActIns);
  AddBtn(2,0,"tan","tan(",ActIns);  AddBtn(3,0,"ln","ln(",ActIns);
  AddBtn(4,0,"log","log(",ActIns);
  AddBtn(0,1,"(","(",ActIns);       AddBtn(1,1,")",")",ActIns);
  AddBtn(2,1,"^","^",ActIns);       AddBtn(3,1,"sqrt","sqrt(",ActIns);
  AddBtn(4,1,"pi","pi",ActIns);
  AddBtn(0,2,"7","7",ActIns);       AddBtn(1,2,"8","8",ActIns);
  AddBtn(2,2,"9","9",ActIns);       AddBtn(3,2,"/","/",ActIns);
  AddBtn(4,2,"e","e",ActIns);
  AddBtn(0,3,"4","4",ActIns);       AddBtn(1,3,"5","5",ActIns);
  AddBtn(2,3,"6","6",ActIns);       AddBtn(3,3,"*","*",ActIns);
  AddBtn(4,3,"C","",ActClear);
  AddBtn(0,4,"1","1",ActIns);       AddBtn(1,4,"2","2",ActIns);
  AddBtn(2,4,"3","3",ActIns);       AddBtn(3,4,"-","-",ActIns);
  AddBtn(4,4,"<-","",ActBack);
  AddBtn(0,5,"0","0",ActIns);       AddBtn(1,5,".",".",ActIns);
  AddBtn(2,5,"exp","exp(",ActIns);  AddBtn(3,5,"+","+",ActIns);
  AddBtn(4,5,"=","",ActEval)
END InitButtons;

PROCEDURE UpdateDisplay;
BEGIN
  Cocoa.SetText(gExprLabel, gExpr);
  IF gResult[0] # 0C THEN Cocoa.SetText(gResultLabel, gResult)
  ELSE Cocoa.SetText(gResultLabel, "0") END
END UpdateDisplay;

(* --- the controller: a Modula-2 CLASS that IS an NSObject --------------- *)
CLASS Calc;
  INHERIT NSObject;

  PROCEDURE OnButton (sender: ObjC.Id);     (* selector onButton: — every key's action *)
    VAR t: ObjC.Id; buf: ARRAY [0..15] OF CHAR; i, n: CARDINAL;
  BEGIN
    t := [sender title]; n := VAL(CARDINAL, ObjC.GetString(t, buf));
    FOR i := 0 TO nBtn-1 DO
      IF StrEq(btn[i].label, buf) THEN
        CASE btn[i].act OF
          ActIns:   AppendIns(btn[i].ins)
        | ActClear: gExpr[0] := 0C; gResult[0] := 0C
        | ActBack:  Backspace; gResult[0] := 0C
        | ActEval:  Eval
        END
      END
    END;
    UpdateDisplay
  END OnButton;
END Calc;

(* --- main --------------------------------------------------------------- *)
VAR win: Cocoa.Window; content: Cocoa.View; calc: Calc;
    gGalleryPath: ARRAY [0..1023] OF CHAR; gGalleryIgnore: BOOLEAN;
    i: CARDINAL; b: ObjC.Id; tlx, tly, cy: REAL;
BEGIN
  InitButtons;
  gExpr[0] := 0C; gResult[0] := 0C;
  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "Calculator");
  content := Cocoa.ContentView(win);
  NEW(calc); gCalc := CAST(ObjC.Id, calc);

  (* two display labels at the top (content view is bottom-left origin) *)
  gExprLabel   := Cocoa.MakeLabel(12.0, WinH - 44.0, 360.0, 28.0, "");
  gResultLabel := Cocoa.MakeLabel(12.0, WinH - 92.0, 360.0, 40.0, "0");
  Cocoa.AddSubview(content, gExprLabel);
  Cocoa.AddSubview(content, gResultLabel);
  [CAST(ObjC.Id, gResultLabel) setAlignment: 1];       (* right-aligned *)
  [CAST(ObjC.Id, gExprLabel) setAlignment: 1];

  (* the button grid, wired to the controller's onButton: *)
  FOR i := 0 TO nBtn-1 DO
    tlx := GX + R(btn[i].col) * (BW + Gap);
    tly := GY + R(btn[i].row) * (BH + Gap);
    cy  := WinH - tly - BH;                             (* top-left -> bottom-left *)
    b := [[Cls("NSButton") alloc] init];
    [b setFrame: Rct(tlx, cy, BW, BH)];
    [b setTitle: ObjC.NSString(btn[i].label)];
    [b setBezelStyle: 1];
    [b setTarget: gCalc];
    [b setAction: ObjC.Selector("onButton:")];
    Cocoa.AddSubview(content, CAST(Cocoa.View, b))
  END;

  UpdateDisplay;
  IF DemoHarness.ScriptArg(gGalleryPath) THEN
    gGalleryIgnore := Cocoa.Snapshot(content, gGalleryPath)
  ELSE
    Cocoa.ShowWindow(win);
  Cocoa.RunApp
  END
END calculator_cocoa.
