MODULE raymarch;
(* A raymarched SDF scene on the GPU, in pure Modula-2: a Metal fragment shader
   (compiled at runtime) marches a signed-distance field per pixel. The scene is a
   ground checker plane plus a bobbing sphere gooey-unioned (smin) with a torus.
   An orbiting camera circles the scene; a key light gives diffuse shading with
   marched soft shadows, ambient, distance fog and gamma. Fully time-driven, so the
   Modula-2 Tick is empty — the GPU does all the work from u.time.

     newm2-driver run --library library cocoademos/raymarch.mod *)
FROM ShaderPane IMPORT Create, Run;

CONST FRAG =
  "float sdSphere(float3 p, float r){ return length(p)-r; } float sdTorus(float3 p, float2 t){ float2 q=float2(length(p.xz)-t.x, p.y); return length(q)-t.y; } float smin(float a, float b, float k){ float h=clamp(0.5+0.5*(b-a)/max(k,1e-6),0.0,1.0); return mix(b,a,h)-k*h*(1.0-h); } float map(float3 p, float t, thread int& id){ float dg=p.y+1.0; float3 sp=p-float3(-1.1,0.2+0.25*sin(t*1.5),0.0); float ds=sdSphere(sp,0.7); float3 tp=p-float3(1.1,0.1,0.0); float dt=sdTorus(tp,float2(0.6,0.28)); float dobj=smin(ds,dt,0.6); if(dg<dobj){ id=0; return dg; } id=1; return dobj; } float mapd(float3 p, float t){ int id; return map(p,t,id); } float3 calcNormal(float3 p, float t){ float2 e=float2(0.001,0.0); float3 n=float3( mapd(p+e.xyy,t)-mapd(p-e.xyy,t), mapd(p+e.yxy,t)-mapd(p-e.yxy,t), mapd(p+e.yyx,t)-mapd(p-e.yyx,t)); return normalize(n+1e-9); } float softShadow(float3 ro, float3 rd, float t){ float res=1.0; float tt=0.05; for(int i=0;i<48;i++){ float3 pos=ro+rd*tt; int id; float h=map(pos,t,id); res=min(res, 12.0*max(h,0.0)/max(tt,1e-4)); if(h<0.001 || tt>20.0) break; tt+=clamp(h,0.02,0.4); } return clamp(res,0.0,1.0); } fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) { float t=u.time; float asp=max(u.aspect,1e-4); float a=t*0.4; float3 ro=float3(3.6*cos(a),1.7,3.6*sin(a)); float3 target=float3(0.0,0.0,0.0); float3 forward=normalize(target-ro+1e-9); float3 right=normalize(cross(float3(0.0,1.0,0.0),forward)+1e-9); float3 up=cross(forward,right); float2 uv=in.uv; float3 rd=normalize(forward*1.6 + (uv.x*2.0-1.0)*asp*right + (1.0-uv.y*2.0)*up); float3 zenith=float3(0.18,0.34,0.62); float3 horizon=float3(0.75,0.82,0.92); float3 sky=mix(horizon,zenith,clamp(uv.y,0.0,1.0)); float3 col=sky; float tt=0.0; int hitId=-1; float3 pos=ro; bool hit=false; for(int i=0;i<90;i++){ pos=ro+rd*tt; int id; float d=map(pos,t,id); if(d<0.001){ hit=true; hitId=id; break; } tt+=d; if(tt>40.0) break; } if(hit){ float3 n=calcNormal(pos,t); float3 L=normalize(float3(0.6,0.8,0.4)); float diff=max(dot(n,L),0.0); float sh=softShadow(pos+n*0.02,L,t); float3 albedo; if(hitId==0){ float c=fract((floor(pos.x)+floor(pos.z))*0.5)*2.0; albedo=mix(float3(0.16,0.18,0.24),float3(0.78,0.80,0.86),c); } else { albedo=float3(0.95,0.55,0.25); } float skyAmb=0.5+0.5*n.y; float3 amb=albedo*mix(float3(0.10,0.11,0.14),float3(0.30,0.34,0.42),skyAmb); float3 lit=albedo*diff*sh*float3(1.05,1.0,0.92); float3 hcol=amb+lit; float3 H=normalize(L-rd); float spec=pow(max(dot(n,H),0.0),48.0)*sh; hcol+=float3(1.0)*spec*0.4; float fog=1.0-exp(-tt*0.025); col=mix(hcol,sky,clamp(fog,0.0,1.0)); } col=clamp(col,0.0,1.0); col=pow(col,float3(1.0/2.2)); return float4(col,1.0); }";

PROCEDURE Tick;
BEGIN
END Tick;

BEGIN
  IF NOT Create("Raymarched scene (Metal shader pane, pure Modula-2)", 640, 480, 1, FRAG) THEN HALT END;
  Run(Tick)
END raymarch.
