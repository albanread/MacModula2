MODULE julia;
(* An animating Julia set on the GPU, in pure Modula-2: a Metal fragment shader
   (compiled at runtime) iterates z=z^2+c per pixel; c sweeps a circle over time,
   so the fractal morphs continuously. Uses the ShaderPane host — M2 supplies the
   MSL + the per-frame params, the GPU does the rest.

     newm2-driver run --library library cocoademos/julia.mod *)
FROM ShaderPane IMPORT Create, SetParam, Time, Run;
FROM NM2Math IMPORT sin, cos;

CONST FRAG =
  "fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) { float2 p=in.uv-0.5; p.x*=u.aspect; float span=3.0/max(u.p[2],1e-6); float2 z=p*span; float2 c=float2(u.p[0],u.p[1]); uint mi=uint(u.p[3]); uint n=0u; while(n<mi){ float x=z.x*z.x-z.y*z.y+c.x; float y=2.0*z.x*z.y+c.y; z=float2(x,y); if(dot(z,z)>4.0) break; n++; } if(n>=mi) return float4(0.0,0.0,0.0,1.0); float mu=float(n)-log2(max(log2(dot(z,z)),1e-6))+4.0; float t=saturate(mu/float(mi)); float3 a=float3(0.5); float3 b=float3(0.5); float3 cc=float3(1.0); float3 d=float3(0.0,0.10,0.20); float3 col=a+b*cos(6.28318*(cc*t+d+u.time*0.04)); return float4(col,1.0); }";

PROCEDURE Tick;
  VAR a: REAL;
BEGIN
  a := Time() * 0.35;                          (* c sweeps a radius-0.7885 circle *)
  SetParam(0, 0.7885 * cos(a));
  SetParam(1, 0.7885 * sin(a));
  SetParam(2, 1.0);                            (* zoom *)
  SetParam(3, 220.0)                           (* maxIter *)
END Tick;

BEGIN
  IF NOT Create("Julia (Metal shader pane, pure Modula-2)", 640, 480, 1, FRAG) THEN HALT END;
  Run(Tick)
END julia.
