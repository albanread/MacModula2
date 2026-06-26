MODULE objcstruct_demo;
(* Struct returns from message sends, typed by the selector database (extension 3):
   [view frame] -> ObjC.NSRect (4-double HFA), [s rangeOfString:] -> ObjC.NSRange
   (two integers in x0/x1). No hand-cast send types, no manual field decoding. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM SRealIO IMPORT WriteFixed;
FROM SYSTEM IMPORT CAST;
IMPORT ObjC;
IMPORT Cocoa;

VAR view, s, sub: ObjC.Id; r: ObjC.NSRect; rng: ObjC.NSRange; sf: ObjC.SendFrame;

PROCEDURE Cls (name: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(name)) END Cls;

BEGIN
  Cocoa.InitApp;
  view := [Cls("NSView") alloc];
  sf := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());
  view := sf(view, ObjC.Selector("initWithFrame:"), 10.0, 20.0, 300.0, 200.0);
  r := [view frame];                                 (* NSRect *)
  WriteString("frame x="); WriteFixed(r.origin.x, 1, 0);
  WriteString(" y=");      WriteFixed(r.origin.y, 1, 0);
  WriteString(" w=");      WriteFixed(r.size.width, 1, 0);
  WriteString(" h=");      WriteFixed(r.size.height, 1, 0); WriteLn;

  s   := ObjC.NSString("hello world");
  sub := ObjC.NSString("world");
  rng := [s rangeOfString: sub];                     (* NSRange *)
  WriteString("range loc="); WriteCard(rng.location, 1);
  WriteString(" len=");      WriteCard(rng.length, 1); WriteLn
END objcstruct_demo.
