MODULE macos_textstore;
(* Stage 2: an efficient editor text store whose characters live in the M2
   TextRope (O(log n) insert/delete), exposed to Cocoa's text system through two
   Modula-2 classes that ARE Cocoa objects:

     RopeString : NSString       length / characterAtIndex: read the rope
     RopeStore  : NSTextStorage  edits go to the rope; `string` returns the
                                 RopeString; attributes are default for now
                                 (the syntax-colour run list is Stage 2b)

   Both share one rope cell (PRopeBox) so the NSString view always reflects the
   current rope after an edit. A hand-built TextKit stack lays out and draws
   through it. See docs/design/mac-text-store.md.  Verified by snapshot. *)
FROM SYSTEM IMPORT CAST, ADDRESS;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT TextRope;

TYPE
  PRopeBox = POINTER TO RECORD r: TextRope.Rope END;   (* the shared, mutable rope cell *)
  PNSRange = POINTER TO RECORD location, length: CARDINAL END;
  SendEdited = PROCEDURE (ObjC.Id, ObjC.SEL, CARDINAL, CARDINAL, CARDINAL, INTEGER): ObjC.Id;
  Send2F     = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, REAL): ObjC.Id;
  SendFrameC = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, REAL, REAL, REAL, ObjC.Id): ObjC.Id;
  SendPP     = PROCEDURE (ObjC.Id, ObjC.SEL, ObjC.Id, ObjC.Id): ObjC.Id;

VAR
  s0: ObjC.Send0; sp: ObjC.SendP; s0i: ObjC.Send0I; sf1: ObjC.SendF;
  sed: SendEdited; s2f: Send2F; sfc: SendFrameC; spp: SendPP;
  ig, font: ObjC.Id;
  gAttrs: ObjC.Id;        (* one stable, retained default-attributes dict *)

(* ---- RopeString: an NSString whose characters come straight from the rope ---- *)
CLASS RopeString;
  <* cocoa "NSString" *>
  VAR box: PRopeBox;
  PROCEDURE SetBox (b: PRopeBox);                 (* helper, not an NSString primitive *)
  BEGIN box := b END SetBox;
  PROCEDURE Length (): CARDINAL;                  (* primitive "length" *)
  BEGIN RETURN TextRope.Length(box^.r) END Length;
  PROCEDURE CharacterAtIndex (i: CARDINAL): CARDINAL;   (* primitive "characterAtIndex:" *)
  BEGIN RETURN ORD(TextRope.CharAt(box^.r, i)) END CharacterAtIndex;
END RopeString;

(* ---- RopeStore: an NSTextStorage backed by the rope ---- *)
CLASS RopeStore;
  <* cocoa "NSTextStorage" *>
  VAR box: PRopeBox; ropeStr: ObjC.Id;

  PROCEDURE Setup;                                (* build the rope cell + string view *)
  VAR rs: RopeString;
  BEGIN
    NEW(box); box^.r := TextRope.Empty();
    NEW(rs); rs.SetBox(box); ropeStr := CAST(ObjC.Id, rs)
  END Setup;

  PROCEDURE String (): ObjC.Id;                   (* primitive "string" *)
  BEGIN RETURN ropeStr END String;

  PROCEDURE ReplaceChars (loc, len: CARDINAL; s: ObjC.Id) <* selector "replaceCharactersInRange:withString:" *>;
  VAR text: ARRAY [0..65535] OF CHAR; inserted: CARDINAL;
  BEGIN
    inserted := s0i(s, ObjC.Selector("length"));
    box^.r := TextRope.DeleteRange(box^.r, loc, len);
    ObjC.GetString(s, text);
    IF text[0] # CHR(0) THEN box^.r := TextRope.Insert(box^.r, loc, text) END;
    ig := sed(CAST(ObjC.Id, SELF), ObjC.Selector("edited:range:changeInLength:"),
              3, loc, len, VAL(INTEGER, inserted) - VAL(INTEGER, len))
  END ReplaceChars;

  (* one uniform attributes run over the whole document (Stage 2b: a real run list) *)
  PROCEDURE AttributesAt (loc: CARDINAL; rangePtr: ADDRESS): ObjC.Id <* selector "attributesAtIndex:effectiveRange:" *>;
  VAR rng: PNSRange;
  BEGIN
    IF rangePtr # NIL THEN
      rng := CAST(PNSRange, rangePtr);
      rng^.location := 0;
      rng^.length := TextRope.Length(box^.r)
    END;
    RETURN gAttrs
  END AttributesAt;

  PROCEDURE SetAttrs (a: ObjC.Id; loc, len: CARDINAL) <* selector "setAttributes:range:" *>;
  BEGIN END SetAttrs;                             (* no-op: we own attributes (Stage 2b) *)

  (* take responsibility for attribute validity — skip Cocoa's attribute fixing
     (which assumes an NSMutableAttributedString backing we don't have) *)
  PROCEDURE FixAttributes (loc, len: CARDINAL) <* selector "fixAttributesInRange:" *>;
  BEGIN END FixAttributes;
END RopeStore;

VAR
  store: RopeStore; win, content, lm, container, tv, storeId: ObjC.Id; got: ARRAY [0..255] OF CHAR;
BEGIN
  s0  := CAST(ObjC.Send0,     ObjC.MsgSendPtr());
  sp  := CAST(ObjC.SendP,     ObjC.MsgSendPtr());
  s0i := CAST(ObjC.Send0I,    ObjC.MsgSendPtr());
  sf1 := CAST(ObjC.SendF,     ObjC.MsgSendPtr());
  sed := CAST(SendEdited,     ObjC.MsgSendPtr());
  s2f := CAST(Send2F,         ObjC.MsgSendPtr());
  sfc := CAST(SendFrameC,     ObjC.MsgSendPtr());
  spp := CAST(SendPP,         ObjC.MsgSendPtr());

  Cocoa.InitApp;
  (* default attributes: a fixed-pitch font (NSFontAttributeName's value is "NSFont") *)
  gAttrs := s0(s0(ObjC.GetClass("NSMutableDictionary"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  font := sf1(ObjC.GetClass("NSFont"), ObjC.Selector("userFixedPitchFontOfSize:"), 14.0);
  ig := spp(gAttrs, ObjC.Selector("setObject:forKey:"), font, ObjC.NSString("NSFont"));

  NEW(store); store.Setup;
  storeId := CAST(ObjC.Id, store);
  store.ReplaceChars(0, 0, ObjC.NSString("MODULE Hello;"));
  store.ReplaceChars(6, 0, ObjC.NSString("Rope"));     (* O(log n) mid-edit -> "MODULERope Hello;" *)

  (* read the text back THROUGH the rope-backed NSString (no whole-buffer copy) *)
  ObjC.GetString(store.String(), got);
  WriteString("rope text via NSString = '"); WriteString(got); WriteString("'"); WriteLn;

  lm := s0(s0(ObjC.GetClass("NSLayoutManager"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  ig := sp(storeId, ObjC.Selector("addLayoutManager:"), lm);
  container := s0(ObjC.GetClass("NSTextContainer"), ObjC.Selector("alloc"));
  container := s2f(container, ObjC.Selector("initWithSize:"), 600.0, 400.0);
  ig := sp(lm, ObjC.Selector("addTextContainer:"), container);
  tv := s0(ObjC.GetClass("NSTextView"), ObjC.Selector("alloc"));
  tv := sfc(tv, ObjC.Selector("initWithFrame:textContainer:"), 0.0, 0.0, 600.0, 400.0, container);

  win := Cocoa.MakeWindow(620.0, 420.0, "M2 rope-backed NSTextStorage");
  content := CAST(ObjC.Id, Cocoa.ContentView(win));
  ig := sp(content, ObjC.Selector("addSubview:"), tv);

  IF Cocoa.Snapshot(Cocoa.ContentView(win), "/tmp/macm2_textstore.png") THEN END
END macos_textstore.
