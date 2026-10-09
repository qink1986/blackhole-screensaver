#version 330
in vec2 vUv;
uniform float iTime;
uniform vec2  iResolution;
uniform float uStarGain;
uniform float uDiskOpacity;
uniform float uDoppler;
uniform float uSkySeed;
uniform vec2 uSceneCenter;
uniform float uApparentRadius;
uniform vec4 uDiskLookA; // temperature, inclination, roll, inner radius
uniform vec4 uDiskLookB; // outer radius, baseline opacity, baseline Doppler, beam
uniform vec4 uDiskLookC; // gain, contrast, wind, material speed
uniform float uSceneExposure;

// --- static-scene and rendering tunables ---
const float LENS_DEPTH    = 13.0000;
const float DISK_MATERIAL_RATE = 0.2500;
// Continuous filaments flow in one direction, while their radius-dependent
// shear remains bounded instead of accumulating into unresolved winding.
const float DISK_FILAMENT_FLOW_RATE = 0.0500;
const float DISK_FILAMENT_SHEAR_RATE = 0.0350;
const float DISK_FILAMENT_SHEAR_AMPLITUDE = 0.3500;
// Deliberately visible world-direction translation, independent of the body.
// uSkySeed selects one fixed random direction for each screensaver launch.
const float SKY_FLOW_SPEED = 0.1500;
const float SKY_FLOW_DISTANCE_PER_PHASE = 0.2247;
const float WORK_AREA     = 0.0;
const float DISK_LOD_CRITICAL_GAIN = 150.0000;
// A finite analytic disk body with deliberately slight, constant thickness.
// Its contact query never consumes extra geodesic steps.
const float DISK_HALF_THICKNESS = 0.0350;
const float DISK_CONTACT_PROBE_DISTANCE = 0.0060;
// Ray-space silhouette of the non-emissive inner inflow between the photon
// ring and visible disk. It blocks only background, never disk emission.
const float INNER_FLOW_SKY_OCCLUDER_START = 1.4200;
const float INNER_FLOW_SKY_OCCLUDER_END = 1.7200;
#define N_STEPS 48
#define B_CRIT 2.5980762

// Hash helper for disk structure and the inertial sky.
float hash21(vec2 p){p=fract(p*vec2(234.34,435.345));p+=dot(p,p+34.23);return fract(p.x*p.y);}

struct DiskLook { float temp,incl,roll,inner,outer,opac,dopp,beam,gain,contr,wind,speed,expo,star; };

float vnoiseWrapY(vec2 p,float perY){
  vec2 i=floor(p),f=fract(p);f=f*f*(3.0-2.0*f);
  float y0=mod(i.y,perY),y1=mod(i.y+1.0,perY);
  return mix(mix(hash21(vec2(i.x,y0)),hash21(vec2(i.x+1.0,y0)),f.x),
             mix(hash21(vec2(i.x,y1)),hash21(vec2(i.x+1.0,y1)),f.x),f.y);
}
// Derivative-free noise LOD is safe inside the fragment-varying disk-hit path.
float filteredVnoiseWrapY(vec2 p,float perY,float footprint){
  float detail=1.0-smoothstep(0.20,0.60,footprint);
  return mix(0.5,vnoiseWrapY(p,perY),detail);
}
float diskNoiseFootprint(float radialScale,float angularPeriod,float swirlScale,float rc,float dSwirl,float b,float W){
  float pixelB=W/max(iResolution.y,1.0);
  float critical=pixelB/max(abs(b-B_CRIT),pixelB);
  float rayFootprint=pixelB*(1.0+DISK_LOD_CRITICAL_GAIN*critical);
  float radialFootprint=radialScale*rayFootprint;
  float angularFootprint=angularPeriod*rayFootprint/(6.2831853*max(rc,1.0));
  float swirlFootprint=swirlScale*abs(dSwirl)*rayFootprint;
  return max(radialFootprint,length(vec2(angularFootprint,swirlFootprint)));
}
// Negative means inside the finite thick disk body. Its center is retained as
// a non-emissive inner flow, so the same entry rule protects the black cavity.
float diskBodyField(vec3 point,vec3 normal,float rout){
  float height=dot(point,normal);
  vec3 diskPoint=point-normal*height;
  float rc=length(diskPoint);
  return max(abs(height)-DISK_HALF_THICKNESS,rc-rout);
}
float diskEntryCandidate(vec3 x0,vec3 x1,vec3 normal,float rout,float tc){
  if(tc<0.0||tc>1.0)return 2.0;
  float probe=min(0.0200,DISK_CONTACT_PROBE_DISTANCE/max(length(x1-x0),0.0200));
  float before=diskBodyField(mix(x0,x1,max(0.0,tc-probe)),normal,rout);
  float after=diskBodyField(mix(x0,x1,min(1.0,tc+probe)),normal,rout);
  return before>0.0&&after<=0.0?tc:2.0;
}
// A bounded analytic chord query finds the two height faces and the outer rim
// without subdividing the 48-step Schwarzschild integration.
float diskBodyEntry(vec3 x0,vec3 x1,vec3 normal,float rout){
  float s0=dot(x0,normal),s1=dot(x1,normal),ds=s1-s0;
  float entry=2.0;
  if(abs(ds)>1e-6){
    entry=min(entry,diskEntryCandidate(x0,x1,normal,rout,(DISK_HALF_THICKNESS-s0)/ds));
    entry=min(entry,diskEntryCandidate(x0,x1,normal,rout,(-DISK_HALF_THICKNESS-s0)/ds));
  }
  vec3 p0=x0-normal*s0,p1=x1-normal*s1,d=p1-p0;
  float qa=dot(d,d);
  if(qa>1e-8){
    float qb=2.0*dot(p0,d),qc=dot(p0,p0)-rout*rout;
    float discriminant=qb*qb-4.0*qa*qc;
    if(discriminant>=0.0){
      float root=sqrt(discriminant);
      entry=min(entry,diskEntryCandidate(x0,x1,normal,rout,(-qb-root)/(2.0*qa)));
      entry=min(entry,diskEntryCandidate(x0,x1,normal,rout,(-qb+root)/(2.0*qa)));
    }
  }
  return entry;
}
vec2 rot(vec2 v,float a){float c=cos(a),s=sin(a);return vec2(c*v.x-s*v.y,s*v.x+c*v.y);}
vec3 blackbody(float T){
  float t=clamp(T,1500.0,40000.0)/100.0;
  float r=t<=66.0?1.0:clamp(1.292936*pow(t-60.0,-0.1332047),0.0,1.0);
  float g=t<=66.0?clamp(0.3900816*log(t)-0.6318414,0.0,1.0):clamp(1.1298909*pow(t-60.0,-0.0755148),0.0,1.0);
  float b=t>=66.0?1.0:(t<=19.0?0.0:clamp(0.5432068*log(t-10.0)-1.1962540,0.0,1.0));
  return vec3(r,g,b);
}
vec3 viewWorldDirection(vec2 uv,float aspect){
  return normalize(vec3((uv-0.5)*vec2(aspect,1.0),-1.0));
}
// Project the traced escaping ray to a fixed local source plane, undo the
// lens-space roll/scale, then put that source back around the fixed body center.
// With no deflection, sourceScreenTangent equals localImageTangent, so this
// returns viewWorldDir exactly instead of translating the entire sky patch.
vec3 lensedWorldDirection(vec3 viewWorldDir,vec2 localImageTangent,vec3 localExitPoint,vec3 localExitDir,float roll,float lensScale){
  // Near-tangential exits cannot provide a stable source-plane projection.
  // Preserve the outgoing negative direction for a bounded, blendable map.
  float safeExitZ=min(localExitDir.z,-0.0200);
  float sourceTravel=(-LENS_DEPTH-localExitPoint.z)/safeExitZ;
  vec3 sourceHit=localExitPoint+localExitDir*sourceTravel;
  vec2 sourceLensTangent=rot(sourceHit.xy,-roll)/lensScale;
  vec2 sourceScreenTangent=vec2(sourceLensTangent.x,-sourceLensTangent.y);
  vec2 viewTangent=viewWorldDir.xy/max(-viewWorldDir.z,0.05);
  vec2 centerTangent=viewTangent-localImageTangent;
  return normalize(vec3(centerTangent+sourceScreenTangent,-1.0));
}
// The catalogue lives in a camera/world-direction tangent plane. A common
// translation makes the distant sky drift without rotating around the body.
const vec2 SKY_CLUSTER_CATALOG[8]=vec2[8](
  vec2(-0.68,0.42),vec2(-0.43,-0.34),vec2(-0.10,0.16),vec2(0.20,-0.52),
  vec2(0.37,0.38),vec2(0.64,-0.14),vec2(-0.73,-0.05),vec2(0.07,0.59));

vec2 skyCoordinates(vec3 worldDir){
  vec2 worldTangent=worldDir.xy/max(-worldDir.z,0.05);
  float skyTime=iTime*SKY_FLOW_SPEED;
  vec2 skySeedOffset=(vec2(hash21(vec2(uSkySeed*17.0,7.0)),
                            hash21(vec2(uSkySeed*29.0,13.0)))-0.5)*0.18;
  // Randomize direction once per launch, not over time: the sky translates in
  // one straight world-space direction and never orbits the black hole.
  float skyFlowAngle=6.2831853*hash21(vec2(uSkySeed*107.0,59.0));
  vec2 skyFlowDirection=vec2(cos(skyFlowAngle),sin(skyFlowAngle));
  vec2 skyDrift=skyTime*SKY_FLOW_DISTANCE_PER_PHASE*skyFlowDirection+skySeedOffset;
  return worldTangent-skyDrift;
}

vec3 starSprite(vec2 skyTangent,vec2 source,float core,float seed,float strength){
  float radius=core*(0.72+0.62*hash21(vec2(seed,13.0)));
  vec2 delta=skyTangent-source;
  float dist2=dot(delta,delta);
  float spark=1.0-smoothstep(radius*radius,(radius*1.70)*(radius*1.70),dist2);
  float hue=hash21(vec2(seed+0.7,uSkySeed*37.0));
  vec3 tint=mix(vec3(1.0,0.74,0.48),vec3(0.62,0.80,1.0),hue);
  return tint*spark*strength;
}

vec3 cellStar(vec2 skyTangent,vec2 cell,float cells,float threshold,float layerSeed,float core){
  float occupied=hash21(cell+vec2(layerSeed,uSkySeed*67.0));
  if(occupied<=threshold)return vec3(0.0);
  vec2 source=(cell+vec2(hash21(cell+vec2(layerSeed+3.1,17.0)),
                          hash21(cell+vec2(layerSeed+11.7,31.0))))/cells;
  float strength=(0.42+1.35*(occupied-threshold)/max(1.0-threshold,1e-3));
  return starSprite(skyTangent,source,core,occupied+layerSeed,strength);
}

vec3 cellStars(vec2 skyTangent,float cells,float threshold,float layerSeed,float core,float gatherNeighbors){
  vec2 cell=floor(skyTangent*cells);
  if(gatherNeighbors<=0.0)return cellStar(skyTangent,cell,cells,threshold,layerSeed,core);
  // Every deflected path is seam-safe, but only a sample within the largest
  // possible sprite tail of a catalogue-cell edge pays for the 3x3 gather.
  // This prevents entry/exit flashes without blurring stars or taxing the
  // whole lensed region; direct sky remains the one-cell path above.
  vec2 cellLocal=fract(skyTangent*cells);
  float nearestCellEdge=min(min(cellLocal.x,1.0-cellLocal.x),min(cellLocal.y,1.0-cellLocal.y));
  float seamReach=core*cells*2.30;
  if(nearestCellEdge>=seamReach)return cellStar(skyTangent,cell,cells,threshold,layerSeed,core);
  vec3 field=vec3(0.0);
  for(int offsetY=-1;offsetY<=1;offsetY++){
    for(int offsetX=-1;offsetX<=1;offsetX++){
      field+=cellStar(skyTangent,cell+vec2(float(offsetX),float(offsetY)),cells,threshold,layerSeed,core);
    }
  }
  return field;
}

vec3 stars(vec3 worldDir,float gatherNeighbors){
  vec2 skyTangent=skyCoordinates(worldDir);
  float core=1.35/max(iResolution.y,1.0);
  vec3 field=vec3(0.0);
  // Four stochastic layers provide a denser deep field without changing the
  // size or energy of an individual catalogue star.
  field+=cellStars(skyTangent,10.0,0.400,3.0,core*1.18,gatherNeighbors);
  field+=cellStars(skyTangent,17.0,0.680,19.0,core*0.92,gatherNeighbors);
  field+=cellStars(skyTangent,27.0,0.840,43.0,core*0.72,gatherNeighbors);
  field+=cellStars(skyTangent,41.0,0.920,71.0,core*0.58,gatherNeighbors);
  float angle=6.2831853*hash21(vec2(uSkySeed*43.0,23.0));
  vec2 offset=(vec2(hash21(vec2(uSkySeed*53.0,11.0)),
                    hash21(vec2(uSkySeed*61.0,31.0)))-0.5)*0.13;
  float layoutScale=0.88+0.10*hash21(vec2(uSkySeed*73.0,47.0));
  for(int clusterIndex=0;clusterIndex<8;clusterIndex++){
    float clusterSeed=hash21(vec2(float(clusterIndex)+uSkySeed*89.0,29.0));
    vec2 cluster=rot(SKY_CLUSTER_CATALOG[clusterIndex]*layoutScale,angle)+offset;
    float clusterRadius=0.010+0.014*clusterSeed;
    vec2 clusterDelta=skyTangent-cluster;
    float haze=1.0-smoothstep(clusterRadius*clusterRadius,(clusterRadius*1.75)*(clusterRadius*1.75),dot(clusterDelta,clusterDelta));
    float hue=hash21(vec2(clusterSeed+2.7,uSkySeed*97.0));
    vec3 hazeTint=mix(vec3(0.009,0.004,0.002),vec3(0.002,0.004,0.011),hue);
    field+=hazeTint*haze;
    float memberAngle=6.2831853*hash21(vec2(clusterSeed*101.0,79.0));
    vec2 memberAxis=vec2(cos(memberAngle),sin(memberAngle));
    field+=starSprite(skyTangent,cluster,core*(1.05+0.38*clusterSeed),clusterSeed,1.10+0.90*clusterSeed);
    field+=starSprite(skyTangent,cluster+memberAxis*clusterRadius*0.58,core*0.72,clusterSeed+17.0,0.52+0.60*clusterSeed);
    field+=starSprite(skyTangent,cluster-memberAxis*clusterRadius*0.43,core*0.64,clusterSeed+31.0,0.44+0.52*clusterSeed);
  }
  return field;
}
vec3 spaceBackground(vec3 worldDir){
  vec2 skyTangent=skyCoordinates(worldDir);
  float vertical=clamp(0.5+skyTangent.y,0.0,1.0);
  float dustBand=exp(-18.0*pow(skyTangent.y+0.13*sin(skyTangent.x*3.1),2.0));
  return vec3(0.0012,0.0010,0.0020)*(0.82+0.18*vertical)+vec3(0.0018,0.0010,0.0034)*dustBand;
}
// Every sky path samples this same inertial directional source.
vec3 skyRadiance(vec3 worldDir,float starGain,float gatherNeighbors){
  return spaceBackground(worldDir)+stars(worldDir,gatherNeighbors)*starGain;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 res=iResolution.xy;
  // Ghostty supplies top-down fragment coordinates; OpenGL gl_FragCoord is bottom-up.
  vec2 uv=vec2(fragCoord.x,res.y-fragCoord.y)/res;float aspect=res.x/res.y;
  DiskLook L=DiskLook(
    uDiskLookA.x,uDiskLookA.y,uDiskLookA.z,uDiskLookA.w,
    uDiskLookB.x,uDiskLookB.y,uDiskLookB.z,uDiskLookB.w,
    uDiskLookC.x,uDiskLookC.y,uDiskLookC.z,uDiskLookC.w,
    uSceneExposure,0.0);
  L.opac=clamp(L.opac*clamp(uDiskOpacity,0.0,1.0)/0.90,0.0,1.0);
  L.dopp=clamp(L.dopp*clamp(uDoppler,0.0,1.0)/0.60,0.0,1.0);
  float filamentFlowPhase=iTime*DISK_FILAMENT_FLOW_RATE*abs(L.speed);
  float filamentShearPulse=sin(iTime*DISK_FILAMENT_SHEAR_RATE)*DISK_FILAMENT_SHEAR_AMPLITUDE;
  float rin=max(L.inner,1.6),rout=max(L.outer,rin+0.5);
  float rh=uApparentRadius;
  vec2 center=uSceneCenter;
  vec3 viewWorldDir=viewWorldDirection(uv,aspect);
  float skyGain=clamp(uStarGain,0.0,1.0);
  vec3 plainBg=skyRadiance(viewWorldDir,skyGain,0.0);
  float dil=1.0;
  vec2 p=(uv-center)*vec2(aspect,1.0);
  float W=B_CRIT/max(rh,1e-4);vec2 pr=rot(vec2(p.x,-p.y),L.roll)*W;float b=length(pr);
  float bmax=rout+3.0;float Z0=max(14.0,rout+5.0);
  // Keep weak but continuous deflection visible well beyond the photon ring.
  // Four critical radii remain inside the existing rout+3 traced domain.
  float lensBlend=1.0-smoothstep(B_CRIT*1.35,B_CRIT*4.00,b);
  if(b>=bmax){fragColor=vec4(plainBg,1.0);return;}
  vec3 x=vec3(pr,Z0),v=vec3(0.0,0.0,-1.0);float h2=dot(pr,pr);
  float ci=cos(L.incl),si=sin(L.incl);vec3 n=vec3(0.0,si,ci),e2=vec3(0.0,ci,-si);
  float sdir=L.speed<0.0?-1.0:1.0;
  vec3 emitc=vec3(0.0);float trans=1.0;bool captured=false;
  vec3 xPrev=x;
  for(int i=0;i<N_STEPS;i++){
    float r2=dot(x,x);if(r2<1.0){captured=true;break;}
    if(x.z<-Z0&&v.z<0.0)break;if(r2>4.0*Z0*Z0)break;
    float r=sqrt(r2);float dt=clamp(0.16*r,0.03,1.5);
    vec3 a=-1.5*h2*x/(r2*r2*r);v+=a*(0.5*dt);x+=v*dt;
    r2=dot(x,x);r=sqrt(r2);a=-1.5*h2*x/(r2*r2*r);v+=a*(0.5*dt);
    float diskEntry=diskBodyEntry(xPrev,x,n,rout);
    // Evaluate once on each outside-to-inside body entry. A paired exit is
    // ignored, while later entries after a genuine exit remain eligible.
    if(diskEntry<=1.0&&trans>0.02){vec3 xc=mix(xPrev,x,diskEntry);
      float diskHeight=dot(xc,n);vec3 diskPoint=xc-n*diskHeight;
      float rc=length(diskPoint);
      // The truncated emissive disk has a non-emissive plunging region below
      // rin. It smoothly blocks background at its thick-body entry so lensed
      // stars cannot visibly pass through the dark inner disk volume.
      if(rc<rin){
        float innerCavityTransmission=smoothstep(rin*0.82,rin*0.98,rc);
        trans*=innerCavityTransmission;
      }else if(rc<rout){
        float band=smoothstep(rin,rin*1.25,rc)*(1.0-smoothstep(rout*0.70,rout,rc));
        float phi=atan(dot(diskPoint,e2),diskPoint.x),turns=phi/6.2831853,kep=pow(rin/rc,1.5);
        float gloc=sqrt(max(1.0-1.5/rc,0.02));
        // A shared directional flow keeps the filament field coherent. Only a
        // bounded radial pulse shears it, preventing old material from winding
        // into an ever-denser unresolved sheet during long screensaver runs.
        float boundedShear=filamentShearPulse*kep*gloc*dil;
        float swirl=rc*L.wind*0.12-(filamentFlowPhase+boundedShear)*sdir;
        vec2 streakA=vec2(rc*1.8,turns*11.0+swirl*1.20);
        vec2 streakB=vec2(rc*0.7,turns*5.0+swirl*0.70+7.0);
        float dKep=-1.5*kep/rc;
        float dGloc=0.75/(rc*rc*max(gloc,1e-3));
        float dSwirl=0.12*L.wind-filamentShearPulse*dil*sdir*(dKep*gloc+kep*dGloc);
        float footprintA=diskNoiseFootprint(1.8,11.0,1.20,rc,dSwirl,b,W);
        float footprintB=diskNoiseFootprint(0.7,5.0,0.70,rc,dSwirl,b,W);
        float innerRing=1.0-smoothstep(1.15*rin,1.70*rin,rc);
        float partialUnresolved=smoothstep(0.15,0.45,max(footprintA,footprintB));
        float ringLodBoost=1.0+1.25*innerRing*partialUnresolved;
        footprintA*=ringLodBoost;footprintB*=ringLodBoost;
        float streaks=filteredVnoiseWrapY(streakA,11.0,footprintA)*0.70
                     +filteredVnoiseWrapY(streakB,5.0,footprintB)*0.30;
        streaks=0.58+0.58*L.contr*streaks*streaks;
        vec3 gasdir=normalize(cross(n,diskPoint))*sdir;
        float beta=clamp(inversesqrt(max(2.0*(rc-1.0),0.2)),0.0,0.99);
        float g2=gloc/max(1.0+beta*dot(gasdir,normalize(v)),0.05);g2=mix(1.0,g2,L.dopp);
        float xpr=max(1.0-sqrt(rin/rc),0.0);
        float tprof=pow(rin/rc,0.75)*pow(xpr,0.25)/0.488;
        vec3 cbb=blackbody(L.temp*tprof*g2);float boost=pow(g2,L.beam);
        float density=band*streaks;
        emitc+=trans*cbb*(L.gain*2.2*density*tprof*tprof*boost);
        trans*=1.0-clamp(L.opac*density,0.0,1.0);
    }}
    xPrev=x;
  }
  if(!captured&&dot(x,x)<4.0)captured=true;
  // Captured rays remain the hard physical shadow. All other rays have a
  // direct-sky fallback, rather than a binary v.z branch that can flash near
  // a nearly tangential 48-step exit.
  vec3 sky=captured?vec3(0.0):plainBg;
  if(!captured){
    vec3 lensedWorldDir=lensedWorldDirection(viewWorldDir,p,x,v,L.roll,W);
    // Only the truly near-tangential exit band falls back to direct sky.
    // Stable outward rays retain their full lens deflection.
    float exitProjectionWeight=1.0-smoothstep(-0.0200,-0.0050,v.z);
    float skyLensBlend=lensBlend*exitProjectionWeight;
    // Enable only seam-aware catalogue gathering on deflected paths. The helper
    // performs its 3x3 work only at a cell edge; this is not star filtering.
    float lensStarGather=step(0.001,skyLensBlend);
    // Interpolate the sampled direction, not two independently visible sky
    // colors. This leaves one continuously warped star feature whose speed and
    // shear are determined by the local lens map instead of a body-local fade.
    vec3 sampledWorldDir=normalize(mix(viewWorldDir,lensedWorldDir,skyLensBlend));
    sky=skyRadiance(sampledWorldDir,skyGain,lensStarGather);
  }
  // Some escaping rays never enter the slim disk body, so its local
  // plunging occluder cannot hide their background. This smooth ray-space
  // inner-flow silhouette removes stars from the intended black gap while
  // leaving accumulated disk emission untouched.
  float innerFlowSkyTransmission=smoothstep(
    B_CRIT*INNER_FLOW_SKY_OCCLUDER_START,B_CRIT*INNER_FLOW_SKY_OCCLUDER_END,b);
  sky*=innerFlowSkyTransmission;
  vec3 col=sky*trans+(vec3(1.0)-exp(-emitc*L.expo));
  fragColor=vec4(col,1.0);
}
out vec4 _fragOut;
void main(){vec4 c;mainImage(c,gl_FragCoord.xy);_fragOut=c;}
