IMPLEMENTATION MODULE IndexedPane;
(* Metal-backed indexed graphics pane + sprites, driven entirely from Modula-2 via
   the Obj-C bridge (see metalpane.mod / metalsprites.mod for the proof). The pane
   index buffer + palette + sprite art live here as byte arrays uploaded to
   MTLBuffers; the Metal shaders do index->colour, the per-line/global split, the
   index-0 discard, and the per-instance sprite transform + alpha. *)
FROM SYSTEM IMPORT CAST, ADDRESS, ADR, BYTE;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT Metal;
FROM NM2Math IMPORT sin, cos;

CONST
  MAXW = 640; MAXH = 512;
  PalCount = MAXH*16 + 240;                 (* per-line (H*16) + global (240) *)
  MAXDEF = 32; MAXINST = 256; MAXSPX = 64*64*8;

TYPE
  Def = RECORD
    used: BOOLEAN; w, h, nframes: CARDINAL; dirty: BOOLEAN;
    idxBuf, palBuf: ObjC.Id;
    pix: ARRAY [0..MAXSPX-1] OF BYTE;        (* nframes*w*h indices, 0..15 *)
    pal: ARRAY [0..63] OF BYTE;              (* 16 colours RGBA *)
  END;
  Inst = RECORD
    used, visible: BOOLEAN; def, frame: CARDINAL;
    x, y, scale, rot, alpha: REAL;
  END;

VAR
  PW, PH, Sc: CARDINAL;
  gDev, gQueue, gLayer, gPanePipe, gSprPipe: ObjC.Id;
  gPalBuf: ObjC.Id; palDirty: BOOLEAN;
  gWin: Cocoa.Window; gView: Cocoa.View;
  indexData: ARRAY [0..MAXW*MAXH-1] OF BYTE;
  palData:   ARRAY [0..PalCount*4-1] OF BYTE;
  defs: ARRAY [0..MAXDEF-1] OF Def;
  inst: ARRAY [0..MAXINST-1] OF Inst;
  gHeld: ARRAY [0..255] OF BOOLEAN;
  gTick: TickProc;
  corners: ARRAY [0..7] OF SHORTREAL;
  sinfo:   ARRAY [0..3] OF SHORTREAL;

PROCEDURE Cls0 (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls0;

PROCEDURE Sz (w, h: REAL): ObjC.NSSize;
VAR s: ObjC.NSSize;
BEGIN s.width := w; s.height := h; RETURN s END Sz;

(* ===== MSL shader source (pane size baked in) ========================== *)
VAR src: ARRAY [0..4095] OF CHAR; sp: CARDINAL;
PROCEDURE E (s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO src[sp]:=s[i]; INC(sp); INC(i) END; src[sp]:=0C END E;
PROCEDURE EN (n: CARDINAL);
  VAR d: ARRAY [0..9] OF CHAR; k: CARDINAL;
BEGIN
  IF n=0 THEN src[sp]:='0'; INC(sp)
  ELSE k:=0; WHILE n>0 DO d[k]:=CHR(ORD('0')+(n MOD 10)); INC(k); n:=n DIV 10 END;
    WHILE k>0 DO DEC(k); src[sp]:=d[k]; INC(sp) END END;
  src[sp]:=0C
END EN;
PROCEDURE NL; BEGIN src[sp]:=CHR(10); INC(sp); src[sp]:=0C END NL;

PROCEDURE BuildShader;
BEGIN
  sp := 0; src[0] := 0C;
  E("#include <metal_stdlib>"); NL;
  E("using namespace metal;"); NL;
  E("struct VOut { float4 pos [[position]]; float2 uv; };"); NL;
  (* background pane *)
  E("vertex VOut vmain(uint vid [[vertex_id]]) {"); NL;
  E("  float2 q[4]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};"); NL;
  E("  VOut o; o.pos=float4(q[vid],0,1); o.uv=float2(q[vid].x*0.5+0.5, 0.5-q[vid].y*0.5); return o; }"); NL;
  E("fragment float4 fmain(VOut in [[stage_in]], device const uchar* idx [[buffer(0)]], device const uchar* pal [[buffer(1)]]) {"); NL;
  E("  uint W="); EN(PW); E("u,H="); EN(PH); E("u;"); NL;
  E("  uint x=uint(in.uv.x*float(W)),y=uint(in.uv.y*float(H)); if(x>=W)x=W-1u; if(y>=H)y=H-1u;"); NL;
  E("  uint ci=uint(idx[y*W+x]); if(ci==0u) discard_fragment();"); NL;
  E("  uint k; if(ci<16u){k=y*16u+ci;} else {k="); EN(PH*16); E("u+(ci-16u);}"); NL;
  E("  uint o=k*4u; return float4(float(pal[o]),float(pal[o+1u]),float(pal[o+2u]),float(pal[o+3u]))/255.0; }"); NL;
  (* sprite quad (per-instance corners + alpha) *)
  E("vertex VOut svmain(uint vid [[vertex_id]], constant float2* cor [[buffer(0)]]) {"); NL;
  E("  float2 uvt[4]={float2(0,0),float2(1,0),float2(0,1),float2(1,1)};"); NL;
  E("  VOut o; o.pos=float4(cor[vid],0,1); o.uv=uvt[vid]; return o; }"); NL;
  E("fragment float4 sfmain(VOut in [[stage_in]], device const uchar* si [[buffer(0)]], device const uchar* sp [[buffer(1)]], constant float4& inf [[buffer(2)]]) {"); NL;
  E("  uint sw=uint(inf.x),sh=uint(inf.y),base=uint(inf.z);"); NL;
  E("  uint sx=uint(in.uv.x*inf.x),sy=uint(in.uv.y*inf.y); if(sx>=sw)sx=sw-1u; if(sy>=sh)sy=sh-1u;"); NL;
  E("  uint ci=uint(si[base+sy*sw+sx]); if(ci==0u) discard_fragment();"); NL;
  E("  uint o=ci*4u; float4 c=float4(float(sp[o]),float(sp[o+1u]),float(sp[o+2u]),float(sp[o+3u]))/255.0; c.a*=inf.w; return c; }"); NL
END BuildShader;

(* ===== Metal pipeline ==================================================== *)
PROCEDURE MakePipe (vn, fn: ARRAY OF CHAR; lib: ObjC.Id; blend: BOOLEAN): ObjC.Id;
  VAR pd, ca, err: ObjC.Id;
BEGIN
  pd := [[Cls0("MTLRenderPipelineDescriptor") alloc] init];
  [pd setVertexFunction: [lib newFunctionWithName: ObjC.NSString(vn)]];
  [pd setFragmentFunction: [lib newFunctionWithName: ObjC.NSString(fn)]];
  ca := [[pd colorAttachments] objectAtIndexedSubscript: 0];
  [ca setPixelFormat: 80];
  IF blend THEN
    [ca setBlendingEnabled: TRUE];
    [ca setSourceRGBBlendFactor: 4]; [ca setDestinationRGBBlendFactor: 5];
    [ca setSourceAlphaBlendFactor: 4]; [ca setDestinationAlphaBlendFactor: 5]
  END;
  err := NIL;
  RETURN [gDev newRenderPipelineStateWithDescriptor: pd error: ADR(err)]
END MakePipe;

PROCEDURE Create (title: ARRAY OF CHAR; w, h, scale: CARDINAL): BOOLEAN;
  VAR lib, err: ObjC.Id; i: CARDINAL;
BEGIN
  IF w > MAXW THEN w := MAXW END; IF h > MAXH THEN h := MAXH END;
  PW := w; PH := h; Sc := scale; palDirty := TRUE;
  FOR i := 0 TO MAXDEF-1 DO defs[i].used := FALSE END;
  FOR i := 0 TO MAXINST-1 DO inst[i].used := FALSE; inst[i].visible := FALSE END;
  FOR i := 0 TO 255 DO gHeld[i] := FALSE END;
  Cocoa.InitApp;
  gWin := Cocoa.MakeWindow(VAL(REAL,PW*Sc), VAL(REAL,PH*Sc), title);
  gView := Cocoa.ContentView(gWin);
  gDev := CAST(ObjC.Id, Metal.CreateSystemDefaultDevice());
  IF gDev = NIL THEN RETURN FALSE END;
  gQueue := [gDev newCommandQueue];
  gLayer := [Cls0("CAMetalLayer") layer];
  [gLayer setDevice: gDev]; [gLayer setPixelFormat: 80]; [gLayer setFramebufferOnly: TRUE];
  [gLayer setDrawableSize: Sz(VAL(REAL,PW*Sc), VAL(REAL,PH*Sc))];
  [CAST(ObjC.Id, gView) setLayer: gLayer]; [CAST(ObjC.Id, gView) setWantsLayer: TRUE];
  BuildShader;
  err := NIL;
  lib := [gDev newLibraryWithSource: ObjC.NSString(src) options: NIL error: ADR(err)];
  IF lib = NIL THEN RETURN FALSE END;
  gPanePipe := MakePipe("vmain", "fmain", lib, FALSE);
  gSprPipe  := MakePipe("svmain", "sfmain", lib, TRUE);
  IF (gPanePipe = NIL) OR (gSprPipe = NIL) THEN RETURN FALSE END;
  Cocoa.ShowWindow(gWin);
  RETURN TRUE
END Create;

(* ===== palette ========================================================== *)
PROCEDURE SetRGB (index, r, g, b: CARDINAL);
  VAR o, y: CARDINAL;
BEGIN
  IF index > 255 THEN RETURN END;
  IF index >= 16 THEN                                  (* global colour *)
    o := (PH*16 + (index-16)) * 4;
    palData[o]:=VAL(BYTE,r); palData[o+1]:=VAL(BYTE,g); palData[o+2]:=VAL(BYTE,b); palData[o+3]:=VAL(BYTE,255)
  ELSIF index >= 1 THEN                                 (* a per-line index: the default on every line *)
    FOR y := 0 TO PH-1 DO
      o := (y*16 + index) * 4;
      palData[o]:=VAL(BYTE,r); palData[o+1]:=VAL(BYTE,g); palData[o+2]:=VAL(BYTE,b); palData[o+3]:=VAL(BYTE,255)
    END
  END;
  palDirty := TRUE
END SetRGB;

PROCEDURE SetLineRGB (y, index, r, g, b: CARDINAL);
  VAR o: CARDINAL;
BEGIN
  IF (y >= PH) OR (index < 1) OR (index > 15) THEN RETURN END;
  o := (y*16 + index) * 4;
  palData[o]:=VAL(BYTE,r); palData[o+1]:=VAL(BYTE,g); palData[o+2]:=VAL(BYTE,b); palData[o+3]:=VAL(BYTE,255);
  palDirty := TRUE
END SetLineRGB;

PROCEDURE LoadDefaultPalette;
  VAR i: CARDINAL;
BEGIN
  FOR i := 16 TO 255 DO SetRGB(i, (i*5) MOD 256, (i*7) MOD 256, (i*11) MOD 256) END
END LoadDefaultPalette;

(* ===== pane drawing ===================================================== *)
PROCEDURE Cls (index: CARDINAL);
  VAR i, n: CARDINAL; v: BYTE;
BEGIN v := VAL(BYTE, index); n := PW*PH; i := 0; WHILE i < n DO indexData[i] := v; INC(i) END END Cls;

PROCEDURE Pset (x, y: INTEGER; index: CARDINAL);
BEGIN
  IF (x >= 0) AND (y >= 0) AND (x < VAL(INTEGER,PW)) AND (y < VAL(INTEGER,PH)) THEN
    indexData[VAL(CARDINAL,y)*PW + VAL(CARDINAL,x)] := VAL(BYTE, index)
  END
END Pset;

PROCEDURE Pget (x, y: INTEGER): CARDINAL;
BEGIN
  IF (x >= 0) AND (y >= 0) AND (x < VAL(INTEGER,PW)) AND (y < VAL(INTEGER,PH)) THEN
    RETURN VAL(CARDINAL, indexData[VAL(CARDINAL,y)*PW + VAL(CARDINAL,x)])
  END;
  RETURN 0
END Pget;

PROCEDURE FillRect (x, y, w, h: INTEGER; index: CARDINAL);
  VAR i, j: INTEGER;
BEGIN
  j := y; WHILE j < y+h DO i := x; WHILE i < x+w DO Pset(i, j, index); INC(i) END; INC(j) END
END FillRect;

PROCEDURE Line (x0, y0, x1, y1: INTEGER; index: CARDINAL);
  VAR dx, dy, sx, sy, err, e2: INTEGER;
BEGIN
  dx := ABS(x1-x0); dy := ABS(y1-y0);
  IF x0 < x1 THEN sx := 1 ELSE sx := -1 END;
  IF y0 < y1 THEN sy := 1 ELSE sy := -1 END;
  err := dx - dy;
  LOOP
    Pset(x0, y0, index);
    IF (x0 = x1) AND (y0 = y1) THEN EXIT END;
    e2 := 2*err;
    IF e2 > -dy THEN err := err - dy; x0 := x0 + sx END;
    IF e2 <  dx THEN err := err + dx; y0 := y0 + sy END
  END
END Line;

PROCEDURE Circle (cx, cy, r: INTEGER; index: CARDINAL);
  VAR x, y, d: INTEGER;
BEGIN
  x := 0; y := r; d := 1 - r;
  WHILE x <= y DO
    Pset(cx+x, cy+y, index); Pset(cx-x, cy+y, index); Pset(cx+x, cy-y, index); Pset(cx-x, cy-y, index);
    Pset(cx+y, cy+x, index); Pset(cx-y, cy+x, index); Pset(cx+y, cy-x, index); Pset(cx-y, cy-x, index);
    INC(x);
    IF d < 0 THEN d := d + 2*x + 1 ELSE DEC(y); d := d + 2*(x-y) + 1 END
  END
END Circle;

PROCEDURE Disc (cx, cy, r: INTEGER; index: CARDINAL);
  VAR x, y: INTEGER;
BEGIN
  y := -r; WHILE y <= r DO x := -r; WHILE x <= r DO
    IF x*x + y*y <= r*r THEN Pset(cx+x, cy+y, index) END; INC(x) END; INC(y) END
END Disc;

(* unscii-8 font, borrowed from the SuperTerminal atlas: 95 glyphs (chars
   32..126), 8x8, MSB-left, 8 hex bytes per glyph. *)
CONST FONTHEX =
  "0000000000000000181818181800180066666600000000006C6CFE6CFE6C6C00183E603C067C180000C6CC183066C600386C3876DCCC760018183000000000000C18303030180C0030180C0C0C18300000663CFF3C6600000018187E1818000000000000001818300000007E00000000000000000018180003060C183060C0003C666E7666663C001838181818187E003C660C1830607E003C66061C06663C001C3C6CCCFE0C0C007E607C0606663C001C30607C66663C007E06060C181818003C66663C66663C003C66663E060C3800001818000018180000181800001818300C18306030180C0000007E007E0000006030180C183060003C66060C180018007CC6DEDEDEC07C00183C66667E6666007C66667C66667C003C66606060663C00786C6666666C78007E60607C60607E007E60607C606060003C66606E66663E006666667E666666007E18181818187E000606060606663C00C6CCD8F0D8CCC6006060606060607E00C6EEFED6C6C6C600C6E6F6DECEC6C6003C66666666663C007C66667C606060003C666666666C36007C66667C6C6666003C66603C06663C007E181818181818006666666666663C0066666666663C1800C6C6C6D6FEEEC600C3663C183C66C300C3663C18181818007E060C1830607E003C30303030303C00C06030180C0603003C0C0C0C0C0C3C0010386CC60000000000000000000000FF180C06000000000000003C063E663E0060607C6666667C0000003C6060603C0006063E6666663E0000003C667E603C001C307C303030300000003E66663E067C60607C66666666001800381818181E000C000C0C0C0C0C786060666C786C66003818181818181E000000CCFED6D6C60000007C666666660000003C6666663C0000007C66667C606000003E66663E060600007C666060600000003E603C067C0030307E3030301E000000666666663E0000006666663C18000000C6C6D67C6C000000C66C386CC60000006666663E063C00007E0C18307E000E18187018180E0018181818181818007018180E1818700076DC000000000000";
VAR fontData: ARRAY [0..759] OF BYTE; fontReady: BOOLEAN;
PROCEDURE HexN (c: CHAR): CARDINAL;
BEGIN
  IF (c >= '0') AND (c <= '9') THEN RETURN ORD(c)-ORD('0')
  ELSIF (c >= 'A') AND (c <= 'F') THEN RETURN 10 + ORD(c)-ORD('A') ELSE RETURN 0 END
END HexN;
PROCEDURE SeedFont (hex: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  fontReady := TRUE;
  FOR i := 0 TO 759 DO fontData[i] := VAL(BYTE, HexN(hex[i*2])*16 + HexN(hex[i*2+1])) END
END SeedFont;

PROCEDURE Text (x, y: INTEGER; s: ARRAY OF CHAR; index: CARDINAL);
  VAR i, g, row, col: CARDINAL; cx: INTEGER; ch: CHAR;
BEGIN
  IF NOT fontReady THEN SeedFont(FONTHEX) END;
  i := 0; cx := x;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO
    ch := s[i];
    IF (ORD(ch) >= 32) AND (ORD(ch) <= 126) THEN
      g := ORD(ch) - 32;
      FOR row := 0 TO 7 DO FOR col := 0 TO 7 DO
        IF (VAL(CARDINAL, fontData[g*8+row]) DIV pow2(7-col)) MOD 2 = 1 THEN
          Pset(cx + VAL(INTEGER,col), y + VAL(INTEGER,row), index)
        END
      END END
    END;
    cx := cx + 9; INC(i)
  END
END Text;

PROCEDURE pow2 (n: CARDINAL): CARDINAL;
  VAR v: CARDINAL;
BEGIN v := 1; WHILE n > 0 DO v := v*2; DEC(n) END; RETURN v END pow2;

(* ===== sprite defs ====================================================== *)
PROCEDURE HexVal (c: CHAR): CARDINAL;
BEGIN
  IF c = '.' THEN RETURN 0
  ELSIF (c >= '0') AND (c <= '9') THEN RETURN ORD(c) - ORD('0')
  ELSIF (c >= 'a') AND (c <= 'f') THEN RETURN 10 + ORD(c) - ORD('a')
  ELSIF (c >= 'A') AND (c <= 'F') THEN RETURN 10 + ORD(c) - ORD('A')
  ELSE RETURN 0 END
END HexVal;

PROCEDURE ParseRows (id: CARDINAL; rows: ARRAY OF CHAR; frame: CARDINAL);
  VAR i, x, y, w, base: CARDINAL;
BEGIN
  w := defs[id].w; base := frame * w * defs[id].h;
  i := 0; x := 0; y := 0;
  WHILE (i <= HIGH(rows)) AND (rows[i] # 0C) DO
    IF rows[i] = '/' THEN INC(y); x := 0
    ELSE
      IF (x < w) AND (y < defs[id].h) THEN defs[id].pix[base + y*w + x] := VAL(BYTE, HexVal(rows[i])) END;
      INC(x)
    END;
    INC(i)
  END
END ParseRows;

PROCEDURE MeasureRows (rows: ARRAY OF CHAR; VAR w, h: CARDINAL);
  VAR i, x: CARDINAL;
BEGIN
  w := 0; h := 1; x := 0; i := 0;
  WHILE (i <= HIGH(rows)) AND (rows[i] # 0C) DO
    IF rows[i] = '/' THEN INC(h); x := 0 ELSE INC(x); IF x > w THEN w := x END END;
    INC(i)
  END
END MeasureRows;

PROCEDURE DefineSprite (id: CARDINAL; rows: ARRAY OF CHAR): BOOLEAN;
  VAR w, h, j: CARDINAL;
BEGIN
  IF id >= MAXDEF THEN RETURN FALSE END;
  MeasureRows(rows, w, h);
  defs[id].used := TRUE; defs[id].w := w; defs[id].h := h; defs[id].nframes := 1; defs[id].dirty := TRUE;
  FOR j := 0 TO 63 DO defs[id].pal[j] := VAL(BYTE, 0) END;
  ParseRows(id, rows, 0);
  RETURN TRUE
END DefineSprite;

PROCEDURE AddFrame (id: CARDINAL; rows: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF (id >= MAXDEF) OR (NOT defs[id].used) THEN RETURN FALSE END;
  ParseRows(id, rows, defs[id].nframes);
  INC(defs[id].nframes); defs[id].dirty := TRUE; RETURN TRUE
END AddFrame;

PROCEDURE SpriteRGB (id, index, r, g, b: CARDINAL);
  VAR o: CARDINAL;
BEGIN
  IF (id >= MAXDEF) OR (index > 15) THEN RETURN END;
  o := index*4;
  defs[id].pal[o]:=VAL(BYTE,r); defs[id].pal[o+1]:=VAL(BYTE,g); defs[id].pal[o+2]:=VAL(BYTE,b); defs[id].pal[o+3]:=VAL(BYTE,255);
  defs[id].dirty := TRUE
END SpriteRGB;

(* ===== instances ======================================================== *)
PROCEDURE Place (i, def: CARDINAL; x, y: REAL);
BEGIN
  IF i >= MAXINST THEN RETURN END;
  inst[i].used:=TRUE; inst[i].visible:=FALSE; inst[i].def:=def; inst[i].frame:=0;
  inst[i].x:=x; inst[i].y:=y; inst[i].scale:=1.0; inst[i].rot:=0.0; inst[i].alpha:=1.0
END Place;
PROCEDURE MoveTo (i: CARDINAL; x, y: REAL); BEGIN IF i<MAXINST THEN inst[i].x:=x; inst[i].y:=y END END MoveTo;
PROCEDURE SetScale (i: CARDINAL; s: REAL); BEGIN IF i<MAXINST THEN inst[i].scale:=s END END SetScale;
PROCEDURE SetRotation (i: CARDINAL; d: REAL); BEGIN IF i<MAXINST THEN inst[i].rot:=d END END SetRotation;
PROCEDURE SetAlpha (i: CARDINAL; a: REAL); BEGIN IF i<MAXINST THEN inst[i].alpha:=a END END SetAlpha;
PROCEDURE SetFrame (i, f: CARDINAL); BEGIN IF i<MAXINST THEN inst[i].frame:=f END END SetFrame;
PROCEDURE Show (i: CARDINAL); BEGIN IF i<MAXINST THEN inst[i].visible:=TRUE END END Show;
PROCEDURE Hide (i: CARDINAL); BEGIN IF i<MAXINST THEN inst[i].visible:=FALSE END END Hide;

PROCEDURE Hit (a, b: CARDINAL): BOOLEAN;
  VAR ax, ay, aw, ah, bx, by, bw, bh: REAL;
BEGIN
  IF (a>=MAXINST) OR (b>=MAXINST) OR (NOT inst[a].used) OR (NOT inst[b].used) THEN RETURN FALSE END;
  aw := VAL(REAL, defs[inst[a].def].w) * inst[a].scale * 0.5;
  ah := VAL(REAL, defs[inst[a].def].h) * inst[a].scale * 0.5;
  bw := VAL(REAL, defs[inst[b].def].w) * inst[b].scale * 0.5;
  bh := VAL(REAL, defs[inst[b].def].h) * inst[b].scale * 0.5;
  ax := inst[a].x; ay := inst[a].y; bx := inst[b].x; by := inst[b].y;
  RETURN (ABS(ax-bx) < aw+bw) AND (ABS(ay-by) < ah+bh)
END Hit;

(* ===== rendering ======================================================== *)
PROCEDURE NewBuf (a: ADDRESS; n: CARDINAL): ObjC.Id;
BEGIN RETURN [gDev newBufferWithBytes: a length: n options: 0] END NewBuf;

PROCEDURE DrawInst (enc: ObjC.Id; i: CARDINAL);
  VAR d, base: CARDINAL; hw, hh, c, s, rad, lx, ly, rx, ry, cxp, cyp: REAL; j: CARDINAL;
BEGIN
  d := inst[i].def;
  IF (NOT defs[d].used) THEN RETURN END;
  IF defs[d].dirty THEN
    defs[d].idxBuf := NewBuf(ADR(defs[d].pix), defs[d].nframes * defs[d].w * defs[d].h);
    defs[d].palBuf := NewBuf(ADR(defs[d].pal), 64);
    defs[d].dirty := FALSE
  END;
  hw := VAL(REAL, defs[d].w) * inst[i].scale * 0.5;
  hh := VAL(REAL, defs[d].h) * inst[i].scale * 0.5;
  rad := inst[i].rot * 0.01745329; c := cos(rad); s := sin(rad);
  cxp := inst[i].x; cyp := inst[i].y;
  (* corners TL,TR,BL,BR in pixel space, rotate, -> NDC *)
  FOR j := 0 TO 3 DO
    IF (j = 0) OR (j = 2) THEN lx := -hw ELSE lx := hw END;
    IF (j = 0) OR (j = 1) THEN ly := -hh ELSE ly := hh END;
    rx := lx*c - ly*s; ry := lx*s + ly*c;
    corners[j*2]   := VAL(SHORTREAL, ((cxp+rx)/VAL(REAL,PW))*2.0 - 1.0);
    corners[j*2+1] := VAL(SHORTREAL, 1.0 - ((cyp+ry)/VAL(REAL,PH))*2.0)
  END;
  base := inst[i].frame * defs[d].w * defs[d].h;
  sinfo[0] := VAL(SHORTREAL, VAL(REAL, defs[d].w));
  sinfo[1] := VAL(SHORTREAL, VAL(REAL, defs[d].h));
  sinfo[2] := VAL(SHORTREAL, VAL(REAL, base));
  sinfo[3] := VAL(SHORTREAL, inst[i].alpha);
  [enc setRenderPipelineState: gSprPipe];
  [enc setVertexBytes: ADR(corners) length: 32 atIndex: 0];
  [enc setFragmentBuffer: defs[d].idxBuf offset: 0 atIndex: 0];
  [enc setFragmentBuffer: defs[d].palBuf offset: 0 atIndex: 1];
  [enc setFragmentBytes: ADR(sinfo) length: 16 atIndex: 2];
  [enc drawPrimitives: 4 vertexStart: 0 vertexCount: 4]
END DrawInst;

PROCEDURE Present;
  VAR drawable, cb, pass, ca, enc, ibuf: ObjC.Id; i: CARDINAL;
BEGIN
  drawable := [gLayer nextDrawable];
  IF drawable = NIL THEN RETURN END;
  IF palDirty THEN gPalBuf := NewBuf(ADR(palData), PalCount*4); palDirty := FALSE END;
  ibuf := NewBuf(ADR(indexData), PW*PH);
  pass := [Cls0("MTLRenderPassDescriptor") renderPassDescriptor];
  ca := [[pass colorAttachments] objectAtIndexedSubscript: 0];
  [ca setTexture: [drawable texture]]; [ca setLoadAction: 2]; [ca setStoreAction: 1];
  cb := [gQueue commandBuffer];
  enc := [cb renderCommandEncoderWithDescriptor: pass];
  [enc setRenderPipelineState: gPanePipe];
  [enc setFragmentBuffer: ibuf offset: 0 atIndex: 0];
  [enc setFragmentBuffer: gPalBuf offset: 0 atIndex: 1];
  [enc drawPrimitives: 4 vertexStart: 0 vertexCount: 4];
  FOR i := 0 TO MAXINST-1 DO
    IF inst[i].used AND inst[i].visible THEN DrawInst(enc, i) END
  END;
  [enc endEncoding]; [cb presentDrawable: drawable]; [cb commit]
END Present;

(* ===== input + loop ===================================================== *)
PROCEDURE KeyHeld (key: CARDINAL): BOOLEAN;
BEGIN IF key <= 255 THEN RETURN gHeld[key] ELSE RETURN FALSE END END KeyHeld;

PROCEDURE Quit;
BEGIN [CAST(ObjC.Id, [Cls0("NSApplication") sharedApplication]) terminate: NIL] END Quit;

PROCEDURE KeyCodeToId (kc: CARDINAL): CARDINAL;
BEGIN
  CASE kc OF
    123: RETURN KeyLeft | 124: RETURN KeyRight | 125: RETURN KeyDown | 126: RETURN KeyUp | 49: RETURN KeySpace
  ELSE RETURN 0 END
END KeyCodeToId;

(* the pane view: receives key events into gHeld[] *)
CLASS PaneView;
  INHERIT NSView;
  PROCEDURE AcceptsFirstResponder (): BOOLEAN; BEGIN RETURN TRUE END AcceptsFirstResponder;
  PROCEDURE KeyDown (ev: ObjC.Id);
    VAR id: CARDINAL;
  BEGIN id := KeyCodeToId(VAL(CARDINAL, [ev keyCode])); IF id > 0 THEN gHeld[id] := TRUE END END KeyDown;
  PROCEDURE KeyUp (ev: ObjC.Id);
    VAR id: CARDINAL;
  BEGIN id := KeyCodeToId(VAL(CARDINAL, [ev keyCode])); IF id > 0 THEN gHeld[id] := FALSE END END KeyUp;
END PaneView;

PROCEDURE TickBlock (block, timer: ObjC.Id);
BEGIN gTick() END TickBlock;

PROCEDURE Run (tick: TickProc);
  VAR pv: PaneView; t: ObjC.Id;
BEGIN
  gTick := tick;
  (* swap the content view for a key-receiving PaneView that hosts the layer *)
  NEW(pv);
  [CAST(ObjC.Id, gWin) setContentView: CAST(ObjC.Id, pv)];
  [CAST(ObjC.Id, pv) setLayer: gLayer]; [CAST(ObjC.Id, pv) setWantsLayer: TRUE];
  [CAST(ObjC.Id, gWin) makeFirstResponder: CAST(ObjC.Id, pv)];
  t := [Cls0("NSTimer") scheduledTimerWithTimeInterval: 0.016
                        repeats: TRUE block: ObjC.MakeBlock(CAST(ADDRESS, TickBlock))];
  Cocoa.RunApp
END Run;

BEGIN
  PW := 0; PH := 0; fontReady := FALSE; palDirty := TRUE
END IndexedPane.
