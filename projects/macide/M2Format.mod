IMPLEMENTATION MODULE M2Format;
(* Re-indenter. One pass over the lines, carrying a structural indent `level`, a
   nested-comment depth, a CASE..OF flag, and a "declaration section" flag (a
   TYPE/VAR/CONST header indents its entries until the next section/BEGIN/PROC/END).
   Per line: classify the first significant token (comment/string aware), pick the
   print indent, copy the trimmed content verbatim, then adjust `level` from the
   block keywords on the line. Whitespace-only changes — content is never touched. *)
FROM Strings IMPORT Equal;

CONST
  INDENT = 2;
  (* token kinds we care about *)
  kOther=0; kEnd=1; kUntil=2; kElse=3; kElsif=4; kBar=5;
  kType=6; kVar=7; kConst=8; kBegin=9; kProc=10; kModule=11; kClass=12;
  kThen=13; kDo=14; kOf=15; kCase=16; kLoop=17; kRecord=18; kRepeat=19; kSemi=20;

PROCEDURE IsWS (c: CHAR): BOOLEAN;
BEGIN RETURN (c = ' ') OR (c = CHR(9)) OR (c = CHR(13)) END IsWS;

PROCEDURE IsAlphaCh (c: CHAR): BOOLEAN;
BEGIN RETURN ((c >= 'A') AND (c <= 'Z')) OR ((c >= 'a') AND (c <= 'z')) OR (c = '_') END IsAlphaCh;

PROCEDURE IsDigitCh (c: CHAR): BOOLEAN;
BEGIN RETURN (c >= '0') AND (c <= '9') END IsDigitCh;

PROCEDURE Len (VAR s: ARRAY OF CHAR): CARDINAL;
VAR n: CARDINAL;
BEGIN n := 0; WHILE (n <= HIGH(s)) AND (s[n] # CHR(0)) DO INC(n) END; RETURN n END Len;

PROCEDURE KwKind (VAR w: ARRAY OF CHAR): INTEGER;
BEGIN
  IF    Equal(w,"END")    THEN RETURN kEnd
  ELSIF Equal(w,"UNTIL")  THEN RETURN kUntil
  ELSIF Equal(w,"ELSE")   THEN RETURN kElse
  ELSIF Equal(w,"ELSIF")  THEN RETURN kElsif
  ELSIF Equal(w,"TYPE")   THEN RETURN kType
  ELSIF Equal(w,"VAR")    THEN RETURN kVar
  ELSIF Equal(w,"CONST")  THEN RETURN kConst
  ELSIF Equal(w,"BEGIN")  THEN RETURN kBegin
  ELSIF Equal(w,"PROCEDURE") THEN RETURN kProc
  ELSIF Equal(w,"MODULE") OR Equal(w,"IMPLEMENTATION") OR Equal(w,"DEFINITION") THEN RETURN kModule
  ELSIF Equal(w,"CLASS")  THEN RETURN kClass
  ELSIF Equal(w,"THEN")   THEN RETURN kThen
  ELSIF Equal(w,"DO")     THEN RETURN kDo
  ELSIF Equal(w,"OF")     THEN RETURN kOf
  ELSIF Equal(w,"CASE")   THEN RETURN kCase
  ELSIF Equal(w,"LOOP")   THEN RETURN kLoop
  ELSIF Equal(w,"RECORD") THEN RETURN kRecord
  ELSIF Equal(w,"REPEAT") THEN RETURN kRepeat
  ELSE RETURN kOther END
END KwKind;

(* Scan one line [lineStart,lineEnd), comment/string aware. Updates commentDepth/
   pendingCase across lines; yields the first significant token kind, the net
   structural delta, whether any code token was seen (hasToken), and whether the
   line ends a statement / opens a block (endsStmt — so the next line is fresh,
   not a continuation of this one). *)
PROCEDURE ScanLine (VAR src: ARRAY OF CHAR; lineStart, lineEnd: CARDINAL;
                    VAR commentDepth, parenDepth: INTEGER; VAR pendingCase: BOOLEAN;
                    VAR firstKind, delta: INTEGER; VAR hasToken, endsStmt: BOOLEAN);
VAR i, ws, j, k: CARDINAL; c: CHAR; kind, lastKind: INTEGER;
    inString, firstSet, ignoreThen: BOOLEAN; strq: CHAR; w: ARRAY [0..31] OF CHAR;
BEGIN
  firstKind := kOther; delta := 0; firstSet := FALSE; ignoreThen := FALSE;
  inString := FALSE; strq := ' '; lastKind := kOther;
  i := lineStart;
  WHILE i < lineEnd DO
    c := src[i];
    IF commentDepth > 0 THEN
      IF (c = '(') AND (i+1 < lineEnd) AND (src[i+1] = '*') THEN INC(commentDepth); i := i+2
      ELSIF (c = '*') AND (i+1 < lineEnd) AND (src[i+1] = ')') THEN DEC(commentDepth); i := i+2
      ELSE INC(i) END
    ELSIF inString THEN
      IF c = strq THEN inString := FALSE END; INC(i)
    ELSIF (c = '(') AND (i+1 < lineEnd) AND (src[i+1] = '*') THEN
      INC(commentDepth); i := i+2
    ELSIF (c = '"') OR (c = "'") THEN
      inString := TRUE; strq := c; lastKind := kOther; INC(i)
    ELSIF IsAlphaCh(c) THEN
      ws := i;
      WHILE (i < lineEnd) AND (IsAlphaCh(src[i]) OR IsDigitCh(src[i])) DO INC(i) END;
      k := 0; j := ws;
      WHILE (j < i) AND (k < 31) DO w[k] := src[j]; INC(k); INC(j) END;
      w[k] := CHR(0);
      kind := KwKind(w);
      IF NOT firstSet THEN firstKind := kind; firstSet := TRUE; ignoreThen := (kind = kElsif) END;
      IF kind = kThen THEN
        IF ignoreThen THEN ignoreThen := FALSE ELSE INC(delta) END
      ELSIF kind = kElsif THEN
        ignoreThen := TRUE          (* an ELSIF re-opens the same block; skip its THEN (even mid-line) *)
      ELSIF (kind=kDo) OR (kind=kLoop) OR (kind=kRecord) OR (kind=kBegin) OR (kind=kRepeat) OR (kind=kClass) THEN
        INC(delta)
      ELSIF kind = kOf THEN
        IF pendingCase THEN INC(delta); pendingCase := FALSE END
      ELSIF kind = kCase THEN
        pendingCase := TRUE
      ELSIF (kind=kEnd) OR (kind=kUntil) THEN
        DEC(delta)
      END;
      lastKind := kind
    ELSE
      IF NOT IsWS(c) THEN
        IF NOT firstSet THEN
          IF c = '|' THEN firstKind := kBar ELSE firstKind := kOther END;
          firstSet := TRUE
        END;
        IF c = '(' THEN INC(parenDepth)
        ELSIF c = ')' THEN IF parenDepth > 0 THEN DEC(parenDepth) END
        END;
        IF c = ';' THEN lastKind := kSemi
        ELSIF c = '|' THEN lastKind := kBar
        ELSE lastKind := kOther END
      END;
      INC(i)
    END
  END;
  hasToken := firstSet;
  (* a line ends a statement only at paren depth 0; a ';' between ( ) is a
     parameter separator, so the next line is a continuation, not a new line. *)
  endsStmt := (parenDepth = 0) AND
              ( (lastKind=kSemi) OR (lastKind=kBar) OR (lastKind=kThen) OR (lastKind=kDo)
                OR (lastKind=kOf) OR (lastKind=kBegin) OR (lastKind=kElse) OR (lastKind=kLoop)
                OR (lastKind=kRepeat) OR (lastKind=kRecord) OR (lastKind=kEnd) OR (lastKind=kUntil)
                OR (lastKind=kCase) )
END ScanLine;

PROCEDURE Format (VAR src, out: ARRAY OF CHAR): BOOLEAN;
VAR srcLen, i, lineStart, lineEnd, cs, ce, o, j: CARDINAL;
    level, delta, commentDepth, parenDepth, printLevel, fk, ind, kk: INTEGER;
    pendingCase, declActive, startedInComment, hasNL, hasToken, endsStmt,
    prevEndsStmt, isCont, commentOnly: BOOLEAN;
BEGIN
  srcLen := Len(src);
  level := 0; commentDepth := 0; parenDepth := 0; pendingCase := FALSE; declActive := FALSE; prevEndsStmt := TRUE;
  o := 0; i := 0;
  WHILE i < srcLen DO
    lineStart := i;
    lineEnd := i;
    WHILE (lineEnd < srcLen) AND (src[lineEnd] # CHR(10)) DO INC(lineEnd) END;
    hasNL := lineEnd < srcLen;
    startedInComment := commentDepth > 0;
    ScanLine(src, lineStart, lineEnd, commentDepth, parenDepth, pendingCase, fk, delta, hasToken, endsStmt);
    (* first non-ws .. last non-ws (+1) of the line *)
    cs := lineStart; WHILE (cs < lineEnd) AND IsWS(src[cs]) DO INC(cs) END;
    ce := lineEnd;   WHILE (ce > lineStart) AND IsWS(src[ce-1]) DO DEC(ce) END;
    (* a non-blank line with no code token is a pure comment line; a kOther line
       whose predecessor did not finish its statement is a continuation. Both keep
       their original indentation — we only re-indent lines that lead a statement. *)
    commentOnly := (NOT startedInComment) AND (cs < ce) AND (NOT hasToken);
    isCont := (NOT startedInComment) AND (cs < ce) AND hasToken AND (NOT prevEndsStmt) AND (fk = kOther);

    IF cs >= ce THEN
      (* blank line: just the newline below; statement state carries across *)
    ELSIF startedInComment OR commentOnly OR isCont THEN
      j := lineStart;                                  (* preserve original indentation *)
      WHILE j < ce DO
        IF o >= HIGH(out) THEN out[HIGH(out)] := CHR(0); RETURN FALSE END;
        out[o] := src[j]; INC(o); INC(j)
      END;
      IF isCont THEN
        level := level + delta; IF level < 0 THEN level := 0 END;
        prevEndsStmt := endsStmt
      END
    ELSE
      (* leading code line: rebuild the indentation from block nesting.
         A TYPE/VAR/CONST section is closed by the next section header / body start;
         NOT by END (an END closing a RECORD inside the section dedents via its own
         -1, and the section continues — so kEnd must not pop the section here). *)
      IF declActive AND ((fk=kType) OR (fk=kVar) OR (fk=kConst) OR (fk=kBegin)
                         OR (fk=kProc) OR (fk=kModule) OR (fk=kClass)) THEN
        IF level > 0 THEN DEC(level) END; declActive := FALSE
      END;
      IF (fk=kEnd) OR (fk=kUntil) OR (fk=kElse) OR (fk=kElsif) OR (fk=kBar) THEN
        printLevel := level - 1
      ELSE
        printLevel := level
      END;
      IF printLevel < 0 THEN printLevel := 0 END;
      ind := printLevel * INDENT;
      kk := 0;
      WHILE kk < ind DO
        IF o >= HIGH(out) THEN out[HIGH(out)] := CHR(0); RETURN FALSE END;
        out[o] := ' '; INC(o); INC(kk)
      END;
      j := cs;
      WHILE j < ce DO
        IF o >= HIGH(out) THEN out[HIGH(out)] := CHR(0); RETURN FALSE END;
        out[o] := src[j]; INC(o); INC(j)
      END;
      level := level + delta; IF level < 0 THEN level := 0 END;
      IF (fk=kType) OR (fk=kVar) OR (fk=kConst) THEN declActive := TRUE; INC(level) END;
      prevEndsStmt := endsStmt
    END;

    IF hasNL THEN
      IF o >= HIGH(out) THEN out[HIGH(out)] := CHR(0); RETURN FALSE END;
      out[o] := CHR(10); INC(o);
      i := lineEnd + 1
    ELSE
      i := lineEnd
    END
  END;
  IF o > HIGH(out) THEN o := HIGH(out) END;
  out[o] := CHR(0);
  RETURN TRUE
END Format;

END M2Format.
