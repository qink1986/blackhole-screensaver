// blackhole_screensaver.c — Windows screensaver host for the black hole shader
// Build: cl /O2 /link /SUBSYSTEM:WINDOWS /OUT:blackhole.scr blackhole_screensaver.c opengl32.lib
// Or use the included Makefile / build.bat

#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <GL/gl.h>

// Manual GL type/enum definitions to avoid glext.h dependency
typedef char GLchar;
typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
#define GL_VERTEX_SHADER_ARB          0x8B31
#define GL_FRAGMENT_SHADER_ARB        0x8B30
#define GL_COMPILE_STATUS              0x8B81
#define GL_LINK_STATUS                 0x8B82
#define GL_INFO_LOG_LENGTH             0x8B84
#define GL_COLOR_BUFFER_BIT           0x00004000
#define GL_DEPTH_BUFFER_BIT           0x00000100
#define GL_TRIANGLE_STRIP             0x0005
#define GL_TRUE                       1
#define GL_FALSE                      0

#pragma comment(lib, "comctl32.lib")
#pragma comment(linker, "/manifestdependency:\"type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

// ============================================================ globals ==
static HGLRC hRC;
static HDC   hDC;
static HWND  hWnd;
static HINSTANCE hInst;
static int   g_W, g_H;
static int   g_preview = 0;   // running in preview mode
static int   g_configured = 0;
static DWORD g_tick0;
static int   g_exitKey = 0;
static int   g_exitMouse = 0;
static POINT g_mousePrev;
static int   g_mouseMoved = 0;
static int   g_fullscreen = 0;
static int   g_cursorHideCount = 0;
static HCURSOR g_savedCursor;

// ============================================================ config ==
// Config stored in registry under HKCU\Software\BlackHoleScreensaver
#define REG_KEY "Software\\BlackHoleScreensaver"
static int   cfg_starBrightness = 30;   // STAR_GAIN * 100
static int   cfg_diskOpacity    = 90;   // DISK_OPACITY * 100
static int   cfg_doppler        = 60;   // DOPPLER_MIX * 100

// ============================================================ shader source ==
// The GLSL source is embedded as a string. The shader declares:
//   uniform float iTime;
//   uniform vec2  iResolution;
// We provide these from the host. The shader's mainImage() is called
// for every fragment.

static const char* shaderSource =
"// --- tunables (screensaver-adapted) ---\n"
"const float HOLE_RADIUS   = 0.0200;\n"
"const float LENS_DEPTH    = 13.0000;\n"
"const float DISK_INNER    = 1.8000;\n"
"const float DISK_OUTER    = 8.0000;\n"
"const float DISK_INCL     = 1.5000;\n"
"const float DISK_ROLL     = 0.3500;\n"
"const float DISK_GAIN     = 2.2000;\n"
"const float DISK_TEMP     = 5500.0000;\n"
"const float DISK_BEAM     = 2.5000;\n"
"const float DISK_SPEED    = 5.0000;\n"
"const float DISK_WIND     = 7.0000;\n"
"const float DISK_CONTRAST = 1.6000;\n"
"const float EXPOSURE      = 1.4000;\n"
"const float DRIFT_SPEED   = 0.5000;\n"
"const float MOVE_SPEED    = 0.2500;\n"
"const float SCENE_SPEED   = 0.5000;\n"
"const float WORK_AREA     = 0.0;\n"
"const float DILATION_MIN  = 0.2000;\n"
"const float DISK_LOD_CRITICAL_GAIN = 150.0000;\n"
"#define N_STEPS 48\n"
"#define B_CRIT 2.5980762\n"
"\n"
"const float DEMO_SEC      = 60.0;\n"
"const float DEMO_XFADE    = 0.18;\n"
"\n"
"struct DiskLook { float temp,incl,roll,inner,outer,opac,dopp,beam,gain,contr,wind,speed,expo,star; };\n"
"#define DEMO_N 8\n"
"const DiskLook DEMO_TOUR[DEMO_N] = DiskLook[DEMO_N](\n"
"  DiskLook(5500.,1.50,0.35,1.8,8.0,0.90,0.60,2.5,2.2,1.6,7.0,5.0,1.40,0.3),\n"
"  DiskLook(4500.,1.52,0.10,2.2,7.0,0.85,0.35,2.0,1.4,0.5,7.0,5.0,1.20,0.3),\n"
"  DiskLook(3800.,0.55,-0.30,2.2,6.0,0.45,0.90,3.5,1.6,0.4,3.0,2.5,1.10,0.3),\n"
"  DiskLook(6500.,0.30,0.00,3.0,10.0,0.50,0.80,2.5,1.0,1.1,7.0,5.0,1.00,0.3),\n"
"  DiskLook(15000.,1.30,0.35,3.0,14.0,0.35,1.00,4.0,1.2,1.3,8.0,5.0,0.80,0.3),\n"
"  DiskLook(18000.,1.05,0.55,3.0,16.0,0.30,1.00,5.0,1.0,1.5,9.0,6.0,0.75,0.3),\n"
"  DiskLook(5500.,1.50,0.35,1.8,8.0,0.00,1.00,2.5,0.0,1.6,7.0,5.0,1.00,0.6),\n"
"  DiskLook(5500.,1.50,0.35,1.8,8.0,0.90,0.60,2.5,2.2,1.6,7.0,5.0,1.40,0.3));\n"
"\n"
"DiskLook mixLook(DiskLook a, DiskLook b, float f) {\n"
"  return DiskLook(mix(a.temp,b.temp,f),mix(a.incl,b.incl,f),mix(a.roll,b.roll,f),\n"
"    mix(a.inner,b.inner,f),mix(a.outer,b.outer,f),mix(a.opac,b.opac,f),\n"
"    mix(a.dopp,b.dopp,f),mix(a.beam,b.beam,f),mix(a.gain,b.gain,f),\n"
"    mix(a.contr,b.contr,f),mix(a.wind,b.wind,f),mix(a.speed,b.speed,f),\n"
"    mix(a.expo,b.expo,f),mix(a.star,b.star,f));\n"
"}\n"
"// hash for pseudo-random but deterministic randomness\n"
"float hash21(vec2 p){p=fract(p*vec2(234.34,435.345));p+=dot(p,p+34.23);return fract(p.x*p.y);}\n"
"\n"
"// random preset + random size per beat, seamless loop\n"
"DiskLook demoLook() {\n"
"  float t=mod(iTime*SCENE_SPEED,DEMO_SEC);\n"
"  // 10 beats, durations normalized to DEMO_SEC\n"
"  const float rawDur[10]=float[10](7.0,5.5,8.0,6.5,5.8,7.5,6.0,5.2,7.8,6.7);\n"
"  float total=0.0;\n"
"  for(int i=0;i<10;i++)total+=rawDur[i];\n"
"  float acc=0.0;int beat=0;float bDur=0.0;\n"
"  for(int i=0;i<10;i++){\n"
"    float d=rawDur[i]/total*DEMO_SEC;\n"
"    if(t>=acc){beat=i;bDur=d;}acc+=d;\n"
"  }\n"
"  // beat boundaries for crossfade\n"
"  float bStart=0.0;\n"
"  acc=0.0;\n"
"  for(int i=0;i<beat;i++){acc+=rawDur[i]/total*DEMO_SEC;}bStart=acc;\n"
"  // cur = preset for this beat, nxt = preset for next beat (same seed!)\n"
"  int cur=int(hash21(vec2(float(beat),7.0))*7.999);\n"
"  int nxt=int(hash21(vec2(float((beat+1)%10),7.0))*7.999);\n"
"  // crossfade: slow blend near beat boundary\n"
"  float xf=min(4.5,bDur*0.35);\n"
"  float f=smoothstep(bStart+bDur-xf,bStart+bDur,t);\n"
"  return mixLook(DEMO_TOUR[cur],DEMO_TOUR[nxt],f);\n"
"}\n"
"\n"
"// smooth size: overlapping sine waves, always visible\n"
"float demoSize() {\n"
"  float t=mod(iTime*SCENE_SPEED,DEMO_SEC);\n"
"  float frac=t/DEMO_SEC;\n"
"  // slow rise and fall\n"
"  float base=smoothstep(0.0,0.22,frac)*(1.0-smoothstep(0.75,1.0,frac));\n"
"  // smooth perturbation via overlapping sines (no hash discontinuity)\n"
"  float wave=0.0;\n"
"  wave+=0.30*sin(frac*6.2832*1.0+1.7);\n"
"  wave+=0.18*sin(frac*6.2832*2.3+4.1);\n"
"  wave+=0.10*sin(frac*6.2832*3.7+0.3);\n"
"  wave+=0.06*sin(frac*6.2832*5.1+2.9);\n"
"  // base ensures 0 at loop ends, wave adds organic modulation\n"
"  return clamp(base*(0.65+wave),0.0,1.0);\n"
"}\n"
"\n"
"float vnoiseWrapY(vec2 p,float perY){\n"
"  vec2 i=floor(p),f=fract(p);f=f*f*(3.0-2.0*f);\n"
"  float y0=mod(i.y,perY),y1=mod(i.y+1.0,perY);\n"
"  return mix(mix(hash21(vec2(i.x,y0)),hash21(vec2(i.x+1.0,y0)),f.x),\n"
"             mix(hash21(vec2(i.x,y1)),hash21(vec2(i.x+1.0,y1)),f.x),f.y);\n"
"}\n"
"// Derivative-free noise LOD is safe inside the fragment-varying disk-hit path.\n"
"float filteredVnoiseWrapY(vec2 p,float perY,float footprint){\n"
"  float detail=1.0-smoothstep(0.20,0.60,footprint);\n"
"  return mix(0.5,vnoiseWrapY(p,perY),detail);\n"
"}\n"
"float diskNoiseFootprint(float radialScale,float angularPeriod,float swirlScale,float rc,float dSwirl,float b,float W){\n"
"  float pixelB=W/max(iResolution.y,1.0);\n"
"  float critical=pixelB/max(abs(b-B_CRIT),pixelB);\n"
"  float rayFootprint=pixelB*(1.0+DISK_LOD_CRITICAL_GAIN*critical);\n"
"  float radialFootprint=radialScale*rayFootprint;\n"
"  float angularFootprint=angularPeriod*rayFootprint/(6.2831853*max(rc,1.0));\n"
"  float swirlFootprint=swirlScale*abs(dSwirl)*rayFootprint;\n"
"  return max(radialFootprint,length(vec2(angularFootprint,swirlFootprint)));\n"
"}\n"
"vec2 mirrorUV(vec2 u){return 1.0-abs(1.0-mod(u,2.0));}\n"
"vec2 rot(vec2 v,float a){float c=cos(a),s=sin(a);return vec2(c*v.x-s*v.y,s*v.x+c*v.y);}\n"
"vec2 lissa(float t){return vec2(0.75*sin(t*0.37)+0.25*sin(t*0.83+1.0),0.70*sin(t*0.54+2.1)+0.30*sin(t*1.07));}\n"
"vec3 blackbody(float T){\n"
"  float t=clamp(T,1500.0,40000.0)/100.0;\n"
"  float r=t<=66.0?1.0:clamp(1.292936*pow(t-60.0,-0.1332047),0.0,1.0);\n"
"  float g=t<=66.0?clamp(0.3900816*log(t)-0.6318414,0.0,1.0):clamp(1.1298909*pow(t-60.0,-0.0755148),0.0,1.0);\n"
"  float b=t>=66.0?1.0:(t<=19.0?0.0:clamp(0.5432068*log(t-10.0)-1.1962540,0.0,1.0));\n"
"  return vec3(r,g,b);\n"
"}\n"
"vec3 stars(vec3 d){\n"
"  vec2 sph=vec2(atan(d.x,-d.z),asin(clamp(d.y,-1.0,1.0)));\n"
"  vec2 g=sph*40.0;vec2 id=floor(g);float h=hash21(id);\n"
"  if(h<0.92)return vec3(0.0);\n"
"  vec2 f=fract(g)-0.5;vec2 off=(vec2(hash21(id+17.3),hash21(id+31.7))-0.5)*0.7;\n"
"  float spark=smoothstep(0.10,0.0,length(f-off));\n"
"  float tw=0.7+0.3*sin(iTime*(0.5+2.0*hash21(id+5.1))+40.0*h);\n"
"  vec3 tint=mix(vec3(1.0,0.82,0.60),vec3(0.75,0.85,1.0),hash21(id+2.9));\n"
"  return tint*spark*tw*((h-0.92)/0.08);\n"
"}\n"
"vec3 spaceBackground(vec2 uv){\n"
"  float n1=hash21(floor(uv*8.0)),n2=hash21(floor(uv*16.0)),n3=hash21(floor(uv*32.0));\n"
"  float nebula=n1*0.3+n2*0.15+n3*0.05;\n"
"  vec3 nebColor=mix(vec3(0.02,0.01,0.04),vec3(0.04,0.02,0.06),sin(n1*6.28+1.0)*0.5+0.5);\n"
"  return nebColor*(0.5+nebula);\n"
"}\n"
"\n"
"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
"  vec2 res=iResolution.xy;\n"
"  // Ghostty supplies top-down fragment coordinates; OpenGL gl_FragCoord is bottom-up.\n"
"  vec2 uv=vec2(fragCoord.x,res.y-fragCoord.y)/res;float aspect=res.x/res.y;\n"
"  float yUp=1.0-uv.y;float rotationPhase=iTime*DRIFT_SPEED*DISK_SPEED;float moveTime=iTime*MOVE_SPEED;\n"
"  DiskLook L=demoLook();\n"
"  float rin=max(L.inner,1.6),rout=max(L.outer,rin+0.5);\n"
"  float g=demoSize(),I=mix(0.10,1.0,g);\n"
"  float vis=smoothstep(0.0,0.10,I);\n"
"  if(vis<=0.0){fragColor=vec4(spaceBackground(uv),1.0);return;}\n"
"  float rhMin=sqrt(0.010*aspect/3.1415927),rhMax=sqrt(0.500*aspect/3.1415927);\n"
"  float rhT=mix(rhMin,rhMax,g)*(HOLE_RADIUS/0.08);\n"
"  float sz=rhT/max(HOLE_RADIUS,1e-4);\n"
"  // roam freely across the whole screen (above work area)\n"
"  float marg=0.08;\n"
"  float xP=marg/aspect;\n"
"  vec2 roamLo=vec2(xP,marg+0.05);\n"
"  vec2 roamHi=vec2(1.0-xP,0.95-marg);\n"
"  // two Lissajous with different frequencies for x and y\n"
"  float wx=0.13+0.07*sin(moveTime*0.017);\n"
"  float wy=0.11+0.05*cos(moveTime*0.023);\n"
"  vec2 lc=vec2(0.5+0.42*sin(moveTime*wx)+0.12*sin(moveTime*wx*2.7+1.3),\n"
"               0.5+0.38*cos(moveTime*wy)+0.10*cos(moveTime*wy*3.1+0.7));\n"
"  // scale to roam area\n"
"  vec2 center=mix(roamLo,roamHi,lc);\n"
"  float rh=HOLE_RADIUS*sz;\n"
"  float dil=mix(1.0,DILATION_MIN,I);\n"
"  float shield=vis*smoothstep(WORK_AREA,WORK_AREA+0.18,yUp);\n"
"  vec2 p=(uv-center)*vec2(aspect,1.0);float plen=length(p);\n"
"  float W=B_CRIT/max(rh,1e-4);vec2 pr=rot(vec2(p.x,-p.y),L.roll)*W;float b=length(pr);\n"
"  float window=exp(-pow(plen/(7.0*rh),2.0));\n"
"  float bmax=rout+3.0;float Z0=max(14.0,rout+5.0);\n"
"  if(b>=bmax){\n"
"    float u=Z0*inversesqrt(Z0*Z0+b*b);\n"
"    float defl=(2.0/(W*W))/max(plen,1e-4)*(1.29*u+0.07)*max(LENS_DEPTH-2.14*u+0.75,0.0)*window*shield;\n"
"    vec2 dir=p/max(plen,1e-5);vec3 term;\n"
"    float ab=0.035*smoothstep(1.0,2.0,b/bmax);\n"
"    for(int i=0;i<3;i++){float k=1.0+(float(i)-1.0)*ab;vec2 sp=p-dir*defl*k;\n"
"      vec2 suv=mirrorUV(center+sp/vec2(aspect,1.0));term[i]=spaceBackground(suv)[i];}\n"
"    vec3 d=normalize(vec3(-(pr/b)*(2.0/b),-1.0));\n"
"    fragColor=vec4(term+stars(d)*L.star*window*shield,1.0);return;\n"
"  }\n"
"  vec3 x=vec3(pr,Z0),v=vec3(0.0,0.0,-1.0);float h2=dot(pr,pr);\n"
"  float ci=cos(L.incl),si=sin(L.incl);vec3 n=vec3(0.0,si,ci),e2=vec3(0.0,ci,-si);\n"
"  float sdir=DISK_SPEED<0.0?-1.0:1.0;\n"
"  vec3 emitc=vec3(0.0);float trans=1.0;bool captured=false;\n"
"  float sPrev=dot(x,n);vec3 xPrev=x;\n"
"  for(int i=0;i<N_STEPS;i++){\n"
"    float r2=dot(x,x);if(r2<1.0){captured=true;break;}\n"
"    if(x.z<-Z0&&v.z<0.0)break;if(r2>4.0*Z0*Z0)break;\n"
"    float r=sqrt(r2);float dt=clamp(0.16*r,0.03,1.5);\n"
"    // Resolve grazing intersections with the infinitesimally thin disk plane.\n"
"    float planeRate=dot(v,n);\n"
"    if(sPrev*planeRate<0.0&&abs(planeRate)>1e-3){\n"
"      float tPlane=abs(sPrev)/abs(planeRate);\n"
"      dt=min(dt,1.10*tPlane);\n"
"    }\n"
"    vec3 a=-1.5*h2*x/(r2*r2*r);v+=a*(0.5*dt);x+=v*dt;\n"
"    r2=dot(x,x);r=sqrt(r2);a=-1.5*h2*x/(r2*r2*r);v+=a*(0.5*dt);\n"
"    float s=dot(x,n);\n"
"    if(s*sPrev<0.0&&trans>0.02){float tc=sPrev/(sPrev-s);vec3 xc=mix(xPrev,x,tc);\n"
"      float rc=length(xc);if(rc>rin&&rc<rout){\n"
"        float band=smoothstep(rin,rin*1.25,rc)*(1.0-smoothstep(rout*0.70,rout,rc));\n"
"        float phi=atan(dot(xc,e2),xc.x),turns=phi/6.2831853,kep=pow(rin/rc,1.5);\n"
"        float gloc=sqrt(max(1.0-1.5/rc,0.02));\n"
"        float swirl=rc*L.wind*0.12-rotationPhase*kep*gloc*dil;\n"
"        vec2 streakA=vec2(rc*2.8,turns*19.0+swirl*3.0);\n"
"        vec2 streakB=vec2(rc*1.0,turns*9.0+swirl*1.5+7.0);\n"
"        float dKep=-1.5*kep/rc;\n"
"        float dGloc=0.75/(rc*rc*max(gloc,1e-3));\n"
"        float dSwirl=0.12*L.wind-rotationPhase*dil*(dKep*gloc+kep*dGloc);\n"
"        float footprintA=diskNoiseFootprint(2.8,19.0,3.0,rc,dSwirl,b,W);\n"
"        float footprintB=diskNoiseFootprint(1.0,9.0,1.5,rc,dSwirl,b,W);\n"
"        float streaks=filteredVnoiseWrapY(streakA,19.0,footprintA)*0.65\n"
"                     +filteredVnoiseWrapY(streakB,9.0,footprintB)*0.35;\n"
"        streaks=0.35+L.contr*streaks*streaks;\n"
"        vec3 gasdir=normalize(cross(n,xc))*sdir;\n"
"        float beta=clamp(inversesqrt(max(2.0*(rc-1.0),0.2)),0.0,0.99);\n"
"        float g2=gloc/max(1.0+beta*dot(gasdir,normalize(v)),0.05);g2=mix(1.0,g2,L.dopp);\n"
"        float xpr=max(1.0-sqrt(rin/rc),0.0);\n"
"        float tprof=pow(rin/rc,0.75)*pow(xpr,0.25)/0.488;\n"
"        vec3 cbb=blackbody(L.temp*tprof*g2);float boost=pow(g2,L.beam);\n"
"        float density=band*streaks;\n"
"        emitc+=trans*cbb*(L.gain*2.2*density*tprof*tprof*boost);\n"
"        trans*=1.0-clamp(L.opac*density,0.0,1.0);\n"
"    }}\n"
"    sPrev=s;xPrev=x;\n"
"  }\n"
"  if(!captured&&dot(x,x)<4.0)captured=true;\n"
"  vec3 bg=vec3(0.0);\n"
"  if(!captured){vec3 d=normalize(v);bg+=stars(d)*L.star*window*shield;\n"
"    if(d.z<-0.05){float tpl=(-LENS_DEPTH-x.z)/d.z;vec3 hp=x+d*tpl;\n"
"      vec2 q=rot(hp.xy,-L.roll)/W,sp=vec2(q.x,-q.y);\n"
"      vec2 suv=mirrorUV(center+(p+(sp-p)*window*shield)/vec2(aspect,1.0));\n"
"      float toward=smoothstep(0.05,0.35,-d.z);bg+=spaceBackground(suv)*toward;\n"
"  }}\n"
"  vec3 col=bg*trans+(vec3(1.0)-exp(-emitc*L.expo));\n"
"  fragColor=vec4(col,1.0);\n"
"}\n"
"out vec4 _fragOut;\n"
"void main(){vec4 c;mainImage(c,gl_FragCoord.xy);_fragOut=c;}\n";

// ============================================================ fullscreen quad ==
static const char* vertSrc =
"#version 330\n"
"out vec2 vUv;\n"
"void main(){\n"
"  int id = gl_VertexID;\n"
"  float x = float((id & 1) << 2) - 1.0;\n"
"  float y = float((id & 2) << 1) - 1.0;\n"
"  vUv = vec2((x + 1.0) * 0.5, (y + 1.0) * 0.5);\n"
"  gl_Position = vec4(x, y, 0.0, 1.0);\n"
"}\n";

static const char* fragHeader =
"#version 330\n"
"in vec2 vUv;\n"
"uniform float iTime;\n"
"uniform vec2  iResolution;\n"
"uniform float uStarGain;\n"
"uniform float uDiskOpacity;\n"
"uniform float uDoppler;\n"
"\n"
"float STAR_GAIN_V;\n"
"float DISK_OPACITY_V;\n"
"float DOPPLER_MIX_V;\n";

// ============================================================ GL helpers ==
// GL extension function pointer types
typedef GLuint (APIENTRY *PFNGLCREATESHADERPROC)(GLenum);
typedef void (APIENTRY *PFNGLSHADERSOURCEPROC)(GLuint, GLsizei, const GLchar**, const GLint*);
typedef void (APIENTRY *PFNGLCOMPILESHADERPROC)(GLuint);
typedef void (APIENTRY *PFNGLGETSHADERIVPROC)(GLuint, GLenum, GLint*);
typedef void (APIENTRY *PFNGLGETSHADERINFOLOGPROC)(GLuint, GLsizei, GLsizei*, GLchar*);
typedef GLuint (APIENTRY *PFNGLCREATEPROGRAMPROC)(void);
typedef void (APIENTRY *PFNGLATTACHSHADERPROC)(GLuint, GLuint);
typedef void (APIENTRY *PFNGLLINKPROGRAMPROC)(GLuint);
typedef void (APIENTRY *PFNGLGETPROGRAMIVPROC)(GLuint, GLenum, GLint*);
typedef void (APIENTRY *PFNGLUSEPROGRAMPROC)(GLuint);
typedef GLint (APIENTRY *PFNGLGETUNIFORMLOCATIONPROC)(GLuint, const GLchar*);
typedef void (APIENTRY *PFNGLUNIFORM1FPROC)(GLint, GLfloat);
typedef void (APIENTRY *PFNGLUNIFORM2FPROC)(GLint, GLfloat, GLfloat);

#define GL_ARRAY_BUFFER               0x8892
#define GL_STATIC_DRAW                0x88E4

typedef void (APIENTRY *PFNGLGENVERTEXARRAYSPROC)(GLsizei, GLuint*);
typedef void (APIENTRY *PFNGLBINDVERTEXARRAYPROC)(GLuint);
typedef void (APIENTRY *PFNGLGENBUFFERSPROC)(GLsizei, GLuint*);
typedef void (APIENTRY *PFNGLBINDBUFFERPROC)(GLenum, GLuint);
typedef void (APIENTRY *PFNGLBUFFERDATAPROC)(GLenum, GLsizei, const void*, GLenum);
typedef void (APIENTRY *PFNGLENABLEVERTEXATTRIBARRAYPROC)(GLuint);
typedef void (APIENTRY *PFNGLVERTEXATTRIBPOINTERPROC)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void*);
typedef GLint (APIENTRY *PFNGLGETATTRIBLOCATIONPROC)(GLuint, const GLchar*);

static PFNGLGENVERTEXARRAYSPROC       p_glGenVertexArrays;
static PFNGLBINDVERTEXARRAYPROC       p_glBindVertexArray;
static PFNGLGENBUFFERSPROC            p_glGenBuffers;
static PFNGLBINDBUFFERPROC            p_glBindBuffer;
static PFNGLBUFFERDATAPROC            p_glBufferData;
static PFNGLENABLEVERTEXATTRIBARRAYPROC p_glEnableVertexAttribArray;
static PFNGLVERTEXATTRIBPOINTERPROC   p_glVertexAttribPointer;
static PFNGLGETATTRIBLOCATIONPROC     p_glGetAttribLocation;
typedef void (APIENTRY *PFNGLGETPROGRAMINFOLOGPROC)(GLuint, GLsizei, GLsizei*, GLchar*);
static PFNGLGETPROGRAMINFOLOGPROC   p_glGetProgramInfoLog;

typedef HGLRC (APIENTRY *PFNWGLCREATECONTEXTATTRIBSARBPROC)(HDC, HGLRC, const int*);

static PFNGLCREATESHADERPROC        glCreateShader;
static PFNGLSHADERSOURCEPROC        glShaderSource;
static PFNGLCOMPILESHADERPROC       glCompileShader;
static PFNGLGETSHADERIVPROC         glGetShaderiv;
static PFNGLGETSHADERINFOLOGPROC    glGetShaderInfoLog;
static PFNGLCREATEPROGRAMPROC       glCreateProgram;
static PFNGLATTACHSHADERPROC        glAttachShader;
static PFNGLLINKPROGRAMPROC         glLinkProgram;
static PFNGLGETPROGRAMIVPROC        glGetProgramiv;
static PFNGLUSEPROGRAMPROC          glUseProgram;
static PFNGLGETUNIFORMLOCATIONPROC  glGetUniformLocation;
static PFNGLUNIFORM1FPROC           glUniform1f;
static PFNGLUNIFORM2FPROC           glUniform2f;

static GLuint shaderProgram;
static GLint  uTime, uResolution, uStarGain, uDiskOpacity, uDoppler;
static GLuint vao;

static int loadGLFunctions(void) {
    glCreateShader       = (void*)wglGetProcAddress("glCreateShader");
    glShaderSource       = (void*)wglGetProcAddress("glShaderSource");
    glCompileShader      = (void*)wglGetProcAddress("glCompileShader");
    glGetShaderiv        = (void*)wglGetProcAddress("glGetShaderiv");
    glGetShaderInfoLog   = (void*)wglGetProcAddress("glGetShaderInfoLog");
    glCreateProgram      = (void*)wglGetProcAddress("glCreateProgram");
    glAttachShader       = (void*)wglGetProcAddress("glAttachShader");
    glLinkProgram        = (void*)wglGetProcAddress("glLinkProgram");
    glGetProgramiv       = (void*)wglGetProcAddress("glGetProgramiv");
    glUseProgram         = (void*)wglGetProcAddress("glUseProgram");
    glGetUniformLocation = (void*)wglGetProcAddress("glGetUniformLocation");
    glUniform1f          = (void*)wglGetProcAddress("glUniform1f");
    glUniform2f          = (void*)wglGetProcAddress("glUniform2f");
    p_glGenVertexArrays    = (void*)wglGetProcAddress("glGenVertexArrays");
    p_glBindVertexArray    = (void*)wglGetProcAddress("glBindVertexArray");
    p_glGenBuffers         = (void*)wglGetProcAddress("glGenBuffers");
    p_glBindBuffer         = (void*)wglGetProcAddress("glBindBuffer");
    p_glBufferData         = (void*)wglGetProcAddress("glBufferData");
    p_glEnableVertexAttribArray = (void*)wglGetProcAddress("glEnableVertexAttribArray");
    p_glVertexAttribPointer    = (void*)wglGetProcAddress("glVertexAttribPointer");
    p_glGetAttribLocation  = (void*)wglGetProcAddress("glGetAttribLocation");
    p_glGetProgramInfoLog  = (void*)wglGetProcAddress("glGetProgramInfoLog");
    return glCreateShader && glCreateProgram && glUseProgram && p_glGenVertexArrays;
}

static void getLogPath(char* buf, size_t sz) {
    const char* tmp = getenv("TEMP");
    if (!tmp) tmp = getenv("TMP");
    if (!tmp) tmp = ".";
    _snprintf(buf, sz, "%s\\blackhole_screensaver.log", tmp);
    buf[sz - 1] = 0;
}

static GLuint compileShader(GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[4096];
        GLint len = 0;
        glGetShaderInfoLog(s, sizeof(log), &len, log);
        char path[MAX_PATH];
        getLogPath(path, sizeof(path));
        FILE* f = fopen(path, "a");
        if (f) { fprintf(f, "COMPILE ERROR (type %d):\n%s\n\n", type, log); fclose(f); }
    }
    return s;
}

static int initShader(void) {
    // Build the full fragment source: header + shader body
    char* fullFrag = (char*)malloc(strlen(fragHeader) + strlen(shaderSource) + 256);
    sprintf(fullFrag, "%s%s", fragHeader, shaderSource);

    GLuint vs = compileShader(GL_VERTEX_SHADER_ARB, vertSrc);
    GLuint fs = compileShader(GL_FRAGMENT_SHADER_ARB, fullFrag);
    free(fullFrag);

    shaderProgram = glCreateProgram();
    glAttachShader(shaderProgram, vs);
    glAttachShader(shaderProgram, fs);
    glLinkProgram(shaderProgram);

    GLint ok = 0;
    glGetProgramiv(shaderProgram, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[4096];
        GLint len = 0;
        p_glGetProgramInfoLog(shaderProgram, sizeof(log), &len, log);
        char path[MAX_PATH];
        getLogPath(path, sizeof(path));
        FILE* f = fopen(path, "w");
        if (f) { fprintf(f, "LINK ERROR:\n%s\n\nFRAGMENT SOURCE:\n%s%s\n", log, fragHeader, shaderSource); fclose(f); }
        return 0;
    }

    glUseProgram(shaderProgram);
    uTime       = glGetUniformLocation(shaderProgram, "iTime");
    uResolution = glGetUniformLocation(shaderProgram, "iResolution");
    uStarGain   = glGetUniformLocation(shaderProgram, "uStarGain");
    uDiskOpacity= glGetUniformLocation(shaderProgram, "uDiskOpacity");
    uDoppler    = glGetUniformLocation(shaderProgram, "uDoppler");

    // empty VAO — needed by some drivers even with gl_VertexID
    p_glGenVertexArrays(1, &vao);
    p_glBindVertexArray(vao);

    return 1;
}

// ============================================================ registry ==
static void loadConfig(void) {
    HKEY key;
    if (RegOpenKeyExA(HKEY_CURRENT_USER, REG_KEY, 0, KEY_READ, &key) == ERROR_SUCCESS) {
        DWORD sz = sizeof(DWORD), type;
        DWORD v;
        if (RegQueryValueExA(key, "StarBrightness", NULL, &type, (LPBYTE)&v, &sz) == ERROR_SUCCESS)
            cfg_starBrightness = (int)v;
        if (RegQueryValueExA(key, "DiskOpacity", NULL, &type, (LPBYTE)&v, &sz) == ERROR_SUCCESS)
            cfg_diskOpacity = (int)v;
        if (RegQueryValueExA(key, "Doppler", NULL, &type, (LPBYTE)&v, &sz) == ERROR_SUCCESS)
            cfg_doppler = (int)v;
        RegCloseKey(key);
    }
}

static void saveConfig(void) {
    HKEY key;
    if (RegCreateKeyExA(HKEY_CURRENT_USER, REG_KEY, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) == ERROR_SUCCESS) {
        DWORD v;
        v = cfg_starBrightness; RegSetValueExA(key, "StarBrightness", 0, REG_DWORD, (LPBYTE)&v, sizeof(DWORD));
        v = cfg_diskOpacity;    RegSetValueExA(key, "DiskOpacity",    0, REG_DWORD, (LPBYTE)&v, sizeof(DWORD));
        v = cfg_doppler;        RegSetValueExA(key, "Doppler",        0, REG_DWORD, (LPBYTE)&v, sizeof(DWORD));
        RegCloseKey(key);
    }
}

// ============================================================ config dialog ==
// Programmatic config dialog (no .rc resource template needed)
#define CFG_ID_STAR_SLIDER   201
#define CFG_ID_DISK_SLIDER   202
#define CFG_ID_DOPPLER_SLIDER 203
#define CFG_ID_STAR_LABEL    204
#define CFG_ID_DISK_LABEL    205
#define CFG_ID_DOPPLER_LABEL 206
#define CFG_ID_STAR_VAL      207
#define CFG_ID_DISK_VAL      208
#define CFG_ID_DOPPLER_VAL   209
#define CFG_ID_OK            210
#define CFG_ID_CANCEL        211
#define CFG_WND_CLASS "BlackHoleConfig"

static void cfgUpdateLabel(HWND hwnd, int sliderId, int valId) {
    char buf[8];
    int pos = (int)SendDlgItemMessage(hwnd, sliderId, TBM_GETPOS, 0, 0);
    wsprintfA(buf, "%d", pos);
    SetDlgItemTextA(hwnd, valId, buf);
}

static LRESULT CALLBACK ConfigWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        HFONT hFont = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
        // --- labels ---
        HWND h;
        h = CreateWindowA("STATIC", "Star Brightness:", WS_CHILD | WS_VISIBLE, 20, 20, 110, 20, hwnd, (HMENU)(intptr_t)CFG_ID_STAR_LABEL, NULL, NULL);
        SendMessage(h, WM_SETFONT, (WPARAM)hFont, TRUE);
        h = CreateWindowA("STATIC", "Disk Opacity:", WS_CHILD | WS_VISIBLE, 20, 60, 110, 20, hwnd, (HMENU)(intptr_t)CFG_ID_DISK_LABEL, NULL, NULL);
        SendMessage(h, WM_SETFONT, (WPARAM)hFont, TRUE);
        h = CreateWindowA("STATIC", "Doppler Effect:", WS_CHILD | WS_VISIBLE, 20, 100, 110, 20, hwnd, (HMENU)(intptr_t)CFG_ID_DOPPLER_LABEL, NULL, NULL);
        SendMessage(h, WM_SETFONT, (WPARAM)hFont, TRUE);
        // --- trackbars ---
        h = CreateWindowA(TRACKBAR_CLASSA, "", WS_CHILD | WS_VISIBLE | TBS_AUTOTICKS | TBS_TOOLTIPS,
            140, 16, 200, 30, hwnd, (HMENU)(intptr_t)CFG_ID_STAR_SLIDER, NULL, NULL);
        SendMessage(h, TBM_SETRANGE, TRUE, MAKELONG(0, 100));
        SendMessage(h, TBM_SETPOS, TRUE, cfg_starBrightness);
        SendMessage(h, WM_SETFONT, (WPARAM)hFont, TRUE);
        h = CreateWindowA(TRACKBAR_CLASSA, "", WS_CHILD | WS_VISIBLE | TBS_AUTOTICKS | TBS_TOOLTIPS,
            140, 56, 200, 30, hwnd, (HMENU)(intptr_t)CFG_ID_DISK_SLIDER, NULL, NULL);
        SendMessage(h, TBM_SETRANGE, TRUE, MAKELONG(0, 100));
        SendMessage(h, TBM_SETPOS, TRUE, cfg_diskOpacity);
        SendMessage(h, WM_SETFONT, (WPARAM)hFont, TRUE);
        h = CreateWindowA(TRACKBAR_CLASSA, "", WS_CHILD | WS_VISIBLE | TBS_AUTOTICKS | TBS_TOOLTIPS,
            140, 96, 200, 30, hwnd, (HMENU)(intptr_t)CFG_ID_DOPPLER_SLIDER, NULL, NULL);
        SendMessage(h, TBM_SETRANGE, TRUE, MAKELONG(0, 100));
        SendMessage(h, TBM_SETPOS, TRUE, cfg_doppler);
        SendMessage(h, WM_SETFONT, (WPARAM)hFont, TRUE);
        // --- value labels ---
        char buf[8];
        wsprintfA(buf, "%d", cfg_starBrightness);
        h = CreateWindowA("STATIC", buf, WS_CHILD | WS_VISIBLE | SS_CENTER, 350, 20, 40, 20, hwnd, (HMENU)(intptr_t)CFG_ID_STAR_VAL, NULL, NULL);
        SendMessage(h, WM_SETFONT, (WPARAM)hFont, TRUE);
        wsprintfA(buf, "%d", cfg_diskOpacity);
        h = CreateWindowA("STATIC", buf, WS_CHILD | WS_VISIBLE | SS_CENTER, 350, 60, 40, 20, hwnd, (HMENU)(intptr_t)CFG_ID_DISK_VAL, NULL, NULL);
        SendMessage(h, WM_SETFONT, (WPARAM)hFont, TRUE);
        wsprintfA(buf, "%d", cfg_doppler);
        h = CreateWindowA("STATIC", buf, WS_CHILD | WS_VISIBLE | SS_CENTER, 350, 100, 40, 20, hwnd, (HMENU)(intptr_t)CFG_ID_DOPPLER_VAL, NULL, NULL);
        SendMessage(h, WM_SETFONT, (WPARAM)hFont, TRUE);
        // --- buttons ---
        h = CreateWindowA("BUTTON", "OK", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON, 240, 140, 80, 28, hwnd, (HMENU)(intptr_t)CFG_ID_OK, NULL, NULL);
        SendMessage(h, WM_SETFONT, (WPARAM)hFont, TRUE);
        h = CreateWindowA("BUTTON", "Cancel", WS_CHILD | WS_VISIBLE, 330, 140, 80, 28, hwnd, (HMENU)(intptr_t)CFG_ID_CANCEL, NULL, NULL);
        SendMessage(h, WM_SETFONT, (WPARAM)hFont, TRUE);
        return 0;
    }
    case WM_HSCROLL: {
        HWND hTB = (HWND)lp;
        int id = GetDlgCtrlID(hTB);
        if (id == CFG_ID_STAR_SLIDER)   cfgUpdateLabel(hwnd, CFG_ID_STAR_SLIDER,   CFG_ID_STAR_VAL);
        if (id == CFG_ID_DISK_SLIDER)   cfgUpdateLabel(hwnd, CFG_ID_DISK_SLIDER,   CFG_ID_DISK_VAL);
        if (id == CFG_ID_DOPPLER_SLIDER) cfgUpdateLabel(hwnd, CFG_ID_DOPPLER_SLIDER, CFG_ID_DOPPLER_VAL);
        return 0;
    }
    case WM_COMMAND: {
        int id = LOWORD(wp);
        if (id == CFG_ID_OK) {
            cfg_starBrightness = (int)SendDlgItemMessage(hwnd, CFG_ID_STAR_SLIDER,   TBM_GETPOS, 0, 0);
            cfg_diskOpacity    = (int)SendDlgItemMessage(hwnd, CFG_ID_DISK_SLIDER,   TBM_GETPOS, 0, 0);
            cfg_doppler        = (int)SendDlgItemMessage(hwnd, CFG_ID_DOPPLER_SLIDER, TBM_GETPOS, 0, 0);
            saveConfig();
            DestroyWindow(hwnd);
            return 0;
        }
        if (id == CFG_ID_CANCEL) {
            DestroyWindow(hwnd);
            return 0;
        }
        break;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

static void showConfigDialog(HINSTANCE hInst) {
    WNDCLASSEXA wc = {0};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = ConfigWndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.lpszClassName = CFG_WND_CLASS;
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    RegisterClassExA(&wc);

    int w = 440, h = 200;
    int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
    HWND hwnd = CreateWindowExA(WS_EX_DLGMODALFRAME, CFG_WND_CLASS,
        "BlackHole Screensaver Settings",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
        (sw - w) / 2, (sh - h) / 2, w, h,
        NULL, NULL, hInst, NULL);
    if (!hwnd) return;
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
}

// ============================================================ WGL init ==
static int initOpenGL(HWND hwnd) {
    hDC = GetDC(hwnd);

    PIXELFORMATDESCRIPTOR pfd = {0};
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.iLayerType = PFD_MAIN_PLANE;

    int pf = ChoosePixelFormat(hDC, &pfd);
    if (!pf) return 0;
    SetPixelFormat(hDC, pf, &pfd);

    hRC = wglCreateContext(hDC);
    if (!hRC) return 0;
    wglMakeCurrent(hDC, hRC);

    // Try to create a core profile context for GLSL 1.30+
    typedef HGLRC (APIENTRY *PFNWGLCREATECONTEXTATTRIBSARBPROC)(HDC, HGLRC, const int*);
    PFNWGLCREATECONTEXTATTRIBSARBPROC wglCreateContextAttribsARB =
        (void*)wglGetProcAddress("wglCreateContextAttribsARB");
    if (wglCreateContextAttribsARB) {
        int attribs[] = {
            0x2091, 3,  // WGL_CONTEXT_MAJOR_VERSION_ARB = 3
            0x2092, 3,  // WGL_CONTEXT_MINOR_VERSION_ARB = 3
            0x209B, 1,  // WGL_CONTEXT_PROFILE_MASK_ARB = WGL_CONTEXT_CORE_PROFILE_BIT_ARB
            0
        };
        HGLRC newRC = wglCreateContextAttribsARB(hDC, NULL, attribs);
        if (newRC) {
            wglMakeCurrent(NULL, NULL);
            wglDeleteContext(hRC);
            hRC = newRC;
            wglMakeCurrent(hDC, hRC);
        }
    }

    return loadGLFunctions();
}

// ============================================================ screensaver proc ==
static void renderFrame(void) {
    DWORD now = GetTickCount();
    float t = (float)(now - g_tick0) / 1000.0f;

    glViewport(0, 0, g_W, g_H);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    glUseProgram(shaderProgram);
    glUniform1f(uTime, t);
    glUniform2f(uResolution, (float)g_W, (float)g_H);
    if (uStarGain >= 0)    glUniform1f(uStarGain, (float)cfg_starBrightness / 100.0f);
    if (uDiskOpacity >= 0) glUniform1f(uDiskOpacity, (float)cfg_diskOpacity / 100.0f);
    if (uDoppler >= 0)     glUniform1f(uDoppler, (float)cfg_doppler / 100.0f);

    // fullscreen quad
    p_glBindVertexArray(vao);
    // glDrawArrays is part of OpenGL 1.1 and is exported by opengl32.dll.
    // Resolving it through wglGetProcAddress hangs on some Intel drivers.
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    p_glBindVertexArray(0);

    SwapBuffers(hDC);
}

static void hideCursor(void) {
    if (g_cursorHideCount) return;
    do {
        ++g_cursorHideCount;
    } while (ShowCursor(FALSE) >= 0);
    g_savedCursor = SetCursor(NULL);
}

static void restoreCursor(void) {
    if (!g_cursorHideCount) return;
    while (g_cursorHideCount > 0) {
        ShowCursor(TRUE);
        --g_cursorHideCount;
    }
    SetCursor(g_savedCursor);
    g_savedCursor = NULL;
}

static int shouldExit(void) {
    POINT pt;
    GetCursorPos(&pt);
    if (g_mouseMoved) {
        int dx = pt.x - g_mousePrev.x;
        int dy = pt.y - g_mousePrev.y;
        if (dx*dx + dy*dy > 25) return 1;  // moved more than 5px
    }
    if (GetAsyncKeyState(VK_ESCAPE) & 0x8000) return 1;
    if (GetAsyncKeyState(VK_LBUTTON) & 0x8000) return 1;
    if (GetAsyncKeyState(VK_RBUTTON) & 0x8000) return 1;
    if (GetAsyncKeyState(VK_RETURN) & 0x8000) return 1;
    if (GetAsyncKeyState(VK_SPACE) & 0x8000) return 1;
    return 0;
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_SETCURSOR:
        if (g_fullscreen && g_cursorHideCount) {
            SetCursor(NULL);
            return TRUE;
        }
        break;
    case WM_CREATE:
        SetTimer(hwnd, 1, 16, NULL);  // ~60fps
        g_tick0 = GetTickCount();
        GetCursorPos(&g_mousePrev);
        g_mouseMoved = 1;  // ignore first frame
        return 0;
    case WM_TIMER:
        if (!g_preview && shouldExit()) {
            PostQuitMessage(0);
            return 0;
        }
        renderFrame();
        return 0;
    case WM_MOUSEMOVE:
        if (!g_preview) {
            POINT pt;
            pt.x = GET_X_LPARAM(lp);
            pt.y = GET_Y_LPARAM(lp);
            if (g_mouseMoved) {
                int dx = pt.x - g_mousePrev.x;
                int dy = pt.y - g_mousePrev.y;
                if (dx*dx + dy*dy > 25) {
                    PostQuitMessage(0);
                    return 0;
                }
            }
            g_mousePrev = pt;
            g_mouseMoved = 1;
        }
        return 0;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
        PostQuitMessage(0);
        return 0;
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
        if (!g_preview) PostQuitMessage(0);
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, 1);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

// ============================================================ entry point ==
// /s       = screensaver mode (fullscreen)
// /p ####  = preview mode (parent window handle)
// /c ####  = configure (parent window handle)
// no args  = configure (settings dialog)

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrev, LPSTR cmdLine, int show) {
    (void)hPrev; (void)show;
    hInst = hInstance;
    loadConfig();

    // parse command line
    LPSTR cl = GetCommandLineA();
    // skip program name
    if (*cl == '"') { cl++; while (*cl && *cl != '"') cl++; if (*cl) cl++; }
    else { while (*cl && *cl != ' ') cl++; }
    while (*cl == ' ') cl++;

    int isScreensaver = 0;
    int isPreview = 0;
    HWND previewParent = NULL;

    if (_strnicmp(cl, "/s", 2) == 0 && (cl[2] == 0 || cl[2] == ' ')) {
        isScreensaver = 1;
    } else if (_strnicmp(cl, "/p", 2) == 0) {
        isPreview = 1;
        cl += 2;
        while (*cl == ' ') cl++;
        previewParent = (HWND)(LONG_PTR)atol(cl);
    } else if (_strnicmp(cl, "/c", 2) == 0 || _strnicmp(cl, "/C", 2) == 0 || cl[0] == 0) {
        // configure
        showConfigDialog(hInstance);
        return 0;
    } else if (_strnicmp(cl, "/a", 2) == 0) {
        // /a = password change — just exit
        return 0;
    } else if (_strnicmp(cl, "/d", 2) == 0) {
        // debug — run screensaver but not fullscreen
        isScreensaver = 1;
    }

    WNDCLASSEXA wc = {0};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.lpszClassName = "BlackHoleSCR";
    RegisterClassExA(&wc);

    HWND hwnd;
    DWORD style;

    if (isPreview && previewParent) {
        RECT rc;
        GetClientRect(previewParent, &rc);
        style = WS_CHILD | WS_VISIBLE;
        g_W = rc.right;
        g_H = rc.bottom;
        hwnd = CreateWindowExA(0, "BlackHoleSCR", "", style,
            0, 0, g_W, g_H, previewParent, NULL, hInstance, NULL);
        g_preview = 1;
    } else {
        // fullscreen
        style = WS_POPUP | WS_VISIBLE | WS_EX_TOPMOST;
        g_W = GetSystemMetrics(SM_CXSCREEN);
        g_H = GetSystemMetrics(SM_CYSCREEN);
        hwnd = CreateWindowExA(0, "BlackHoleSCR", "", style,
            0, 0, g_W, g_H, NULL, NULL, hInstance, NULL);
        g_fullscreen = 1;
    }

    if (!hwnd) return 1;
    hWnd = hwnd;

    if (!initOpenGL(hwnd)) {
        MessageBoxA(NULL, "OpenGL 3.3+ not available", "Error", MB_OK | MB_ICONERROR);
        return 1;
    }

    if (!initShader()) return 1;

    if (g_fullscreen) hideCursor();
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    restoreCursor();
    wglMakeCurrent(NULL, NULL);
    if (hRC) wglDeleteContext(hRC);
    if (hDC) ReleaseDC(hwnd, hDC);
    return 0;
}
