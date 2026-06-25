MODULE macos_textstore;
(* Stage 1 proof: a custom NSTextStorage written as an ordinary Modula-2 CLASS
   on the Cocoa model. It overrides the four NSTextStorage primitives, forwarding
   to an internal NSMutableAttributedString (the rope swaps in at Stage 2). The
   point is to prove an M2 object can BE the text storage an NSTextView drives —
   the gating capability for docs/design/mac-text-store.md. Verified by snapshot. *)
FROM SYSTEM IMPORT CAST, ADDRESS;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;
IMPORT Cocoa;

TYPE
  SendRangeStr = PROCEDURE (ObjC.Id, ObjC.SEL, INTEGER, INTEGER, ObjC.Id): ObjC.Id; (* …InRange:withString: *)
  SendIAddr    = PROCEDURE (ObjC.Id, ObjC.SEL, INTEGER, ADDRESS): ObjC.Id;          (* atIndex:effectiveRange: *)
  SendPRange   = PROCEDURE (ObjC.Id, ObjC.SEL, ObjC.Id, INTEGER, INTEGER): ObjC.Id; (* setAttributes:range: *)
  SendEdited   = PROCEDURE (ObjC.Id, ObjC.SEL, INTEGER, INTEGER, INTEGER, INTEGER): ObjC.Id; (* edited:range:changeInLength: *)
  Send2F       = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, REAL): ObjC.Id;
  SendFrameC   = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, REAL, REAL, REAL, ObjC.Id): ObjC.Id; (* initWithFrame:textContainer: *)

VAR
  s0: ObjC.Send0; sp: ObjC.SendP; s0i: ObjC.Send0I;
  srs: SendRangeStr; sia: SendIAddr; spr: SendPRange; sed: SendEdited; s2f: Send2F; sfc: SendFrameC;
  ig: ObjC.Id;

(* ---- the text store: a Modula-2 class that IS an NSTextStorage ---- *)
CLASS RopeStore;
  <* cocoa "NSTextStorage" *>
  VAR backing: ObjC.Id;          (* Stage 1: an NSMutableAttributedString; Stage 2: a TextRope *)

  PROCEDURE Setup;               (* not a primitive — create the backing store *)
  BEGIN
    backing := s0(s0(ObjC.GetClass("NSMutableAttributedString"), ObjC.Selector("alloc")), ObjC.Selector("init"))
  END Setup;

  (* primitive 1: the "string" accessor (derived selector "string" matches) *)
  PROCEDURE String (): ObjC.Id;
  BEGIN RETURN s0(backing, ObjC.Selector("string")) END String;

  (* primitive 2: -replaceCharactersInRange:withString: *)
  PROCEDURE ReplaceChars (loc, len: INTEGER; s: ObjC.Id) <* selector "replaceCharactersInRange:withString:" *>;
  VAR newLen: INTEGER;
  BEGIN
    ig := srs(backing, ObjC.Selector("replaceCharactersInRange:withString:"), loc, len, s);
    newLen := s0i(s, ObjC.Selector("length"));
    ig := sed(CAST(ObjC.Id, SELF), ObjC.Selector("edited:range:changeInLength:"), 3, loc, len, newLen - len)
  END ReplaceChars;

  (* primitive 3: attributesAtIndex:effectiveRange: *)
  PROCEDURE AttributesAt (loc: INTEGER; rangePtr: ADDRESS): ObjC.Id <* selector "attributesAtIndex:effectiveRange:" *>;
  BEGIN RETURN sia(backing, ObjC.Selector("attributesAtIndex:effectiveRange:"), loc, rangePtr) END AttributesAt;

  (* primitive 4: -setAttributes:range: *)
  PROCEDURE SetAttrs (attrs: ObjC.Id; loc, len: INTEGER) <* selector "setAttributes:range:" *>;
  BEGIN
    ig := spr(backing, ObjC.Selector("setAttributes:range:"), attrs, loc, len);
    ig := sed(CAST(ObjC.Id, SELF), ObjC.Selector("edited:range:changeInLength:"), 2, loc, len, 0)
  END SetAttrs;
END RopeStore;

VAR
  store: RopeStore; win, content, lm, container, tv: ObjC.Id; storeId: ObjC.Id;
BEGIN
  s0  := CAST(ObjC.Send0,     ObjC.MsgSendPtr());
  sp  := CAST(ObjC.SendP,     ObjC.MsgSendPtr());
  s0i := CAST(ObjC.Send0I,    ObjC.MsgSendPtr());
  srs := CAST(SendRangeStr,   ObjC.MsgSendPtr());
  sia := CAST(SendIAddr,      ObjC.MsgSendPtr());
  spr := CAST(SendPRange,     ObjC.MsgSendPtr());
  sed := CAST(SendEdited,     ObjC.MsgSendPtr());
  s2f := CAST(Send2F,         ObjC.MsgSendPtr());
  sfc := CAST(SendFrameC,     ObjC.MsgSendPtr());

  Cocoa.InitApp;

  (* the custom storage, populated through its own primitive *)
  NEW(store); store.Setup;
  storeId := CAST(ObjC.Id, store);
  store.ReplaceChars(0, 0, ObjC.NSString("MODULE Hello;  (* text in a Modula-2 NSTextStorage *)"));

  (* hand-built TextKit stack on top of our storage *)
  lm := s0(s0(ObjC.GetClass("NSLayoutManager"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  ig := sp(storeId, ObjC.Selector("addLayoutManager:"), lm);
  container := s0(ObjC.GetClass("NSTextContainer"), ObjC.Selector("alloc"));
  container := s2f(container, ObjC.Selector("initWithSize:"), 600.0, 400.0);
  ig := sp(lm, ObjC.Selector("addTextContainer:"), container);
  tv := s0(ObjC.GetClass("NSTextView"), ObjC.Selector("alloc"));
  tv := sfc(tv, ObjC.Selector("initWithFrame:textContainer:"), 0.0, 0.0, 600.0, 400.0, container);

  win := Cocoa.MakeWindow(620.0, 420.0, "M2 NSTextStorage");
  content := CAST(ObjC.Id, Cocoa.ContentView(win));
  ig := sp(content, ObjC.Selector("addSubview:"), tv);

  IF Cocoa.Snapshot(Cocoa.ContentView(win), "/tmp/macm2_textstore.png") THEN END;
  WriteString("text store length = ");
  IF s0i(storeId, ObjC.Selector("length")) > 0 THEN WriteString("non-zero (storage live)") END; WriteLn
END macos_textstore.
