MODULE objcsend_demo;
(* Exercises the new [recv sel: args] Objective-C message-send syntax — no
   hand-cast Send* procedure types, no manual ObjC.Selector() calls. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM SYSTEM IMPORT CAST;
IMPORT ObjC;

VAR arr, s1, s2, got, ig: ObjC.Id; n: CARDINAL;

PROCEDURE Cls (name: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(name)) END Cls;

BEGIN
  arr := [[Cls("NSMutableArray") alloc] init];      (* nested sends *)
  s1  := ObjC.NSString("hello");
  s2  := ObjC.NSString("world");
  ig  := [arr addObject: s1];                        (* keyword send *)
  ig  := [arr addObject: s2];
  n   := CAST(CARDINAL, [arr count]);                (* unary send, x0 result *)
  WriteString("count="); WriteCard(n, 1); WriteLn;
  got := [arr objectAtIndex: 1];                      (* keyword send, id result *)
  n   := CAST(CARDINAL, [got length]);
  WriteString("len[1]="); WriteCard(n, 1); WriteLn
END objcsend_demo.
