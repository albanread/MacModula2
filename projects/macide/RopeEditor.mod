IMPLEMENTATION MODULE RopeEditor;
(* The rope-backed text store (RopeStore : NSTextStorage, RopeString : NSString)
   + a small M2 lexer + incremental re-lex, wrapped as a reusable editor factory.
   See docs/design/mac-text-store.md and macos_textstore.mod (the staged proof). *)
FROM SYSTEM IMPORT CAST, ADDRESS, TSIZE;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM Strings IMPORT Equal, Length, Assign;
IMPORT ObjC;
IMPORT TextRope;

CONST
  kDefault = 0; kKeyword = 1; kComment = 2; kString = 3; kNumber = 4; kKinds = 5;
  (* theme palette slots: background, caret, selection, then the 5 token classes *)
  sBg = 0; sCaret = 1; sSel = 2; sDef = 3; sKw = 4; sCom = 5; sStr = 6; sNum = 7; nSlots = 8;

TYPE
  PRopeBox = POINTER TO RECORD r: TextRope.Rope END;
  PNSRange = POINTER TO RECORD location, length: CARDINAL END;
  PWide    = POINTER TO ARRAY [0..16777215] OF CHAR;
  Run      = RECORD len: CARDINAL; kind: INTEGER END;
  PRunArr  = POINTER TO ARRAY [0..16777215] OF Run;   (* overlay on a heap block *)
  PRuns    = POINTER TO RECORD count, cap: CARDINAL; a: PRunArr END;  (* growable run vector *)

(* All Cocoa calls use the [recv sel: args] message-send syntax, with Range()/Rect()
   building the struct arguments (NSRange / NSRect) — no hand-cast send machinery. *)
VAR
  font: ObjC.Id;
  gKind: ARRAY [0..kKinds-1] OF ObjC.Id;
  gEdBuf, gEdOut: ARRAY [0..262143] OF CHAR;       (* scratch for indent/comment ops *)
  gNewRuns, gScratch: PRuns;
  gInited: BOOLEAN;
  gHoverProc: HoverProc;        (* hover callback: char index under the pointer *)
  gHoverSet: BOOLEAN;
  gPal: ARRAY [0..255] OF REAL;  (* flat RGB palette: [(theme*nSlots+slot)*3 + {r,g,b}], needs 120 *)
  gThemeId: CARDINAL;           (* the active theme *)

(* NSRange / NSRect values for struct-typed send args (selectedRange, edited:range:,
   setFrame:); the send returns NSRange as a real struct too — see Sel below. *)
PROCEDURE Range (loc, len: CARDINAL): ObjC.NSRange;
VAR r: ObjC.NSRange;
BEGIN r.location := loc; r.length := len; RETURN r END Range;

PROCEDURE Rect (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rect;

PROCEDURE Cls (name: ARRAY OF CHAR): ObjC.Id;   (* class object as a send receiver *)
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(name)) END Cls;

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
    inserted := [s length];
    box^.r := TextRope.DeleteRange(box^.r, loc, len);
    ObjC.GetString(s, text);
    IF text[0] # CHR(0) THEN box^.r := TextRope.Insert(box^.r, loc, text) END;
    SELF.RelexEdit(loc, len, inserted);
    [CAST(ObjC.Id, SELF) edited: 3
                         range: Range(loc, len)
                         changeInLength: VAL(INTEGER, inserted) - VAL(INTEGER, len)]
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
VAR r: ObjC.NSRange;                       (* a struct return — NSRange in x0/x1 *)
BEGIN r := [me selectedRange]; loc := r.location; len := r.length END Sel;

PROCEDURE Replace (me: ObjC.Id; loc, len: CARDINAL; s: ARRAY OF CHAR);
VAR ns, store: ObjC.Id;
BEGIN
  ns := ObjC.NSString(s);
  IF [me shouldChangeTextInRange: Range(loc, len) replacementString: ns] THEN
    store := [me textStorage];
    [store replaceCharactersInRange: Range(loc, len) withString: ns];
    [me didChangeText]
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
    loc := [me selectedRange].location;     (* NSRange.location is returned in x0 *)
    ObjC.GetString([me string], buf);
    ls := loc;
    WHILE (ls > 0) AND (buf[ls-1] # CHR(10)) DO DEC(ls) END;
    ins[0] := CHR(10); k := 1; i := ls;
    WHILE (i < loc) AND ((buf[i] = ' ') OR (buf[i] = CHR(9))) AND (k < 254) DO
      ins[k] := buf[i]; INC(k); INC(i)
    END;
    ins[k] := CHR(0);
    [me insertText: ObjC.NSString(ins)]
  END InsertNewline;

  (* Tab: indent the selected lines by 2 spaces; with no selection, a soft tab *)
  PROCEDURE InsertTab (sender: ObjC.Id) <* selector "insertTab:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, i, k: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    IF len = 0 THEN
      Replace(me, loc, 0, "  "); [me setSelectedRange: Range(loc+2, 0)]; RETURN
    END;
    ObjC.GetString([me string], gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    k := 0; gEdOut[k] := ' '; INC(k); gEdOut[k] := ' '; INC(k);
    i := ls;
    WHILE i < le DO
      gEdOut[k] := gEdBuf[i]; INC(k);
      IF (gEdBuf[i] = CHR(10)) AND (i+1 < le) THEN gEdOut[k] := ' '; INC(k); gEdOut[k] := ' '; INC(k) END;
      INC(i)
    END;
    gEdOut[k] := CHR(0);
    Replace(me, ls, le-ls, gEdOut); [me setSelectedRange: Range(ls, k)]
  END InsertTab;

  (* Shift-Tab: outdent the selected lines (drop up to 2 leading spaces / 1 tab) *)
  PROCEDURE InsertBacktab (sender: ObjC.Id) <* selector "insertBacktab:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, i, k, nsp: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString([me string], gEdBuf); total := Length(gEdBuf);
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
    Replace(me, ls, le-ls, gEdOut); [me setSelectedRange: Range(ls, k)]
  END InsertBacktab;

  (* Cmd-/: toggle an (* … *) comment around the selected lines *)
  PROCEDURE ToggleComment (sender: ObjC.Id) <* selector "toggleComment:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, a, b, i, k: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString([me string], gEdBuf); total := Length(gEdBuf);
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
    Replace(me, ls, le-ls, gEdOut); [me setSelectedRange: Range(ls, k)]
  END ToggleComment;

  (* Cmd-L: select the current line(s) *)
  PROCEDURE SelectLine (sender: ObjC.Id) <* selector "selectLine:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString([me string], gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    [me setSelectedRange: Range(ls, le-ls)]
  END SelectLine;

  (* Cmd-Shift-D: duplicate the current line(s) below *)
  PROCEDURE DuplicateLine (sender: ObjC.Id) <* selector "duplicateLine:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, i, k: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString([me string], gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    k := 0;
    IF NOT ((le > ls) AND (gEdBuf[le-1] = CHR(10))) THEN gEdOut[k] := CHR(10); INC(k) END;  (* last line: add nl *)
    i := ls; WHILE i < le DO gEdOut[k] := gEdBuf[i]; INC(k); INC(i) END;
    gEdOut[k] := CHR(0);
    Replace(me, le, 0, gEdOut); [me setSelectedRange: Range(le, 0)]
  END DuplicateLine;

  (* Cmd-Shift-K: delete the current line(s) *)
  PROCEDURE DeleteLine (sender: ObjC.Id) <* selector "deleteLine:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total: CARDINAL;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString([me string], gEdBuf); total := Length(gEdBuf);
    LineSpan(gEdBuf, total, loc, len, ls, le);
    Replace(me, ls, le-ls, ""); [me setSelectedRange: Range(ls, 0)]
  END DeleteLine;

  (* Opt-Cmd-Up: swap the current line with the one above *)
  PROCEDURE MoveLineUp (sender: ObjC.Id) <* selector "moveLineUp:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, pls, ce, i, k: CARDINAL; endNl: BOOLEAN;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString([me string], gEdBuf); total := Length(gEdBuf);
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
    Replace(me, pls, le-pls, gEdOut); [me setSelectedRange: Range(pls, ce-ls)]
  END MoveLineUp;

  (* Opt-Cmd-Down: swap the current line with the one below *)
  PROCEDURE MoveLineDown (sender: ObjC.Id) <* selector "moveLineDown:" *>;
  VAR me: ObjC.Id; loc, len, ls, le, total, ne, nce, i, k: CARDINAL; endNl: BOOLEAN;
  BEGIN
    me := CAST(ObjC.Id, SELF); Sel(me, loc, len);
    ObjC.GetString([me string], gEdBuf); total := Length(gEdBuf);
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
    [me setSelectedRange: Range(ls + (nce-le) + 1, (le-1)-ls)]
  END MoveLineDown;

  (* The range that a completion REPLACES.  AppKit's default treats `foo.bar` as a
     single word and so overtypes the receiver `foo.` when you accept a member —
     wrong for code completion.  We restrict it to the identifier fragment that
     ends at the insertion point, stopping at the first non-identifier char (the
     '.').  Right after a '.', that fragment is empty, so the chosen member is
     inserted AFTER the dot; once you have typed a few letters it replaces just
     those letters.  Returning NSRange by value is ABI-safe — a 16-byte record
     comes back in x0/x1, which is exactly what -rangeForUserCompletion expects. *)
  (* Hover: report the character index under the pointer to the registered hover
     callback. Cheap (one hit-test); the IDE debounces and describes on dwell. *)
  PROCEDURE MouseMoved (ev: ObjC.Id) <* selector "mouseMoved:" *>;
  VAR me: ObjC.Id; p: ObjC.NSPoint; idx: CARDINAL;
  BEGIN
    IF gHoverSet THEN
      me  := CAST(ObjC.Id, SELF);
      p   := [ev locationInWindow];
      p   := [me convertPoint: p fromView: NIL];
      idx := [me characterIndexForInsertionAtPoint: p];
      gHoverProc(idx)
    END
  END MouseMoved;
  PROCEDURE RangeForCompletion (): ObjC.NSRange <* selector "rangeForUserCompletion" *>;
  VAR me, s: ObjC.Id; r: ObjC.NSRange; ip, start, ch: CARDINAL; stop: BOOLEAN;
  BEGIN
    me := CAST(ObjC.Id, SELF);
    r  := [me selectedRange];
    ip := r.location + r.length;            (* the insertion point *)
    s  := [me string];
    start := ip; stop := FALSE;
    WHILE (start > 0) AND (NOT stop) DO
      ch := [s characterAtIndex: start - 1];
      IF ((ch >= 65) AND (ch <= 90))        (* A..Z *)
         OR ((ch >= 97) AND (ch <= 122))    (* a..z *)
         OR ((ch >= 48) AND (ch <= 57))     (* 0..9 *)
         OR (ch = 95)                       (* _    *)
      THEN DEC(start) ELSE stop := TRUE END
    END;
    r.location := start; r.length := ip - start;
    RETURN r
  END RangeForCompletion;
END RopeTextView;

PROCEDURE SetHoverProc (p: HoverProc);
BEGIN gHoverProc := p; gHoverSet := TRUE END SetHoverProc;

PROCEDURE MakeAttrs (r, g, b: REAL): ObjC.Id;
VAR d, color: ObjC.Id;
BEGIN
  d := [[Cls("NSMutableDictionary") alloc] init];
  [d setObject: font forKey: ObjC.NSString("NSFont")];
  color := [Cls("NSColor") colorWithCalibratedRed: r green: g blue: b alpha: 1.0];
  [d setObject: color forKey: ObjC.NSString("NSColor")];
  RETURN d
END MakeAttrs;

(* ---- colour themes ----------------------------------------------------
   The palette is a FLAT REAL array (gPal), addressed [(theme*nSlots+slot)*3 + rgb].
   This deliberately avoids record value-parameters AND VAR parameters bound to a
   nested field of a global array element — both miscompile in this codegen and
   silently corrupt adjacent globals. (A VAR-to-gThemes[i].field write clobbered
   gKind; the store then handed the layout manager the stray double 0.5 instead of
   an attributes dictionary, and objc_msgSend(0.5) segfaulted.) Flat indexed
   reads/writes are the safe path. *)
PROCEDURE PalBase (theme, slot: CARDINAL): CARDINAL;
BEGIN RETURN (theme*nSlots + slot) * 3 END PalBase;

PROCEDURE SetPal (theme, slot: CARDINAL; r, g, b: REAL);
VAR k: CARDINAL;
BEGIN k := PalBase(theme, slot); gPal[k] := r; gPal[k+1] := g; gPal[k+2] := b END SetPal;

PROCEDURE ColorAt (theme, slot: CARDINAL): ObjC.Id;
VAR k: CARDINAL; c: ObjC.Id;
BEGIN
  k := PalBase(theme, slot);                         (* store-then-return: never RETURN a float-arg call directly *)
  c := [Cls("NSColor") colorWithCalibratedRed: gPal[k] green: gPal[k+1] blue: gPal[k+2] alpha: 1.0];
  RETURN c
END ColorAt;


PROCEDURE SetupThemes;
BEGIN
  (*       theme          slot      r     g     b *)
  SetPal(themeDefault, sBg,  1.0,1.0,1.0 );  SetPal(themeDefault, sCaret, 0.0,0.0,0.0 );  SetPal(themeDefault, sSel, 0.70,0.80,1.0);
  SetPal(themeDefault, sDef, 0.0,0.0,0.0 );  SetPal(themeDefault, sKw,  0.15,0.15,0.8 );  SetPal(themeDefault, sCom, 0.0,0.5,0.0);
  SetPal(themeDefault, sStr, 0.6,0.1,0.1 );  SetPal(themeDefault, sNum, 0.5,0.0,0.5);
  SetPal(themeMono, sBg, 0.98,0.98,0.96);    SetPal(themeMono, sCaret, 0.1,0.1,0.1);      SetPal(themeMono, sSel, 0.80,0.80,0.80);
  SetPal(themeMono, sDef, 0.12,0.12,0.12);   SetPal(themeMono, sKw, 0.0,0.0,0.0);         SetPal(themeMono, sCom, 0.5,0.5,0.5);
  SetPal(themeMono, sStr, 0.32,0.32,0.32);   SetPal(themeMono, sNum, 0.2,0.2,0.2);
  SetPal(themeAmber, sBg, 0.06,0.04,0.0);    SetPal(themeAmber, sCaret, 1.0,0.72,0.0);    SetPal(themeAmber, sSel, 0.40,0.26,0.0);
  SetPal(themeAmber, sDef, 1.0,0.69,0.0);    SetPal(themeAmber, sKw, 1.0,0.85,0.30);      SetPal(themeAmber, sCom, 0.62,0.42,0.0);
  SetPal(themeAmber, sStr, 1.0,0.78,0.35);   SetPal(themeAmber, sNum, 1.0,0.88,0.5);
  SetPal(themeGreen, sBg, 0.0,0.04,0.0);     SetPal(themeGreen, sCaret, 0.3,1.0,0.3);     SetPal(themeGreen, sSel, 0.0,0.40,0.0);
  SetPal(themeGreen, sDef, 0.25,1.0,0.25);   SetPal(themeGreen, sKw, 0.60,1.0,0.60);      SetPal(themeGreen, sCom, 0.0,0.55,0.0);
  SetPal(themeGreen, sStr, 0.45,1.0,0.6);    SetPal(themeGreen, sNum, 0.7,1.0,0.4);
  SetPal(themeTurbo, sBg, 0.0,0.0,0.66);     SetPal(themeTurbo, sCaret, 1.0,1.0,0.4);     SetPal(themeTurbo, sSel, 0.0,0.55,0.55);
  SetPal(themeTurbo, sDef, 1.0,1.0,0.45);    SetPal(themeTurbo, sKw, 1.0,1.0,1.0);        SetPal(themeTurbo, sCom, 0.55,0.55,0.6);
  SetPal(themeTurbo, sStr, 0.45,1.0,1.0);    SetPal(themeTurbo, sNum, 0.5,1.0,0.7)
END SetupThemes;

PROCEDURE ApplyKinds (id: CARDINAL);   (* rebuild the token attribute dicts from theme `id` *)
VAR b: CARDINAL;
BEGIN
  b := id * (nSlots*3);              (* base of theme `id` in gPal *)
  gKind[kDefault] := MakeAttrs(gPal[b+ sDef*3], gPal[b+ sDef*3+1], gPal[b+ sDef*3+2]);
  gKind[kKeyword] := MakeAttrs(gPal[b+ sKw*3],  gPal[b+ sKw*3+1],  gPal[b+ sKw*3+2]);
  gKind[kComment] := MakeAttrs(gPal[b+ sCom*3], gPal[b+ sCom*3+1], gPal[b+ sCom*3+2]);
  gKind[kString]  := MakeAttrs(gPal[b+ sStr*3], gPal[b+ sStr*3+1], gPal[b+ sStr*3+2]);
  gKind[kNumber]  := MakeAttrs(gPal[b+ sNum*3], gPal[b+ sNum*3+1], gPal[b+ sNum*3+2])
END ApplyKinds;

PROCEDURE ApplyViewColors (tv: ObjC.Id; id: CARDINAL);   (* background / caret / selection *)
VAR selAttr: ObjC.Id;
BEGIN
  [tv setDrawsBackground: TRUE];
  [tv setBackgroundColor: ColorAt(id, sBg)];
  [tv setInsertionPointColor: ColorAt(id, sCaret)];
  selAttr := [[Cls("NSMutableDictionary") alloc] init];
  [selAttr setObject: ColorAt(id, sSel) forKey: ObjC.NSString("NSBackgroundColor")];
  [tv setSelectedTextAttributes: selAttr]
END ApplyViewColors;

PROCEDURE Recolor (tv: ObjC.Id);   (* force the layout manager to refetch attributes from gKind *)
VAR store: ObjC.Id; len: CARDINAL;
BEGIN
  store := [tv textStorage]; len := [store length];
  IF len > 0 THEN [store edited: 1 range: Range(0, len) changeInLength: 0] END;  (* NSTextStorageEditedAttributes *)
  [tv setNeedsDisplay: TRUE]
END Recolor;

PROCEDURE ApplyTheme (editor: ObjC.Id);   (* editor = an NSScrollView from Make *)
VAR tv: ObjC.Id;
BEGIN
  tv := [editor documentView];
  ApplyViewColors(tv, gThemeId); Recolor(tv)
END ApplyTheme;

PROCEDURE SetTheme (id: CARDINAL);
BEGIN
  IF id >= themeCount THEN RETURN END;
  gThemeId := id; ApplyKinds(id)
END SetTheme;

PROCEDURE CurrentTheme (): CARDINAL;
BEGIN RETURN gThemeId END CurrentTheme;

PROCEDURE ThemeName (id: CARDINAL; VAR name: ARRAY OF CHAR);
BEGIN
  CASE id OF
    themeMono:  Assign("Monochrome", name)
  | themeAmber: Assign("Amber CRT", name)
  | themeGreen: Assign("Green CRT", name)
  | themeTurbo: Assign("Turbo Pascal", name)
  ELSE Assign("Default", name) END
END ThemeName;

PROCEDURE EnsureInit;   (* lazy: must run after Cocoa.InitApp, so do it on first Make *)
BEGIN
  IF gInited THEN RETURN END;
  font := [Cls("NSFont") userFixedPitchFontOfSize: 13.0];
  SetupThemes; gThemeId := themeDefault; ApplyKinds(themeDefault);
  gNewRuns := NewRuns(); gScratch := NewRuns();
  gInited := TRUE
END EnsureInit;

PROCEDURE Make (x, y, w, h: REAL): ObjC.Id;
VAR store: RopeStore; tv: RopeTextView; sid, tvId, lm, scroll: ObjC.Id;
BEGIN
  EnsureInit;
  NEW(store); store.Setup; sid := CAST(ObjC.Id, store);
  NEW(tv); tvId := CAST(ObjC.Id, tv);                  (* an auto-indenting text view *)
  lm := [tvId layoutManager];
  [lm setAllowsNonContiguousLayout: TRUE];
  [lm replaceTextStorage: sid];   (* render the rope store *)
  [tvId setFrame: Rect(0.0, 0.0, w, h)];
  [tvId setVerticallyResizable: TRUE];
  [tvId setHorizontallyResizable: FALSE];
  [tvId setAutoresizingMask: 2];   (* width sizable *)
  [[tvId textContainer] setWidthTracksTextView: TRUE];
  scroll := [[Cls("NSScrollView") alloc] initWithFrame: Rect(x, y, w, h)];
  [scroll setHasVerticalScroller: TRUE];
  [scroll setDocumentView: tvId];
  ObjC.LineNumbers(scroll);                          (* line-number ruler *)
  ApplyViewColors(tvId, gThemeId); Recolor(tvId);    (* new editor adopts the active theme *)
  RETURN scroll
END Make;

BEGIN
  gInited := FALSE; gHoverSet := FALSE
END RopeEditor.
