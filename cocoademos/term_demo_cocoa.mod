MODULE term_demo_cocoa;
(* A live TUI terminal as a native Cocoa app — the macOS port of demos/term-demo.mod
   (Terminal + TermRender / Direct2D on Windows). The Windows demo drives the
   Terminal cell-grid model (menu bar with drop-downs, status bar, a boxed text
   panel, multi-colour text, an editable field, and a semantic event queue). Here
   that whole model is reimplemented compactly in Modula-2 over a colour cell
   buffer, rendered by a flipped NSView with Core Graphics + a monospaced font
   (the macOS analogue of TermRender's DirectWrite glyphs). Keyboard navigation
   produces semantic actions (menu chosen / field submitted / help toggled) that
   update the status bar — the same event-driven flavour as the original.

     newm2-driver run --library library cocoademos/term_demo_cocoa.mod
   Tab            switch focus between the menu bar and the input field
   menu focus     Left/Right pick a menu, Down/Enter open, Up/Down pick item,
                  Enter choose, Esc close
   field focus    type to edit, Left/Right/Home/End/Del move+edit, Enter submit
   View > Toggle Help enables/disables the Help menu; close the window to quit *)
FROM SYSTEM IMPORT CAST, ADDRESS;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT CG;
IMPORT DemoHarness;

CONST
  Cols = 80; Rows = 25;
  CellW = 11.0; CellH = 21.0;
  WinW = 880.0;                          (* Cols*CellW *)
  WinH = 525.0;                          (* Rows*CellH *)

  (* palette indices *)
  Black = 0; Navy = 1; Silver = 2; Lime = 3; Yellow = 4; Aqua = 5;
  Fuchsia = 6; White = 7; Red = 8; Teal = 9; Bar = 10; Hi = 11; Dim = 12; Drop = 13;

  (* macOS virtual key codes *)
  KC_TAB = 48; KC_RET = 36; KC_ESC = 53; KC_DEL = 51;
  KC_LEFT = 123; KC_RIGHT = 124; KC_DOWN = 125; KC_UP = 126;
  KC_HOME = 115; KC_END = 119;

  NMenus = 4; MaxItems = 4;
  FocusField = 0; FocusMenu = 1;
  FileMenu = 0; ViewMenu = 2; HelpMenu = 3;

VAR
  chBuf:        ARRAY [0..Rows-1], [0..Cols-1] OF CHAR;
  fgBuf, bgBuf: ARRAY [0..Rows-1], [0..Cols-1] OF CARDINAL;
  palR, palG, palB: ARRAY [0..15] OF REAL;

  title:    ARRAY [0..NMenus-1] OF ARRAY [0..15] OF CHAR;
  item:     ARRAY [0..NMenus-1], [0..MaxItems-1] OF ARRAY [0..15] OF CHAR;
  nItems:   ARRAY [0..NMenus-1] OF CARDINAL;
  menuCol:  ARRAY [0..NMenus-1] OF CARDINAL;       (* x of each title on the bar *)

  selMenu:  CARDINAL;
  openMenu: INTEGER;                                (* -1 = none open *)
  selItem:  CARDINAL;
  gFocus:   CARDINAL;
  helpOn:   BOOLEAN;

  fld:      ARRAY [0..47] OF CHAR;
  fldLen:   CARDINAL;
  fldCur:   CARDINAL;

  status:   ARRAY [0..95] OF CHAR;
  gView:    ObjC.Id;
  gTimer:   ObjC.Id;
  gHeadless: BOOLEAN;

(* ---- small string helpers --------------------------------------------- *)
PROCEDURE SLen (VAR s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END; RETURN i END SLen;

PROCEDURE SCopy (src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (i < HIGH(dst)) AND (src[i] # 0C) DO dst[i] := src[i]; INC(i) END;
  dst[i] := 0C
END SCopy;

PROCEDURE NameIs (VAR name: ARRAY OF CHAR; lit: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL; ca, cb: CHAR;
BEGIN
  i := 0;
  LOOP
    IF i <= HIGH(name) THEN ca := name[i] ELSE ca := 0C END;
    IF i <= HIGH(lit)  THEN cb := lit[i]  ELSE cb := 0C END;
    IF ca # cb THEN RETURN FALSE END;
    IF ca = 0C THEN RETURN TRUE END;
    INC(i)
  END
END NameIs;

(* ---- cell buffer primitives ------------------------------------------- *)
PROCEDURE ClearAll (bg: CARDINAL);
  VAR r, c: CARDINAL;
BEGIN
  FOR r := 0 TO Rows-1 DO FOR c := 0 TO Cols-1 DO
    chBuf[r][c] := ' '; fgBuf[r][c] := White; bgBuf[r][c] := bg
  END END
END ClearAll;

PROCEDURE Put (row, col, fg, bg: CARDINAL; s: ARRAY OF CHAR);
  VAR i, c: CARDINAL;
BEGIN
  IF row >= Rows THEN RETURN END;
  i := 0; c := col;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) AND (c < Cols) DO
    chBuf[row][c] := s[i]; fgBuf[row][c] := fg; bgBuf[row][c] := bg; INC(i); INC(c)
  END
END Put;

PROCEDURE FillRow (row, fg, bg: CARDINAL);
  VAR c: CARDINAL;
BEGIN
  IF row >= Rows THEN RETURN END;
  FOR c := 0 TO Cols-1 DO chBuf[row][c] := ' '; fgBuf[row][c] := fg; bgBuf[row][c] := bg END
END FillRow;

PROCEDURE FillBox (row, col, w, h, fg, bg: CARDINAL);
  VAR r, c: CARDINAL;
BEGIN
  FOR r := row TO row+h-1 DO FOR c := col TO col+w-1 DO
    IF (r < Rows) AND (c < Cols) THEN chBuf[r][c] := ' '; fgBuf[r][c] := fg; bgBuf[r][c] := bg END
  END END
END FillBox;

PROCEDURE Box (row, col, w, h, fg, bg: CARDINAL);   (* ASCII frame *)
  VAR r, c: CARDINAL;
BEGIN
  FillBox(row, col, w, h, fg, bg);
  FOR c := col+1 TO col+w-2 DO chBuf[row][c] := '-'; chBuf[row+h-1][c] := '-' END;
  FOR r := row+1 TO row+h-2 DO chBuf[r][col] := '|'; chBuf[r][col+w-1] := '|' END;
  chBuf[row][col] := '+'; chBuf[row][col+w-1] := '+';
  chBuf[row+h-1][col] := '+'; chBuf[row+h-1][col+w-1] := '+'
END Box;

(* ---- the persistent screen content (the Windows Compose) -------------- *)
PROCEDURE Compose;
BEGIN
  Put(2, 2, Lime,    Black, "NewM2 Terminal");
  Put(3, 2, Yellow,  Black, "Core Graphics monospaced text, in Modula-2:");
  Put(4, 4, Aqua,    Black, "* coloured monospaced cells, drop-down menus");
  Put(5, 4, Fuchsia, Black, "* event-driven: the app reacts to menu/field actions");
  Put(6, 4, White,   Black, "* an editable input field below");

  Box(2, 48, 28, 8, White, Teal);
  Put(3, 50, White, Teal, "Text window (panel)");
  Put(5, 50, White, Teal, "Tab switches focus.");
  Put(6, 50, White, Teal, "Menu focus: Down opens.");

  Put(18, 2, Silver, Black, "Name:")
END Compose;

(* ---- dynamic UI: menu bar, drop-down, field, status (rebuilt each key) - *)
PROCEDURE PaintField;
  VAR c: CARDINAL;
BEGIN
  FillBox(18, 8, 40, 1, White, Navy);
  Put(18, 8, White, Navy, fld);
  IF (gFocus = FocusField) AND (openMenu < 0) THEN     (* show the cursor cell *)
    c := 8 + fldCur;
    IF c < 48 THEN bgBuf[18][c] := Silver; fgBuf[18][c] := Black END
  END
END PaintField;

PROCEDURE PaintMenuBar;
  VAR m, bg, fg: CARDINAL;
BEGIN
  FillRow(0, Silver, Bar);
  FOR m := 0 TO NMenus-1 DO
    fg := White; bg := Bar;
    IF (m = HelpMenu) AND (NOT helpOn) THEN fg := Dim END;
    IF (gFocus = FocusMenu) AND (m = selMenu) AND (openMenu < 0) THEN fg := Black; bg := Hi END;
    IF openMenu = VAL(INTEGER, m) THEN fg := Black; bg := Hi END;
    Put(0, menuCol[m], fg, bg, title[m])
  END
END PaintMenuBar;

PROCEDURE PaintDropDown;
  VAR i, w, col, row, fg, bg: CARDINAL; m: CARDINAL;
BEGIN
  IF openMenu < 0 THEN RETURN END;
  m := VAL(CARDINAL, openMenu);
  w := 16; col := menuCol[m];
  IF col + w > Cols THEN col := Cols - w END;
  FOR i := 0 TO nItems[m]-1 DO
    row := 1 + i;
    fg := White; bg := Drop;
    IF i = selItem THEN fg := Black; bg := Hi END;
    FillBox(row, col, w, 1, fg, bg);
    Put(row, col+1, fg, bg, item[m][i])
  END
END PaintDropDown;

PROCEDURE Rebuild;
BEGIN
  ClearAll(Black);
  Compose;
  PaintField;
  PaintMenuBar;
  PaintDropDown;
  FillRow(Rows-1, Black, Bar);
  Put(Rows-1, 0, Yellow, Bar, status)
END Rebuild;

PROCEDURE Refresh;
BEGIN
  Rebuild;
  IF gView # NIL THEN [gView setNeedsDisplay: TRUE] END
END Refresh;

(* ---- semantic actions (the Windows React) ----------------------------- *)
PROCEDURE Cls0 (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls0;

PROCEDURE SetStatus (s: ARRAY OF CHAR);
BEGIN SCopy(s, status) END SetStatus;

PROCEDURE Append (VAR buf: ARRAY OF CHAR; VAR p: CARDINAL; s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) AND (p < HIGH(buf)) DO buf[p] := s[i]; INC(p); INC(i) END;
  buf[p] := 0C
END Append;

PROCEDURE ChooseItem;
  VAR buf: ARRAY [0..95] OF CHAR; p, m: CARDINAL;
BEGIN
  m := VAL(CARDINAL, openMenu);
  IF (openMenu = VAL(INTEGER, FileMenu)) AND (selItem = 3) THEN          (* File > Quit *)
    IF gHeadless THEN SetStatus(" quit (File > Quit) ")
    ELSE [[Cls0("NSApplication") sharedApplication] terminate: NIL] END
  ELSIF (openMenu = VAL(INTEGER, ViewMenu)) AND (selItem = 2) THEN       (* View > Toggle Help *)
    helpOn := NOT helpOn;
    IF helpOn THEN SetStatus(" Help menu enabled ") ELSE SetStatus(" Help menu disabled ") END
  ELSE
    p := 0; Append(buf, p, " chose: "); Append(buf, p, title[m]);
    Append(buf, p, " / "); Append(buf, p, item[m][selItem]);
    SetStatus(buf)
  END;
  openMenu := -1
END ChooseItem;

PROCEDURE Submit;
  VAR buf: ARRAY [0..95] OF CHAR; p: CARDINAL;
BEGIN
  p := 0; Append(buf, p, " submitted: "); Append(buf, p, fld);
  SetStatus(buf)
END Submit;

(* ---- focus + key handling --------------------------------------------- *)
PROCEDURE ToggleFocus;
BEGIN
  IF gFocus = FocusField THEN
    gFocus := FocusMenu; SetStatus(" [MENU] Left/Right pick | Down open | Enter choose | Tab: field ")
  ELSE
    gFocus := FocusField; SetStatus(" [FIELD] type to edit | Enter submit | Tab: menu bar ")
  END
END ToggleFocus;

PROCEDURE NextMenu (delta: INTEGER);
  VAR m: INTEGER;
BEGIN
  m := VAL(INTEGER, selMenu) + delta;
  IF m < 0 THEN m := NMenus-1 ELSIF m >= NMenus THEN m := 0 END;
  IF (m = HelpMenu) AND (NOT helpOn) THEN m := m + delta;
     IF m < 0 THEN m := NMenus-2 ELSIF m >= NMenus THEN m := 0 END END;
  selMenu := VAL(CARDINAL, m)
END NextMenu;

PROCEDURE OpenSel;
BEGIN openMenu := VAL(INTEGER, selMenu); selItem := 0 END OpenSel;

PROCEDURE FieldInsert (ch: CHAR);
  VAR i: CARDINAL;
BEGIN
  IF fldLen >= HIGH(fld) THEN RETURN END;
  FOR i := fldLen TO fldCur+1 BY -1 DO fld[i] := fld[i-1] END;
  fld[fldCur] := ch; INC(fldLen); INC(fldCur); fld[fldLen] := 0C
END FieldInsert;

PROCEDURE FieldBack;
  VAR i: CARDINAL;
BEGIN
  IF fldCur = 0 THEN RETURN END;
  FOR i := fldCur-1 TO fldLen-1 DO fld[i] := fld[i+1] END;
  DEC(fldLen); DEC(fldCur); fld[fldLen] := 0C
END FieldBack;

PROCEDURE OnKey (kc: INTEGER; ch: CHAR);
BEGIN
  IF kc = KC_TAB THEN
    IF openMenu >= 0 THEN openMenu := -1 ELSE ToggleFocus END;
    RETURN
  END;
  IF openMenu >= 0 THEN                       (* a menu is open *)
    IF    kc = KC_UP    THEN IF selItem > 0 THEN DEC(selItem) ELSE selItem := nItems[VAL(CARDINAL,openMenu)]-1 END
    ELSIF kc = KC_DOWN  THEN selItem := (selItem + 1) MOD nItems[VAL(CARDINAL,openMenu)]
    ELSIF kc = KC_LEFT  THEN NextMenu(-1); OpenSel
    ELSIF kc = KC_RIGHT THEN NextMenu(1);  OpenSel
    ELSIF kc = KC_RET   THEN ChooseItem
    ELSIF kc = KC_ESC   THEN openMenu := -1; SetStatus(" menu closed ")
    END;
    RETURN
  END;
  IF gFocus = FocusMenu THEN                   (* menu bar, nothing open *)
    IF    kc = KC_LEFT  THEN NextMenu(-1); SetStatus(" menu bar ")
    ELSIF kc = KC_RIGHT THEN NextMenu(1);  SetStatus(" menu bar ")
    ELSIF (kc = KC_DOWN) OR (kc = KC_RET) THEN OpenSel; SetStatus(" menu open ")
    ELSIF kc = KC_ESC   THEN ToggleFocus
    END;
    RETURN
  END;
  (* focus = field *)
  IF    kc = KC_DOWN  THEN gFocus := FocusMenu; OpenSel; SetStatus(" menu open ")
  ELSIF kc = KC_LEFT  THEN IF fldCur > 0 THEN DEC(fldCur) END
  ELSIF kc = KC_RIGHT THEN IF fldCur < fldLen THEN INC(fldCur) END
  ELSIF kc = KC_HOME  THEN fldCur := 0
  ELSIF kc = KC_END   THEN fldCur := fldLen
  ELSIF kc = KC_DEL   THEN FieldBack
  ELSIF kc = KC_RET   THEN Submit
  ELSIF (ch >= ' ') AND (ch < CHR(127)) THEN FieldInsert(ch);
    SetStatus(" editing ")
  END
END OnKey;

(* ---- the screen: a Modula-2 CLASS that IS a flipped NSView ------------- *)
PROCEDURE Pt (x, y: REAL): ObjC.NSPoint;
VAR p: ObjC.NSPoint;
BEGIN p.x := x; p.y := y; RETURN p END Pt;

PROCEDURE DrawGlyph (cg: ObjC.Id; col, row: CARDINAL; ch: CHAR; fg: CARDINAL);
VAR s: ARRAY [0..1] OF CHAR; color, font, dict, ns: ObjC.Id;
BEGIN
  s[0] := ch; s[1] := 0C;
  color := [Cls0("NSColor") colorWithDeviceRed: palR[fg] green: palG[fg] blue: palB[fg] alpha: 1.0];
  font  := [Cls0("NSFont") userFixedPitchFontOfSize: 16.0];
  dict  := [[Cls0("NSMutableDictionary") alloc] init];
  [dict setObject: font  forKey: ObjC.NSString("NSFont")];
  [dict setObject: color forKey: ObjC.NSString("NSColor")];
  ns := ObjC.NSString(s);
  [ns drawAtPoint: Pt(FLOAT(VAL(INTEGER,col)) * CellW + 1.0,
                      FLOAT(VAL(INTEGER,row)) * CellH + 1.0) withAttributes: dict]
END DrawGlyph;

CLASS TermView;
  INHERIT NSView;

  PROCEDURE IsFlipped (): BOOLEAN;
  BEGIN RETURN TRUE END IsFlipped;

  PROCEDURE AcceptsFirstResponder (): BOOLEAN;
  BEGIN RETURN TRUE END AcceptsFirstResponder;

  PROCEDURE DrawRect (px, py, pw, ph: REAL);
    VAR cg: ObjC.Id; r, c, bg: CARDINAL; ch: CHAR;
  BEGIN
    cg := [[Cls0("NSGraphicsContext") currentContext] CGContext];
    IF cg = NIL THEN RETURN END;
    CG.SetRGBFillColor(cg, 0.0, 0.0, 0.0, 1.0); CG.FillRect(cg, 0.0, 0.0, WinW, WinH);
    FOR r := 0 TO Rows-1 DO FOR c := 0 TO Cols-1 DO
      bg := bgBuf[r][c];
      IF bg # Black THEN
        CG.SetRGBFillColor(cg, palR[bg], palG[bg], palB[bg], 1.0);
        CG.FillRect(cg, FLOAT(VAL(INTEGER,c)) * CellW, FLOAT(VAL(INTEGER,r)) * CellH, CellW, CellH)
      END
    END END;
    FOR r := 0 TO Rows-1 DO FOR c := 0 TO Cols-1 DO
      ch := chBuf[r][c];
      IF (ch # ' ') AND (ch # 0C) THEN DrawGlyph(cg, c, r, ch, fgBuf[r][c]) END
    END END
  END DrawRect;

  PROCEDURE KeyDown (event: ObjC.Id);
    VAR getCode: ObjC.Send0I; kc: INTEGER;
        s: ObjC.Id; buf: ARRAY [0..15] OF CHAR; n: INTEGER; ch: CHAR;
  BEGIN
    getCode := CAST(ObjC.Send0I, ObjC.MsgSendPtr());
    kc := getCode(event, ObjC.Selector("keyCode"));
    s := [event characters];
    n := ObjC.GetString(s, buf);
    IF n > 0 THEN ch := buf[0] ELSE ch := 0C END;
    OnKey(kc, ch);
    Refresh
  END KeyDown;
END TermView;

(* ---- test-harness callbacks ------------------------------------------- *)
PROCEDURE DoSteps (n: CARDINAL);
BEGIN Rebuild END DoSteps;                     (* no animation; just recompose *)

PROCEDURE DoKey (name: ARRAY OF CHAR);
BEGIN
  IF    NameIs(name, "tab")       THEN OnKey(KC_TAB, 0C)
  ELSIF NameIs(name, "enter")     THEN OnKey(KC_RET, 0C)
  ELSIF NameIs(name, "return")    THEN OnKey(KC_RET, 0C)
  ELSIF NameIs(name, "esc")       THEN OnKey(KC_ESC, 0C)
  ELSIF NameIs(name, "up")        THEN OnKey(KC_UP, 0C)
  ELSIF NameIs(name, "down")      THEN OnKey(KC_DOWN, 0C)
  ELSIF NameIs(name, "left")      THEN OnKey(KC_LEFT, 0C)
  ELSIF NameIs(name, "right")     THEN OnKey(KC_RIGHT, 0C)
  ELSIF NameIs(name, "backspace") THEN OnKey(KC_DEL, 0C)
  ELSIF NameIs(name, "home")      THEN OnKey(KC_HOME, 0C)
  ELSIF NameIs(name, "end")       THEN OnKey(KC_END, 0C)
  ELSE  OnKey(0, name[0])                       (* a literal character to type *)
  END;
  Rebuild
END DoKey;

(* ---- setup ------------------------------------------------------------ *)
PROCEDURE SetPal (i: CARDINAL; r, g, b: REAL);
BEGIN palR[i] := r; palG[i] := g; palB[i] := b END SetPal;

PROCEDURE InitPalette;
BEGIN
  SetPal(Black, 0.0,0.0,0.0);     SetPal(Navy, 0.10,0.12,0.42);
  SetPal(Silver, 0.75,0.76,0.80); SetPal(Lime, 0.40,0.90,0.35);
  SetPal(Yellow, 0.95,0.85,0.25); SetPal(Aqua, 0.30,0.85,0.95);
  SetPal(Fuchsia, 0.95,0.45,0.85);SetPal(White, 0.95,0.96,0.98);
  SetPal(Red, 0.95,0.30,0.30);    SetPal(Teal, 0.12,0.45,0.48);
  SetPal(Bar, 0.20,0.22,0.30);    SetPal(Hi, 0.30,0.55,0.95);
  SetPal(Dim, 0.45,0.46,0.50);    SetPal(Drop, 0.14,0.15,0.20)
END InitPalette;

PROCEDURE InitMenus;
BEGIN
  title[0] := "File"; nItems[0] := 4; menuCol[0] := 2;
  item[0][0] := "New"; item[0][1] := "Open"; item[0][2] := "Save"; item[0][3] := "Quit";
  title[1] := "Edit"; nItems[1] := 3; menuCol[1] := 9;
  item[1][0] := "Cut"; item[1][1] := "Copy"; item[1][2] := "Paste";
  title[2] := "View"; nItems[2] := 3; menuCol[2] := 16;
  item[2][0] := "Zoom In"; item[2][1] := "Zoom Out"; item[2][2] := "Toggle Help";
  title[3] := "Help"; nItems[3] := 1; menuCol[3] := 23;
  item[3][0] := "About"
END InitMenus;

PROCEDURE Rct (x, y, w, h: REAL): ObjC.NSRect;
VAR r: ObjC.NSRect;
BEGIN r.origin.x := x; r.origin.y := y; r.size.width := w; r.size.height := h; RETURN r END Rct;

(* ---- main ------------------------------------------------------------- *)
VAR win: Cocoa.Window; content: Cocoa.View; view: TermView;
    spath: ARRAY [0..1023] OF CHAR; ignore: BOOLEAN;
BEGIN
  InitPalette; InitMenus;
  selMenu := 0; openMenu := -1; selItem := 0; gFocus := FocusField; helpOn := TRUE;
  fld[0] := 0C; fldLen := 0; fldCur := 0;
  SCopy(" [FIELD] Tab: focus | type to edit | Down: open menu | File>Quit ", status);
  gHeadless := FALSE;
  Rebuild;

  Cocoa.InitApp;
  win := Cocoa.MakeWindow(WinW, WinH, "NewM2 Terminal");
  content := Cocoa.ContentView(win);
  NEW(view);
  [CAST(ObjC.Id, view) setFrame: Rct(0.0, 0.0, WinW, WinH)];
  Cocoa.AddSubview(content, CAST(Cocoa.View, view));
  gView := CAST(ObjC.Id, view);
  [CAST(ObjC.Id, win) makeFirstResponder: CAST(ObjC.Id, view)];
  IF DemoHarness.ScriptArg(spath) THEN
    gHeadless := TRUE;
    ignore := DemoHarness.Drive(CAST(Cocoa.View, view), DoSteps, DoKey, spath)
  ELSE
    Cocoa.ShowWindow(win);
    Cocoa.RunApp
  END
END term_demo_cocoa.
