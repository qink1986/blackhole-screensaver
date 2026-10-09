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

// M8 keeps every scene inside this reviewed Schwarzschild-style look. Only
// center, apparent radius, inclination, and roll are sampled at an interval boundary.
static const StaticSchwarzschildScene M8_SCHWARZSCHILD_BASELINE = {
    0.50f, 0.50f, 0.120f,
    5500.0f, 1.50f, 0.35f, 1.80f, 8.00f,
    0.90f, 0.60f, 2.50f, 2.20f, 1.60f, 7.00f, 5.00f, 1.40f
};

#define M8_SCENE_DURATION_MS 45000ULL
#define M8_OFF_CENTER_POSITION_SLOT_COUNT 4u

typedef struct M8SceneRange {
    GLfloat apparentRadiusMinimum;
    GLfloat apparentRadiusMaximum;
    GLfloat inclinationMinimum;
    GLfloat inclinationMaximum;
    GLfloat rollMinimum;
    GLfloat rollMaximum;
} M8SceneRange;

typedef struct M8ScenePositionRange {
    GLfloat centerXMinimum;
    GLfloat centerXMaximum;
    GLfloat centerYMinimum;
    GLfloat centerYMaximum;
} M8ScenePositionRange;

// Inclination is the polar angle of the disk normal: 0 is the north pole and
// pi/2 is the equator. The maximum stays strictly below pi/2, so a scene never
// crosses to the opposite hemisphere or flips its visible disk face.
static const M8SceneRange M8_NORTH_HEMISPHERE_RANGE = {
    0.100f, 0.135f, 0.050f, 1.480f, 0.00f, 0.78f
};

// Every approved placement slot excludes the screen center. This keeps the
// near-polar compositions intentionally off-center while allowing bounded
// random placement throughout the run.
static const M8ScenePositionRange M8_OFF_CENTER_POSITION_SLOTS[M8_OFF_CENTER_POSITION_SLOT_COUNT] = {
    { 0.30f, 0.42f, 0.33f, 0.47f },
    { 0.58f, 0.70f, 0.33f, 0.47f },
    { 0.30f, 0.42f, 0.53f, 0.67f },
    { 0.58f, 0.70f, 0.53f, 0.67f }
};

typedef struct ActiveScene {
    // Values are committed together at a scene boundary and are immutable
    // until endTick. The next render sees either the old or the new snapshot.
    StaticSchwarzschildScene scene;
    GLfloat skySeed;
    GLfloat skyFlowDirectionX;
    GLfloat skyFlowDirectionY;
    GLfloat starDensityMultiplier;
    ULONGLONG startTick;
    ULONGLONG endTick;
} ActiveScene;

typedef struct SceneState {
    // Immutable snapshot passed from the host to one rendered frame.
    GLfloat elapsedSeconds;
    GLfloat resolutionX;
    GLfloat resolutionY;
    GLfloat starGain;
    GLfloat diskOpacity;
    GLfloat doppler;
    GLfloat skySeed;
    GLfloat skyFlowDirectionX;
    GLfloat skyFlowDirectionY;
    GLfloat starDensity;
    GLfloat skyFlowSpeed;
    StaticSchwarzschildScene scene;
} SceneState;

static GLsync g_frameFence;
static ULONGLONG g_frameSubmitTick;
static ULONGLONG g_nextFrameEligibleTick;
static int g_frameSyncReady;
static DWORD g_sceneRandomState;
static ActiveScene g_activeScene;
// Set only for the automated M6 OpenGL smoke. Production runs ignore this
// entirely unless the test process explicitly supplies a named event.
static HANDLE g_shaderSmokeEvent;

// ============================================================ config ==
// Config stored in registry under HKCU\Software\BlackHoleScreensaver.
// Schema v3 retains the M7 fields and expands only SkyFlowSpeed to 0..500%.
#define REG_KEY "Software\\BlackHoleScreensaver"
#define REG_VALUE_CONFIG_SCHEMA_VERSION "ConfigSchemaVersion"
#define CONFIG_SCHEMA_VERSION 3u
#define CONFIG_VALUE_MIN 0
#define CONFIG_VALUE_MAX 100
#define CONFIG_STAR_DENSITY_MIN 50
#define CONFIG_STAR_DENSITY_MAX 200
#define CONFIG_SKY_FLOW_SPEED_V2_MIN 50
#define CONFIG_SKY_FLOW_SPEED_V2_MAX 200
#define CONFIG_SKY_FLOW_SPEED_MIN 0
#define CONFIG_SKY_FLOW_SPEED_MAX 500
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
static HWND g_settingsWindow;
static int g_creatingAdjustmentSettings;

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
static GLint uDoppler = -1, uSkySeed = -1, uSkyFlowDirection = -1;
static GLint uStarDensity = -1, uSkyFlowSpeed = -1;
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

static DWORD makeSceneRandomState(void) {
    LARGE_INTEGER counter;
    DWORD seed;
    counter.QuadPart = 0;
    QueryPerformanceCounter(&counter);
    seed = (DWORD)counter.LowPart ^ (DWORD)counter.HighPart ^ GetCurrentProcessId() ^ GetTickCount();
    return seed ? seed : 0x6d2b79f5u;
}

static DWORD nextSceneRandomValue(void) {
    DWORD value = g_sceneRandomState;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    g_sceneRandomState = value ? value : 0x6d2b79f5u;
    return g_sceneRandomState;
}

static GLfloat sceneRandomUnit(void) {
    return (GLfloat)(nextSceneRandomValue() & 0x00ffffffu) * (1.0f / 16777216.0f);
}

static GLfloat sceneRandomRange(GLfloat minimum, GLfloat maximum) {
    return minimum + (maximum - minimum) * sceneRandomUnit();
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
    uSkyFlowDirection = glGetUniformLocation(shaderProgram, "uSkyFlowDirection");
    uStarDensity = glGetUniformLocation(shaderProgram, "uStarDensity");
    uSkyFlowSpeed = glGetUniformLocation(shaderProgram, "uSkyFlowSpeed");
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

static int configStarDensityIsValid(int value) {
    return value >= CONFIG_STAR_DENSITY_MIN && value <= CONFIG_STAR_DENSITY_MAX;
}

static int configSkyFlowSpeedIsValid(int value) {
    return value >= CONFIG_SKY_FLOW_SPEED_MIN && value <= CONFIG_SKY_FLOW_SPEED_MAX;
}

static int configIsValid(const ConfigValues* config) {
    return configValueIsValid(config->starBrightness) &&
        configValueIsValid(config->diskOpacity) &&
        configValueIsValid(config->doppler) &&
        configStarDensityIsValid(config->starDensity) &&
        configSkyFlowSpeedIsValid(config->skyFlowSpeed);
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
    // Absent marker and v1 deliberately ignore newer fields. Marker 0 is the
    // interrupted-save sentinel and therefore falls back to all safe defaults.
    if (schemaStatus == CONFIG_REGISTRY_VALUE_MISSING ||
        (schemaStatus == CONFIG_REGISTRY_VALUE_VALID && schemaVersion == 1u)) {
        config.starBrightness = readValidatedConfigValue(key, "StarBrightness", config.starBrightness, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.diskOpacity = readValidatedConfigValue(key, "DiskOpacity", config.diskOpacity, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.doppler = readValidatedConfigValue(key, "Doppler", config.doppler, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
    } else if (schemaStatus == CONFIG_REGISTRY_VALUE_VALID && schemaVersion == 2u) {
        config.starBrightness = readValidatedConfigValue(key, "StarBrightness", config.starBrightness, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.diskOpacity = readValidatedConfigValue(key, "DiskOpacity", config.diskOpacity, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.doppler = readValidatedConfigValue(key, "Doppler", config.doppler, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.starDensity = readValidatedConfigValue(key, "StarDensity", config.starDensity, CONFIG_STAR_DENSITY_MIN, CONFIG_STAR_DENSITY_MAX);
        config.skyFlowSpeed = readValidatedConfigValue(key, "SkyFlowSpeed", config.skyFlowSpeed, CONFIG_SKY_FLOW_SPEED_V2_MIN, CONFIG_SKY_FLOW_SPEED_V2_MAX);
    } else if (schemaStatus == CONFIG_REGISTRY_VALUE_VALID && schemaVersion == CONFIG_SCHEMA_VERSION) {
        config.starBrightness = readValidatedConfigValue(key, "StarBrightness", config.starBrightness, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.diskOpacity = readValidatedConfigValue(key, "DiskOpacity", config.diskOpacity, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.doppler = readValidatedConfigValue(key, "Doppler", config.doppler, CONFIG_VALUE_MIN, CONFIG_VALUE_MAX);
        config.starDensity = readValidatedConfigValue(key, "StarDensity", config.starDensity, CONFIG_STAR_DENSITY_MIN, CONFIG_STAR_DENSITY_MAX);
        config.skyFlowSpeed = readValidatedConfigValue(key, "SkyFlowSpeed", config.skyFlowSpeed, CONFIG_SKY_FLOW_SPEED_MIN, CONFIG_SKY_FLOW_SPEED_MAX);
    }
    RegCloseKey(key);
    applyConfig(&config);
}

static int saveConfig(const ConfigValues* config) {
    HKEY key;
    int ok;

    if (!configIsValid(config)) return 0;
    if (RegCreateKeyExA(HKEY_CURRENT_USER, REG_KEY, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS) return 0;

    // Invalidate first. All writes short-circuit; schema 3 is published only
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

// ============================================================ settings window ==
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
#define SETTINGS_WND_CLASS "BlackHoleSettings"
#define SETTINGS_BASE_DPI 96
#define SETTINGS_CLIENT_WIDTH 460
#define SETTINGS_CLIENT_HEIGHT 235
#define SETTINGS_WINDOW_STYLE (WS_CAPTION | WS_SYSMENU | WS_THICKFRAME)
#define SETTINGS_SLIDER_UNITS 1000

typedef enum SettingsWindowMode {
    SETTINGS_WINDOW_CONFIG,
    SETTINGS_WINDOW_ADJUSTMENT
} SettingsWindowMode;

// Exactly one settings window exists per process. Windows can send
// WM_GETMINMAXINFO before CreateWindowExA returns, so creation has a separate
// explicit mode until the /w palette HWND can be stored.
static UINT settingsSystemDpi(void) {
    HDC screen = GetDC(NULL);
    UINT dpi = SETTINGS_BASE_DPI;
    if (screen) {
        int systemDpi = GetDeviceCaps(screen, LOGPIXELSX);
        ReleaseDC(NULL, screen);
        if (systemDpi > 0) dpi = (UINT)systemDpi;
    }
    return dpi;
}

static int settingsScale(int logicalPixels, UINT dpi) {
    return MulDiv(logicalPixels, (int)dpi, SETTINGS_BASE_DPI);
}

static SettingsWindowMode settingsWindowMode(HWND hwnd) {
    return hwnd == g_settingsWindow || g_creatingAdjustmentSettings ?
        SETTINGS_WINDOW_ADJUSTMENT : SETTINGS_WINDOW_CONFIG;
}

static int configValuesEqual(const ConfigValues* left, const ConfigValues* right) {
    return left->starBrightness == right->starBrightness &&
        left->diskOpacity == right->diskOpacity &&
        left->doppler == right->doppler &&
        left->starDensity == right->starDensity &&
        left->skyFlowSpeed == right->skyFlowSpeed;
}

static int settingMinimum(int index) {
    if (index == 3) return CONFIG_STAR_DENSITY_MIN;
    return CONFIG_VALUE_MIN;
}

static int settingMaximum(int index) {
    if (index < 3) return CONFIG_VALUE_MAX;
    if (index == 3) return CONFIG_STAR_DENSITY_MAX;
    return CONFIG_SKY_FLOW_SPEED_MAX;
}

static int settingSliderPosition(int index, int value) {
    int minimum = settingMinimum(index);
    int maximum = settingMaximum(index);
    if (value < minimum) value = minimum;
    if (value > maximum) value = maximum;
    return (value - minimum) * SETTINGS_SLIDER_UNITS / (maximum - minimum);
}

static int settingValueFromSlider(int index, int position) {
    int minimum = settingMinimum(index);
    int maximum = settingMaximum(index);
    if (position < 0) position = 0;
    if (position > SETTINGS_SLIDER_UNITS) position = SETTINGS_SLIDER_UNITS;
    return minimum + (position * (maximum - minimum) + SETTINGS_SLIDER_UNITS / 2) / SETTINGS_SLIDER_UNITS;
}

static void setControlText(HWND hwnd, int controlId, int position) {
    char buffer[16];
    sprintf(buffer, "%.3f", (double)position / SETTINGS_SLIDER_UNITS);
    SetDlgItemTextA(hwnd, controlId, buffer);
}

static ConfigValues settingsControlsConfig(HWND hwnd) {
    ConfigValues config;
    config.starBrightness = settingValueFromSlider(0, (int)SendDlgItemMessage(hwnd, CFG_ID_STAR_SLIDER, TBM_GETPOS, 0, 0));
    config.diskOpacity = settingValueFromSlider(1, (int)SendDlgItemMessage(hwnd, CFG_ID_DISK_SLIDER, TBM_GETPOS, 0, 0));
    config.doppler = settingValueFromSlider(2, (int)SendDlgItemMessage(hwnd, CFG_ID_DOPPLER_SLIDER, TBM_GETPOS, 0, 0));
    config.starDensity = settingValueFromSlider(3, (int)SendDlgItemMessage(hwnd, CFG_ID_DENSITY_SLIDER, TBM_GETPOS, 0, 0));
    config.skyFlowSpeed = settingValueFromSlider(4, (int)SendDlgItemMessage(hwnd, CFG_ID_SPEED_SLIDER, TBM_GETPOS, 0, 0));
    return config;
}

static void updateSettingsLabels(HWND hwnd) {
    int index;
    for (index = 0; index < 5; ++index) {
        int position = (int)SendDlgItemMessage(hwnd, CFG_ID_STAR_SLIDER + index, TBM_GETPOS, 0, 0);
        setControlText(hwnd, CFG_ID_STAR_LABEL + index, position);
    }
}

static void setSettingsControls(HWND hwnd, const ConfigValues* config) {
    int values[5] = {
        config->starBrightness, config->diskOpacity, config->doppler, config->starDensity, config->skyFlowSpeed
    };
    int index;
    for (index = 0; index < 5; ++index) {
        int position = settingSliderPosition(index, values[index]);
        SendDlgItemMessage(hwnd, CFG_ID_STAR_SLIDER + index, TBM_SETPOS, TRUE, position);
        setControlText(hwnd, CFG_ID_STAR_LABEL + index, position);
    }
}

static void setSettingsMinimumTrackSize(SettingsWindowMode mode, MINMAXINFO* info) {
    UINT dpi = settingsSystemDpi();
    RECT outer = { 0, 0, settingsScale(SETTINGS_CLIENT_WIDTH, dpi), settingsScale(SETTINGS_CLIENT_HEIGHT, dpi) };
    DWORD exStyle = WS_EX_DLGMODALFRAME | (mode == SETTINGS_WINDOW_ADJUSTMENT ? WS_EX_TOOLWINDOW : 0);
    AdjustWindowRectEx(&outer, SETTINGS_WINDOW_STYLE, FALSE, exStyle);
    info->ptMinTrackSize.x = outer.right - outer.left;
    info->ptMinTrackSize.y = outer.bottom - outer.top;
}

static void layoutSettingsControls(HWND hwnd, int clientWidth, int clientHeight) {
    UINT dpi = settingsSystemDpi();
    int margin = settingsScale(18, dpi);
    int rowHeight = settingsScale(31, dpi);
    int labelWidth = settingsScale(122, dpi);
    int valueWidth = settingsScale(58, dpi);
    int gap = settingsScale(10, dpi);
    int sliderLeft = margin + labelWidth + gap;
    int sliderWidth = clientWidth - sliderLeft - valueWidth - margin - gap;
    int trackHeight = settingsScale(27, dpi);
    int textHeight = settingsScale(20, dpi);
    int buttonWidth = settingsScale(82, dpi);
    int buttonHeight = settingsScale(28, dpi);
    int index;

    if (sliderWidth < settingsScale(100, dpi)) sliderWidth = settingsScale(100, dpi);
    for (index = 0; index < 5; ++index) {
        int y = margin + index * rowHeight;
        MoveWindow(GetDlgItem(hwnd, CFG_ID_STAR_SLIDER + index), sliderLeft, y - settingsScale(4, dpi), sliderWidth, trackHeight, TRUE);
        MoveWindow(GetDlgItem(hwnd, CFG_ID_STAR_LABEL + index), sliderLeft + sliderWidth + gap, y, valueWidth, textHeight, TRUE);
        MoveWindow(GetDlgItem(hwnd, CFG_ID_STAR_SLIDER + 50 + index), margin, y, labelWidth, textHeight, TRUE);
    }
    MoveWindow(GetDlgItem(hwnd, CFG_ID_OK), clientWidth - margin - buttonWidth * 2 - gap,
        clientHeight - margin - buttonHeight, buttonWidth, buttonHeight, TRUE);
    MoveWindow(GetDlgItem(hwnd, CFG_ID_CANCEL), clientWidth - margin - buttonWidth,
        clientHeight - margin - buttonHeight, buttonWidth, buttonHeight, TRUE);
}

static void createSettingsControls(HWND hwnd, SettingsWindowMode mode, const ConfigValues* config) {
    static const char* names[5] = {
        "Star Brightness:", "Disk Opacity:", "Doppler Effect:", "Star Density:", "Sky Flow Speed:"
    };
    int values[5] = {
        config->starBrightness, config->diskOpacity, config->doppler, config->starDensity, config->skyFlowSpeed
    };
    HFONT font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    int index;

    for (index = 0; index < 5; ++index) {
        HWND control = CreateWindowA("STATIC", names[index], WS_CHILD | WS_VISIBLE,
            0, 0, 0, 0, hwnd, (HMENU)(INT_PTR)(CFG_ID_STAR_SLIDER + 50 + index), hInst, NULL);
        SendMessage(control, WM_SETFONT, (WPARAM)font, TRUE);
        // The bar stores 0..1000 implementation units for a smooth normalized
        // 0.000..1.000 value. Do not expose that raw position through the
        // common-control tooltip; the adjacent label is the canonical value.
        control = CreateWindowA(TRACKBAR_CLASSA, "", WS_CHILD | WS_VISIBLE | TBS_AUTOTICKS,
            0, 0, 0, 0, hwnd, (HMENU)(INT_PTR)(CFG_ID_STAR_SLIDER + index), hInst, NULL);
        SendMessage(control, TBM_SETRANGE, TRUE, MAKELONG(0, SETTINGS_SLIDER_UNITS));
        SendMessage(control, TBM_SETPOS, TRUE, settingSliderPosition(index, values[index]));
        SendMessage(control, WM_SETFONT, (WPARAM)font, TRUE);
        control = CreateWindowA("STATIC", "", WS_CHILD | WS_VISIBLE | SS_CENTER,
            0, 0, 0, 0, hwnd, (HMENU)(INT_PTR)(CFG_ID_STAR_LABEL + index), hInst, NULL);
        SendMessage(control, WM_SETFONT, (WPARAM)font, TRUE);
        setControlText(hwnd, CFG_ID_STAR_LABEL + index, settingSliderPosition(index, values[index]));
    }
    {
        HWND control = CreateWindowA("BUTTON", mode == SETTINGS_WINDOW_ADJUSTMENT ? "Save" : "OK",
            WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON, 0, 0, 0, 0, hwnd, (HMENU)(INT_PTR)CFG_ID_OK, hInst, NULL);
        SendMessage(control, WM_SETFONT, (WPARAM)font, TRUE);
        control = CreateWindowA("BUTTON", mode == SETTINGS_WINDOW_ADJUSTMENT ? "Revert" : "Cancel",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, (HMENU)(INT_PTR)CFG_ID_CANCEL, hInst, NULL);
        SendMessage(control, WM_SETFONT, (WPARAM)font, TRUE);
    }
}

static void registerSettingsWindowClass(HINSTANCE instance);

static void placeSettingsWindow(HWND owner, int width, int height, int* x, int* y) {
    MONITORINFO monitorInfo = { sizeof(monitorInfo) };
    HMONITOR monitor;
    RECT work;
    if (owner) {
        monitor = MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST);
    } else {
        POINT cursor;
        GetCursorPos(&cursor);
        monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
    }
    if (!GetMonitorInfoA(monitor, &monitorInfo)) {
        work.left = 0;
        work.top = 0;
        work.right = GetSystemMetrics(SM_CXSCREEN);
        work.bottom = GetSystemMetrics(SM_CYSCREEN);
    } else work = monitorInfo.rcWork;

    if (owner) {
        RECT ownerRect;
        GetWindowRect(owner, &ownerRect);
        *x = ownerRect.right + 10;
        *y = ownerRect.top;
        if (*x + width > work.right) *x = ownerRect.left - width - 10;
        if (*x < work.left) *x = work.left + (work.right - work.left - width) / 2;
        if (*y + height > work.bottom) *y = work.bottom - height;
        if (*y < work.top) *y = work.top;
    } else {
        *x = work.left + (work.right - work.left - width) / 2;
        *y = work.top + (work.bottom - work.top - height) / 2;
    }
}

static HWND createSettingsWindow(HWND owner, SettingsWindowMode mode) {
    UINT dpi = settingsSystemDpi();
    RECT outer = { 0, 0, settingsScale(SETTINGS_CLIENT_WIDTH, dpi), settingsScale(SETTINGS_CLIENT_HEIGHT, dpi) };
    DWORD style = SETTINGS_WINDOW_STYLE;
    DWORD exStyle = WS_EX_DLGMODALFRAME | (owner ? WS_EX_TOOLWINDOW : 0);
    HWND hwnd;
    int x;
    int y;

    registerSettingsWindowClass(hInst);
    AdjustWindowRectEx(&outer, style, FALSE, exStyle);
    placeSettingsWindow(owner, outer.right - outer.left, outer.bottom - outer.top, &x, &y);
    if (mode == SETTINGS_WINDOW_ADJUSTMENT) g_creatingAdjustmentSettings = 1;
    hwnd = CreateWindowExA(exStyle, SETTINGS_WND_CLASS,
        mode == SETTINGS_WINDOW_ADJUSTMENT ? "Black Hole Live Settings" : "BlackHole Screensaver Settings",
        style, x, y, outer.right - outer.left, outer.bottom - outer.top,
        owner, NULL, hInst, NULL);
    if (mode == SETTINGS_WINDOW_ADJUSTMENT) g_creatingAdjustmentSettings = 0;
    return hwnd;
}

static LRESULT CALLBACK SettingsWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    SettingsWindowMode mode = settingsWindowMode(hwnd);
    switch (msg) {
    case WM_CREATE: {
        ConfigValues config = currentConfig();
        createSettingsControls(hwnd, mode, &config);
        { RECT client; GetClientRect(hwnd, &client); layoutSettingsControls(hwnd, client.right, client.bottom); }
        return 0;
    }
    case WM_GETMINMAXINFO:
        setSettingsMinimumTrackSize(mode, (MINMAXINFO*)lp);
        return 0;
    case WM_SIZE:
        layoutSettingsControls(hwnd, LOWORD(lp), HIWORD(lp));
        return 0;
    case WM_HSCROLL:
        updateSettingsLabels(hwnd);
        if (mode == SETTINGS_WINDOW_ADJUSTMENT) {
            ConfigValues pending = settingsControlsConfig(hwnd);
            applyConfig(&pending);
            g_adjustmentDirty = !configValuesEqual(&pending, &g_adjustmentSnapshot);
        }
        return 0;
    case WM_COMMAND:
        if (LOWORD(wp) == CFG_ID_OK) {
            ConfigValues pending = settingsControlsConfig(hwnd);
            if (!saveConfig(&pending)) {
                MessageBoxA(hwnd, "Settings could not be saved.", "BlackHole Screensaver Settings", MB_OK | MB_ICONERROR);
                return 0;
            }
            applyConfig(&pending);
            if (mode == SETTINGS_WINDOW_ADJUSTMENT) {
                g_adjustmentSnapshot = pending;
                g_adjustmentDirty = 0;
            } else DestroyWindow(hwnd);
            return 0;
        }
        if (LOWORD(wp) == CFG_ID_CANCEL) {
            if (mode == SETTINGS_WINDOW_ADJUSTMENT) {
                applyConfig(&g_adjustmentSnapshot);
                setSettingsControls(hwnd, &g_adjustmentSnapshot);
                g_adjustmentDirty = 0;
            } else DestroyWindow(hwnd);
            return 0;
        }
        break;
    case WM_CLOSE:
        if (mode == SETTINGS_WINDOW_ADJUSTMENT) {
            HWND owner = GetWindow(hwnd, GW_OWNER);
            if (IsWindow(owner)) {
                PostMessage(owner, WM_CLOSE, 0, 0);
                return 0;
            }
        }
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        if (mode == SETTINGS_WINDOW_ADJUSTMENT) {
            if (hwnd == g_settingsWindow) g_settingsWindow = NULL;
        } else PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

static void registerSettingsWindowClass(HINSTANCE instance) {
    WNDCLASSEXA windowClass = {0};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.style = CS_HREDRAW | CS_VREDRAW;
    windowClass.lpfnWndProc = SettingsWndProc;
    windowClass.hInstance = instance;
    windowClass.hCursor = LoadCursor(NULL, IDC_ARROW);
    windowClass.lpszClassName = SETTINGS_WND_CLASS;
    windowClass.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    if (!RegisterClassExA(&windowClass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        MessageBoxA(NULL, "The settings window could not be registered.", "BlackHole Screensaver Settings", MB_OK | MB_ICONERROR);
    }
}

static void showConfigDialog(void) {
    HWND hwnd = createSettingsWindow(NULL, SETTINGS_WINDOW_CONFIG);
    MSG msg;
    if (!hwnd) {
        char message[128];
        wsprintfA(message, "The settings window could not be created (error %lu).", GetLastError());
        MessageBoxA(NULL, message, "BlackHole Screensaver Settings", MB_OK | MB_ICONERROR);
        return;
    }
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
}

static int showAdjustmentSettings(HWND owner) {
    g_adjustmentSnapshot = currentConfig();
    g_adjustmentDirty = 0;
    g_settingsWindow = createSettingsWindow(owner, SETTINGS_WINDOW_ADJUSTMENT);
    if (!g_settingsWindow) return 0;
    ShowWindow(g_settingsWindow, SW_SHOW);
    UpdateWindow(g_settingsWindow);
    return 1;
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

static void beginScene(ULONGLONG startTick) {
    const M8SceneRange* range = &M8_NORTH_HEMISPHERE_RANGE;
    const M8ScenePositionRange* position;
    unsigned int positionIndex;
    GLfloat skyFlowAngle;

    positionIndex = nextSceneRandomValue() % M8_OFF_CENTER_POSITION_SLOT_COUNT;
    position = &M8_OFF_CENTER_POSITION_SLOTS[positionIndex];
    g_activeScene.scene = M8_SCHWARZSCHILD_BASELINE;
    g_activeScene.scene.centerX = sceneRandomRange(position->centerXMinimum, position->centerXMaximum);
    g_activeScene.scene.centerY = sceneRandomRange(position->centerYMinimum, position->centerYMaximum);
    g_activeScene.scene.apparentRadius = sceneRandomRange(range->apparentRadiusMinimum, range->apparentRadiusMaximum);
    g_activeScene.scene.inclination = sceneRandomRange(range->inclinationMinimum, range->inclinationMaximum);
    g_activeScene.scene.roll = sceneRandomRange(range->rollMinimum, range->rollMaximum);
    g_activeScene.skySeed = sceneRandomUnit();
    skyFlowAngle = sceneRandomRange(0.0f, 6.28318530718f);
    g_activeScene.skyFlowDirectionX = cosf(skyFlowAngle);
    g_activeScene.skyFlowDirectionY = sinf(skyFlowAngle);
    g_activeScene.starDensityMultiplier = sceneRandomRange(0.85f, 1.15f);
    g_activeScene.startTick = startTick;
    g_activeScene.endTick = startTick + M8_SCENE_DURATION_MS;
}

static void advanceSceneTo(ULONGLONG now) {
    // A delayed frame may cross more than one fixed-duration boundary. Advance
    // through each interval so state never depends on a frame-local remainder.
    while (now >= g_activeScene.endTick) beginScene(g_activeScene.endTick);
}

static SceneState makeSceneState(ULONGLONG now) {
    SceneState state;
    advanceSceneTo(now);
    state.elapsedSeconds = (float)(now - g_tick0) / 1000.0f;
    state.resolutionX = (float)g_W;
    state.resolutionY = (float)g_H;
    state.starGain = (float)cfg_starBrightness / 100.0f;
    state.diskOpacity = (float)cfg_diskOpacity / 100.0f;
    state.doppler = (float)cfg_doppler / 100.0f;
    state.skySeed = g_activeScene.skySeed;
    state.skyFlowDirectionX = g_activeScene.skyFlowDirectionX;
    state.skyFlowDirectionY = g_activeScene.skyFlowDirectionY;
    state.starDensity = (float)cfg_starDensity / 100.0f;
    state.starDensity *= g_activeScene.starDensityMultiplier;
    state.skyFlowSpeed = (float)cfg_skyFlowSpeed / 100.0f;
    state.scene = g_activeScene.scene;
    return state;
}

static void uploadSceneState(const SceneState* state) {
    glUniform1f(uTime, state->elapsedSeconds);
    glUniform2f(uResolution, state->resolutionX, state->resolutionY);
    if (uStarGain >= 0) glUniform1f(uStarGain, state->starGain);
    if (uDiskOpacity >= 0) glUniform1f(uDiskOpacity, state->diskOpacity);
    if (uDoppler >= 0) glUniform1f(uDoppler, state->doppler);
    if (uSkySeed >= 0) glUniform1f(uSkySeed, state->skySeed);
    if (uSkyFlowDirection >= 0) glUniform2f(uSkyFlowDirection, state->skyFlowDirectionX, state->skyFlowDirectionY);
    if (uStarDensity >= 0) glUniform1f(uStarDensity, state->starDensity);
    if (uSkyFlowSpeed >= 0) glUniform1f(uSkyFlowSpeed, state->skyFlowSpeed);
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

    glViewport(0, 0, g_W, g_H);
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
        SetTimer(hwnd, 1, FRAME_INTERVAL_MS, NULL);
        g_tick0 = GetTickCount64();
        GetCursorPos(&g_mousePrev);
        g_mouseMoved = 0;
        return 0;
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
    case WM_SIZE:
        g_W = LOWORD(lp);
        g_H = HIWORD(lp);
        if (g_H < 1) g_H = 1;
        return 0;
    case WM_CLOSE:
        if (g_adjustmentMode && g_adjustmentDirty) applyConfig(&g_adjustmentSnapshot);
        if (g_settingsWindow && IsWindow(g_settingsWindow)) DestroyWindow(g_settingsWindow);
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, 1);
        if (g_settingsWindow && IsWindow(g_settingsWindow)) DestroyWindow(g_settingsWindow);
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
        showConfigDialog();
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
        showConfigDialog();
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
        RECT outer = { 0, 0, 900, 600 };
        style = WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN;
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
    g_sceneRandomState = makeSceneRandomState();
    g_tick0 = GetTickCount64();
    beginScene(g_tick0);
    if (!initShader()) {
        shutdownRenderer();
        DestroyWindow(hwnd);
        return 1;
    }

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
    if (g_adjustmentMode && !showAdjustmentSettings(hwnd)) {
        shutdownRenderer();
        DestroyWindow(hwnd);
        return 1;
    }

    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    restoreCursor();
    shutdownRenderer();
    DestroyWindow(hwnd);
    return 0;
}
