IMPLEMENTATION MODULE ShaderPane;
(* A full-screen MSL fragment shader, driven from Modula-2 over the Obj-C bridge.
   Just a full-screen quad + the user's fmain + a uniforms block; no buffers. *)
FROM SYSTEM IMPORT CAST, ADDRESS, ADR;
IMPORT ObjC;
IMPORT Cocoa;
IMPORT Metal;

VAR
  PW, PH, Sc: CARDINAL;
  gDev, gQueue, gLayer, gPipe: ObjC.Id;
  gWin: Cocoa.Window; gView: Cocoa.View;
  gU: ARRAY [0..9] OF SHORTREAL;             (* time, aspect, p[0..7] = 40 bytes *)
  gHeld: ARRAY [0..15] OF BOOLEAN;
  gTick: TickProc;

PROCEDURE Cls0 (n: ARRAY OF CHAR): ObjC.Id;
BEGIN RETURN CAST(ObjC.Id, ObjC.GetClass(n)) END Cls0;
PROCEDURE Sz (w, h: REAL): ObjC.NSSize;
VAR s: ObjC.NSSize;
BEGIN s.width := w; s.height := h; RETURN s END Sz;

VAR src: ARRAY [0..8191] OF CHAR; sp: CARDINAL;
PROCEDURE E (s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO src[sp]:=s[i]; INC(sp); INC(i) END; src[sp]:=0C END E;

PROCEDURE Create (title: ARRAY OF CHAR; w, h, scale: CARDINAL; fragMSL: ARRAY OF CHAR): BOOLEAN;
  VAR lib, vfn, ffn, pd, ca, err: ObjC.Id; i: CARDINAL;
BEGIN
  PW := w; PH := h; Sc := scale;
  FOR i := 0 TO 9 DO gU[i] := VAL(SHORTREAL, 0.0) END;
  FOR i := 0 TO 15 DO gHeld[i] := FALSE END;
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
  (* header + the user's fragment shader *)
  sp := 0; src[0] := 0C;
  E("#include <metal_stdlib>"); src[sp]:=CHR(10); INC(sp);
  E("using namespace metal;"); src[sp]:=CHR(10); INC(sp);
  E("struct VOut { float4 pos [[position]]; float2 uv; };"); src[sp]:=CHR(10); INC(sp);
  E("struct Uniforms { float time; float aspect; float p[8]; };"); src[sp]:=CHR(10); INC(sp);
  E("vertex VOut vmain(uint vid [[vertex_id]]) {"); src[sp]:=CHR(10); INC(sp);
  E("  float2 q[4]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};"); src[sp]:=CHR(10); INC(sp);
  E("  VOut o; o.pos=float4(q[vid],0,1); o.uv=float2(q[vid].x*0.5+0.5, 0.5-q[vid].y*0.5); return o; }"); src[sp]:=CHR(10); INC(sp);
  E(fragMSL); src[sp]:=CHR(10); INC(sp);
  err := NIL;
  lib := [gDev newLibraryWithSource: ObjC.NSString(src) options: NIL error: ADR(err)];
  IF lib = NIL THEN RETURN FALSE END;
  vfn := [lib newFunctionWithName: ObjC.NSString("vmain")];
  ffn := [lib newFunctionWithName: ObjC.NSString("fmain")];
  pd := [[Cls0("MTLRenderPipelineDescriptor") alloc] init];
  [pd setVertexFunction: vfn]; [pd setFragmentFunction: ffn];
  ca := [[pd colorAttachments] objectAtIndexedSubscript: 0]; [ca setPixelFormat: 80];
  err := NIL;
  gPipe := [gDev newRenderPipelineStateWithDescriptor: pd error: ADR(err)];
  IF gPipe = NIL THEN RETURN FALSE END;
  Cocoa.ShowWindow(gWin);
  RETURN TRUE
END Create;

PROCEDURE SetParam (i: CARDINAL; v: REAL);
BEGIN IF i <= 7 THEN gU[2+i] := VAL(SHORTREAL, v) END END SetParam;
PROCEDURE Time (): REAL; BEGIN RETURN VAL(REAL, gU[0]) END Time;
PROCEDURE Aspect (): REAL; BEGIN RETURN VAL(REAL, gU[1]) END Aspect;

PROCEDURE Render;
  VAR drawable, cb, pass, ca, enc: ObjC.Id;
BEGIN
  drawable := [gLayer nextDrawable];
  IF drawable = NIL THEN RETURN END;
  pass := [Cls0("MTLRenderPassDescriptor") renderPassDescriptor];
  ca := [[pass colorAttachments] objectAtIndexedSubscript: 0];
  [ca setTexture: [drawable texture]]; [ca setLoadAction: 2]; [ca setStoreAction: 1];
  cb := [gQueue commandBuffer];
  enc := [cb renderCommandEncoderWithDescriptor: pass];
  [enc setRenderPipelineState: gPipe];
  [enc setFragmentBytes: ADR(gU) length: 40 atIndex: 0];
  [enc drawPrimitives: 4 vertexStart: 0 vertexCount: 4];
  [enc endEncoding]; [cb presentDrawable: drawable]; [cb commit]
END Render;

PROCEDURE KeyHeld (key: CARDINAL): BOOLEAN;
BEGIN IF key <= 15 THEN RETURN gHeld[key] ELSE RETURN FALSE END END KeyHeld;

PROCEDURE Quit;
BEGIN [CAST(ObjC.Id, [Cls0("NSApplication") sharedApplication]) terminate: NIL] END Quit;

PROCEDURE KeyCodeToId (kc: CARDINAL): CARDINAL;
BEGIN
  CASE kc OF
    123: RETURN KeyLeft | 124: RETURN KeyRight | 125: RETURN KeyDown | 126: RETURN KeyUp
  | 24: RETURN KeyPlus | 69: RETURN KeyPlus | 27: RETURN KeyMinus | 78: RETURN KeyMinus | 15: RETURN KeyR
  ELSE RETURN 0 END
END KeyCodeToId;

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
BEGIN
  gU[0] := VAL(SHORTREAL, VAL(REAL, gU[0]) + 0.016667);    (* advance time *)
  gU[1] := VAL(SHORTREAL, VAL(REAL, PW) / VAL(REAL, PH));  (* aspect *)
  gTick();
  Render
END TickBlock;

PROCEDURE Run (tick: TickProc);
  VAR pv: PaneView; t: ObjC.Id;
BEGIN
  gTick := tick;
  NEW(pv);
  [CAST(ObjC.Id, gWin) setContentView: CAST(ObjC.Id, pv)];
  [CAST(ObjC.Id, pv) setLayer: gLayer]; [CAST(ObjC.Id, pv) setWantsLayer: TRUE];
  [CAST(ObjC.Id, gWin) makeFirstResponder: CAST(ObjC.Id, pv)];
  t := [Cls0("NSTimer") scheduledTimerWithTimeInterval: 0.016
                        repeats: TRUE block: ObjC.MakeBlock(CAST(ADDRESS, TickBlock))];
  Cocoa.RunApp
END Run;

BEGIN
  PW := 0; PH := 0
END ShaderPane.
