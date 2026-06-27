MODULE tunnel;
FROM ShaderPane IMPORT Create, Run;
CONST FRAG =
  "fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) { float2 q=in.uv-0.5; q.x*=u.aspect; float rad=length(q); float ang=atan2(q.y,q.x)+u.time*0.18+sin(u.time*0.3)*0.4; float tu=ang/6.28318+0.5; float tv=0.32/max(rad,1e-3)+u.time*0.7; float a=step(0.5,fract(tu*12.0)); float b=step(0.5,fract(tv*5.0)); float chk=abs(a-b); float3 pa=float3(0.5); float3 pb=float3(0.5); float3 pc=float3(1.0); float3 pd=float3(0.0,0.33,0.67); float3 pal=pa+pb*cos(6.28318*(pc*(tv*0.35+tu*0.5+u.time*0.2)+pd)); float3 col=pal*(0.30+0.70*chk); float grid=smoothstep(0.02,0.0,abs(fract(tv*5.0)-0.5)-0.42)+smoothstep(0.02,0.0,abs(fract(tu*12.0)-0.5)-0.42); col+=grid*float3(0.9,1.0,1.1)*0.6; float shade=smoothstep(0.0,0.55,rad); col*=shade; float glow=exp(-rad*7.0); col+=glow*float3(0.15,0.35,0.7); col=clamp(col,0.0,1.0); return float4(col,1.0); }";
PROCEDURE Tick;
BEGIN
END Tick;
BEGIN
  IF NOT Create("Tunnel (Metal shader pane, pure Modula-2)", 640, 480, 1, FRAG) THEN HALT END;
  Run(Tick)
END tunnel.
