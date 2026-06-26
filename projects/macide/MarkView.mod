IMPLEMENTATION MODULE MarkView;

FROM SYSTEM IMPORT CAST;
IMPORT ObjC;

VAR
  gInited: BOOLEAN;
  fBody, fBold, fItalic, fMono, fH1, fH2, fH3: ObjC.Id;  (* fonts *)
  aBody, aBold, aItalic, aH1, aH2, aH3, aCode, aBullet, aRule: ObjC.Id;   (* attribute dicts *)
  cLink: ObjC.Id;                                        (* link foreground colour (reused per link) *)
  gNL, gBullet, gRule: ARRAY [0..63] OF CHAR;

PROCEDURE Cls (name: ARRAY OF CHAR): ObjC.Id;            (* class object as a send receiver *)
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(name)) END Cls;

PROCEDURE Range (loc, len: CARDINAL): ObjC.NSRange;
VAR r: ObjC.NSRange;
BEGIN r.location := loc; r.length := len; RETURN r END Range;

PROCEDURE MkColor (r, g, b: REAL): ObjC.Id;
BEGIN RETURN [Cls("NSColor") colorWithCalibratedRed: r green: g blue: b alpha: 1.0] END MkColor;

(* an NSMutableDictionary carrying a font + foreground colour (the attribute keys
   are the literal AppKit attribute-name strings: "NSFont"/"NSColor"). *)
PROCEDURE MkAttr (font, color: ObjC.Id): ObjC.Id;
VAR d: ObjC.Id;
BEGIN
  d := [[Cls("NSMutableDictionary") alloc] init];
  [d setObject: font forKey: ObjC.NSString("NSFont")];
  [d setObject: color forKey: ObjC.NSString("NSColor")];
  RETURN d
END MkAttr;

(* a fresh link-attribute dict for `tgt` (the NSLink value the click handler reads) *)
PROCEDURE LinkAttrs (tgt: ARRAY OF CHAR): ObjC.Id;
VAR d: ObjC.Id;
BEGIN
  d := MkAttr(fBody, cLink);
  [d setObject: ObjC.NSString(tgt) forKey: ObjC.NSString("NSLink")];
  RETURN d
END LinkAttrs;

PROCEDURE Init;
VAR cBody, cCode, cCodeBg, cBullet, cRule, cH1, cH2, cH3: ObjC.Id; i: CARDINAL;
BEGIN
  IF gInited THEN RETURN END;
  fBody := [Cls("NSFont") systemFontOfSize: 13.0];
  fBold := [Cls("NSFont") boldSystemFontOfSize: 13.0];
  fItalic := [[Cls("NSFontManager") sharedFontManager] convertFont: fBody toHaveTrait: 1];  (* NSItalicFontMask *)
  fMono := [Cls("NSFont") userFixedPitchFontOfSize: 12.0];
  fH1   := [Cls("NSFont") boldSystemFontOfSize: 18.0];
  fH2   := [Cls("NSFont") boldSystemFontOfSize: 15.0];
  fH3   := [Cls("NSFont") boldSystemFontOfSize: 13.0];
  cBody   := MkColor(0.12, 0.12, 0.14);
  cH1     := MkColor(0.10, 0.22, 0.46);
  cH2     := MkColor(0.10, 0.34, 0.55);
  cH3     := MkColor(0.18, 0.40, 0.34);
  cCode   := MkColor(0.0,  0.36, 0.10);
  cCodeBg := MkColor(0.94, 0.95, 0.93);
  cBullet := MkColor(0.30, 0.45, 0.70);
  cRule   := MkColor(0.62, 0.64, 0.68);
  cLink   := MkColor(0.0,  0.32, 0.85);
  aBody   := MkAttr(fBody, cBody);
  aBold   := MkAttr(fBold, cBody);
  aItalic := MkAttr(fItalic, cBody);
  aH1     := MkAttr(fH1,   cH1);
  aH2     := MkAttr(fH2,   cH2);
  aH3     := MkAttr(fH3,   cH3);
  aCode   := MkAttr(fMono, cCode);
  [aCode setObject: cCodeBg forKey: ObjC.NSString("NSBackgroundColor")];
  aBullet := MkAttr(fBody, cBullet);
  aRule   := MkAttr(fBody, cRule);
  gNL[0] := CHR(10); gNL[1] := CHR(0);
  gBullet[0] := ' '; gBullet[1] := ' '; gBullet[2] := CHR(02022H); gBullet[3] := ' '; gBullet[4] := CHR(0);  (* "  • " *)
  i := 0; WHILE i < 40 DO gRule[i] := CHR(02500H); INC(i) END; gRule[40] := CHR(0);  (* "────…" *)
  gInited := TRUE
END Init;

(* append `s` to `doc` carrying attribute dict `attrs` (over exactly the new run) *)
PROCEDURE Emit (doc: ObjC.Id; s: ARRAY OF CHAR; attrs: ObjC.Id);
VAR ms, ns: ObjC.Id; loc, len: CARDINAL;
BEGIN
  IF s[0] = CHR(0) THEN RETURN END;
  ms  := [doc mutableString];
  loc := [ms length];
  ns  := ObjC.NSString(s);
  [ms appendString: ns];
  len := [ns length];
  (* setAttributes (replace), NOT addAttributes (merge): appending via the mutable
     string makes new chars INHERIT the previous run's attributes, so a merge would
     let an NSLink bleed into every following run. Replacing clears that. *)
  [doc setAttributes: attrs range: Range(loc, len)]
END Emit;

(* inline span from ln[from..]: **bold**, `code`, [text](target) links; the rest
   in `base`. Accumulates same-style runs and flushes on every style change. *)
PROCEDURE DrawInline (doc: ObjC.Id; VAR ln: ARRAY OF CHAR; from: CARDINAL; base, bold: ObjC.Id);
VAR i, j, k, n: CARDINAL; buf, txt, tgt: ARRAY [0..1023] OF CHAR; isBold, isCode, isItalic: BOOLEAN;
  PROCEDURE Flush;
  BEGIN
    IF n > 0 THEN
      buf[n] := CHR(0);
      IF isCode THEN Emit(doc, buf, aCode)
      ELSIF isBold THEN Emit(doc, buf, bold)
      ELSIF isItalic THEN Emit(doc, buf, aItalic)
      ELSE Emit(doc, buf, base) END;
      n := 0
    END
  END Flush;
  PROCEDURE PutCh (c: CHAR);
  BEGIN IF n < 1023 THEN buf[n] := c; INC(n) END END PutCh;
BEGIN
  i := from; n := 0; isBold := FALSE; isCode := FALSE; isItalic := FALSE;
  WHILE ln[i] # CHR(0) DO
    IF ln[i] = '`' THEN Flush; isCode := NOT isCode; INC(i)            (* `code` *)
    ELSIF isCode THEN PutCh(ln[i]); INC(i)                            (* inside code: everything literal *)
    ELSIF (ln[i] = '*') & (ln[i+1] = '*') THEN Flush; isBold := NOT isBold; INC(i, 2)   (* **bold** *)
    ELSIF (ln[i] = '*') OR (ln[i] = '_') THEN Flush; isItalic := NOT isItalic; INC(i)   (* *italic* / _italic_ *)
    ELSIF ln[i] = '[' THEN
      j := i + 1; k := 0;
      WHILE (ln[j] # CHR(0)) & (ln[j] # ']') DO IF k < 1023 THEN txt[k] := ln[j]; INC(k) END; INC(j) END;
      txt[k] := CHR(0);
      IF (ln[j] = ']') & (ln[j+1] = '(') THEN
        j := j + 2; k := 0;
        WHILE (ln[j] # CHR(0)) & (ln[j] # ')') DO IF k < 1023 THEN tgt[k] := ln[j]; INC(k) END; INC(j) END;
        tgt[k] := CHR(0);
        IF ln[j] = ')' THEN Flush; Emit(doc, txt, LinkAttrs(tgt)); i := j + 1
        ELSE PutCh('['); INC(i) END
      ELSE PutCh('['); INC(i) END
    ELSE PutCh(ln[i]); INC(i) END
  END;
  Flush
END DrawInline;

(* one markdown line -> attributed runs in `doc`; `codeMode` tracks ``` fences *)
PROCEDURE ProcessLine (doc: ObjC.Id; VAR ln: ARRAY OF CHAR; VAR codeMode: BOOLEAN);
VAR k: CARDINAL;
BEGIN
  IF (ln[0] = '`') & (ln[1] = '`') & (ln[2] = '`') THEN codeMode := NOT codeMode; RETURN END;
  IF codeMode THEN Emit(doc, ln, aCode); RETURN END;
  IF (ln[0] = '#') & (ln[1] = '#') & (ln[2] = '#') THEN
    k := 3; WHILE ln[k] = ' ' DO INC(k) END; DrawInline(doc, ln, k, aH3, aH3)
  ELSIF (ln[0] = '#') & (ln[1] = '#') THEN
    k := 2; WHILE ln[k] = ' ' DO INC(k) END; DrawInline(doc, ln, k, aH2, aH2)
  ELSIF ln[0] = '#' THEN
    k := 1; WHILE ln[k] = ' ' DO INC(k) END; DrawInline(doc, ln, k, aH1, aH1)
  ELSIF (ln[0] = '-') & (ln[1] = '-') & (ln[2] = '-') THEN
    Emit(doc, gRule, aRule)
  ELSIF ((ln[0] = '-') & (ln[1] = ' ')) OR ((ln[0] = '*') & (ln[1] = ' ')) THEN
    Emit(doc, gBullet, aBullet); DrawInline(doc, ln, 2, aBody, aBold)
  ELSE
    DrawInline(doc, ln, 0, aBody, aBold)
  END
END ProcessLine;

PROCEDURE Render (editor: ObjC.Id; md: ARRAY OF CHAR);
VAR tv, storage, doc: ObjC.Id; i, c: CARDINAL; ln: ARRAY [0..2047] OF CHAR; codeMode: BOOLEAN;
BEGIN
  Init;
  tv := [editor documentView];
  storage := [tv textStorage];
  doc := [[Cls("NSMutableAttributedString") alloc] init];
  codeMode := FALSE; i := 0;
  WHILE md[i] # CHR(0) DO
    c := 0;
    WHILE (md[i] # CHR(0)) & (md[i] # CHR(10)) DO IF c < 2047 THEN ln[c] := md[i]; INC(c) END; INC(i) END;
    ln[c] := CHR(0);
    IF md[i] = CHR(10) THEN INC(i) END;
    ProcessLine(doc, ln, codeMode);
    Emit(doc, gNL, aBody)
  END;
  [storage setAttributedString: doc];
  [tv setEditable: FALSE];
  [tv setSelectable: TRUE]
END Render;

BEGIN
  gInited := FALSE
END MarkView.
