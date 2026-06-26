MODULE metalpane;
(* Proof that Modula-2 ALONE can drive Metal — no Rust, no Obj-C, just the
   [recv sel: args] bridge + one EXTERNAL C entry (MTLCreateSystemDefaultDevice).

   An indexed graphics pane on the GPU, to the spec: 256 colours = 16 PER-LINE
   (indices 1..15, 240 lines) + 240 GLOBAL (indices 16..255); index 0 is always
   transparent. The index buffer + palette live in M2 as byte arrays, uploaded to
   MTLBuffers; a Metal fragment shader (compiled at runtime from MSL) does the
   index -> colour lookup, the per-line/global split, and the index-0 discard.

   This module is a self-contained test: a horizontal global-palette rainbow, a
   transparent (index 0) square showing the black clear, and a per-line gradient
   band. Build & run:  newm2-driver run --library library cocoademos/metalpane.mod *)
FROM SYSTEM IMPORT CAST, ADDRESS, ADR, BYTE;
FROM STextIO IMPORT WriteString, WriteLn;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT Metal;

CONST
  PW = 256; PH = 240;               (* pane size in pixels *)
  Scale = 3.0;
  WinW = 768.0; WinH = 720.0;       (* PW*Scale, PH*Scale *)
  IdxBytes = PW * PH;               (* 61440 *)
  PalBytes = (240*16 + 240) * 4;    (* per-line 240*16 + global 240, RGBA = 65280 *)

VAR
  gDev, gQueue, gLayer, gPipe, gIndexBuf, gPalBuf: ObjC.Id;
  gWin: Cocoa.Window; gView: Cocoa.View;
  indexData: ARRAY [0..IdxBytes-1] OF BYTE;
  palData:   ARRAY [0..PalBytes-1] OF BYTE;

PROCEDURE Cls (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls;

PROCEDURE Size (w, h: REAL): ObjC.NSSize;
VAR s: ObjC.NSSize;
BEGIN s.width := w; s.height := h; RETURN s END Size;

(* --- MSL source, built with real newlines (CHR(10)) --------------------- *)
VAR src: ARRAY [0..2047] OF CHAR; srcPos: CARDINAL;
PROCEDURE Ln (s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO src[srcPos] := s[i]; INC(srcPos); INC(i) END;
  src[srcPos] := CHR(10); INC(srcPos); src[srcPos] := 0C
END Ln;

PROCEDURE BuildShader;
BEGIN
  srcPos := 0; src[0] := 0C;
  Ln("#include <metal_stdlib>");
  Ln("using namespace metal;");
  Ln("struct VOut { float4 pos [[position]]; float2 uv; };");
  Ln("vertex VOut vmain(uint vid [[vertex_id]]) {");
  Ln("  float2 q[4]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};");
  Ln("  VOut o; o.pos=float4(q[vid],0,1); o.uv=float2(q[vid].x*0.5+0.5, 0.5-q[vid].y*0.5); return o; }");
  Ln("fragment float4 fmain(VOut in [[stage_in]],");
  Ln("    device const uchar* idx [[buffer(0)]], device const uchar* pal [[buffer(1)]]) {");
  Ln("  uint W=256u, H=240u;");
  Ln("  uint x=uint(in.uv.x*float(W)); uint y=uint(in.uv.y*float(H));");
  Ln("  if(x>=W)x=W-1u; if(y>=H)y=H-1u;");
  Ln("  uint ci=uint(idx[y*W+x]); if(ci==0u) discard_fragment();");
  Ln("  uint k; if(ci<16u){uint l=y; if(l>239u)l=239u; k=l*16u+ci;} else {k=3840u+(ci-16u);}");
  Ln("  uint o=k*4u;");
  Ln("  return float4(float(pal[o]),float(pal[o+1u]),float(pal[o+2u]),float(pal[o+3u]))/255.0; }")
END BuildShader;

(* --- palette + index test data ------------------------------------------ *)
PROCEDURE Wave (n: CARDINAL): CARDINAL;     (* 0..255 triangle *)
BEGIN n := n MOD 512; IF n >= 256 THEN n := 511 - n END; RETURN n END Wave;

PROCEDURE SetPal (off, r, g, b: CARDINAL);
BEGIN
  palData[off]   := VAL(BYTE, r); palData[off+1] := VAL(BYTE, g);
  palData[off+2] := VAL(BYTE, b); palData[off+3] := VAL(BYTE, 255)
END SetPal;

PROCEDURE FillTest;
  VAR x, y, k, g, line: CARDINAL;
BEGIN
  (* global palette 0..239 -> a rainbow (used by indices 16..255) *)
  FOR g := 0 TO 239 DO
    SetPal((3840 + g) * 4, Wave(g*3), Wave(g*3 + 170), Wave(g*3 + 340))
  END;
  (* per-line colour 1 (index 1) on each of the 240 lines -> a vertical gradient *)
  FOR line := 0 TO 239 DO
    SetPal((line*16 + 1) * 4, 40 + line, 200 - (line*200 DIV 240), 230)
  END;
  (* index buffer: horizontal global rainbow, a transparent square, a per-line band *)
  FOR y := 0 TO PH-1 DO
    FOR x := 0 TO PW-1 DO
      k := y*PW + x;
      IF (x >= 100) AND (x < 156) AND (y >= 92) AND (y < 148) THEN
        indexData[k] := VAL(BYTE, 0)                          (* transparent -> black *)
      ELSIF (y >= 180) AND (y < 220) THEN
        indexData[k] := VAL(BYTE, 1)                          (* per-line colour 1 *)
      ELSE
        indexData[k] := VAL(BYTE, 16 + (x*240 DIV PW))        (* global rainbow *)
      END
    END
  END
END FillTest;

(* --- Metal setup -------------------------------------------------------- *)
PROCEDURE ReportError (what: ARRAY OF CHAR; err: ObjC.Id);
  VAR d: ObjC.Id; buf: ARRAY [0..1023] OF CHAR; n: INTEGER;
BEGIN
  WriteString(what); WriteString(": ");
  IF err # NIL THEN
    d := [err localizedDescription]; n := ObjC.GetString(d, buf); WriteString(buf)
  ELSE WriteString("(nil error)") END;
  WriteLn
END ReportError;

PROCEDURE SetupMetal (): BOOLEAN;
  VAR lib, vfn, ffn, pd, ca, err: ObjC.Id;
BEGIN
  gDev := CAST(ObjC.Id, Metal.CreateSystemDefaultDevice());
  IF gDev = NIL THEN WriteString("no Metal device"); WriteLn; RETURN FALSE END;
  gQueue := [gDev newCommandQueue];

  (* a CAMetalLayer hosted by the content view *)
  gLayer := [Cls("CAMetalLayer") layer];
  [gLayer setDevice: gDev];
  [gLayer setPixelFormat: 80];                  (* MTLPixelFormatBGRA8Unorm *)
  [gLayer setFramebufferOnly: TRUE];
  [gLayer setDrawableSize: Size(WinW, WinH)];
  [CAST(ObjC.Id, gView) setLayer: gLayer];
  [CAST(ObjC.Id, gView) setWantsLayer: TRUE];

  (* compile the MSL + build the pipeline *)
  BuildShader;
  err := NIL;
  lib := [gDev newLibraryWithSource: ObjC.NSString(src) options: NIL error: ADR(err)];
  IF lib = NIL THEN ReportError("shader compile failed", err); RETURN FALSE END;
  vfn := [lib newFunctionWithName: ObjC.NSString("vmain")];
  ffn := [lib newFunctionWithName: ObjC.NSString("fmain")];
  pd := [[Cls("MTLRenderPipelineDescriptor") alloc] init];
  [pd setVertexFunction: vfn];
  [pd setFragmentFunction: ffn];
  ca := [[pd colorAttachments] objectAtIndexedSubscript: 0];
  [ca setPixelFormat: 80];
  err := NIL;
  gPipe := [gDev newRenderPipelineStateWithDescriptor: pd error: ADR(err)];
  IF gPipe = NIL THEN ReportError("pipeline failed", err); RETURN FALSE END;

  (* upload the index buffer + palette as MTLBuffers *)
  gIndexBuf := [gDev newBufferWithBytes: ADR(indexData) length: IdxBytes options: 0];
  gPalBuf   := [gDev newBufferWithBytes: ADR(palData)   length: PalBytes options: 0];
  RETURN TRUE
END SetupMetal;

(* --- one rendered frame ------------------------------------------------- *)
PROCEDURE Render;
  VAR drawable, cb, pass, ca, enc: ObjC.Id;
BEGIN
  drawable := [gLayer nextDrawable];
  IF drawable = NIL THEN RETURN END;
  pass := [Cls("MTLRenderPassDescriptor") renderPassDescriptor];
  ca := [[pass colorAttachments] objectAtIndexedSubscript: 0];
  [ca setTexture: [drawable texture]];
  [ca setLoadAction: 2];                          (* MTLLoadActionClear *)
  [ca setStoreAction: 1];                         (* MTLStoreActionStore *)
  cb := [gQueue commandBuffer];
  enc := [cb renderCommandEncoderWithDescriptor: pass];
  [enc setRenderPipelineState: gPipe];
  [enc setFragmentBuffer: gIndexBuf offset: 0 atIndex: 0];
  [enc setFragmentBuffer: gPalBuf offset: 0 atIndex: 1];
  [enc drawPrimitives: 4 vertexStart: 0 vertexCount: 4];   (* MTLPrimitiveTypeTriangleStrip *)
  [enc endEncoding];
  [cb presentDrawable: drawable];
  [cb commit]
END Render;

PROCEDURE Tick (block, timer: ObjC.Id);
BEGIN Render END Tick;

(* --- main --------------------------------------------------------------- *)
VAR timer: ObjC.Id;
BEGIN
  FillTest;
  Cocoa.InitApp;
  gWin := Cocoa.MakeWindow(WinW, WinH, "Metal indexed pane (pure Modula-2)");
  gView := Cocoa.ContentView(gWin);
  IF NOT SetupMetal() THEN WriteString("Metal setup failed"); WriteLn; RETURN END;
  Cocoa.ShowWindow(gWin);
  Render;
  timer := [Cls("NSTimer") scheduledTimerWithTimeInterval: 0.1
                            repeats: TRUE block: ObjC.MakeBlock(CAST(ADDRESS, Tick))];
  Cocoa.RunApp
END metalpane.
