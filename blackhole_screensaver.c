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
typedef unsigned int GLbitfield;
typedef unsigned long long GLuint64;
typedef struct __GLsync* GLsync;
#define GL_VERTEX_SHADER_ARB          0x8B31
#define GL_FRAGMENT_SHADER_ARB        0x8B30
#define GL_COMPILE_STATUS             0x8B81
#define GL_LINK_STATUS                0x8B82
#define GL_INFO_LOG_LENGTH            0x8B84
#define GL_COLOR_BUFFER_BIT           0x00004000
#define GL_DEPTH_BUFFER_BIT           0x00000100
#define GL_TRIANGLE_STRIP             0x0005
#define GL_TRUE                       1
#define GL_FALSE                      0
#define GL_SYNC_GPU_COMMANDS_COMPLETE 0x9117
#define GL_ALREADY_SIGNALED           0x911A
#define GL_TIMEOUT_EXPIRED            0x911B
#define GL_CONDITION_SATISFIED        0x911C
#define GL_WAIT_FAILED                0x911D

#pragma comment(lib, "comctl32.lib")
#pragma comment(linker, "/manifestdependency:\"type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

// ============================================================ globals ==
static HGLRC hRC;
static HDC   hDC;
static HWND  hWnd;
static HINSTANCE hInst;
static int   g_W, g_H;
static int   g_preview = 0;
static int   g_adjustmentMode = 0;
static int   g_fullscreen = 0;
static ULONGLONG g_tick0;
static POINT g_mousePrev;
static int   g_mouseMoved = 0;
static int   g_cursorHideCount = 0;
static HCURSOR g_savedCursor;

#define FRAME_INTERVAL_MS 10
#define FRAME_COOLDOWN_TRIGGER_MS (2ULL * FRAME_INTERVAL_MS)
#define FRAME_COOLDOWN_DIVISOR 4ULL
#define FRAME_COOLDOWN_MAX_MS 3000ULL
#define ADJUST_PANEL_HEIGHT 205
#define ADJUST_MIN_CLIENT_WIDTH 470
#define ADJUST_MIN_CLIENT_HEIGHT (ADJUST_PANEL_HEIGHT + 180)

typedef struct StaticSchwarzschildScene {
    GLfloat centerX;
    GLfloat centerY;
    GLfloat apparentRadius;
    GLfloat temperature;
    GLfloat inclination;
    GLfloat roll;
    GLfloat innerRadius;
    GLfloat outerRadius;
    GLfloat baselineOpacity;
    GLfloat baselineDoppler;
    GLfloat beam;
    GLfloat gain;
    GLfloat contrast;
    GLfloat wind;
    GLfloat materialSpeed;
    GLfloat exposure;
} StaticSchwarzschildScene;

// M6 owns one named, fixed Schwarzschild-style composition. Future named
// scenes must be added deliberately rather than reviving time-driven presets.
static const StaticSchwarzschildScene STATIC_SCHWARZSCHILD = {
    0.50f, 0.50f, 0.120f,
    5500.0f, 1.50f, 0.35f, 1.80f, 8.00f,
    0.90f, 0.60f, 2.50f, 2.20f, 1.60f, 7.00f, 5.00f, 1.40f
};

typedef struct SceneState {
    // Immutable snapshot passed from the host to one rendered frame. M6 owns
    // the complete static scene layout and look before GLSL builds local rays.
    GLfloat elapsedSeconds;
    GLfloat resolutionX;
    GLfloat resolutionY;
    GLfloat starGain;
    GLfloat diskOpacity;
    GLfloat doppler;
    GLfloat skySeed;
    GLfloat starDensity;
    GLfloat skyFlowSpeed;
    GLfloat viewportOriginY;
    StaticSchwarzschildScene scene;
} SceneState;

static GLsync g_frameFence;
static ULONGLONG g_frameSubmitTick;
static ULONGLONG g_nextFrameEligibleTick;
static int g_frameSyncReady;
static GLfloat g_skySeed;
// Set only for the automated M6 OpenGL smoke. Production runs ignore this
// entirely unless the test process explicitly supplies a named event.
static HANDLE g_shaderSmokeEvent;

// ============================================================ config ==
// Config stored in registry under HKCU\Software\BlackHoleScreensaver.
// Schema v2 retains the three M4 values and adds only the two safe sky controls.
#define REG_KEY "Software\\BlackHoleScreensaver"
#define REG_VALUE_CONFIG_SCHEMA_VERSION "ConfigSchemaVersion"
#define CONFIG_SCHEMA_VERSION 2u
#define CONFIG_VALUE_MIN 0
#define CONFIG_VALUE_MAX 100
#define CONFIG_V2_VALUE_MIN 50
#define CONFIG_V2_VALUE_MAX 200
#define CONFIG_DEFAULT_STAR_BRIGHTNESS 30
#define CONFIG_DEFAULT_DISK_OPACITY 90
#define CONFIG_DEFAULT_DOPPLER 60
#define CONFIG_DEFAULT_STAR_DENSITY 100
#define CONFIG_DEFAULT_SKY_FLOW_SPEED 100

typedef struct ConfigValues {
    int starBrightness;
    int diskOpacity;
    int doppler;
    int starDensity;
    int skyFlowSpeed;
} ConfigValues;

typedef enum ConfigRegistryValueStatus {
    CONFIG_REGISTRY_VALUE_MISSING,
    CONFIG_REGISTRY_VALUE_VALID,
    CONFIG_REGISTRY_VALUE_INVALID
} ConfigRegistryValueStatus;

static int cfg_starBrightness = CONFIG_DEFAULT_STAR_BRIGHTNESS;
static int cfg_diskOpacity = CONFIG_DEFAULT_DISK_OPACITY;
static int cfg_doppler = CONFIG_DEFAULT_DOPPLER;
static int cfg_starDensity = CONFIG_DEFAULT_STAR_DENSITY;
static int cfg_skyFlowSpeed = CONFIG_DEFAULT_SKY_FLOW_SPEED;
static ConfigValues g_adjustmentSnapshot;
static int g_adjustmentDirty = 0;

// ============================================================ shader source ==
// Canonical GLSL is generated into a C string include at build time. The
// resulting source is compiled from this translation unit, so the runtime
// remains a single self-contained .scr with no shader file reads.
static const char shaderSource[] =
#include "generated/blackhole_screensaver_frag.inc"
;

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

// ============================================================ GL helpers ==
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
typedef void (APIENTRY *PFNGLUNIFORM4FPROC)(GLint, GLfloat, GLfloat, GLfloat, GLfloat);
typedef GLsync (APIENTRY *PFNGLFENCESYNCPROC)(GLenum, GLbitfield);
typedef GLenum (APIENTRY *PFNGLCLIENTWAITSYNCPROC)(GLsync, GLbitfield, GLuint64);
typedef void (APIENTRY *PFNGLDELETESYNCPROC)(GLsync);
typedef void (APIENTRY *PFNGLGETPROGRAMINFOLOGPROC)(GLuint, GLsizei, GLsizei*, GLchar*);
typedef void (APIENTRY *PFNGLGENVERTEXARRAYSPROC)(GLsizei, GLuint*);
typedef void (APIENTRY *PFNGLBINDVERTEXARRAYPROC)(GLuint);
typedef void (APIENTRY *PFNGLGENBUFFERSPROC)(GLsizei, GLuint*);
typedef void (APIENTRY *PFNGLBINDBUFFERPROC)(GLenum, GLuint);
typedef void (APIENTRY *PFNGLBUFFERDATAPROC)(GLenum, GLsizei, const void*, GLenum);
typedef void (APIENTRY *PFNGLENABLEVERTEXATTRIBARRAYPROC)(GLuint);
typedef void (APIENTRY *PFNGLVERTEXATTRIBPOINTERPROC)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void*);
typedef GLint (APIENTRY *PFNGLGETATTRIBLOCATIONPROC)(GLuint, const GLchar*);

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
static PFNGLUNIFORM4FPROC           glUniform4f;
static PFNGLFENCESYNCPROC           p_glFenceSync;
static PFNGLCLIENTWAITSYNCPROC      p_glClientWaitSync;
static PFNGLDELETESYNCPROC          p_glDeleteSync;
static PFNGLGETPROGRAMINFOLOGPROC   p_glGetProgramInfoLog;
static PFNGLGENVERTEXARRAYSPROC     p_glGenVertexArrays;
static PFNGLBINDVERTEXARRAYPROC     p_glBindVertexArray;
static PFNGLGENBUFFERSPROC          p_glGenBuffers;
static PFNGLBINDBUFFERPROC          p_glBindBuffer;
static PFNGLBUFFERDATAPROC          p_glBufferData;
static PFNGLENABLEVERTEXATTRIBARRAYPROC p_glEnableVertexAttribArray;
static PFNGLVERTEXATTRIBPOINTERPROC p_glVertexAttribPointer;
static PFNGLGETATTRIBLOCATIONPROC   p_glGetAttribLocation;

static GLuint shaderProgram;
static GLint uTime = -1, uResolution = -1, uStarGain = -1, uDiskOpacity = -1;
static GLint uDoppler = -1, uSkySeed = -1, uStarDensity = -1, uSkyFlowSpeed = -1;
static GLint uViewportOriginY = -1;
static GLint uSceneCenter = -1, uApparentRadius = -1, uDiskLookA = -1;
static GLint uDiskLookB = -1, uDiskLookC = -1, uSceneExposure = -1;
static GLuint vao;

static void* getGLProc(const char* name) {
    void* proc = (void*)wglGetProcAddress(name);
    if (proc == (void*)0x1 || proc == (void*)0x2 || proc == (void*)0x3 ||
        proc == (void*)(INT_PTR)-1) return NULL;
    return proc;
}

static int loadGLFunctions(void) {
    glCreateShader = (void*)getGLProc("glCreateShader");
    glShaderSource = (void*)getGLProc("glShaderSource");
    glCompileShader = (void*)getGLProc("glCompileShader");
    glGetShaderiv = (void*)getGLProc("glGetShaderiv");
    glGetShaderInfoLog = (void*)getGLProc("glGetShaderInfoLog");
    glCreateProgram = (void*)getGLProc("glCreateProgram");
    glAttachShader = (void*)getGLProc("glAttachShader");
    glLinkProgram = (void*)getGLProc("glLinkProgram");
    glGetProgramiv = (void*)getGLProc("glGetProgramiv");
    glUseProgram = (void*)getGLProc("glUseProgram");
    glGetUniformLocation = (void*)getGLProc("glGetUniformLocation");
    glUniform1f = (void*)getGLProc("glUniform1f");
    glUniform2f = (void*)getGLProc("glUniform2f");
    glUniform4f = (void*)getGLProc("glUniform4f");
    p_glFenceSync = (void*)getGLProc("glFenceSync");
    p_glClientWaitSync = (void*)getGLProc("glClientWaitSync");
    p_glDeleteSync = (void*)getGLProc("glDeleteSync");
    p_glGenVertexArrays = (void*)getGLProc("glGenVertexArrays");
    p_glBindVertexArray = (void*)getGLProc("glBindVertexArray");
    p_glGenBuffers = (void*)getGLProc("glGenBuffers");
    p_glBindBuffer = (void*)getGLProc("glBindBuffer");
    p_glBufferData = (void*)getGLProc("glBufferData");
    p_glEnableVertexAttribArray = (void*)getGLProc("glEnableVertexAttribArray");
    p_glVertexAttribPointer = (void*)getGLProc("glVertexAttribPointer");
    p_glGetAttribLocation = (void*)getGLProc("glGetAttribLocation");
    p_glGetProgramInfoLog = (void*)getGLProc("glGetProgramInfoLog");
    g_frameSyncReady = p_glFenceSync && p_glClientWaitSync && p_glDeleteSync;
    return glCreateShader && glShaderSource && glCompileShader && glGetShaderiv &&
        glGetShaderInfoLog && glCreateProgram && glAttachShader && glLinkProgram &&
        glGetProgramiv && glUseProgram && glGetUniformLocation && glUniform1f &&
        glUniform2f && glUniform4f && p_glGenVertexArrays && p_glBindVertexArray &&
        p_glGetProgramInfoLog;
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
    {
        GLint ok = 0;
        glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
        if (!ok) {
            char log[4096];
            GLint len = 0;
            char path[MAX_PATH];
            glGetShaderInfoLog(s, sizeof(log), &len, log);
            getLogPath(path, sizeof(path));
            { FILE* f = fopen(path, "a"); if (f) { fprintf(f, "COMPILE ERROR (type %d):\n%s\n\n", type, log); fclose(f); } }
        }
    }
    return s;
}

static GLfloat makeSceneSeed(void) {
    LARGE_INTEGER counter;
    DWORD seed;
    counter.QuadPart = 0;
    QueryPerformanceCounter(&counter);
    seed = (DWORD)counter.LowPart ^ (DWORD)counter.HighPart ^ GetCurrentProcessId() ^ GetTickCount();
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return (GLfloat)(seed & 0x00ffffffu) * (1.0f / 16777216.0f);
}

static void signalShaderSmokeReady(void) {
    char eventName[128];
    DWORD length = GetEnvironmentVariableA("BLACKHOLE_SHADER_SMOKE_EVENT", eventName, sizeof(eventName));
    if (length == 0 || length >= sizeof(eventName)) return;
    g_shaderSmokeEvent = CreateEventA(NULL, TRUE, FALSE, eventName);
    if (g_shaderSmokeEvent) SetEvent(g_shaderSmokeEvent);
}

static int initShader(void) {
    GLuint vs = compileShader(GL_VERTEX_SHADER_ARB, vertSrc);
    GLuint fs = compileShader(GL_FRAGMENT_SHADER_ARB, shaderSource);
    GLint ok = 0;

    shaderProgram = glCreateProgram();
    glAttachShader(shaderProgram, vs);
    glAttachShader(shaderProgram, fs);
    glLinkProgram(shaderProgram);
    glGetProgramiv(shaderProgram, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[4096];
        GLint len = 0;
        char path[MAX_PATH];
        p_glGetProgramInfoLog(shaderProgram, sizeof(log), &len, log);
        getLogPath(path, sizeof(path));
        { FILE* f = fopen(path, "w"); if (f) { fprintf(f, "LINK ERROR:\n%s\n\nFRAGMENT SOURCE:\n%s\n", log, shaderSource); fclose(f); } }
        return 0;
    }

    glUseProgram(shaderProgram);
    uTime = glGetUniformLocation(shaderProgram, "iTime");
    uResolution = glGetUniformLocation(shaderProgram, "iResolution");
    uStarGain = glGetUniformLocation(shaderProgram, "uStarGain");
    uDiskOpacity = glGetUniformLocation(shaderProgram, "uDiskOpacity");
    uDoppler = glGetUniformLocation(shaderProgram, "uDoppler");
    uSkySeed = glGetUniformLocation(shaderProgram, "uSkySeed");
    uStarDensity = glGetUniformLocation(shaderProgram, "uStarDensity");
    uSkyFlowSpeed = glGetUniformLocation(shaderProgram, "uSkyFlowSpeed");
    uViewportOriginY = glGetUniformLocation(shaderProgram, "uViewportOriginY");
    uSceneCenter = glGetUniformLocation(shaderProgram, "uSceneCenter");
    uApparentRadius = glGetUniformLocation(shaderProgram, "uApparentRadius");
    uDiskLookA = glGetUniformLocation(shaderProgram, "uDiskLookA");
    uDiskLookB = glGetUniformLocation(shaderProgram, "uDiskLookB");
    uDiskLookC = glGetUniformLocation(shaderProgram, "uDiskLookC");
    uSceneExposure = glGetUniformLocation(shaderProgram, "uSceneExposure");
    p_glGenVertexArrays(1, &vao);
    p_glBindVertexArray(vao);
    return 1;
}

// ============================================================ registry ==
static ConfigValues makeDefaultConfig(void) {
    ConfigValues config = {
        CONFIG_DEFAULT_STAR_BRIGHTNESS,
        CONFIG_DEFAULT_DISK_OPACITY,
        CONFIG_DEFAULT_DOPPLER,
        CONFIG_DEFAULT_STAR_DENSITY,
        CONFIG_DEFAULT_SKY_FLOW_SPEED
    };
    return config;
}

static int configValueIsValid(int value) {
    return value >= CONFIG_VALUE_MIN && value <= CONFIG_VALUE_MAX;
}

static int configV2ValueIsValid(int value) {
    return value >= CONFIG_V2_VALUE_MIN && value <= CONFIG_V2_VALUE_MAX;
}

static int configIsValid(const ConfigValues* config) {
    return configValueIsValid(config->starBrightness) &&
        configValueIsValid(config->diskOpacity) &&
        configValueIsValid(config->doppler) &&
        configV2ValueIsValid(config->starDensity) &&
        configV2ValueIsValid(config->skyFlowSpeed);
}

static void applyConfig(const ConfigValues* config) {
    cfg_starBrightness = config->starBrightness;
    cfg_diskOpacity = config->diskOpacity;
    cfg_doppler = config->doppler;
    cfg_starDensity = config->starDensity;
    cfg_skyFlowSpeed = config->skyFlowSpeed;
}

static ConfigValues currentConfig(void) {
    ConfigValues config = { cfg_starBrightness, cfg_diskOpacity, cfg_doppler, cfg_starDensity, cfg_skyFlowSpeed };
    return config;
}

static ConfigRegistryValueStatus readRegistryDword(HKEY key, const char* valueName, DWORD* value) {
    DWORD type = 0;
    DWORD bytes = sizeof(DWORD);
    DWORD raw = 0;
    LONG result = RegQueryValueExA(key, valueName, NULL, &type, (LPBYTE)&raw, &bytes);
    if (result == ERROR_FILE_NOT_FOUND) return CONFIG_REGISTRY_VALUE_MISSING;
    if (result != ERROR_SUCCESS || type != REG_DWORD || bytes != sizeof(DWORD)) return CONFIG_REGISTRY_VALUE_INVALID;
    *value = raw;
    return CONFIG_REGISTRY_VALUE_VALID;
}

static int readValidatedConfigValue(HKEY key, const char* valueName, int fallback, int minimum, int maximum) {
    DWORD value = 0;
    if (readRegistryDword(key, valueName, &value) != CONFIG_REGISTRY_VALUE_VALID) return fallback;
    if (value < (DWORD)minimum || value > (DWORD)maximum) return fallback;
    return (int)value;
}

static int writeRegistryDword(HKEY key, const char* valueName, DWORD value) {
    return RegSetValueExA(key, valueName, 0, REG_DWORD, (const BYTE*)&value, sizeof(value)) == ERROR_SUCCESS;
}

static void loadConfig(void) {
    ConfigValues config = makeDefaultConfig();
    HKEY key;
    DWORD schemaVersion = 0;
    ConfigRegistryValueStatus schemaStatus;

    if (RegOpenKeyExA(HKEY_CURRENT_USER, REG_KEY, 0, KEY_READ, &key) != ERROR_SUCCESS) {
        applyConfig(&config);
        return;
    }
    schemaStatus = readRegistryDword(key, REG_VALUE_CONFIG_SCHEMA_VERSION, &schemaVersion);
    // Absent marker and v1 deliberately ignore v2 values: an interrupted v2
    // save uses marker 0 and therefore falls back to all safe defaults.
    if (schemaStatus == CONFIG_REGISTRY_VALUE_MISSING ||
        (schemaStatus == CONFIG_REGISTRY_VALUE_VALID && schemaVersion == 1u)) {
        config.starBrightness = readValidatedConfigValue(key, "StarBrightness", config.starBrightness, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.diskOpacity = readValidatedConfigValue(key, "DiskOpacity", config.diskOpacity, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.doppler = readValidatedConfigValue(key, "Doppler", config.doppler, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
    } else if (schemaStatus == CONFIG_REGISTRY_VALUE_VALID && schemaVersion == CONFIG_SCHEMA_VERSION) {
        config.starBrightness = readValidatedConfigValue(key, "StarBrightness", config.starBrightness, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.diskOpacity = readValidatedConfigValue(key, "DiskOpacity", config.diskOpacity, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.doppler = readValidatedConfigValue(key, "Doppler", config.doppler, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.starDensity = readValidatedConfigValue(key, "StarDensity", config.starDensity, CONFIG_V2_VALUE_MIN, CONFIG_V2_VALUE_MAX);
        config.skyFlowSpeed = readValidatedConfigValue(key, "SkyFlowSpeed", config.skyFlowSpeed, CONFIG_V2_VALUE_MIN, CONFIG_V2_VALUE_MAX);
    }
    RegCloseKey(key);
    applyConfig(&config);
}

static int saveConfig(const ConfigValues* config) {
    HKEY key;
    int ok;

    if (!configIsValid(config)) return 0;
    if (RegCreateKeyExA(HKEY_CURRENT_USER, REG_KEY, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS) return 0;

    // Invalidate first. All writes short-circuit; schema 2 is published only
    // once every setting has been stored, so a failed save cannot look valid.
    ok = writeRegistryDword(key, REG_VALUE_CONFIG_SCHEMA_VERSION, 0);
    if (ok) ok = writeRegistryDword(key, "StarBrightness", (DWORD)config->starBrightness);
    if (ok) ok = writeRegistryDword(key, "DiskOpacity", (DWORD)config->diskOpacity);
    if (ok) ok = writeRegistryDword(key, "Doppler", (DWORD)config->doppler);
    if (ok) ok = writeRegistryDword(key, "StarDensity", (DWORD)config->starDensity);
    if (ok) ok = writeRegistryDword(key, "SkyFlowSpeed", (DWORD)config->skyFlowSpeed);
    if (ok) ok = writeRegistryDword(key, REG_VALUE_CONFIG_SCHEMA_VERSION, CONFIG_SCHEMA_VERSION);
    RegCloseKey(key);
    return ok;
}

// ============================================================ controls ==
#define CFG_ID_STAR_SLIDER     201
#define CFG_ID_DISK_SLIDER     202
#define CFG_ID_DOPPLER_SLIDER  203
#define CFG_ID_DENSITY_SLIDER  204
#define CFG_ID_SPEED_SLIDER    205
#define CFG_ID_STAR_LABEL      206
#define CFG_ID_DISK_LABEL      207
#define CFG_ID_DOPPLER_LABEL   208
#define CFG_ID_DENSITY_LABEL   209
#define CFG_ID_SPEED_LABEL     210
#define CFG_ID_OK              211
#define CFG_ID_CANCEL          212
#define ADJ_ID_STAR_SLIDER     301
#define ADJ_ID_DISK_SLIDER     302
#define ADJ_ID_DOPPLER_SLIDER  303
#define ADJ_ID_DENSITY_SLIDER  304
#define ADJ_ID_SPEED_SLIDER    305
#define ADJ_ID_STAR_LABEL      306
#define ADJ_ID_DISK_LABEL      307
#define ADJ_ID_DOPPLER_LABEL   308
#define ADJ_ID_DENSITY_LABEL   309
#define ADJ_ID_SPEED_LABEL     310
#define ADJ_ID_SAVE            311
#define ADJ_ID_REVERT          312
#define CFG_WND_CLASS "BlackHoleConfig"
#define CFG_BASE_DPI 96
#define CFG_CLIENT_WIDTH 440
#define CFG_CLIENT_HEIGHT 235

static UINT configSystemDpi(void) {
    HDC screen = GetDC(NULL);
    UINT dpi = CFG_BASE_DPI;
    if (screen) {
        int systemDpi = GetDeviceCaps(screen, LOGPIXELSX);
        ReleaseDC(NULL, screen);
        if (systemDpi > 0) dpi = (UINT)systemDpi;
    }
    return dpi;
}

static int cfgScale(int logicalPixels, UINT dpi) {
    return MulDiv(logicalPixels, (int)dpi, CFG_BASE_DPI);
}

static void setControlText(HWND hwnd, int controlId, int value, int percent) {
    char buffer[16];
    wsprintfA(buffer, percent ? "%d%%" : "%d", value);
    SetDlgItemTextA(hwnd, controlId, buffer);
}

static void createSettingsControls(HWND hwnd, int sliderBase, int labelBase, int saveId, int revertId, const ConfigValues* config) {
    static const char* names[5] = {
        "Star Brightness:", "Disk Opacity:", "Doppler Effect:", "Star Density:", "Sky Flow Speed:"
    };
    int values[5] = {
        config->starBrightness, config->diskOpacity, config->doppler, config->starDensity, config->skyFlowSpeed
    };
    HFONT font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    int index;

    for (index = 0; index < 5; ++index) {
        HWND control;
        control = CreateWindowA("STATIC", names[index], WS_CHILD | WS_VISIBLE,
            20, 10 + index * 30, 110, 20, hwnd, (HMENU)(INT_PTR)(sliderBase + 50 + index), hInst, NULL);
        SendMessage(control, WM_SETFONT, (WPARAM)font, TRUE);
        control = CreateWindowA(TRACKBAR_CLASSA, "", WS_CHILD | WS_VISIBLE | TBS_AUTOTICKS | TBS_TOOLTIPS,
            140, 6 + index * 30, 200, 26, hwnd, (HMENU)(INT_PTR)(sliderBase + index), hInst, NULL);
        SendMessage(control, TBM_SETRANGE, TRUE, MAKELONG(index < 3 ? CONFIG_VALUE_MIN : CONFIG_V2_VALUE_MIN,
            index < 3 ? CONFIG_VALUE_MAX : CONFIG_V2_VALUE_MAX));
        SendMessage(control, TBM_SETPOS, TRUE, values[index]);
        SendMessage(control, WM_SETFONT, (WPARAM)font, TRUE);
        control = CreateWindowA("STATIC", "", WS_CHILD | WS_VISIBLE | SS_CENTER,
            350, 10 + index * 30, 55, 20, hwnd, (HMENU)(INT_PTR)(labelBase + index), hInst, NULL);
        SendMessage(control, WM_SETFONT, (WPARAM)font, TRUE);
        setControlText(hwnd, labelBase + index, values[index], index >= 3);
    }
    {
        HWND control = CreateWindowA("BUTTON", saveId == ADJ_ID_SAVE ? "Save" : "OK",
            WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON, 240, 165, 80, 28,
            hwnd, (HMENU)(INT_PTR)saveId, hInst, NULL);
        SendMessage(control, WM_SETFONT, (WPARAM)font, TRUE);
        control = CreateWindowA("BUTTON", revertId == ADJ_ID_REVERT ? "Revert" : "Cancel",
            WS_CHILD | WS_VISIBLE, 330, 165, 80, 28,
            hwnd, (HMENU)(INT_PTR)revertId, hInst, NULL);
        SendMessage(control, WM_SETFONT, (WPARAM)font, TRUE);
    }
}

static ConfigValues controlsConfig(HWND hwnd, int sliderBase) {
    ConfigValues config;
    config.starBrightness = (int)SendDlgItemMessage(hwnd, sliderBase, TBM_GETPOS, 0, 0);
    config.diskOpacity = (int)SendDlgItemMessage(hwnd, sliderBase + 1, TBM_GETPOS, 0, 0);
    config.doppler = (int)SendDlgItemMessage(hwnd, sliderBase + 2, TBM_GETPOS, 0, 0);
    config.starDensity = (int)SendDlgItemMessage(hwnd, sliderBase + 3, TBM_GETPOS, 0, 0);
    config.skyFlowSpeed = (int)SendDlgItemMessage(hwnd, sliderBase + 4, TBM_GETPOS, 0, 0);
    return config;
}

static void setControlsConfig(HWND hwnd, int sliderBase, int labelBase, const ConfigValues* config) {
    int values[5] = {
        config->starBrightness, config->diskOpacity, config->doppler, config->starDensity, config->skyFlowSpeed
    };
    int index;
    for (index = 0; index < 5; ++index) {
        SendDlgItemMessage(hwnd, sliderBase + index, TBM_SETPOS, TRUE, values[index]);
        setControlText(hwnd, labelBase + index, values[index], index >= 3);
    }
}

static void updateLabels(HWND hwnd, int sliderBase, int labelBase) {
    int index;
    for (index = 0; index < 5; ++index) {
        int value = (int)SendDlgItemMessage(hwnd, sliderBase + index, TBM_GETPOS, 0, 0);
        setControlText(hwnd, labelBase + index, value, index >= 3);
    }
}

static void layoutAdjustmentControls(HWND hwnd, int clientWidth, int clientHeight) {
    int panelTop = clientHeight - ADJUST_PANEL_HEIGHT;
    int sliderWidth = clientWidth - 240;
    int index;
    if (sliderWidth < 100) sliderWidth = 100;
    for (index = 0; index < 5; ++index) {
        int y = panelTop + 10 + index * 30;
        MoveWindow(GetDlgItem(hwnd, ADJ_ID_STAR_SLIDER + index), 140, y, sliderWidth, 26, TRUE);
        MoveWindow(GetDlgItem(hwnd, ADJ_ID_STAR_LABEL + index), clientWidth - 80, y + 4, 55, 20, TRUE);
        MoveWindow(GetDlgItem(hwnd, ADJ_ID_STAR_SLIDER + 50 + index), 20, y + 4, 110, 20, TRUE);
    }
    MoveWindow(GetDlgItem(hwnd, ADJ_ID_SAVE), clientWidth - 200, clientHeight - 32, 80, 25, TRUE);
    MoveWindow(GetDlgItem(hwnd, ADJ_ID_REVERT), clientWidth - 110, clientHeight - 32, 80, 25, TRUE);
}

static LRESULT CALLBACK ConfigWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        ConfigValues config = currentConfig();
        createSettingsControls(hwnd, CFG_ID_STAR_SLIDER, CFG_ID_STAR_LABEL, CFG_ID_OK, CFG_ID_CANCEL, &config);
        return 0;
    }
    case WM_HSCROLL:
        updateLabels(hwnd, CFG_ID_STAR_SLIDER, CFG_ID_STAR_LABEL);
        return 0;
    case WM_COMMAND:
        if (LOWORD(wp) == CFG_ID_OK) {
            ConfigValues pending = controlsConfig(hwnd, CFG_ID_STAR_SLIDER);
            if (!saveConfig(&pending)) {
                MessageBoxA(hwnd, "Settings could not be saved.", "BlackHole Screensaver Settings", MB_OK | MB_ICONERROR);
                return 0;
            }
            applyConfig(&pending);
            DestroyWindow(hwnd);
            return 0;
        }
        if (LOWORD(wp) == CFG_ID_CANCEL) {
            DestroyWindow(hwnd);
            return 0;
        }
        break;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

static void showConfigDialog(HINSTANCE instance) {
    WNDCLASSEXA windowClass = {0};
    RECT outer;
    UINT dpi = configSystemDpi();
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;
    HWND hwnd;
    MSG msg;

    windowClass.cbSize = sizeof(windowClass);
    windowClass.style = CS_HREDRAW | CS_VREDRAW;
    windowClass.lpfnWndProc = ConfigWndProc;
    windowClass.hInstance = instance;
    windowClass.hCursor = LoadCursor(NULL, IDC_ARROW);
    windowClass.lpszClassName = CFG_WND_CLASS;
    windowClass.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    RegisterClassExA(&windowClass);

    outer.left = 0;
    outer.top = 0;
    outer.right = cfgScale(CFG_CLIENT_WIDTH, dpi);
    outer.bottom = cfgScale(CFG_CLIENT_HEIGHT, dpi);
    AdjustWindowRectEx(&outer, style, FALSE, WS_EX_DLGMODALFRAME);
    hwnd = CreateWindowExA(WS_EX_DLGMODALFRAME, CFG_WND_CLASS, "BlackHole Screensaver Settings", style,
        (GetSystemMetrics(SM_CXSCREEN) - (outer.right - outer.left)) / 2,
        (GetSystemMetrics(SM_CYSCREEN) - (outer.bottom - outer.top)) / 2,
        outer.right - outer.left, outer.bottom - outer.top, NULL, NULL, instance, NULL);
    if (!hwnd) return;
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
}

// ============================================================ WGL init ==
static int initOpenGL(HWND hwnd) {
    PIXELFORMATDESCRIPTOR pfd = {0};
    int pixelFormat;
    hDC = GetDC(hwnd);
    if (!hDC) return 0;
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.iLayerType = PFD_MAIN_PLANE;
    pixelFormat = ChoosePixelFormat(hDC, &pfd);
    if (!pixelFormat || !SetPixelFormat(hDC, pixelFormat, &pfd)) return 0;
    hRC = wglCreateContext(hDC);
    if (!hRC || !wglMakeCurrent(hDC, hRC)) return 0;
    {
        typedef HGLRC (APIENTRY *PFNWGLCREATECONTEXTATTRIBSARBPROC)(HDC, HGLRC, const int*);
        PFNWGLCREATECONTEXTATTRIBSARBPROC createContext = (void*)getGLProc("wglCreateContextAttribsARB");
        if (createContext) {
            int attributes[] = { 0x2091, 3, 0x2092, 3, 0x209B, 1, 0 };
            HGLRC newer = createContext(hDC, NULL, attributes);
            if (newer) {
                wglMakeCurrent(NULL, NULL);
                wglDeleteContext(hRC);
                hRC = newer;
                if (!wglMakeCurrent(hDC, hRC)) return 0;
            }
        }
    }
    return loadGLFunctions();
}

static void shutdownRenderer(void) {
    g_frameSubmitTick = 0;
    g_nextFrameEligibleTick = 0;
    if (g_shaderSmokeEvent) { CloseHandle(g_shaderSmokeEvent); g_shaderSmokeEvent = NULL; }
    if (hRC && hDC) {
        if (wglMakeCurrent(hDC, hRC)) {
            if (g_frameFence && p_glDeleteSync) p_glDeleteSync(g_frameFence);
            g_frameFence = NULL;
        } else g_frameFence = NULL;
        wglMakeCurrent(NULL, NULL);
        wglDeleteContext(hRC);
        hRC = NULL;
    }
    if (hDC && hWnd) { ReleaseDC(hWnd, hDC); hDC = NULL; }
}

// ============================================================ renderer ==
static void completeFrameSchedule(ULONGLONG completedTick) {
    ULONGLONG elapsed = 0;
    ULONGLONG cooldown = 0;
    if (g_frameSubmitTick && completedTick >= g_frameSubmitTick) elapsed = completedTick - g_frameSubmitTick;
    if (elapsed > FRAME_COOLDOWN_TRIGGER_MS) {
        cooldown = (elapsed - FRAME_INTERVAL_MS) / FRAME_COOLDOWN_DIVISOR;
        if (cooldown > FRAME_COOLDOWN_MAX_MS) cooldown = FRAME_COOLDOWN_MAX_MS;
    }
    g_frameSubmitTick = 0;
    g_nextFrameEligibleTick = completedTick + cooldown;
}

static void resetFrameSchedule(ULONGLONG now) {
    g_frameSubmitTick = 0;
    g_nextFrameEligibleTick = now;
}

static int previousFrameComplete(ULONGLONG now) {
    GLenum result;
    if (!g_frameFence) return 1;
    if (!g_frameSyncReady) {
        glFinish();
        g_frameFence = NULL;
        completeFrameSchedule(GetTickCount64());
        return 0;
    }
    result = p_glClientWaitSync(g_frameFence, 0, 0);
    if (result == GL_ALREADY_SIGNALED || result == GL_CONDITION_SATISFIED) {
        p_glDeleteSync(g_frameFence);
        g_frameFence = NULL;
        completeFrameSchedule(now);
        return 0;
    }
    if (result == GL_WAIT_FAILED) {
        p_glDeleteSync(g_frameFence);
        g_frameFence = NULL;
        glFinish();
        completeFrameSchedule(GetTickCount64());
        return 0;
    }
    return 0;
}

static int presentPreparedFrame(void) {
    GLsync fence = NULL;
    ULONGLONG submitTick;
    if (g_frameSyncReady) fence = p_glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    submitTick = GetTickCount64();
    if (!SwapBuffers(hDC)) {
        if (fence && p_glDeleteSync) p_glDeleteSync(fence);
        g_frameSubmitTick = submitTick;
        glFinish();
        completeFrameSchedule(GetTickCount64());
        return 0;
    }
    if (fence) {
        g_frameFence = fence;
        g_frameSubmitTick = submitTick;
        glFlush();
    } else {
        g_frameSubmitTick = submitTick;
        glFinish();
        completeFrameSchedule(GetTickCount64());
    }
    return 1;
}

static SceneState makeSceneState(ULONGLONG now) {
    SceneState state;
    state.elapsedSeconds = (float)(now - g_tick0) / 1000.0f;
    state.resolutionX = (float)g_W;
    state.resolutionY = (float)g_H;
    state.starGain = (float)cfg_starBrightness / 100.0f;
    state.diskOpacity = (float)cfg_diskOpacity / 100.0f;
    state.doppler = (float)cfg_doppler / 100.0f;
    state.skySeed = g_skySeed;
    state.starDensity = (float)cfg_starDensity / 100.0f;
    state.skyFlowSpeed = (float)cfg_skyFlowSpeed / 100.0f;
    state.viewportOriginY = g_adjustmentMode ? (GLfloat)ADJUST_PANEL_HEIGHT : 0.0f;
    state.scene = STATIC_SCHWARZSCHILD;
    return state;
}

static void uploadSceneState(const SceneState* state) {
    glUniform1f(uTime, state->elapsedSeconds);
    glUniform2f(uResolution, state->resolutionX, state->resolutionY);
    if (uStarGain >= 0) glUniform1f(uStarGain, state->starGain);
    if (uDiskOpacity >= 0) glUniform1f(uDiskOpacity, state->diskOpacity);
    if (uDoppler >= 0) glUniform1f(uDoppler, state->doppler);
    if (uSkySeed >= 0) glUniform1f(uSkySeed, state->skySeed);
    if (uStarDensity >= 0) glUniform1f(uStarDensity, state->starDensity);
    if (uSkyFlowSpeed >= 0) glUniform1f(uSkyFlowSpeed, state->skyFlowSpeed);
    if (uViewportOriginY >= 0) glUniform1f(uViewportOriginY, state->viewportOriginY);
    if (uSceneCenter >= 0) glUniform2f(uSceneCenter, state->scene.centerX, state->scene.centerY);
    if (uApparentRadius >= 0) glUniform1f(uApparentRadius, state->scene.apparentRadius);
    if (uDiskLookA >= 0) glUniform4f(uDiskLookA, state->scene.temperature, state->scene.inclination, state->scene.roll, state->scene.innerRadius);
    if (uDiskLookB >= 0) glUniform4f(uDiskLookB, state->scene.outerRadius, state->scene.baselineOpacity, state->scene.baselineDoppler, state->scene.beam);
    if (uDiskLookC >= 0) glUniform4f(uDiskLookC, state->scene.gain, state->scene.contrast, state->scene.wind, state->scene.materialSpeed);
    if (uSceneExposure >= 0) glUniform1f(uSceneExposure, state->scene.exposure);
}

static int renderFrame(int present) {
    ULONGLONG now = GetTickCount64();
    const SceneState state = makeSceneState(now);
    int viewportY = 0;
    if (g_adjustmentMode) viewportY = ADJUST_PANEL_HEIGHT;

    glViewport(0, viewportY, g_W, g_H);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glUseProgram(shaderProgram);
    uploadSceneState(&state);
    p_glBindVertexArray(vao);
    // glDrawArrays is part of OpenGL 1.1 and is exported by opengl32.dll.
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    p_glBindVertexArray(0);
    return present ? presentPreparedFrame() : 1;
}

static void renderVisibleFrame(void) {
    ULONGLONG now = GetTickCount64();
    if (!previousFrameComplete(now)) return;
    if (now < g_nextFrameEligibleTick) return;
    renderFrame(1);
}

// ============================================================ window behavior ==
static void hideCursor(void) {
    if (g_cursorHideCount) return;
    do { ++g_cursorHideCount; } while (ShowCursor(FALSE) >= 0);
    g_savedCursor = SetCursor(NULL);
}

static void restoreCursor(void) {
    if (!g_cursorHideCount) return;
    while (g_cursorHideCount > 0) { ShowCursor(TRUE); --g_cursorHideCount; }
    SetCursor(g_savedCursor);
    g_savedCursor = NULL;
}

static int shouldExit(void) {
    POINT point;
    GetCursorPos(&point);
    if (g_mouseMoved) {
        int dx = point.x - g_mousePrev.x;
        int dy = point.y - g_mousePrev.y;
        if (dx * dx + dy * dy > 25) return 1;
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
        if (g_fullscreen && g_cursorHideCount) { SetCursor(NULL); return TRUE; }
        break;
    case WM_CREATE:
        if (g_adjustmentMode) {
            ConfigValues config = currentConfig();
            RECT client;
            g_adjustmentSnapshot = config;
            createSettingsControls(hwnd, ADJ_ID_STAR_SLIDER, ADJ_ID_STAR_LABEL, ADJ_ID_SAVE, ADJ_ID_REVERT, &config);
            GetClientRect(hwnd, &client);
            layoutAdjustmentControls(hwnd, client.right, client.bottom);
        }
        SetTimer(hwnd, 1, FRAME_INTERVAL_MS, NULL);
        g_tick0 = GetTickCount64();
        GetCursorPos(&g_mousePrev);
        g_mouseMoved = 0;
        return 0;
    case WM_GETMINMAXINFO:
        if (g_adjustmentMode) {
            MINMAXINFO* info = (MINMAXINFO*)lp;
            RECT outer = { 0, 0, ADJUST_MIN_CLIENT_WIDTH, ADJUST_MIN_CLIENT_HEIGHT };
            AdjustWindowRect(&outer, WS_OVERLAPPEDWINDOW, FALSE);
            info->ptMinTrackSize.x = outer.right - outer.left;
            info->ptMinTrackSize.y = outer.bottom - outer.top;
            return 0;
        }
        break;
    case WM_TIMER:
        if (!g_preview && !g_adjustmentMode && shouldExit()) { PostQuitMessage(0); return 0; }
        renderVisibleFrame();
        return 0;
    case WM_MOUSEMOVE:
        if (!g_preview && !g_adjustmentMode) {
            POINT point;
            point.x = GET_X_LPARAM(lp);
            point.y = GET_Y_LPARAM(lp);
            ClientToScreen(hwnd, &point);
            if (g_mouseMoved) {
                int dx = point.x - g_mousePrev.x;
                int dy = point.y - g_mousePrev.y;
                if (dx * dx + dy * dy > 25) { PostQuitMessage(0); return 0; }
            }
            g_mousePrev = point;
            g_mouseMoved = 1;
        }
        return 0;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
        if (!g_adjustmentMode) PostQuitMessage(0);
        return 0;
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
        if (!g_preview && !g_adjustmentMode) PostQuitMessage(0);
        return 0;
    case WM_HSCROLL:
        if (g_adjustmentMode) {
            ConfigValues config = controlsConfig(hwnd, ADJ_ID_STAR_SLIDER);
            applyConfig(&config);
            updateLabels(hwnd, ADJ_ID_STAR_SLIDER, ADJ_ID_STAR_LABEL);
            g_adjustmentDirty = 1;
        }
        return 0;
    case WM_COMMAND:
        if (g_adjustmentMode && LOWORD(wp) == ADJ_ID_SAVE) {
            ConfigValues config = controlsConfig(hwnd, ADJ_ID_STAR_SLIDER);
            if (!saveConfig(&config)) {
                MessageBoxA(hwnd, "Settings could not be saved.", "BlackHole Screensaver Settings", MB_OK | MB_ICONERROR);
                return 0;
            }
            applyConfig(&config);
            g_adjustmentSnapshot = config;
            g_adjustmentDirty = 0;
            return 0;
        }
        if (g_adjustmentMode && LOWORD(wp) == ADJ_ID_REVERT) {
            applyConfig(&g_adjustmentSnapshot);
            setControlsConfig(hwnd, ADJ_ID_STAR_SLIDER, ADJ_ID_STAR_LABEL, &g_adjustmentSnapshot);
            g_adjustmentDirty = 0;
            return 0;
        }
        break;
    case WM_SIZE:
        if (g_adjustmentMode) {
            int clientWidth = LOWORD(lp);
            int clientHeight = HIWORD(lp);
            g_W = clientWidth;
            g_H = clientHeight - ADJUST_PANEL_HEIGHT;
            if (g_H < 1) g_H = 1;
            layoutAdjustmentControls(hwnd, clientWidth, clientHeight);
        } else {
            g_W = LOWORD(lp);
            g_H = HIWORD(lp);
        }
        return 0;
    case WM_CLOSE:
        if (g_adjustmentMode && g_adjustmentDirty) applyConfig(&g_adjustmentSnapshot);
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, 1);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

// ============================================================ entry point ==
static int commandHasNoArguments(const char* command) {
    while (*command == ' ' || *command == '\t') ++command;
    return *command == 0;
}

static int parsePreviewParent(char* text, HWND* parent) {
    char* end;
    unsigned long long raw;
    while (*text == ' ' || *text == '\t') ++text;
    if (*text == 0 || *text == '-' || *text == '+') return 0;
    raw = _strtoui64(text, &end, 0);
    if (end == text || !commandHasNoArguments(end) || raw == 0) return 0;
    *parent = (HWND)(UINT_PTR)raw;
    return IsWindow(*parent) != 0;
}

// /s = screensaver, /p <HWND> = preview, /c = configuration, /d = fullscreen
// debug lifecycle, /w = interactive windowed adjustment.
int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrev, LPSTR cmdLine, int show) {
    LPSTR commandLine;
    int isPreview = 0;
    int isAdjustment = 0;
    HWND previewParent = NULL;
    WNDCLASSEXA windowClass = {0};
    HWND hwnd;
    DWORD style;
    MSG msg;

    (void)hPrev;
    (void)cmdLine;
    (void)show;
    SetProcessDPIAware();
    hInst = hInstance;
    InitCommonControls();
    loadConfig();

    commandLine = GetCommandLineA();
    if (*commandLine == '"') {
        ++commandLine;
        while (*commandLine && *commandLine != '"') ++commandLine;
        if (*commandLine) ++commandLine;
    } else while (*commandLine && *commandLine != ' ') ++commandLine;
    while (*commandLine == ' ' || *commandLine == '\t') ++commandLine;

    if (commandLine[0] == 0) {
        showConfigDialog(hInstance);
        return 0;
    }
    if (_strnicmp(commandLine, "/s", 2) == 0 && commandHasNoArguments(commandLine + 2)) {
        // Standard fullscreen screen-saver mode.
    } else if (_strnicmp(commandLine, "/p", 2) == 0) {
        if (commandLine[2] != ' ' && commandLine[2] != '\t') return 0;
        if (!parsePreviewParent(commandLine + 2, &previewParent)) return 0;
        isPreview = 1;
    } else if ((_strnicmp(commandLine, "/c", 2) == 0 || _strnicmp(commandLine, "/C", 2) == 0) &&
               commandHasNoArguments(commandLine + 2)) {
        showConfigDialog(hInstance);
        return 0;
    } else if (_strnicmp(commandLine, "/w", 2) == 0 && commandHasNoArguments(commandLine + 2)) {
        isAdjustment = 1;
        g_adjustmentMode = 1;
    } else if (_strnicmp(commandLine, "/a", 2) == 0 && commandHasNoArguments(commandLine + 2)) {
        return 0;
    } else if (_strnicmp(commandLine, "/d", 2) == 0 && commandHasNoArguments(commandLine + 2)) {
        // /d intentionally uses the same non-preview fullscreen path as /s.
    } else {
        return 0;
    }

    windowClass.cbSize = sizeof(windowClass);
    windowClass.style = CS_HREDRAW | CS_VREDRAW;
    windowClass.lpfnWndProc = WndProc;
    windowClass.hInstance = hInstance;
    windowClass.hCursor = LoadCursor(NULL, IDC_ARROW);
    windowClass.lpszClassName = "BlackHoleSCR";
    RegisterClassExA(&windowClass);

    if (isPreview) {
        RECT client;
        GetClientRect(previewParent, &client);
        style = WS_CHILD;
        g_W = client.right;
        g_H = client.bottom;
        hwnd = CreateWindowExA(0, "BlackHoleSCR", "", style, 0, 0, g_W, g_H, previewParent, NULL, hInstance, NULL);
        g_preview = 1;
    } else if (isAdjustment) {
        RECT outer = { 0, 0, 900, 600 + ADJUST_PANEL_HEIGHT };
        style = WS_OVERLAPPEDWINDOW;
        AdjustWindowRect(&outer, style, FALSE);
        g_W = 900;
        g_H = 600;
        hwnd = CreateWindowExA(0, "BlackHoleSCR", "Black Hole Live Adjustment", style,
            CW_USEDEFAULT, CW_USEDEFAULT, outer.right - outer.left, outer.bottom - outer.top,
            NULL, NULL, hInstance, NULL);
    } else {
        style = WS_POPUP;
        g_W = GetSystemMetrics(SM_CXSCREEN);
        g_H = GetSystemMetrics(SM_CYSCREEN);
        hwnd = CreateWindowExA(WS_EX_TOPMOST, "BlackHoleSCR", "", style, 0, 0, g_W, g_H, NULL, NULL, hInstance, NULL);
        g_fullscreen = 1;
    }

    if (!hwnd) return 1;
    hWnd = hwnd;
    if (!initOpenGL(hwnd)) {
        shutdownRenderer();
        DestroyWindow(hwnd);
        MessageBoxA(NULL, "OpenGL 3.3+ not available", "Error", MB_OK | MB_ICONERROR);
        return 1;
    }
    g_skySeed = makeSceneSeed();
    if (!initShader()) {
        shutdownRenderer();
        DestroyWindow(hwnd);
        return 1;
    }
    g_tick0 = GetTickCount64();

    // Prepare an initial frame before revealing a fullscreen saver. /w is also
    // initialized through this same one-context, one-draw path.
    if (!renderFrame(1)) {
        shutdownRenderer();
        DestroyWindow(hwnd);
        return 1;
    }
    glFinish();
    if (g_frameFence && p_glDeleteSync) p_glDeleteSync(g_frameFence);
    g_frameFence = NULL;
    resetFrameSchedule(GetTickCount64());
    signalShaderSmokeReady();
    if (g_fullscreen) hideCursor();
    ShowWindow(hwnd, g_fullscreen ? SW_SHOWNOACTIVATE : SW_SHOW);
    UpdateWindow(hwnd);

    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    restoreCursor();
    shutdownRenderer();
    DestroyWindow(hwnd);
    return 0;
}
