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
#define GL_COMPILE_STATUS              0x8B81
#define GL_LINK_STATUS                 0x8B82
#define GL_INFO_LOG_LENGTH             0x8B84
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
static int   g_preview = 0;   // running in preview mode
static int   g_configured = 0;
static ULONGLONG g_tick0;
static int   g_exitKey = 0;
static int   g_exitMouse = 0;
static POINT g_mousePrev;
static int   g_mouseMoved = 0;
static int   g_fullscreen = 0;
static int   g_cursorHideCount = 0;
static HCURSOR g_savedCursor;

// Permit presentation attempts up to 100 fps. The one-pass 48-step ray marcher
// still stays bounded by the one-frame fence and adaptive post-frame cooldown.
#define FRAME_INTERVAL_MS 10
// Slow frames get an additional bounded rest after their fence retires. The
// elapsed time is host submit-to-observation time, not a hardware GPU query.
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
    GLfloat sceneSeed;
    GLfloat skySeed;
    StaticSchwarzschildScene scene;
} SceneState;

static GLsync g_frameFence;
static ULONGLONG g_frameSubmitTick;
static ULONGLONG g_nextFrameEligibleTick;
static int g_frameSyncReady;
static GLfloat g_sceneSeed;
static GLfloat g_skySeed;
// Set only for the automated M6 OpenGL smoke. Production runs ignore this
// entirely unless the test process explicitly supplies a named event.
static HANDLE g_shaderSmokeEvent;

// ============================================================ config ==
// Config stored in registry under HKCU\Software\BlackHoleScreensaver.
// M4 accepts legacy unversioned values but writes only the validated v1 schema.
#define REG_KEY "Software\\BlackHoleScreensaver"
#define REG_VALUE_CONFIG_SCHEMA_VERSION "ConfigSchemaVersion"
#define CONFIG_SCHEMA_VERSION 1u
#define CONFIG_VALUE_MIN 0
#define CONFIG_VALUE_MAX 100
#define CONFIG_DEFAULT_STAR_BRIGHTNESS 30
#define CONFIG_DEFAULT_DISK_OPACITY 90
#define CONFIG_DEFAULT_DOPPLER 60

typedef struct ConfigValues {
    int starBrightness;
    int diskOpacity;
    int doppler;
} ConfigValues;

typedef enum ConfigRegistryValueStatus {
    CONFIG_REGISTRY_VALUE_MISSING,
    CONFIG_REGISTRY_VALUE_VALID,
    CONFIG_REGISTRY_VALUE_INVALID
} ConfigRegistryValueStatus;

static int cfg_starBrightness = CONFIG_DEFAULT_STAR_BRIGHTNESS;
static int cfg_diskOpacity = CONFIG_DEFAULT_DISK_OPACITY;
static int cfg_doppler = CONFIG_DEFAULT_DOPPLER;

// ============================================================ shader source ==
// Canonical GLSL is generated into a C string include at build time. The
// resulting source is compiled from this translation unit, so the runtime
// remains a single self-contained .scr with no shader file reads.

// Canonical GLSL lives in blackhole_screensaver.glsl. The checked-in generated
// include is compiled into this translation unit; no shader file is read
// by the running .scr. Regenerate it with tools\generate-shader-include.ps1.
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
typedef void (APIENTRY *PFNGLUNIFORM4FPROC)(GLint, GLfloat, GLfloat, GLfloat, GLfloat);
typedef GLsync (APIENTRY *PFNGLFENCESYNCPROC)(GLenum, GLbitfield);
typedef GLenum (APIENTRY *PFNGLCLIENTWAITSYNCPROC)(GLsync, GLbitfield, GLuint64);
typedef void (APIENTRY *PFNGLDELETESYNCPROC)(GLsync);

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
static PFNGLUNIFORM4FPROC           glUniform4f;
static PFNGLFENCESYNCPROC           p_glFenceSync;
static PFNGLCLIENTWAITSYNCPROC      p_glClientWaitSync;
static PFNGLDELETESYNCPROC          p_glDeleteSync;

static GLuint shaderProgram;
static GLint  uTime = -1, uResolution = -1, uStarGain = -1, uDiskOpacity = -1, uDoppler = -1, uSceneSeed = -1, uSkySeed = -1;
static GLint  uSceneCenter = -1, uApparentRadius = -1, uDiskLookA = -1, uDiskLookB = -1, uDiskLookC = -1, uSceneExposure = -1;
static GLuint vao;

static void* getGLProc(const char* name) {
    void* proc = (void*)wglGetProcAddress(name);
    if (proc == (void*)0x1 || proc == (void*)0x2 || proc == (void*)0x3 ||
        proc == (void*)(INT_PTR)-1) return NULL;
    return proc;
}

static int loadGLFunctions(void) {
    glCreateShader       = (void*)getGLProc("glCreateShader");
    glShaderSource       = (void*)getGLProc("glShaderSource");
    glCompileShader      = (void*)getGLProc("glCompileShader");
    glGetShaderiv        = (void*)getGLProc("glGetShaderiv");
    glGetShaderInfoLog   = (void*)getGLProc("glGetShaderInfoLog");
    glCreateProgram      = (void*)getGLProc("glCreateProgram");
    glAttachShader       = (void*)getGLProc("glAttachShader");
    glLinkProgram        = (void*)getGLProc("glLinkProgram");
    glGetProgramiv       = (void*)getGLProc("glGetProgramiv");
    glUseProgram         = (void*)getGLProc("glUseProgram");
    glGetUniformLocation = (void*)getGLProc("glGetUniformLocation");
    glUniform1f          = (void*)getGLProc("glUniform1f");
    glUniform2f          = (void*)getGLProc("glUniform2f");
    glUniform4f          = (void*)getGLProc("glUniform4f");
    p_glFenceSync        = (void*)getGLProc("glFenceSync");
    p_glClientWaitSync   = (void*)getGLProc("glClientWaitSync");
    p_glDeleteSync       = (void*)getGLProc("glDeleteSync");
    p_glGenVertexArrays    = (void*)getGLProc("glGenVertexArrays");
    p_glBindVertexArray    = (void*)getGLProc("glBindVertexArray");
    p_glGenBuffers         = (void*)getGLProc("glGenBuffers");
    p_glBindBuffer         = (void*)getGLProc("glBindBuffer");
    p_glBufferData         = (void*)getGLProc("glBufferData");
    p_glEnableVertexAttribArray = (void*)getGLProc("glEnableVertexAttribArray");
    p_glVertexAttribPointer    = (void*)getGLProc("glVertexAttribPointer");
    p_glGetAttribLocation  = (void*)getGLProc("glGetAttribLocation");
    p_glGetProgramInfoLog  = (void*)getGLProc("glGetProgramInfoLog");
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

static GLfloat makeSceneSeed(void) {
    LARGE_INTEGER counter;
    DWORD seed;
    counter.QuadPart = 0;
    QueryPerformanceCounter(&counter);
    seed = (DWORD)counter.LowPart ^ (DWORD)counter.HighPart ^
           GetCurrentProcessId() ^ GetTickCount();
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    // A 24-bit fraction is exactly representable in GLfloat and remains < 1.
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
    // shaderSource is the deterministic generated form of the canonical
    // GLSL file, already including #version and all fragment uniforms.
    GLuint vs = compileShader(GL_VERTEX_SHADER_ARB, vertSrc);
    GLuint fs = compileShader(GL_FRAGMENT_SHADER_ARB, shaderSource);

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
        if (f) { fprintf(f, "LINK ERROR:\n%s\n\nFRAGMENT SOURCE:\n%s\n", log, shaderSource); fclose(f); }
        return 0;
    }

    glUseProgram(shaderProgram);
    uTime       = glGetUniformLocation(shaderProgram, "iTime");
    uResolution = glGetUniformLocation(shaderProgram, "iResolution");
    uStarGain   = glGetUniformLocation(shaderProgram, "uStarGain");
    uDiskOpacity= glGetUniformLocation(shaderProgram, "uDiskOpacity");
    uDoppler    = glGetUniformLocation(shaderProgram, "uDoppler");
    uSceneSeed  = glGetUniformLocation(shaderProgram, "uSceneSeed");
    uSkySeed    = glGetUniformLocation(shaderProgram, "uSkySeed");
    uSceneCenter = glGetUniformLocation(shaderProgram, "uSceneCenter");
    uApparentRadius = glGetUniformLocation(shaderProgram, "uApparentRadius");
    uDiskLookA = glGetUniformLocation(shaderProgram, "uDiskLookA");
    uDiskLookB = glGetUniformLocation(shaderProgram, "uDiskLookB");
    uDiskLookC = glGetUniformLocation(shaderProgram, "uDiskLookC");
    uSceneExposure = glGetUniformLocation(shaderProgram, "uSceneExposure");

    // empty VAO — needed by some drivers even with gl_VertexID
    p_glGenVertexArrays(1, &vao);
    p_glBindVertexArray(vao);

    return 1;
}

// ============================================================ registry ==
static ConfigValues makeDefaultConfig(void) {
    ConfigValues config;
    config.starBrightness = CONFIG_DEFAULT_STAR_BRIGHTNESS;
    config.diskOpacity = CONFIG_DEFAULT_DISK_OPACITY;
    config.doppler = CONFIG_DEFAULT_DOPPLER;
    return config;
}

static int configValueIsValid(int value) {
    return value >= CONFIG_VALUE_MIN && value <= CONFIG_VALUE_MAX;
}

static void applyConfig(const ConfigValues* config) {
    cfg_starBrightness = config->starBrightness;
    cfg_diskOpacity = config->diskOpacity;
    cfg_doppler = config->doppler;
}

static ConfigRegistryValueStatus readRegistryDword(HKEY key, const char* valueName, DWORD* value) {
    DWORD type = 0;
    DWORD bytes = sizeof(DWORD);
    DWORD raw = 0;
    LONG result = RegQueryValueExA(key, valueName, NULL, &type, (LPBYTE)&raw, &bytes);
    if (result == ERROR_FILE_NOT_FOUND) return CONFIG_REGISTRY_VALUE_MISSING;
    if (result != ERROR_SUCCESS) return CONFIG_REGISTRY_VALUE_INVALID;
    if (type != REG_DWORD || bytes != sizeof(DWORD)) return CONFIG_REGISTRY_VALUE_INVALID;
    *value = raw;
    return CONFIG_REGISTRY_VALUE_VALID;
}

static int readValidatedConfigValue(HKEY key, const char* valueName, int fallback) {
    DWORD value = 0;
    ConfigRegistryValueStatus status = readRegistryDword(key, valueName, &value);
    if (status != CONFIG_REGISTRY_VALUE_VALID) return fallback;
    if (value > (DWORD)CONFIG_VALUE_MAX) return fallback;
    return (int)value;
}

static int writeRegistryDword(HKEY key, const char* valueName, DWORD value) {
    return RegSetValueExA(key, valueName, 0, REG_DWORD, (const BYTE*)&value, sizeof(value)) == ERROR_SUCCESS;
}

static void loadConfig(void) {
    ConfigValues config = makeDefaultConfig();
    HKEY key;
    if (RegOpenKeyExA(HKEY_CURRENT_USER, REG_KEY, 0, KEY_READ, &key) != ERROR_SUCCESS) {
        applyConfig(&config);
        return;
    }

    DWORD schemaVersion = 0;
    ConfigRegistryValueStatus schemaStatus = readRegistryDword(key, REG_VALUE_CONFIG_SCHEMA_VERSION, &schemaVersion);
    // No marker is a supported M3-and-earlier configuration. A present marker
    // must be exactly the current schema before its values are interpreted.
    if (schemaStatus == CONFIG_REGISTRY_VALUE_MISSING) {
        config.starBrightness = readValidatedConfigValue(key, "StarBrightness", config.starBrightness);
        config.diskOpacity = readValidatedConfigValue(key, "DiskOpacity", config.diskOpacity);
        config.doppler = readValidatedConfigValue(key, "Doppler", config.doppler);
    } else if (schemaStatus == CONFIG_REGISTRY_VALUE_VALID && schemaVersion == CONFIG_SCHEMA_VERSION) {
        config.starBrightness = readValidatedConfigValue(key, "StarBrightness", config.starBrightness);
        config.diskOpacity = readValidatedConfigValue(key, "DiskOpacity", config.diskOpacity);
        config.doppler = readValidatedConfigValue(key, "Doppler", config.doppler);
    }
    // Invalid or future version markers intentionally preserve safe defaults.
    RegCloseKey(key);
    applyConfig(&config);
}

static int saveConfig(const ConfigValues* config) {
    HKEY key;
    int success;
    if (!configValueIsValid(config->starBrightness) ||
        !configValueIsValid(config->diskOpacity) ||
        !configValueIsValid(config->doppler)) return 0;
    if (RegCreateKeyExA(HKEY_CURRENT_USER, REG_KEY, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS)
        return 0;

    // Write the marker last. A failed first save therefore remains readable as
    // legacy data rather than claiming a complete current-version schema.
    success = writeRegistryDword(key, "StarBrightness", (DWORD)config->starBrightness);
    success = writeRegistryDword(key, "DiskOpacity", (DWORD)config->diskOpacity) && success;
    success = writeRegistryDword(key, "Doppler", (DWORD)config->doppler) && success;
    success = writeRegistryDword(key, REG_VALUE_CONFIG_SCHEMA_VERSION, CONFIG_SCHEMA_VERSION) && success;
    RegCloseKey(key);
    return success;
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
            ConfigValues pending;
            pending.starBrightness = (int)SendDlgItemMessage(hwnd, CFG_ID_STAR_SLIDER,   TBM_GETPOS, 0, 0);
            pending.diskOpacity = (int)SendDlgItemMessage(hwnd, CFG_ID_DISK_SLIDER,   TBM_GETPOS, 0, 0);
            pending.doppler = (int)SendDlgItemMessage(hwnd, CFG_ID_DOPPLER_SLIDER, TBM_GETPOS, 0, 0);
            if (!saveConfig(&pending)) {
                MessageBoxA(hwnd, "Settings could not be saved.", "BlackHole Screensaver Settings", MB_OK | MB_ICONERROR);
                return 0;
            }
            applyConfig(&pending);
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
    if (!hDC) return 0;

    PIXELFORMATDESCRIPTOR pfd = {0};
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.iLayerType = PFD_MAIN_PLANE;

    int pf = ChoosePixelFormat(hDC, &pfd);
    if (!pf || !SetPixelFormat(hDC, pf, &pfd)) return 0;

    hRC = wglCreateContext(hDC);
    if (!hRC || !wglMakeCurrent(hDC, hRC)) return 0;

    // Prefer the GLSL 3.30 core context required by the embedded shader.
    typedef HGLRC (APIENTRY *PFNWGLCREATECONTEXTATTRIBSARBPROC)(HDC, HGLRC, const int*);
    PFNWGLCREATECONTEXTATTRIBSARBPROC wglCreateContextAttribsARB =
        (void*)getGLProc("wglCreateContextAttribsARB");
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
            if (!wglMakeCurrent(hDC, hRC)) return 0;
        }
    }

    return loadGLFunctions();
}

static void shutdownRenderer(void) {
    g_frameSubmitTick = 0;
    g_nextFrameEligibleTick = 0;
    if (g_shaderSmokeEvent) {
        CloseHandle(g_shaderSmokeEvent);
        g_shaderSmokeEvent = NULL;
    }
    if (hRC && hDC) {
        if (wglMakeCurrent(hDC, hRC)) {
            if (g_frameFence && p_glDeleteSync) p_glDeleteSync(g_frameFence);
            g_frameFence = NULL;
        } else {
            g_frameFence = NULL;
        }
        wglMakeCurrent(NULL, NULL);
        wglDeleteContext(hRC);
        hRC = NULL;
    }
    if (hDC && hWnd) {
        ReleaseDC(hWnd, hDC);
        hDC = NULL;
    }
}

// ============================================================ screensaver proc ==
static void completeFrameSchedule(ULONGLONG completedTick) {
    ULONGLONG elapsed = 0;
    ULONGLONG cooldown = 0;
    if (g_frameSubmitTick && completedTick >= g_frameSubmitTick)
        elapsed = completedTick - g_frameSubmitTick;

    // A completion observed within two timer periods is already governed by
    // the 100 fps cap. Longer frames receive a bounded fractional rest: the
    // one-frame fence still prevents queue growth, while this avoids doubling
    // every measured GPU frame interval and causing visible sky-motion jumps.
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
        // Fall back to a one-off synchronous wait rather than letting an
        // unreliable driver build an unbounded queue of ray-march frames.
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
    // Capture the host timestamp after fence creation and before SwapBuffers,
    // which may itself flush or block on some drivers.
    submitTick = GetTickCount64();
    if (!SwapBuffers(hDC)) {
        if (fence && p_glDeleteSync) p_glDeleteSync(fence);
        // A failed present does not prove the draw was discarded. Retire the
        // submitted work synchronously before a later timer can try again.
        g_frameSubmitTick = submitTick;
        glFinish();
        completeFrameSchedule(GetTickCount64());
        return 0;
    }
    if (fence) {
        g_frameFence = fence;
        g_frameSubmitTick = submitTick;
        // Ensure the non-blocking fence is submitted; the next timer tick
        // skips rendering until this completed frame has retired on the GPU.
        glFlush();
    } else {
        // Compatibility fallback for a driver that exposes GLSL 3.30 but not
        // the sync entry points: never let it queue more than one frame.
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
    // M4 guarantees bounded persisted controls; keep this compatible raw
    // percentage-to-uniform mapping while GLSL clamps remain defense in depth.
    state.starGain = (float)cfg_starBrightness / 100.0f;
    state.diskOpacity = (float)cfg_diskOpacity / 100.0f;
    state.doppler = (float)cfg_doppler / 100.0f;
    state.sceneSeed = g_sceneSeed;
    state.skySeed = g_skySeed;
    state.scene = STATIC_SCHWARZSCHILD;
    return state;
}

static void uploadSceneState(const SceneState* state) {
    glUniform1f(uTime, state->elapsedSeconds);
    glUniform2f(uResolution, state->resolutionX, state->resolutionY);
    if (uStarGain >= 0)    glUniform1f(uStarGain, state->starGain);
    if (uDiskOpacity >= 0) glUniform1f(uDiskOpacity, state->diskOpacity);
    if (uDoppler >= 0)     glUniform1f(uDoppler, state->doppler);
    if (uSceneSeed >= 0)   glUniform1f(uSceneSeed, state->sceneSeed);
    // M6 retains sceneSeed as a future material-only seed. The static scene
    // itself never reads it for center, radius, inclination, roll, or look.
    if (uSkySeed >= 0)     glUniform1f(uSkySeed, state->skySeed);
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

    // fullscreen quad
    p_glBindVertexArray(vao);
    // glDrawArrays is part of OpenGL 1.1 and is exported by opengl32.dll.
    // Resolving it through wglGetProcAddress hangs on some Intel drivers.
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
        SetTimer(hwnd, 1, FRAME_INTERVAL_MS, NULL);  // 100 fps submission cap
        g_tick0 = GetTickCount64();
        GetCursorPos(&g_mousePrev);
        g_mouseMoved = 0;  // ignore the first mouse message after showing the saver
        return 0;
    case WM_TIMER:
        if (!g_preview && shouldExit()) {
            PostQuitMessage(0);
            return 0;
        }
        renderVisibleFrame();
        return 0;
    case WM_MOUSEMOVE:
        if (!g_preview) {
            POINT pt;
            pt.x = GET_X_LPARAM(lp);
            pt.y = GET_Y_LPARAM(lp);
            ClientToScreen(hwnd, &pt);
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
    (void)hPrev; (void)cmdLine; (void)show;
    SetProcessDPIAware();  // Primary-screen metrics use physical pixels.
    hInst = hInstance;
    loadConfig();

    // parse command line
    LPSTR cl = GetCommandLineA();
    // skip program name
    if (*cl == '"') { cl++; while (*cl && *cl != '"') cl++; if (*cl) cl++; }
    else { while (*cl && *cl != ' ') cl++; }
    while (*cl == ' ') cl++;

    int isPreview = 0;
    HWND previewParent = NULL;

    if (_strnicmp(cl, "/s", 2) == 0) {
        LPSTR end = cl + 2;
        while (*end == ' ' || *end == '\t') ++end;
        // Accept only standalone /s, matching the screensaver control-panel contract.
        if (*end != 0) return 0;
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
        // Debug explicitly uses the same non-preview rendering path as /s.
        g_preview = 0;
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
        style = WS_CHILD;
        g_W = rc.right;
        g_H = rc.bottom;
        hwnd = CreateWindowExA(0, "BlackHoleSCR", "", style,
            0, 0, g_W, g_H, previewParent, NULL, hInstance, NULL);
        g_preview = 1;
    } else {
        style = WS_POPUP;
        g_W = GetSystemMetrics(SM_CXSCREEN);
        g_H = GetSystemMetrics(SM_CYSCREEN);
        hwnd = CreateWindowExA(WS_EX_TOPMOST, "BlackHoleSCR", "", style,
            0, 0, g_W, g_H, NULL, NULL, hInstance, NULL);
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

    // Separate immutable run seeds are owned by the host. The active shader
    // uses skySeed for its per-launch catalogue, offset, and flow direction;
    // sceneSeed remains reserved for a future material-only variation.
    g_sceneSeed = makeSceneSeed();
    g_skySeed = makeSceneSeed();
    if (!initShader()) {
        shutdownRenderer();
        DestroyWindow(hwnd);
        return 1;
    }
    // Start the self-running drifting tour at a known phase after shader setup.
    g_tick0 = GetTickCount64();

    // Finish and present one frame while hidden so the topmost popup never
    // exposes an uninitialized black front buffer. Per-frame work uses a
    // non-blocking fence.
    {
        int initialFramePresented = renderFrame(1);
        if (!initialFramePresented) {
            // Never reveal a fullscreen popup with an uninitialized front
            // buffer. Leaving the display untouched is safer than flashing
            // black when the driver's hidden present has failed.
            shutdownRenderer();
            DestroyWindow(hwnd);
            return 1;
        }
        glFinish();
        // The hidden first frame is fully retired before display; do not let
        // it create a cooldown before the first visible update.
        if (g_frameFence && p_glDeleteSync) p_glDeleteSync(g_frameFence);
        g_frameFence = NULL;
        resetFrameSchedule(GetTickCount64());
        // The smoke event is set only after OpenGL initialization, shader
        // compile/link, and the hidden first present have all completed.
        signalShaderSmokeReady();
        if (g_fullscreen) hideCursor();
        ShowWindow(hwnd, g_fullscreen ? SW_SHOWNOACTIVATE : SW_SHOW);
    }
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    restoreCursor();
    shutdownRenderer();
    DestroyWindow(hwnd);
    return 0;
}
