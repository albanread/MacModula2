IMPLEMENTATION MODULE RopeEditor;
(* The rope-backed text store (RopeStore : NSTextStorage, RopeString : NSString)
   + a small M2 lexer + incremental re-lex, wrapped as a reusable editor factory.
   See docs/design/mac-text-store.md and macos_textstore.mod (the staged proof). *)
FROM SYSTEM IMPORT CAST, ADDRESS;
FROM Strings IMPORT Equal;
IMPORT ObjC;
IMPORT TextRope;

CONST
  kDefault = 0; kKeyword = 1; kComment = 2; kString = 3; kNumber = 4; kKinds = 5;

TYPE
  PRopeBox = POINTER TO RECORD r: TextRope.Rope END;
  PNSRange = POINTER TO RECORD location, length: CARDINAL END;
  PWide    = POINTER TO ARRAY [0..16777215] OF CHAR;
  Run      = RECORD len: CARDINAL; kind: INTEGER END;
  PRuns    = POINTER TO RECORD count: CARDINAL; a: ARRAY [0..16383] OF Run END;
  SendEdited = PROCEDURE (ObjC.Id, ObjC.SEL, CARDINAL, CARDINAL, CARDINAL, INTEGER): ObjC.Id;
  Send2F     = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, REAL): ObjC.Id;
  SendFrameC = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, REAL, REAL, REAL, ObjC.Id): ObjC.Id;
  SendPP     = PROCEDURE (ObjC.Id, ObjC.SEL, ObjC.Id, ObjC.Id): ObjC.Id;
  Send4F     = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, REAL, REAL, REAL): ObjC.Id;

VAR
  s0: ObjC.Send0; sp: ObjC.SendP; s0i: ObjC.Send0I; sf1: ObjC.SendF; sb: ObjC.SendB;
  sf: ObjC.SendFrame; si: ObjC.SendI;
  sed: SendEdited; s2f: Send2F; sfc: SendFrameC; spp: SendPP; s4f: Send4F;
  ig, font: ObjC.Id;
  gKind: ARRAY [0..kKinds-1] OF ObjC.Id;
  gNewRuns, gScratch: PRuns;
  gInited: BOOLEAN;

(* ---- M2 lexer over a wide buffer -> runs ---- *)
PROCEDURE IsAlpha (c: CHAR): BOOLEAN;
BEGIN RETURN ((c >= 'A') AND (c <= 'Z')) OR ((c >= 'a') AND (c <= 'z')) OR (c = '_') END IsAlpha;

PROCEDURE IsDigit (c: CHAR): BOOLEAN;
BEGIN RETURN (c >= '0') AND (c <= '9') END IsDigit;

PROCEDURE IsKeyword (w: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Equal(w,"MODULE") OR Equal(w,"IMPLEMENTATION") OR Equal(w,"DEFINITION") OR
    Equal(w,"BEGIN") OR Equal(w,"END") OR Equal(w,"PROCEDURE") OR Equal(w,"CLASS") OR
    Equal(w,"IF") OR Equal(w,"THEN") OR Equal(w,"ELSE") OR Equal(w,"ELSIF") OR
    Equal(w,"WHILE") OR Equal(w,"DO") OR Equal(w,"FOR") OR Equal(w,"TO") OR Equal(w,"BY") OR
    Equal(w,"REPEAT") OR Equal(w,"UNTIL") OR Equal(w,"CASE") OR Equal(w,"OF") OR
    Equal(w,"LOOP") OR Equal(w,"EXIT") OR Equal(w,"RETURN") OR Equal(w,"VAR") OR
    Equal(w,"CONST") OR Equal(w,"TYPE") OR Equal(w,"RECORD") OR Equal(w,"ARRAY") OR
    Equal(w,"POINTER") OR Equal(w,"SET") OR Equal(w,"IMPORT") OR Equal(w,"FROM") OR
    Equal(w,"WITH") OR Equal(w,"AND") OR Equal(w,"OR") OR Equal(w,"NOT") OR
    Equal(w,"DIV") OR Equal(w,"MOD") OR Equal(w,"IN") OR Equal(w,"NIL") OR
    Equal(w,"TRUE") OR Equal(w,"FALSE")
END IsKeyword;

PROCEDURE AddRun (p: PRuns; len: CARDINAL; kind: INTEGER);
BEGIN
  IF (p^.count > 0) AND (kind = kDefault) AND (p^.a[p^.count-1].kind = kDefault) THEN
    p^.a[p^.count-1].len := p^.a[p^.count-1].len + len
  ELSIF p^.count <= 16383 THEN
    p^.a[p^.count].len := len; p^.a[p^.count].kind := kind; INC(p^.count)
  END
END AddRun;

PROCEDURE Lex (text: ARRAY OF CHAR; n: CARDINAL; p: PRuns);
VAR i, j, k: CARDINAL; w: ARRAY [0..63] OF CHAR; q: CHAR;
BEGIN
  p^.count := 0; i := 0;
  WHILE i < n DO
    IF (text[i] = '(') AND (i+1 < n) AND (text[i+1] = '*') THEN
      j := i+2;
      WHILE (j+1 < n) AND NOT ((text[j] = '*') AND (text[j+1] = ')')) DO INC(j) END;
      IF j+1 < n THEN j := j+2 ELSE j := n END;
      AddRun(p, j-i, kComment); i := j
    ELSIF (text[i] = '"') OR (text[i] = "'") THEN
      q := text[i]; j := i+1;
      WHILE (j < n) AND (text[j] # q) DO INC(j) END;
      IF j < n THEN INC(j) END;
      AddRun(p, j-i, kString); i := j
    ELSIF IsAlpha(text[i]) THEN
      j := i;
      WHILE (j < n) AND (IsAlpha(text[j]) OR IsDigit(text[j])) DO INC(j) END;
      k := 0;
      WHILE (i+k < j) AND (k < 63) DO w[k] := text[i+k]; INC(k) END;
      w[k] := CHR(0);
      IF IsKeyword(w) THEN AddRun(p, j-i, kKeyword) ELSE AddRun(p, j-i, kDefault) END;
      i := j
    ELSIF IsDigit(text[i]) THEN
      j := i;
      WHILE (j < n) AND (IsDigit(text[j]) OR IsAlpha(text[j])) DO INC(j) END;
      AddRun(p, j-i, kNumber); i := j
    ELSE
      AddRun(p, 1, kDefault); INC(i)
    END
  END
END Lex;

PROCEDURE Splice (dst: PRuns; oldStart, oldEnd: CARDINAL; mid, out: PRuns);
VAR ri, off, k: CARDINAL;
BEGIN
  out^.count := 0; off := 0; ri := 0;
  WHILE (ri < dst^.count) AND (off + dst^.a[ri].len <= oldStart) DO
    out^.a[out^.count] := dst^.a[ri]; INC(out^.count); off := off + dst^.a[ri].len; INC(ri)
  END;
  IF (ri < dst^.count) AND (off < oldStart) THEN
    out^.a[out^.count].len := oldStart - off; out^.a[out^.count].kind := dst^.a[ri].kind; INC(out^.count)
  END;
  k := 0;
  WHILE k < mid^.count DO out^.a[out^.count] := mid^.a[k]; INC(out^.count); INC(k) END;
  WHILE (ri < dst^.count) AND (off + dst^.a[ri].len <= oldEnd) DO off := off + dst^.a[ri].len; INC(ri) END;
  IF (ri < dst^.count) AND (off < oldEnd) THEN
    out^.a[out^.count].len := (off + dst^.a[ri].len) - oldEnd; out^.a[out^.count].kind := dst^.a[ri].kind;
    INC(out^.count); off := off + dst^.a[ri].len; INC(ri)
  END;
  WHILE ri < dst^.count DO out^.a[out^.count] := dst^.a[ri]; INC(out^.count); INC(ri) END;
  dst^.count := out^.count; k := 0;
  WHILE k < out^.count DO dst^.a[k] := out^.a[k]; INC(k) END
END Splice;

CLASS RopeString;
  <* cocoa "NSString" *>
  VAR box: PRopeBox;
  PROCEDURE SetBox (b: PRopeBox);
  BEGIN box := b END SetBox;
  PROCEDURE Length (): CARDINAL;
  BEGIN RETURN TextRope.Length(box^.r) END Length;
  PROCEDURE CharacterAtIndex (i: CARDINAL): CARDINAL;
  BEGIN RETURN ORD(TextRope.CharAt(box^.r, i)) END CharacterAtIndex;
  PROCEDURE GetCharacters (buffer: ADDRESS; loc, len: CARDINAL) <* selector "getCharacters:range:" *>;
  VAR tmp: ARRAY [0..65535] OF CHAR; pbuf: PWide; k: CARDINAL;
  BEGIN
    TextRope.Sub(box^.r, loc, len, tmp);
    pbuf := CAST(PWide, buffer); k := 0;
    WHILE k < len DO pbuf^[k] := tmp[k]; INC(k) END
  END GetCharacters;
END RopeString;

CLASS RopeStore;
  <* cocoa "NSTextStorage" *>
  VAR box: PRopeBox; ropeStr: ObjC.Id; runs: PRuns;
  PROCEDURE Setup;
  VAR rs: RopeString;
  BEGIN
    NEW(box); box^.r := TextRope.Empty();
    NEW(rs); rs.SetBox(box); ropeStr := CAST(ObjC.Id, rs);
    NEW(runs); runs^.count := 0
  END Setup;
  PROCEDURE RelexEdit (editLoc, removed, inserted: CARDINAL);
  VAR lineStart, lineEnd, docLen, oldEnd: CARDINAL; sub: ARRAY [0..65535] OF CHAR; delta: INTEGER;
  BEGIN
    docLen := TextRope.Length(box^.r);
    lineStart := editLoc;
    WHILE (lineStart > 0) AND (TextRope.CharAt(box^.r, lineStart-1) # CHR(10)) DO DEC(lineStart) END;
    lineEnd := editLoc + inserted;
    IF lineEnd > docLen THEN lineEnd := docLen END;
    WHILE (lineEnd < docLen) AND (TextRope.CharAt(box^.r, lineEnd) # CHR(10)) DO INC(lineEnd) END;
    IF lineEnd < docLen THEN INC(lineEnd) END;
    TextRope.Sub(box^.r, lineStart, lineEnd - lineStart, sub);
    Lex(sub, lineEnd - lineStart, gNewRuns);
    delta := VAL(INTEGER, inserted) - VAL(INTEGER, removed);
    oldEnd := VAL(CARDINAL, VAL(INTEGER, lineEnd) - delta);
    Splice(runs, lineStart, oldEnd, gNewRuns, gScratch)
  END RelexEdit;
  PROCEDURE String (): ObjC.Id;
  BEGIN RETURN ropeStr END String;
  PROCEDURE ReplaceChars (loc, len: CARDINAL; s: ObjC.Id) <* selector "replaceCharactersInRange:withString:" *>;
  VAR text: ARRAY [0..65535] OF CHAR; inserted: CARDINAL;
  BEGIN
    inserted := s0i(s, ObjC.Selector("length"));
    box^.r := TextRope.DeleteRange(box^.r, loc, len);
    ObjC.GetString(s, text);
    IF text[0] # CHR(0) THEN box^.r := TextRope.Insert(box^.r, loc, text) END;
    SELF.RelexEdit(loc, len, inserted);
    ig := sed(CAST(ObjC.Id, SELF), ObjC.Selector("edited:range:changeInLength:"),
              3, loc, len, VAL(INTEGER, inserted) - VAL(INTEGER, len))
  END ReplaceChars;
  PROCEDURE AttributesAt (loc: CARDINAL; rangePtr: ADDRESS): ObjC.Id <* selector "attributesAtIndex:effectiveRange:" *>;
  VAR rng: PNSRange; i, start: CARDINAL;
  BEGIN
    i := 0; start := 0;
    WHILE (i < runs^.count) AND (start + runs^.a[i].len <= loc) DO start := start + runs^.a[i].len; INC(i) END;
    IF rangePtr # NIL THEN
      rng := CAST(PNSRange, rangePtr);
      IF i < runs^.count THEN rng^.location := start; rng^.length := runs^.a[i].len
      ELSE rng^.location := loc; rng^.length := 1 END
    END;
    IF i < runs^.count THEN RETURN gKind[runs^.a[i].kind] ELSE RETURN gKind[kDefault] END
  END AttributesAt;
  PROCEDURE SetAttrs (a: ObjC.Id; loc, len: CARDINAL) <* selector "setAttributes:range:" *>;
  BEGIN END SetAttrs;
  PROCEDURE FixAttributes (loc, len: CARDINAL) <* selector "fixAttributesInRange:" *>;
  BEGIN END FixAttributes;
END RopeStore;

PROCEDURE MakeAttrs (r, g, b: REAL): ObjC.Id;
VAR d, color: ObjC.Id;
BEGIN
  d := s0(s0(ObjC.GetClass("NSMutableDictionary"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  ig := spp(d, ObjC.Selector("setObject:forKey:"), font, ObjC.NSString("NSFont"));
  color := s4f(ObjC.GetClass("NSColor"), ObjC.Selector("colorWithCalibratedRed:green:blue:alpha:"), r, g, b, 1.0);
  ig := spp(d, ObjC.Selector("setObject:forKey:"), color, ObjC.NSString("NSColor"));
  RETURN d
END MakeAttrs;

PROCEDURE EnsureInit;   (* lazy: must run after Cocoa.InitApp, so do it on first Make *)
BEGIN
  IF gInited THEN RETURN END;
  font := sf1(ObjC.GetClass("NSFont"), ObjC.Selector("userFixedPitchFontOfSize:"), 13.0);
  gKind[kDefault] := MakeAttrs(0.0, 0.0, 0.0);
  gKind[kKeyword] := MakeAttrs(0.15, 0.15, 0.8);
  gKind[kComment] := MakeAttrs(0.0, 0.5, 0.0);
  gKind[kString]  := MakeAttrs(0.6, 0.1, 0.1);
  gKind[kNumber]  := MakeAttrs(0.5, 0.0, 0.5);
  NEW(gNewRuns); NEW(gScratch);
  gInited := TRUE
END EnsureInit;

PROCEDURE Make (x, y, w, h: REAL): ObjC.Id;
VAR store: RopeStore; sid, lm, container, tv, scroll: ObjC.Id;
BEGIN
  EnsureInit;
  NEW(store); store.Setup;
  sid := CAST(ObjC.Id, store);
  lm := s0(s0(ObjC.GetClass("NSLayoutManager"), ObjC.Selector("alloc")), ObjC.Selector("init"));
  ig := sb(lm, ObjC.Selector("setAllowsNonContiguousLayout:"), TRUE);
  ig := sp(sid, ObjC.Selector("addLayoutManager:"), lm);
  container := s0(ObjC.GetClass("NSTextContainer"), ObjC.Selector("alloc"));
  container := s2f(container, ObjC.Selector("initWithSize:"), w, 10000000.0);
  ig := sb(container, ObjC.Selector("setWidthTracksTextView:"), TRUE);
  ig := sp(lm, ObjC.Selector("addTextContainer:"), container);
  tv := s0(ObjC.GetClass("NSTextView"), ObjC.Selector("alloc"));
  tv := sfc(tv, ObjC.Selector("initWithFrame:textContainer:"), 0.0, 0.0, w, h, container);
  ig := sb(tv, ObjC.Selector("setVerticallyResizable:"), TRUE);
  ig := sb(tv, ObjC.Selector("setHorizontallyResizable:"), FALSE);
  ig := si(tv, ObjC.Selector("setAutoresizingMask:"), 2);   (* width sizable *)
  scroll := s0(ObjC.GetClass("NSScrollView"), ObjC.Selector("alloc"));
  scroll := sf(scroll, ObjC.Selector("initWithFrame:"), x, y, w, h);
  ig := sb(scroll, ObjC.Selector("setHasVerticalScroller:"), TRUE);
  ig := sp(scroll, ObjC.Selector("setDocumentView:"), tv);
  RETURN scroll
END Make;

BEGIN
  s0  := CAST(ObjC.Send0,     ObjC.MsgSendPtr());
  sp  := CAST(ObjC.SendP,     ObjC.MsgSendPtr());
  s0i := CAST(ObjC.Send0I,    ObjC.MsgSendPtr());
  sf1 := CAST(ObjC.SendF,     ObjC.MsgSendPtr());
  sb  := CAST(ObjC.SendB,     ObjC.MsgSendPtr());
  sf  := CAST(ObjC.SendFrame, ObjC.MsgSendPtr());
  si  := CAST(ObjC.SendI,     ObjC.MsgSendPtr());
  sed := CAST(SendEdited,     ObjC.MsgSendPtr());
  s2f := CAST(Send2F,         ObjC.MsgSendPtr());
  sfc := CAST(SendFrameC,     ObjC.MsgSendPtr());
  spp := CAST(SendPP,         ObjC.MsgSendPtr());
  s4f := CAST(Send4F,         ObjC.MsgSendPtr());
  gInited := FALSE
END RopeEditor.
