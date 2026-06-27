MODULE metaballs;
FROM ShaderPane IMPORT Create, SetParam, Time, Run;
FROM NM2Math IMPORT sin, cos;
CONST FRAG =
  "fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) { float2 q=in.uv; q.x*=u.aspect; float f=0.0; float2 d0=in.uv-float2(u.p[0],u.p[1]); d0.x*=u.aspect; f+=0.020/max(dot(d0,d0),1e-4); float2 d1=in.uv-float2(u.p[2],u.p[3]); d1.x*=u.aspect; f+=0.020/max(dot(d1,d1),1e-4); float2 d2=in.uv-float2(u.p[4],u.p[5]); d2.x*=u.aspect; f+=0.020/max(dot(d2,d2),1e-4); float2 d3=in.uv-float2(u.p[6],u.p[7]); d3.x*=u.aspect; f+=0.020/max(dot(d3,d3),1e-4); float bw=0.5+0.5*sin(q.x*3.0+u.time*0.5)*sin(q.y*3.0-u.time*0.35); float3 bg=mix(float3(0.05,0.07,0.18),float3(0.16,0.06,0.22),bw); bg+=0.06*cos(6.28318*(float3(0.0,0.33,0.67)+(q.x+q.y)*0.25+u.time*0.1)); float e=smoothstep(0.8,1.4,f); float3 body=0.5+0.5*cos(6.28318*(float3(0.0,0.15,0.3)+f*0.15+u.time*0.2)); float3 col=mix(bg,body,e); col+=float3(0.1,0.2,0.4)*smoothstep(0.5,0.8,f)*(1.0-e); col+=body*0.6*smoothstep(1.4,3.0,f); col=clamp(col,0.0,1.0); return float4(col,1.0); }";
PROCEDURE Tick;
  VAR t: REAL;
BEGIN
  t := Time();
  SetParam(0, 0.5 + 0.30 * cos(t * 0.70));
  SetParam(1, 0.5 + 0.26 * sin(t * 0.90));
  SetParam(2, 0.5 + 0.28 * cos(t * 1.10 + 1.30));
  SetParam(3, 0.5 + 0.30 * sin(t * 0.60 + 0.70));
  SetParam(4, 0.5 + 0.26 * cos(t * 0.50 + 2.50));
  SetParam(5, 0.5 + 0.28 * sin(t * 1.30 + 1.90));
  SetParam(6, 0.5 + 0.30 * cos(t * 0.85 + 3.70));
  SetParam(7, 0.5 + 0.27 * sin(t * 0.75 + 0.40))
END Tick;
BEGIN
  IF NOT Create("Metaballs (Metal shader pane, pure Modula-2)", 640, 480, 1, FRAG) THEN HALT END;
  Run(Tick)
END metaballs.
