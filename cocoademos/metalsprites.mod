MODULE metalsprites;
(* Metal sprites over an indexed pane — still pure Modula-2 over the Obj-C bridge.
   Builds on metalpane.mod: the same indexed background pane, plus a 16-colour
   sprite (its OWN palette, index 0 transparent) composited on the GPU as a quad
   in a second render pipeline. The sprite bounces, driven by the NSTimer loop,
   uploading only its position each frame.

     newm2-driver run --library library cocoademos/metalsprites.mod *)
FROM SYSTEM IMPORT CAST, ADDRESS, ADR, BYTE;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT Metal;

CONST
  PW = 256; PH = 240;
  WinW = 768.0; WinH = 720.0;
  IdxBytes = PW * PH;
  PalBytes = (240*16 + 240) * 4;
  SW = 16; SH = 16;                 (* sprite size *)
  SIdxBytes = SW * SH;
  SPalBytes = 16 * 4;

VAR
  gDev, gQueue, gLayer, gPipe, gSPipe: ObjC.Id;
  gIndexBuf, gPalBuf, gSIdxBuf, gSPalBuf: ObjC.Id;
  gWin: Cocoa.Window; gView: Cocoa.View;
  indexData: ARRAY [0..IdxBytes-1] OF BYTE;
  palData:   ARRAY [0..PalBytes-1] OF BYTE;
  spr:       ARRAY [0..SIdxBytes-1] OF BYTE;
  sprPal:    ARRAY [0..SPalBytes-1] OF BYTE;
  gRect:     ARRAY [0..3] OF SHORTREAL;        (* sprite quad in NDC *)
  gSSize:    ARRAY [0..1] OF SHORTREAL;        (* sprite w,h *)
  px, py, vx, vy: REAL;                         (* sprite position + velocity *)

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

PROCEDURE Size (w, h: REAL): ObjC.NSSize;
VAR s: ObjC.NSSize;
BEGIN s.width := w; s.height := h; RETURN s END Size;

(* --- MSL: pane (vmain/fmain) + sprite (svmain/sfmain) ------------------- *)
VAR src: ARRAY [0..3071] OF CHAR; srcPos: CARDINAL;
PROCEDURE Ln (s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO src[srcPos] := s[i]; INC(srcPos); INC(i) END;
  src[srcPos] := CHR(10); INC(srcPos); src[srcPos] := 0C
END Ln;

PROCEDURE BuildShader;
BEGIN
  srcPos := 0; src[0] := 0C;
  Ln("#include <metal_stdlib>");
  Ln("using namespace metal;");
  Ln("struct VOut { float4 pos [[position]]; float2 uv; };");
  (* --- background pane --- *)
  Ln("vertex VOut vmain(uint vid [[vertex_id]]) {");
  Ln("  float2 q[4]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};");
  Ln("  VOut o; o.pos=float4(q[vid],0,1); o.uv=float2(q[vid].x*0.5+0.5, 0.5-q[vid].y*0.5); return o; }");
  Ln("fragment float4 fmain(VOut in [[stage_in]],");
  Ln("    device const uchar* idx [[buffer(0)]], device const uchar* pal [[buffer(1)]]) {");
  Ln("  uint W=256u,H=240u; uint x=uint(in.uv.x*float(W)),y=uint(in.uv.y*float(H));");
  Ln("  if(x>=W)x=W-1u; if(y>=H)y=H-1u;");
  Ln("  uint ci=uint(idx[y*W+x]); if(ci==0u) discard_fragment();");
  Ln("  uint k; if(ci<16u){uint l=y; if(l>239u)l=239u; k=l*16u+ci;} else {k=3840u+(ci-16u);}");
  Ln("  uint o=k*4u; return float4(float(pal[o]),float(pal[o+1u]),float(pal[o+2u]),float(pal[o+3u]))/255.0; }");
  (* --- sprite quad --- *)
  Ln("vertex VOut svmain(uint vid [[vertex_id]], constant float4& rect [[buffer(0)]]) {");
  Ln("  float2 c[4]={float2(0,0),float2(1,0),float2(0,1),float2(1,1)};");
  Ln("  float2 p=float2(rect.x+c[vid].x*rect.z, rect.y+c[vid].y*rect.w);");
  Ln("  VOut o; o.pos=float4(p,0,1); o.uv=c[vid]; return o; }");
  Ln("fragment float4 sfmain(VOut in [[stage_in]], device const uchar* si [[buffer(0)]],");
  Ln("    device const uchar* sp [[buffer(1)]], constant float2& sz [[buffer(2)]]) {");
  Ln("  uint sw=uint(sz.x),sh=uint(sz.y);");
  Ln("  uint sx=uint(in.uv.x*sz.x),sy=uint(in.uv.y*sz.y); if(sx>=sw)sx=sw-1u; if(sy>=sh)sy=sh-1u;");
  Ln("  uint ci=uint(si[sy*sw+sx]); if(ci==0u) discard_fragment();");
  Ln("  uint o=ci*4u; return float4(float(sp[o]),float(sp[o+1u]),float(sp[o+2u]),float(sp[o+3u]))/255.0; }")
END BuildShader;

(* --- data --------------------------------------------------------------- *)
PROCEDURE SetRGBA (VAR a: ARRAY OF BYTE; off, r, g, b, al: CARDINAL);
BEGIN a[off]:=VAL(BYTE,r); a[off+1]:=VAL(BYTE,g); a[off+2]:=VAL(BYTE,b); a[off+3]:=VAL(BYTE,al) END SetRGBA;

PROCEDURE FillPane;
  VAR x, y, g: CARDINAL;
BEGIN
  FOR g := 0 TO 239 DO                                   (* global = dusk gradient *)
    SetRGBA(palData, (3840+g)*4, 20 + g DIV 4, 24 + g DIV 3, 60 + g, 255)
  END;
  FOR y := 0 TO PH-1 DO FOR x := 0 TO PW-1 DO
    indexData[y*PW + x] := VAL(BYTE, 16 + (y*224 DIV PH))
  END END
END FillPane;

PROCEDURE BuildSprite;
  VAR x, y, dx, dy, d2: INTEGER;
BEGIN
  (* a shaded ball: 0 transparent, 1 outline, 2 body, 3 highlight *)
  SetRGBA(sprPal,  1*4,  20, 10, 10, 255);
  SetRGBA(sprPal,  2*4, 220, 60, 60, 255);
  SetRGBA(sprPal,  3*4, 255, 200,190, 255);
  FOR y := 0 TO SH-1 DO FOR x := 0 TO SW-1 DO
    dx := x-8; dy := y-8; d2 := dx*dx + dy*dy;
    IF d2 <= 30 THEN spr[y*SW+x] := VAL(BYTE, 2)
    ELSIF d2 <= 52 THEN spr[y*SW+x] := VAL(BYTE, 1)
    ELSE spr[y*SW+x] := VAL(BYTE, 0) END;
    IF (d2 <= 14) AND (dy < -1) AND (dx < 2) THEN spr[y*SW+x] := VAL(BYTE, 3) END
  END END
END BuildSprite;

PROCEDURE SpriteRect;                                    (* px,py (pane px) -> NDC *)
BEGIN
  gRect[0] := VAL(SHORTREAL, (px/VAL(REAL,PW))*2.0 - 1.0);
  gRect[1] := VAL(SHORTREAL, 1.0 - (py/VAL(REAL,PH))*2.0);
  gRect[2] := VAL(SHORTREAL, (VAL(REAL,SW)/VAL(REAL,PW))*2.0);
  gRect[3] := VAL(SHORTREAL, -(VAL(REAL,SH)/VAL(REAL,PH))*2.0)
END SpriteRect;

(* --- Metal -------------------------------------------------------------- *)
PROCEDURE ReportError (what: ARRAY OF CHAR; err: ObjC.Id);
  VAR d: ObjC.Id; buf: ARRAY [0..1023] OF CHAR; n: INTEGER;
BEGIN
  WriteString(what); WriteString(": ");
  IF err # NIL THEN d := [err localizedDescription]; n := ObjC.GetString(d, buf); WriteString(buf)
  ELSE WriteString("(nil)") END; WriteLn
END ReportError;

PROCEDURE MakePipe (vname, fname: ARRAY OF CHAR; lib: ObjC.Id): ObjC.Id;
  VAR pd, ca, err, pipe: ObjC.Id;
BEGIN
  pd := [[Cls("MTLRenderPipelineDescriptor") alloc] init];
  [pd setVertexFunction: [lib newFunctionWithName: ObjC.NSString(vname)]];
  [pd setFragmentFunction: [lib newFunctionWithName: ObjC.NSString(fname)]];
  ca := [[pd colorAttachments] objectAtIndexedSubscript: 0];
  [ca setPixelFormat: 80];
  err := NIL;
  pipe := [gDev newRenderPipelineStateWithDescriptor: pd error: ADR(err)];
  IF pipe = NIL THEN ReportError("pipeline failed", err) END;
  RETURN pipe
END MakePipe;

PROCEDURE SetupMetal (): BOOLEAN;
  VAR lib, err: ObjC.Id;
BEGIN
  gDev := CAST(ObjC.Id, Metal.CreateSystemDefaultDevice());
  IF gDev = NIL THEN WriteString("no device"); WriteLn; RETURN FALSE END;
  gQueue := [gDev newCommandQueue];
  gLayer := [Cls("CAMetalLayer") layer];
  [gLayer setDevice: gDev];
  [gLayer setPixelFormat: 80];
  [gLayer setFramebufferOnly: TRUE];
  [gLayer setDrawableSize: Size(WinW, WinH)];
  [CAST(ObjC.Id, gView) setLayer: gLayer];
  [CAST(ObjC.Id, gView) setWantsLayer: TRUE];
  BuildShader;
  err := NIL;
  lib := [gDev newLibraryWithSource: ObjC.NSString(src) options: NIL error: ADR(err)];
  IF lib = NIL THEN ReportError("shader compile failed", err); RETURN FALSE END;
  gPipe  := MakePipe("vmain", "fmain", lib);
  gSPipe := MakePipe("svmain", "sfmain", lib);
  IF (gPipe = NIL) OR (gSPipe = NIL) THEN RETURN FALSE END;
  gIndexBuf := [gDev newBufferWithBytes: ADR(indexData) length: IdxBytes options: 0];
  gPalBuf   := [gDev newBufferWithBytes: ADR(palData)   length: PalBytes options: 0];
  gSIdxBuf  := [gDev newBufferWithBytes: ADR(spr)       length: SIdxBytes options: 0];
  gSPalBuf  := [gDev newBufferWithBytes: ADR(sprPal)    length: SPalBytes options: 0];
  RETURN TRUE
END SetupMetal;

PROCEDURE Render;
  VAR drawable, cb, pass, ca, enc: ObjC.Id;
BEGIN
  drawable := [gLayer nextDrawable];
  IF drawable = NIL THEN RETURN END;
  pass := [Cls("MTLRenderPassDescriptor") renderPassDescriptor];
  ca := [[pass colorAttachments] objectAtIndexedSubscript: 0];
  [ca setTexture: [drawable texture]];
  [ca setLoadAction: 2]; [ca setStoreAction: 1];
  cb := [gQueue commandBuffer];
  enc := [cb renderCommandEncoderWithDescriptor: pass];
  (* background pane *)
  [enc setRenderPipelineState: gPipe];
  [enc setFragmentBuffer: gIndexBuf offset: 0 atIndex: 0];
  [enc setFragmentBuffer: gPalBuf offset: 0 atIndex: 1];
  [enc drawPrimitives: 4 vertexStart: 0 vertexCount: 4];
  (* sprite, composited over the pane (index 0 discarded) *)
  [enc setRenderPipelineState: gSPipe];
  [enc setVertexBytes: ADR(gRect) length: 16 atIndex: 0];
  [enc setFragmentBuffer: gSIdxBuf offset: 0 atIndex: 0];
  [enc setFragmentBuffer: gSPalBuf offset: 0 atIndex: 1];
  [enc setFragmentBytes: ADR(gSSize) length: 8 atIndex: 2];
  [enc drawPrimitives: 4 vertexStart: 0 vertexCount: 4];
  [enc endEncoding];
  [cb presentDrawable: drawable];
  [cb commit]
END Render;

PROCEDURE Tick (block, timer: ObjC.Id);
BEGIN
  px := px + vx; py := py + vy;
  IF (px < 0.0) THEN px := 0.0; vx := -vx END;
  IF (px > VAL(REAL, PW-SW)) THEN px := VAL(REAL, PW-SW); vx := -vx END;
  IF (py < 0.0) THEN py := 0.0; vy := -vy END;
  IF (py > VAL(REAL, PH-SH)) THEN py := VAL(REAL, PH-SH); vy := -vy END;
  SpriteRect;
  Render
END Tick;

VAR timer: ObjC.Id;
BEGIN
  FillPane; BuildSprite;
  gSSize[0] := VAL(SHORTREAL, VAL(REAL, SW)); gSSize[1] := VAL(SHORTREAL, VAL(REAL, SH));
  px := 30.0; py := 40.0; vx := 2.3; vy := 1.7;
  SpriteRect;
  Cocoa.InitApp;
  gWin := Cocoa.MakeWindow(WinW, WinH, "Metal sprite over indexed pane (pure Modula-2)");
  gView := Cocoa.ContentView(gWin);
  IF NOT SetupMetal() THEN WriteString("setup failed"); WriteLn; RETURN END;
  Cocoa.ShowWindow(gWin);
  Render;
  timer := [Cls("NSTimer") scheduledTimerWithTimeInterval: 0.016
                            repeats: TRUE block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
  Cocoa.RunApp
END metalsprites.
