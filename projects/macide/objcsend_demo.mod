MODULE objcsend_demo;
(* The [recv sel: args] message-send syntax with selector-database typing
   (extension 3): no CAST on the results — count/length are CARDINAL, a Number's
   doubleValue is REAL — the compiler reads the return types from the DB. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM SRealIO IMPORT WriteFixed;
FROM SYSTEM IMPORT CAST;
IMPORT ObjC;

VAR arr, s1, s2, got, num, ig: ObjC.Id; n: CARDINAL; d: REAL;

PROCEDURE Cls (name: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(name)) END Cls;

BEGIN
  arr := [[Cls("NSMutableArray") alloc] init];
  s1  := ObjC.NSString("hello");
  s2  := ObjC.NSString("worlds");
  ig  := [arr addObject: s1];
  ig  := [arr addObject: s2];
  n   := [arr count];                       (* DB: count -> u (CARDINAL), no CAST *)
  WriteString("count="); WriteCard(n, 1); WriteLn;
  got := [arr objectAtIndex: 1];
  n   := [got length];                      (* DB: length -> u (CARDINAL) *)
  WriteString("len[1]="); WriteCard(n, 1); WriteLn;
  num := [Cls("NSNumber") numberWithDouble: 3.5];
  d   := [num doubleValue];                 (* DB: doubleValue -> d (REAL), via d0 *)
  WriteString("dbl="); WriteFixed(d, 2, 0); WriteLn
END objcsend_demo.
