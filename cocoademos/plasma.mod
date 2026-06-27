MODULE plasma;
(* Classic flowing colour plasma on the GPU, in pure Modula-2: a Metal fragment
   shader (compiled at runtime) sums several drifting sine waves per pixel into a
   scalar, then maps it through a time-drifting cosine palette. Fully time-driven,
   so the M2 Tick is empty — the GPU does all the work each frame.

     newm2-driver run --library library cocoademos/plasma.mod *)
FROM ShaderPane IMPORT Create, Run;

CONST FRAG =
  "fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) { float2 p=in.uv; float2 q=in.uv-0.5; q.x*=u.aspect; float t=u.time; float r=length(q); float v=sin(p.x*9.0+t)+sin(p.y*11.0-t*1.2)+sin((p.x+p.y)*8.0+t*0.7)+sin(r*14.0-t*2.0); v+=0.5*sin((p.x-p.y)*17.0+t*1.7)+0.5*sin(r*22.0+t*1.3); v*=0.5; float3 col=0.5+0.5*cos(6.28318*(float3(0.0,0.33,0.67)+v*0.55)+t*0.3); col=mix(col,col*col*(3.0-2.0*col),0.35); float vig=smoothstep(1.15,0.35,r); col=mix(col*0.65,col,vig); return float4(clamp(col,0.0,1.0),1.0); }";

PROCEDURE Tick;
BEGIN
END Tick;

BEGIN
  IF NOT Create("Plasma (Metal shader pane, pure Modula-2)", 640, 480, 1, FRAG) THEN HALT END;
  Run(Tick)
END plasma.
