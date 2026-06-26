IMPLEMENTATION MODULE RopeEditor;
(* The rope-backed text store (RopeStore : NSTextStorage, RopeString : NSString)
   + a small M2 lexer + incremental re-lex, wrapped as a reusable editor factory.
   See docs/design/mac-text-store.md and macos_textstore.mod (the staged proof). *)
FROM SYSTEM IMPORT CAST, ADDRESS, TSIZE;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM Strings IMPORT Equal, Length;
IMPORT ObjC;
IMPORT TextRope;

CONST
  kDefault = 0; kKeyword = 1; kComment = 2; kString = 3; kNumber = 4; kKinds = 5;

TYPE
  PRopeBox = POINTER TO RECORD r: TextRope.Rope END;
  PNSRange = POINTER TO RECORD location, length: CARDINAL END;
  PWide    = POINTER TO ARRAY [0..16777215] OF CHAR;
  Run      = RECORD len: CARDINAL; kind: INTEGER END;
  PRunArr  = POINTER TO ARRAY [0..16777215] OF Run;   (* overlay on a heap block *)
  PRuns    = POINTER TO RECORD count, cap: CARDINAL; a: PRunArr END;  (* growable run vector *)
  SendEdited = PROCEDURE (ObjC.Id, ObjC.SEL, CARDINAL, CARDINAL, CARDINAL, INTEGER): ObjC.Id;
  Send2F     = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, REAL): ObjC.Id;
  SendFrameC = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, REAL, REAL, REAL, ObjC.Id): ObjC.Id;
  SendPP     = PROCEDURE (ObjC.Id, ObjC.SEL, ObjC.Id, ObjC.Id): ObjC.Id;
  Send4F     = PROCEDURE (ObjC.Id, ObjC.SEL, REAL, REAL, REAL, REAL): ObjC.Id;
  NSRangeR   = RECORD location, length: CARDINAL END;       (* returned in x0/x1 *)
  SendRRet   = PROCEDURE (ObjC.Id, ObjC.SEL): NSRangeR;     (* selectedRange *)
  SendSetR   = PROCEDURE (ObjC.Id, ObjC.SEL, CARDINAL, CARDINAL): ObjC.Id;  (* setSelectedRange: *)
  SendChg    = PROCEDURE (ObjC.Id, ObjC.SEL, CARDINAL, CARDINAL, ObjC.Id): BOOLEAN; (* shouldChange… *)
  SendRepl   = PROCEDURE (ObjC.Id, ObjC.SEL, CARDINAL, CARDINAL, ObjC.Id): ObjC.Id; (* replaceChars… *)

VAR
  s0: ObjC.Send0; sp: ObjC.SendP; s0i: ObjC.Send0I; sf1: ObjC.SendF; sb: ObjC.SendB;
  sf: ObjC.SendFrame; si: ObjC.SendI;
  sed: SendEdited; s2f: Send2F; sfc: SendFrameC; spp: SendPP; s4f: Send4F;
  srr: SendRRet; ssr: SendSetR; schg: SendChg; srepl: SendRepl;
  ig, font: ObjC.Id;
  gKind: ARRAY [0..kKinds-1] OF ObjC.Id;
  gEdBuf, gEdOut: ARRAY [0..262143] OF CHAR;       (* scratch for indent/comment ops *)
  gNewRuns, gScratch: PRuns;
  gInited: BOOLEAN;

(* a fresh growable run vector, and grow-to-fit (heap-backed, no cap) *)
PROCEDURE NewRuns (): PRuns;
VAR p: PRuns;
BEGIN NEW(p); p^.count := 0; p^.cap := 256; ALLOCATE(p^.a, p^.cap * TSIZE(Run)); RETURN p END NewRuns;

PROCEDURE Reserve (p: PRuns; need: CARDINAL);
VAR newcap, k: CARDINAL; na: PRunArr;
BEGIN
  IF need <= p^.cap THEN RETURN END;
  newcap := p^.cap; WHILE newcap < need DO newcap := newcap * 2 END;
  ALLOCATE(na, newcap * TSIZE(Run));
  k := 0; WHILE k < p^.count DO na^[k] := p^.a^[k]; INC(k) END;
  DEALLOCATE(p^.a, p^.cap * TSIZE(Run));
  p^.a := na; p^.cap := newcap
END Reserve;

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
  IF (p^.count > 0) AND (kind = kDefault) AND (p^.a^[p^.count-1].kind = kDefault) THEN
    p^.a^[p^.count-1].len := p^.a^[p^.count-1].len + len
  ELSE
    Reserve(p, p^.count + 1);
    p^.a^[p^.count].len := len; p^.a^[p^.count].kind := kind; INC(p^.count)
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
  Reserve(out, dst^.count + mid^.count + 4);       (* room for prefix + mid + suffix *)
  out^.count := 0; off := 0; ri := 0;
  WHILE (ri < dst^.count) AND (off + dst^.a^[ri].len <= oldStart) DO
    out^.a^[out^.count] := dst^.a^[ri]; INC(out^.count); off := off + dst^.a^[ri].len; INC(ri)
  END;
  IF (ri < dst^.count) AND (off < oldStart) THEN
    out^.a^[out^.count].len := oldStart - off; out^.a^[out^.count].kind := dst^.a^[ri].kind; INC(out^.count)
  END;
  k := 0;
  WHILE k < mid^.count DO out^.a^[out^.count] := mid^.a^[k]; INC(out^.count); INC(k) END;
  WHILE (ri < dst^.count) AND (off + dst^.a^[ri].len <= oldEnd) DO off := off + dst^.a^[ri].len; INC(ri) END;
  IF (ri < dst^.count) AND (off < oldEnd) THEN
    out^.a^[out^.count].len := (off + dst^.a^[ri].len) - oldEnd; out^.a^[out^.count].kind := dst^.a^[ri].kind;
    INC(out^.count); off := off + dst^.a^[ri].len; INC(ri)
  END;
  WHILE ri < dst^.count DO out^.a^[out^.count] := dst^.a^[ri]; INC(out^.count); INC(ri) END;
  Reserve(dst, out^.count); dst^.count := out^.count; k := 0;
  WHILE k < out^.count DO dst^.a^[k] := out^.a^[k]; INC(k) END
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
  VAR pbuf: PWide; k: CARDINAL;
  BEGIN                                            (* straight from the rope — any length, no buffer *)
    pbuf := CAST(PWide, buffer); k := 0;
    WHILE k < len DO pbuf^[k] := TextRope.CharAt(box^.r, loc + k); INC(k) END
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
    runs := NewRuns()
  END Setup;
  PROCEDURE RelexEdit (editLoc, removed, inserted: CARDINAL);
  VAR lineStart, lineEnd, docLen, oldEnd: CARDINAL; sub: ARRAY [0..262143] OF CHAR; delta: INTEGER;
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
  VAR text: ARRAY [0..262143] OF CHAR; inserted: CARDINAL;
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
    WHILE (i < runs^.count) AND (start + runs^.a^[i].len <= loc) DO start := start + runs^.a^[i].len; INC(i) END;
    IF rangePtr # NIL THEN
      rng := CAST(PNSRange, rangePtr);
      IF i < runs^.count THEN rng^.location := start; rng^.length := runs^.a^[i].len
      ELSE rng^.location := loc; rng^.length := 1 END
    END;
    IF i < runs^.count THEN RETURN gKind[runs^.a^[i].kind] ELSE RETURN gKind[kDefault] END
  END AttributesAt;
  PROCEDURE SetAttrs (a: ObjC.Id; loc, len: CARDINAL) <* selector "setAttributes:range:" *>;
  BEGIN END SetAttrs;
  PROCEDURE FixAttributes (loc, len: CARDINAL) <* selector "fixAttributesInRange:" *>;
  BEGIN END FixAttributes;
END RopeStore;

(* selection range, an undo-aware range replace (fires didChangeText so the IDE's
   autosave delegate runs), and the full-line span covering a selection — shared by
   the editing commands below. *)
PROCEDURE Sel (me: ObjC.Id; VAR loc, len: CARDINAL);
VAR r: NSRangeR;
BEGIN r := srr(me, ObjC.Selector("selectedRange")); loc := r.location; len := r.length END Sel;

PROCEDURE Replace (me: ObjC.Id; loc, len: CARDINAL; s: ARRAY OF CHAR);
VAR ns, store: ObjC.Id;
BEGIN
  ns := ObjC.NSString(s);
  IF schg(me, ObjC.Selector("shouldChangeTextInRange:replacementString:"), loc, len, ns) THEN
    store := s0(me, ObjC.Selector("textStorage"));
    ig := srepl(store, ObjC.Selector("replaceCharactersInRange:withString:"), loc, len, ns);
    ig := s0(me, ObjC.Selector("didChangeText"))
  END
END Replace;

PROCEDURE LineSpan (VAR buf: ARRAY OF CHAR; total, loc, len: CARDINAL; VAR ls, le: CARDINAL);
VAR endPos: CARDINAL;                            (* last selected char (or the cursor) *)
BEGIN
  ls := loc; WHILE (ls > 0) AND (buf[ls-1] # CHR(10)) DO DEC(ls) END;
  endPos := loc + len; IF len > 0 THEN endPos := loc + len - 1 END;
  le := endPos; WHILE (le < total) AND (buf[le] # CHR(10)) DO INC(le) END;
  IF le < total THEN INC(le) END                 (* include the line's trailing newline *)
END LineSpan;

(* an NSTextView that auto-indents (Enter copies the line's leading whitespace) and
   adds standard code-editor commands: Tab/Shift-Tab indent, Cmd-/ comment toggle *)
CLASS RopeTextView;
  <* cocoa "NSTextView" *>
  PROCEDURE InsertNewline (sender: ObjC.Id) <* selector "insertNewline:" *>;
  VAR loc, ls, i, k: CARDINAL; buf: ARRAY [0..262143] OF CHAR; ins: ARRAY [0..255] OF CHAR; me: ObjC.Id;
  BEGIN
    me := CAST(ObjC.Id, SELF);
    loc := s0i(me, ObjC.Selector("selectedRange"));     (* NSRange.location is returned in x0 *)
    ObjC.GetString(s0(me, ObjC.Selector("string")), buf);
    ls := loc;
    WHILE (ls > 0) AND (buf[ls-1] # CHR(10)) DO DEC(ls) END;
    ins[0] := CHR(10); k := 1; i := ls;
    WHILE (i < loc) AND ((buf[i] = ' ') OR (buf[i] = CHR(9))) AND (k < 254) DO
      ins[k] := buf[i]; INC(k); INC(i)
    END;
    ins[k] := CHR(0);
    ig := sp(me, ObjC.Selector("insertText:"), ObjC.NSString(ins))
  END InsertNewline;

  (* Tab: indent the selected lines by 2 spaces; with no selection, a soft tab *)
  PROCEDURE InsertTab (sender: ObjC.Id) <* selector "insertTab:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, i, k: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    IF len = 0 THEN
      Replace(me, loc, 0, "  "); ig := ssr(me, ObjC.Selector("setSelectedRange:"), loc+2, 0); RETURN
    END;
    ObjC.GetString(s0(me, ObjC.Selector("string")), gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    k := 0; gEdOut[k] := ' '; INC(k); gEdOut[k] := ' '; INC(k);
    i := ls;
    WHILE i < le DO
      gEdOut[k] := gEdBuf[i]; INC(k);
      IF (gEdBuf[i] = CHR(10)) AND (i+1 < le) THEN gEdOut[k] := ' '; INC(k); gEdOut[k] := ' '; INC(k) END;
      INC(i)
    END;
    gEdOut[k] := CHR(0);
    Replace(me, ls, le-ls, gEdOut); ig := ssr(me, ObjC.Selector("setSelectedRange:"), ls, k)
  END InsertTab;

  (* Shift-Tab: outdent the selected lines (drop up to 2 leading spaces / 1 tab) *)
  PROCEDURE InsertBacktab (sender: ObjC.Id) <* selector "insertBacktab:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, i, k, nsp: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString(s0(me, ObjC.Selector("string")), gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    k := 0; i := ls;
    WHILE i < le DO
      nsp := 0;
      WHILE (i < le) AND (nsp < 2) AND (gEdBuf[i] = ' ') DO INC(i); INC(nsp) END;
      IF (nsp = 0) AND (i < le) AND (gEdBuf[i] = CHR(9)) THEN INC(i) END;
      WHILE (i < le) AND (gEdBuf[i] # CHR(10)) DO gEdOut[k] := gEdBuf[i]; INC(k); INC(i) END;
      IF (i < le) AND (gEdBuf[i] = CHR(10)) THEN gEdOut[k] := CHR(10); INC(k); INC(i) END
    END;
    gEdOut[k] := CHR(0);
    Replace(me, ls, le-ls, gEdOut); ig := ssr(me, ObjC.Selector("setSelectedRange:"), ls, k)
  END InsertBacktab;

  (* Cmd-/: toggle an (* … *) comment around the selected lines *)
  PROCEDURE ToggleComment (sender: ObjC.Id) <* selector "toggleComment:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, a, b, i, k: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString(s0(me, ObjC.Selector("string")), gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    IF (le > ls) AND (gEdBuf[le-1] = CHR(10)) THEN DEC(le) END;     (* exclude trailing newline *)
    k := 0;
    IF (le-ls >= 4) AND (gEdBuf[ls]='(') AND (gEdBuf[ls+1]='*')
       AND (gEdBuf[le-2]='*') AND (gEdBuf[le-1]=')') THEN
      a := ls+2; b := le-2;                                          (* already commented -> unwrap *)
      IF (a < b) AND (gEdBuf[a] = ' ') THEN INC(a) END;
      IF (a < b) AND (gEdBuf[b-1] = ' ') THEN DEC(b) END;
      i := a; WHILE i < b DO gEdOut[k] := gEdBuf[i]; INC(k); INC(i) END
    ELSE
      gEdOut[k]:='('; INC(k); gEdOut[k]:='*'; INC(k); gEdOut[k]:=' '; INC(k);   (* wrap *)
      i := ls; WHILE i < le DO gEdOut[k] := gEdBuf[i]; INC(k); INC(i) END;
      gEdOut[k]:=' '; INC(k); gEdOut[k]:='*'; INC(k); gEdOut[k]:=')'; INC(k)
    END;
    gEdOut[k] := CHR(0);
    Replace(me, ls, le-ls, gEdOut); ig := ssr(me, ObjC.Selector("setSelectedRange:"), ls, k)
  END ToggleComment;

  (* Cmd-L: select the current line(s) *)
  PROCEDURE SelectLine (sender: ObjC.Id) <* selector "selectLine:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString(s0(me, ObjC.Selector("string")), gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    ig := ssr(me, ObjC.Selector("setSelectedRange:"), ls, le-ls)
  END SelectLine;

  (* Cmd-Shift-D: duplicate the current line(s) below *)
  PROCEDURE DuplicateLine (sender: ObjC.Id) <* selector "duplicateLine:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, i, k: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString(s0(me, ObjC.Selector("string")), gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    k := 0;
    IF NOT ((le > ls) AND (gEdBuf[le-1] = CHR(10))) THEN gEdOut[k] := CHR(10); INC(k) END;  (* last line: add nl *)
    i := ls; WHILE i < le DO gEdOut[k] := gEdBuf[i]; INC(k); INC(i) END;
    gEdOut[k] := CHR(0);
    Replace(me, le, 0, gEdOut); ig := ssr(me, ObjC.Selector("setSelectedRange:"), le, 0)
  END DuplicateLine;

  (* Cmd-Shift-K: delete the current line(s) *)
  PROCEDURE DeleteLine (sender: ObjC.Id) <* selector "deleteLine:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString(s0(me, ObjC.Selector("string")), gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    Replace(me, ls, le-ls, ""); ig := ssr(me, ObjC.Selector("setSelectedRange:"), ls, 0)
  END DeleteLine;

  (* Opt-Cmd-Up: swap the current line with the one above *)
  PROCEDURE MoveLineUp (sender: ObjC.Id) <* selector "moveLineUp:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, pls, ce, i, k: CARDINAL; endNl: BOOLEAN;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString(s0(me, ObjC.Selector("string")), gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    IF ls = 0 THEN RETURN END;
    pls := ls-1; WHILE (pls > 0) AND (gEdBuf[pls-1] # CHR(10)) DO DEC(pls) END;
    endNl := (le > ls) AND (gEdBuf[le-1] = CHR(10)); ce := le; IF endNl THEN DEC(ce) END;
    k := 0;
    i := ls;  WHILE i < ce    DO gEdOut[k] := gEdBuf[i]; INC(k); INC(i) END;  (* current content *)
    gEdOut[k] := CHR(10); INC(k);
    i := pls; WHILE i < ls-1  DO gEdOut[k] := gEdBuf[i]; INC(k); INC(i) END;  (* previous content *)
    IF endNl THEN gEdOut[k] := CHR(10); INC(k) END;
    gEdOut[k] := CHR(0);
    Replace(me, pls, le-pls, gEdOut); ig := ssr(me, ObjC.Selector("setSelectedRange:"), pls, ce-ls)
  END MoveLineUp;

  (* Opt-Cmd-Down: swap the current line with the one below *)
  PROCEDURE MoveLineDown (sender: ObjC.Id) <* selector "moveLineDown:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, ne, nce, i, k: CARDINAL; endNl: BOOLEAN;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString(s0(me, ObjC.Selector("string")), gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    IF le >= total THEN RETURN END;                                  (* current is the last line *)
    ne := le; WHILE (ne < total) AND (gEdBuf[ne] # CHR(10)) DO INC(ne) END;
    IF ne < total THEN INC(ne) END;                                  (* include next line's newline *)
    endNl := (ne > le) AND (gEdBuf[ne-1] = CHR(10)); nce := ne; IF endNl THEN DEC(nce) END;
    k := 0;
    i := le; WHILE i < nce   DO gEdOut[k] := gEdBuf[i]; INC(k); INC(i) END;  (* next content *)
    gEdOut[k] := CHR(10); INC(k);
    i := ls; WHILE i < le-1  DO gEdOut[k] := gEdBuf[i]; INC(k); INC(i) END;  (* current content *)
    IF endNl THEN gEdOut[k] := CHR(10); INC(k) END;
    gEdOut[k] := CHR(0);
    Replace(me, ls, ne-ls, gEdOut);
    ig := ssr(me, ObjC.Selector("setSelectedRange:"), ls + (nce-le) + 1, (le-1)-ls)
  END MoveLineDown;
END RopeTextView;

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
  gNewRuns := NewRuns(); gScratch := NewRuns();
  gInited := TRUE
END EnsureInit;

PROCEDURE Make (x, y, w, h: REAL): ObjC.Id;
VAR store: RopeStore; tv: RopeTextView; sid, tvId, lm, scroll: ObjC.Id;
BEGIN
  EnsureInit;
  NEW(store); store.Setup; sid := CAST(ObjC.Id, store);
  NEW(tv); tvId := CAST(ObjC.Id, tv);                  (* an auto-indenting text view *)
  lm := s0(tvId, ObjC.Selector("layoutManager"));
  ig := sb(lm, ObjC.Selector("setAllowsNonContiguousLayout:"), TRUE);
  ig := sp(lm, ObjC.Selector("replaceTextStorage:"), sid);   (* render the rope store *)
  ig := sf(tvId, ObjC.Selector("setFrame:"), 0.0, 0.0, w, h);
  ig := sb(tvId, ObjC.Selector("setVerticallyResizable:"), TRUE);
  ig := sb(tvId, ObjC.Selector("setHorizontallyResizable:"), FALSE);
  ig := si(tvId, ObjC.Selector("setAutoresizingMask:"), 2);   (* width sizable *)
  ig := sb(s0(tvId, ObjC.Selector("textContainer")), ObjC.Selector("setWidthTracksTextView:"), TRUE);
  scroll := s0(ObjC.GetClass("NSScrollView"), ObjC.Selector("alloc"));
  scroll := sf(scroll, ObjC.Selector("initWithFrame:"), x, y, w, h);
  ig := sb(scroll, ObjC.Selector("setHasVerticalScroller:"), TRUE);
  ig := sp(scroll, ObjC.Selector("setDocumentView:"), tvId);
  ObjC.LineNumbers(scroll);                          (* line-number ruler *)
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
  srr := CAST(SendRRet,       ObjC.MsgSendPtr());
  ssr := CAST(SendSetR,       ObjC.MsgSendPtr());
  schg := CAST(SendChg,       ObjC.MsgSendPtr());
  srepl := CAST(SendRepl,     ObjC.MsgSendPtr());
  gInited := FALSE
END RopeEditor.
