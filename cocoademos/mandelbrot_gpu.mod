MODULE mandelbrot_gpu;
(* A zooming Mandelbrot on the GPU, in pure Modula-2: a Metal fragment shader
   (compiled at runtime) iterates z=z^2+c per pixel with smooth colouring; M2
   drives an auto-dive toward a famous spiral, deepening the iteration cap as it
   descends and looping when float precision runs out. Uses the ShaderPane host.

     newm2-driver run --library library cocoademos/mandelbrot_gpu.mod
   arrows nudge    + / -  zoom    R  reset *)
FROM ShaderPane IMPORT Create, SetParam, Run, KeyHeld, KeyLeft, KeyRight, KeyDown, KeyUp, KeyPlus, KeyMinus, KeyR;

CONST FRAG =
  "fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) { float2 p=in.uv-0.5; p.x*=u.aspect; float span=3.0/max(u.p[2],1e-6); float2 c=float2(u.p[0],u.p[1])+p*span; float2 z=float2(0.0,0.0); uint mi=uint(u.p[3]); uint n=0u; while(n<mi){ float x=z.x*z.x-z.y*z.y+c.x; float y=2.0*z.x*z.y+c.y; z=float2(x,y); if(dot(z,z)>4.0) break; n++; } if(n>=mi) return float4(0.0,0.0,0.0,1.0); float mu=float(n)-log2(max(log2(dot(z,z)),1e-6))+4.0; float t=saturate(mu/float(mi)); float3 a=float3(0.5); float3 b=float3(0.5); float3 cc=float3(1.0); float3 d=float3(0.0,0.33,0.67); float3 col=a+b*cos(6.28318*(cc*t+d+u.time*0.05)); return float4(col,1.0); }";

VAR cx, cy, zoom, miter: REAL;

PROCEDURE Reset;
BEGIN cx := -0.5; cy := 0.0; zoom := 1.0; miter := 140.0 END Reset;

PROCEDURE Tick;
  VAR pan: REAL;
BEGIN
  IF KeyHeld(KeyR) THEN Reset END;
  (* ease toward the famous spiral while shrinking the view *)
  cx := cx + (-0.743643887037151 - cx) * 0.015;
  cy := cy + ( 0.131825904205330 - cy) * 0.015;
  zoom := zoom * 1.012;
  IF miter < 500.0 THEN miter := miter + 0.5 END;
  IF zoom > 80000.0 THEN Reset END;                  (* float32 detail floor -> loop *)
  pan := (3.0/zoom) * 0.05;
  IF KeyHeld(KeyLeft)  THEN cx := cx - pan END;
  IF KeyHeld(KeyRight) THEN cx := cx + pan END;
  IF KeyHeld(KeyUp)    THEN cy := cy - pan END;
  IF KeyHeld(KeyDown)  THEN cy := cy + pan END;
  IF KeyHeld(KeyPlus)  THEN zoom := zoom * 1.03 END;
  IF KeyHeld(KeyMinus) THEN zoom := zoom / 1.04 END;
  SetParam(0, cx); SetParam(1, cy); SetParam(2, zoom); SetParam(3, miter)
END Tick;

BEGIN
  Reset;
  IF NOT Create("Mandelbrot zoom (Metal shader pane, pure Modula-2)", 640, 480, 1, FRAG) THEN HALT END;
  Run(Tick)
END mandelbrot_gpu.
