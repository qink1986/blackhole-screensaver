[CmdletBinding()]
param(
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

function Fail([string]$Message) {
    throw "Milestone 3 contract failure: $Message"
}

function Require-File([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Label is missing: $Path"
    }
}

function Require-Contains([string]$Text, [string]$Needle, [string]$Label) {
    if ([string]::IsNullOrEmpty($Needle)) {
        Fail "$Label requested an empty source anchor"
    }
    if ($Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) {
        Fail "$Label is missing source anchor: $Needle"
    }
}

function Require-NotContains([string]$Text, [string]$Needle, [string]$Label) {
    if ($Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -ge 0) {
        Fail "$Label unexpectedly contains: $Needle"
    }
}

function Require-Match([string]$Text, [string]$Pattern, [string]$Label) {
    if (-not [regex]::IsMatch($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        Fail "$Label does not match: $Pattern"
    }
}

function Normalize-Lf([string]$Text) {
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-LfNormalizedSha256([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((Normalize-Lf $Text))
    return Get-BytesSha256 $bytes
}

function Get-BytesSha256([byte[]]$Bytes) {
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($hasher.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $hasher.Dispose()
    }
}

function Get-GitRevisionText([string]$Root, [string]$Revision, [string]$RepositoryPath) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'git'
    $startInfo.Arguments = '-C "' + $Root.Replace('"', '\"') + '" show ' + $Revision + ':' + $RepositoryPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        Fail "Could not start git to read immutable baseline $Revision"
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        Fail "Could not read immutable baseline $Revision`:$RepositoryPath from Git: $stderr"
    }
    return $stdout
}

function Get-CStringBlock([string]$Text, [string]$Symbol, [string]$FollowingMarker) {
    $startPattern = 'static\s+const\s+char\*\s+' + [regex]::Escape($Symbol) + '\s*='
    $start = [regex]::Match($Text, $startPattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $start.Success) {
        Fail "Could not find C string block $Symbol"
    }
    $end = $Text.IndexOf($FollowingMarker, $start.Index, [System.StringComparison]::Ordinal)
    if ($end -lt 0) {
        Fail "Could not delimit C string block $Symbol"
    }
    $block = $Text.Substring($start.Index, $end - $start.Index)
    $semicolon = $block.LastIndexOf(';')
    if ($semicolon -lt 0) {
        Fail "Could not terminate C string block $Symbol"
    }
    return $block.Substring(0, $semicolon + 1)
}

function Get-CFunctionBlock([string]$Text, [string]$Name) {
    $signature = [regex]::Match($Text, '(?m)^(?:static\s+)?[^\r\n]*\b' + [regex]::Escape($Name) + '\s*\([^\)]*\)\s*\{', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $signature.Success) {
        Fail "Could not find function $Name"
    }
    $open = $Text.IndexOf('{', $signature.Index, [System.StringComparison]::Ordinal)
    $depth = 0
    for ($index = $open; $index -lt $Text.Length; ++$index) {
        if ($Text[$index] -eq '{') { ++$depth }
        elseif ($Text[$index] -eq '}') {
            --$depth
            if ($depth -eq 0) {
                return $Text.Substring($signature.Index, $index - $signature.Index + 1)
            }
        }
    }
    Fail "Could not delimit function $Name"
}

function Get-CFunctionRange([string]$Text, [string]$Name) {
    $signature = [regex]::Match($Text, '(?m)^(?:static\s+)?[^\r\n]*\b' + [regex]::Escape($Name) + '\s*\([^\)]*\)\s*\{', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $signature.Success) {
        Fail "Could not find function $Name"
    }
    $open = $Text.IndexOf('{', $signature.Index, [System.StringComparison]::Ordinal)
    $depth = 0
    for ($index = $open; $index -lt $Text.Length; ++$index) {
        if ($Text[$index] -eq '{') { ++$depth }
        elseif ($Text[$index] -eq '}') {
            --$depth
            if ($depth -eq 0) {
                return @{ Start = $signature.Index; End = $index + 1 }
            }
        }
    }
    Fail "Could not delimit function $Name"
}

function Get-GlslFunctionBlock([string]$Text, [string]$Name) {
    $signature = [regex]::Match($Text, '(?m)^(?:[A-Za-z_][A-Za-z0-9_]*\s+)+' + [regex]::Escape($Name) + '\s*\([^\)]*\)\s*\{', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $signature.Success) {
        Fail "Could not find canonical GLSL function $Name"
    }
    $open = $Text.IndexOf('{', $signature.Index, [System.StringComparison]::Ordinal)
    $depth = 0
    for ($index = $open; $index -lt $Text.Length; ++$index) {
        if ($Text[$index] -eq '{') { ++$depth }
        elseif ($Text[$index] -eq '}') {
            --$depth
            if ($depth -eq 0) {
                return $Text.Substring($signature.Index, $index - $signature.Index + 1)
            }
        }
    }
    Fail "Could not delimit canonical GLSL function $Name"
}

function Replace-ExactlyOnce([string]$Text, [string]$Before, [string]$After, [string]$Label) {
    $Before = Normalize-Lf $Before
    $After = Normalize-Lf $After
    $first = $Text.IndexOf($Before, [System.StringComparison]::Ordinal)
    if ($first -lt 0) {
        Fail "Immutable baseline does not contain expected $Label patch anchor"
    }
    $second = $Text.IndexOf($Before, $first + $Before.Length, [System.StringComparison]::Ordinal)
    if ($second -ge 0) {
        Fail "Immutable baseline has ambiguous $Label patch anchors"
    }
    return $Text.Substring(0, $first) + $After + $Text.Substring($first + $Before.Length)
}

function Replace-Range([string]$Text, [int]$Start, [int]$End, [string]$After, [string]$Label) {
    if ($Start -lt 0 -or $End -lt $Start -or $End -gt $Text.Length) {
        Fail "Could not delimit $Label replacement range"
    }
    return $Text.Substring(0, $Start) + (Normalize-Lf $After) + $Text.Substring($End)
}

function Get-GeneratedIncludeBytes([byte[]]$IncludeBytes) {
    if ($IncludeBytes.Length -lt 1) {
        Fail 'Generated shader include is empty'
    }
    if ($IncludeBytes.Length -ge 3 -and $IncludeBytes[0] -eq 0xef -and $IncludeBytes[1] -eq 0xbb -and $IncludeBytes[2] -eq 0xbf) {
        Fail 'Generated shader include must not contain a UTF-8 BOM'
    }
    foreach ($byte in $IncludeBytes) {
        if ($byte -eq 13 -or $byte -eq 0) {
            Fail 'Generated shader include must use LF-only text without NUL bytes'
        }
    }

    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $include = $encoding.GetString($IncludeBytes)
    }
    catch {
        Fail "Generated shader include is not valid UTF-8: $($_.Exception.Message)"
    }
    if (-not $include.EndsWith("`n", [System.StringComparison]::Ordinal)) {
        Fail 'Generated shader include must end with LF'
    }

    $lines = $include.Split(@("`n"), [System.StringSplitOptions]::None)
    if ($lines.Count -lt 3 -or $lines[$lines.Count - 1] -ne '') {
        Fail 'Generated shader include has an invalid line layout'
    }
    if ($lines[0] -ne '/* Generated from blackhole_screensaver.glsl; do not edit. */') {
        Fail 'Generated shader include has an unexpected provenance banner'
    }

    $stream = New-Object System.IO.MemoryStream
    try {
        for ($lineIndex = 1; $lineIndex -lt $lines.Count - 1; ++$lineIndex) {
            $line = $lines[$lineIndex]
            if ($line.Length -lt 2 -or $line[0] -ne '"' -or $line[$line.Length - 1] -ne '"') {
                Fail "Generated shader include line $($lineIndex + 1) is not a C string literal"
            }
            for ($index = 1; $index -lt $line.Length - 1; ++$index) {
                $character = $line[$index]
                if ($character -eq '\') {
                    ++$index
                    if ($index -ge $line.Length - 1) {
                        Fail "Generated shader include line $($lineIndex + 1) ends in an incomplete C escape"
                    }
                    switch ($line[$index]) {
                        'n' { [void]$stream.WriteByte(10) }
                        't' { [void]$stream.WriteByte(9) }
                        '"' { [void]$stream.WriteByte(34) }
                        '\' { [void]$stream.WriteByte(92) }
                        default { Fail "Generated shader include line $($lineIndex + 1) contains an unsupported C escape" }
                    }
                }
                else {
                    if ([int][char]$character -gt 127) {
                        Fail "Generated shader include line $($lineIndex + 1) is not ASCII-safe"
                    }
                    [void]$stream.WriteByte([byte][char]$character)
                }
            }
        }
        return $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

function Test-ByteEquality([byte[]]$Left, [byte[]]$Right, [string]$Label) {
    if ($Left.Length -ne $Right.Length) {
        Fail "$Label byte length differs ($($Left.Length) versus $($Right.Length))"
    }
    for ($index = 0; $index -lt $Left.Length; ++$index) {
        if ($Left[$index] -ne $Right[$index]) {
            Fail "$Label differs at byte $index"
        }
    }
}

function Build-Milestone2Source([string]$BaselineSource) {
    $expected = $BaselineSource
    $expected = Replace-ExactlyOnce $expected @'
static GLsync g_frameFence;
static ULONGLONG g_frameSubmitTick;
static ULONGLONG g_nextFrameEligibleTick;
static int g_frameSyncReady;
static GLfloat g_sceneSeed;
'@ @'
typedef struct SceneState {
    // Immutable snapshot passed from the host to one rendered frame. M2 owns
    // frame inputs only; legacy GLSL still derives the tour and pose for parity.
    GLfloat elapsedSeconds;
    GLfloat resolutionX;
    GLfloat resolutionY;
    GLfloat starGain;
    GLfloat diskOpacity;
    GLfloat doppler;
    GLfloat sceneSeed;
    GLfloat skySeed;
} SceneState;

static GLsync g_frameFence;
static ULONGLONG g_frameSubmitTick;
static ULONGLONG g_nextFrameEligibleTick;
static int g_frameSyncReady;
static GLfloat g_sceneSeed;
static GLfloat g_skySeed;
'@ 'SceneState global declaration'
    $expected = Replace-ExactlyOnce $expected @'
"uniform float uSceneSeed;\n"
"\n";
'@ @'
"uniform float uSceneSeed;\n"
"uniform float uSkySeed;\n"
"\n";
'@ 'fragment header sky-seed declaration'
    $expected = Replace-ExactlyOnce $expected @'
static GLint  uTime = -1, uResolution = -1, uStarGain = -1, uDiskOpacity = -1, uDoppler = -1, uSceneSeed = -1;
'@ @'
static GLint  uTime = -1, uResolution = -1, uStarGain = -1, uDiskOpacity = -1, uDoppler = -1, uSceneSeed = -1, uSkySeed = -1;
'@ 'sky-seed uniform location'
    $expected = Replace-ExactlyOnce $expected @'
    uSceneSeed  = glGetUniformLocation(shaderProgram, "uSceneSeed");
    if (uSceneSeed >= 0) glUniform1f(uSceneSeed, g_sceneSeed);
'@ @'
    uSceneSeed  = glGetUniformLocation(shaderProgram, "uSceneSeed");
    uSkySeed    = glGetUniformLocation(shaderProgram, "uSkySeed");
'@ 'centralized seed upload'

    $baselineRenderFrame = Get-CFunctionBlock $BaselineSource 'renderFrame'
    $expectedRenderFrame = @'
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
'@
    $sceneStateHelpers = @'
static SceneState makeSceneState(ULONGLONG now) {
    SceneState state;
    state.elapsedSeconds = (float)(now - g_tick0) / 1000.0f;
    state.resolutionX = (float)g_W;
    state.resolutionY = (float)g_H;
    // Preserve raw legacy normalization here. Shader-side clamps remain the
    // authority for malformed registry values until the later config milestone.
    state.starGain = (float)cfg_starBrightness / 100.0f;
    state.diskOpacity = (float)cfg_diskOpacity / 100.0f;
    state.doppler = (float)cfg_doppler / 100.0f;
    state.sceneSeed = g_sceneSeed;
    state.skySeed = g_skySeed;
    return state;
}

static void uploadSceneState(const SceneState* state) {
    glUniform1f(uTime, state->elapsedSeconds);
    glUniform2f(uResolution, state->resolutionX, state->resolutionY);
    if (uStarGain >= 0)    glUniform1f(uStarGain, state->starGain);
    if (uDiskOpacity >= 0) glUniform1f(uDiskOpacity, state->diskOpacity);
    if (uDoppler >= 0)     glUniform1f(uDoppler, state->doppler);
    if (uSceneSeed >= 0)   glUniform1f(uSceneSeed, state->sceneSeed);
    // uSkySeed is deliberately inactive in M2 because shaderSource does not
    // consume it yet. -1 is valid and becomes active with the M3 sky migration.
    if (uSkySeed >= 0)     glUniform1f(uSkySeed, state->skySeed);
}
'@
    $expected = Replace-ExactlyOnce $expected $baselineRenderFrame ($sceneStateHelpers + "`n" + $expectedRenderFrame) 'SceneState frame upload seam'
    $expected = Replace-ExactlyOnce $expected @'
    // Immutable for this run: it randomizes the four-look tour without
    // introducing host-side current/next scene state.
    g_sceneSeed = makeSceneSeed();
'@ @'
    // Separate immutable run seeds are owned by the host. M2 leaves the
    // legacy shader's tour and sky layout bound to sceneSeed for exact parity;
    // skySeed becomes active only with the future inertial-sky migration.
    g_sceneSeed = makeSceneSeed();
    g_skySeed = makeSceneSeed();
'@ 'independent run seeds'
    return $expected
}

function Build-Milestone3Source([string]$Milestone2Source) {
    $shaderStart = $Milestone2Source.IndexOf('// ============================================================ shader source ==', [System.StringComparison]::Ordinal)
    $shaderEnd = $Milestone2Source.IndexOf('// ============================================================ fullscreen quad ==', $shaderStart, [System.StringComparison]::Ordinal)
    $shaderRegion = @'
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
'@ + "`n`n"
    $expected = Replace-Range $Milestone2Source $shaderStart $shaderEnd $shaderRegion 'canonical shader source migration'

    # The generated canonical source owns #version and all fragment uniforms,
    # so the M2 assembly header is deliberately removed rather than retained.
    $fragmentHeaderStart = $expected.IndexOf('static const char* fragHeader =', [System.StringComparison]::Ordinal)
    $glHelpersStart = $expected.IndexOf('// ============================================================ GL helpers ==', $fragmentHeaderStart, [System.StringComparison]::Ordinal)
    $expected = Replace-Range $expected $fragmentHeaderStart $glHelpersStart '' 'retired fragment assembly header'

    # Replace the exact lexical function range. This avoids encoding-dependent
    # comparisons against legacy non-ASCII comments in the immutable source.
    $m2InitShaderRange = Get-CFunctionRange $expected 'initShader'
    $m3InitShader = @'
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

    // empty VAO __EM_DASH__ needed by some drivers even with gl_VertexID
    p_glGenVertexArrays(1, &vao);
    p_glBindVertexArray(vao);

    return 1;
}
'@
    $m3InitShader = $m3InitShader.Replace('__EM_DASH__', ([char]0x2014).ToString())
    $expected = Replace-Range $expected ([int]$m2InitShaderRange.Start) ([int]$m2InitShaderRange.End) $m3InitShader 'canonical shader compilation path'
    $m2SkyUploadCommentStart = $expected.IndexOf('    // uSkySeed is deliberately inactive in M2', [System.StringComparison]::Ordinal)
    $m2SkyUploadGuardStart = $expected.IndexOf('    if (uSkySeed >= 0)', $m2SkyUploadCommentStart, [System.StringComparison]::Ordinal)
    $m2SkyUploadGuardEnd = $expected.IndexOf("`n", $m2SkyUploadGuardStart) + 1
    # Preserve the uploader closing brace and its existing blank separator.
    $m3SkyUpload = "    // M3 consumes uSkySeed for the inertial sky. Keep the location guard for`n" +
                   "    // compatibility with drivers that optimize a uniform in a failed fallback.`n" +
                   "    if (uSkySeed >= 0)     glUniform1f(uSkySeed, state->skySeed);`n"
    $expected = Replace-Range $expected $m2SkyUploadCommentStart $m2SkyUploadGuardEnd $m3SkyUpload 'active inertial-sky seed upload comment'
    return $expected
}

$contractPath = Join-Path $ProjectRoot 'tests\milestone-3-contract.json'
Require-File $contractPath 'Contract JSON'
try {
    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
}
catch {
    Fail "Contract JSON is invalid: $($_.Exception.Message)"
}
if ($contract.contract -ne 'blackhole-screensaver-milestone-3' -or [int]$contract.version -ne 1) {
    Fail 'Unexpected contract identity or version'
}
if ($contract.scope -ne 'canonical-glsl-and-inertial-world-sky') {
    Fail 'Unexpected contract scope'
}

$sourceRelativePath = [string]$contract.preMilestoneBaseline.sourcePath
if ($sourceRelativePath -ne 'blackhole_screensaver.c') {
    Fail 'Unexpected authoritative host source path'
}
$sourcePath = Join-Path $ProjectRoot $sourceRelativePath
$canonicalPath = Join-Path $ProjectRoot ([string]$contract.canonicalShader.path)
$includePath = Join-Path $ProjectRoot ([string]$contract.canonicalShader.generatedInclude)
$generatorPath = Join-Path $ProjectRoot ([string]$contract.canonicalShader.generator)
$buildPath = Join-Path $ProjectRoot ([string]$contract.build.script)
Require-File $sourcePath 'Authoritative host source'
Require-File $canonicalPath 'Canonical GLSL source'
Require-File $includePath 'Generated shader include'
Require-File $generatorPath 'Shader include generator'
Require-File $buildPath 'Build script'

$baseline = $contract.preMilestoneBaseline
if ($baseline.lineEndingNormalization -ne 'lf') {
    Fail 'Unexpected immutable baseline line ending policy'
}
$baselineCommit = [string]$baseline.preM2Commit
if ($baselineCommit -notmatch '^[0-9a-f]{40}$') {
    Fail 'Pre-M2 baseline commit must be a full lowercase SHA-1'
}
$baselineSource = Normalize-Lf (Get-GitRevisionText $ProjectRoot $baselineCommit $sourceRelativePath)
if ((Get-LfNormalizedSha256 $baselineSource) -ne ([string]$baseline.preM2SourceSha256).ToUpperInvariant()) {
    Fail 'Immutable pre-M2 host source does not match its reviewed SHA-256'
}
$baselineShaderBlock = Get-CStringBlock $baselineSource 'shaderSource' '// ============================================================ fullscreen quad =='
if ((Get-LfNormalizedSha256 $baselineShaderBlock) -ne ([string]$baseline.preM2ShaderCBlockSha256).ToUpperInvariant()) {
    Fail 'Immutable pre-M2 embedded shader C block does not match its reviewed SHA-256'
}

$currentSource = Normalize-Lf ([System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8))
$m2Source = Build-Milestone2Source $baselineSource
$expectedM3Source = Build-Milestone3Source $m2Source
$currentSourceForParity = $currentSource
if ($currentSourceForParity -cne $expectedM3Source) {
    $differenceAt = 0
    $limit = [Math]::Min($currentSourceForParity.Length, $expectedM3Source.Length)
    while ($differenceAt -lt $limit -and $currentSourceForParity[$differenceAt] -ceq $expectedM3Source[$differenceAt]) {
        ++$differenceAt
    }
    $contextStart = [Math]::Max(0, $differenceAt - 48)
    $contextLength = [Math]::Min(120, $limit - $contextStart)
    $actualContext = $currentSourceForParity.Substring($contextStart, $contextLength).Replace("`n", "\\n")
    $expectedContext = $expectedM3Source.Substring($contextStart, $contextLength).Replace("`n", "\\n")
    Fail ("Authoritative host source is not exactly the reviewed M2 host plus the canonical-shader M3 patch (first difference at character {0}; actual length {1}, expected length {2}; actual: {3}; expected: {4})" -f $differenceAt, $currentSourceForParity.Length, $expectedM3Source.Length, $actualContext, $expectedContext)
}

foreach ($functionName in @($contract.host.preservedFunctions)) {
    $currentBlock = Get-CFunctionBlock $currentSource ([string]$functionName)
    $m2Block = Get-CFunctionBlock $m2Source ([string]$functionName)
    if ($currentBlock -cne $m2Block) {
        Fail "M3 unexpectedly changed preserved host function $functionName"
    }
}
Require-Contains $currentSource ([string]$contract.host.shaderDeclaration) 'Generated shader C declaration'
Require-Contains $currentSource ([string]$contract.host.sourceInclude) 'Generated shader C include'
Require-Contains $currentSource ([string]$contract.host.requiredUniformUpload) 'Active inertial-sky uniform upload'
Require-Contains $currentSource ([string]$contract.host.drawCall) 'Single fullscreen draw call'
foreach ($token in @($contract.host.forbiddenTokens)) {
    Require-NotContains $currentSource ([string]$token) 'Host source'
}
if ([regex]::Matches($currentSource, '\bglDrawArrays\s*\(', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 1) {
    Fail 'Host must retain exactly one glDrawArrays call'
}
if ([regex]::Matches($currentSource, '\bSwapBuffers\s*\(', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 1) {
    Fail 'Host must retain exactly one SwapBuffers call'
}

$canonicalBytes = [System.IO.File]::ReadAllBytes($canonicalPath)
if ($canonicalBytes.Length -lt 1) {
    Fail 'Canonical GLSL source is empty'
}
if ($canonicalBytes.Length -ge 3 -and $canonicalBytes[0] -eq 0xef -and $canonicalBytes[1] -eq 0xbb -and $canonicalBytes[2] -eq 0xbf) {
    Fail 'Canonical GLSL source must not contain a UTF-8 BOM'
}
foreach ($byte in $canonicalBytes) {
    if ($byte -eq 13 -or $byte -eq 0 -or $byte -gt 127) {
        Fail 'Canonical GLSL must be ASCII, LF-only, and NUL-free'
    }
}
$canonicalText = [System.Text.Encoding]::UTF8.GetString($canonicalBytes)
if (-not $canonicalText.EndsWith("`n", [System.StringComparison]::Ordinal)) {
    Fail 'Canonical GLSL source must end with LF'
}
if (-not $canonicalText.StartsWith([string]$contract.canonicalShader.firstDirective, [System.StringComparison]::Ordinal)) {
    Fail 'Canonical GLSL source must begin with the required OpenGL 3.30 directive'
}
if ((Get-BytesSha256 $canonicalBytes) -ne ([string]$contract.canonicalShader.sourceSha256).ToUpperInvariant()) {
    Fail 'Canonical GLSL source does not match its reviewed SHA-256'
}
foreach ($uniform in @($contract.canonicalShader.requiredUniforms)) {
    Require-Contains $canonicalText ([string]$uniform) 'Canonical GLSL uniform declaration'
}
foreach ($token in @($contract.canonicalShader.forbiddenTokens)) {
    Require-NotContains $canonicalText ([string]$token) 'Canonical GLSL'
}
Require-Contains $canonicalText '#define N_STEPS 48' '48-step Schwarzschild baseline'
Require-Contains $canonicalText '#define DEMO_N 4' 'Four-look baseline'

# Independently decode the generated C literals byte-for-byte, then ensure the
# checked-in include is current through the generator's own stale-file check.
$decodedIncludeBytes = Get-GeneratedIncludeBytes ([System.IO.File]::ReadAllBytes($includePath))
Test-ByteEquality $decodedIncludeBytes $canonicalBytes 'Generated include decoded GLSL'
& $generatorPath -ProjectRoot $ProjectRoot -Check
if (-not $?) {
    Fail 'Shader include generator check did not complete successfully'
}

$starsBlock = Get-GlslFunctionBlock $canonicalText ([string]$contract.inertialSky.starsFunction)
$spaceBlock = Get-GlslFunctionBlock $canonicalText ([string]$contract.inertialSky.spaceFunction)
$skyBlock = Get-GlslFunctionBlock $canonicalText ([string]$contract.inertialSky.skyFunction)
$coordinatesBlock = Get-GlslFunctionBlock $canonicalText ([string]$contract.inertialSky.coordinatesFunction)
$lensBlock = Get-GlslFunctionBlock $canonicalText ([string]$contract.inertialSky.lensFunction)
$viewBlock = Get-GlslFunctionBlock $canonicalText ([string]$contract.inertialSky.viewFunction)
Require-Contains $starsBlock 'uSkySeed' 'Inertial star catalogue seed use'
Require-NotContains $starsBlock 'uSceneSeed' 'Inertial star catalogue'
Require-Contains $skyBlock 'return spaceBackground(worldDir)+stars(worldDir)*starGain;' 'Unified inertial sky sample'
Require-Contains $starsBlock ([string]$contract.inertialSky.sharedCoordinatesCall) 'Star catalogue shared world-sky coordinates'
Require-Contains $spaceBlock ([string]$contract.inertialSky.sharedCoordinatesCall) 'Background shared world-sky coordinates'
foreach ($motionStatement in @($contract.inertialSky.skyMotionStatements)) {
    Require-Contains $coordinatesBlock ([string]$motionStatement) 'World-sky motion mapping'
}
foreach ($token in @($contract.inertialSky.skyForbiddenTokens)) {
    Require-NotContains $starsBlock ([string]$token) 'Inertial star catalogue'
    Require-NotContains $spaceBlock ([string]$token) 'Inertial background field'
    Require-NotContains $skyBlock ([string]$token) 'Unified inertial sky sample'
    Require-NotContains $coordinatesBlock ([string]$token) 'World-sky coordinate mapping'
}
Require-Contains $viewBlock 'return normalize(vec3((uv-0.5)*vec2(aspect,1.0),-1.0));' 'Direct world direction mapping'
foreach ($identityStatement in @($contract.inertialSky.identityStatements)) {
    Require-Contains $lensBlock ([string]$identityStatement) 'Lensed direction identity invariant'
}
Require-Contains $lensBlock ([string]$contract.inertialSky.lensScaleParameter) 'Lens-space to world-space scale parameter'
Require-Contains $lensBlock ([string]$contract.inertialSky.sourcePlaneProjection) 'Escaping-ray source-plane projection'
Require-Contains $canonicalText ([string]$contract.inertialSky.lensScaleCall) 'Lens-space to world-space scale call'
Require-Contains $canonicalText ([string]$contract.inertialSky.escapeDirectionGuard) 'Escaping ray direction guard'
Require-Contains $canonicalText ([string]$contract.inertialSky.directCall) 'Direct inertial sky call'
Require-Contains $canonicalText ([string]$contract.inertialSky.directionRemap) 'Continuous lensed sky direction remap'
Require-Contains $canonicalText ([string]$contract.inertialSky.noColorCrossfade) 'Captured-ray sky edge'
Require-Contains $canonicalText ([string]$contract.inertialSky.lensedCall) 'Lensed inertial sky call'
if ([regex]::Matches($canonicalText, '\bskyRadiance\s*\(', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 3) {
    Fail 'Canonical GLSL must have one skyRadiance definition and exactly two sampling paths'
}
if ([regex]::Matches($canonicalText, '\bstars\s*\(', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 2) {
    Fail 'Canonical GLSL must route all star sampling through skyRadiance'
}

$buildText = Normalize-Lf ([System.IO.File]::ReadAllText($buildPath, [System.Text.Encoding]::UTF8))
Require-Contains $buildText ([string]$contract.build.generatorInvocation) 'Build-time canonical shader generator invocation'
Require-Contains $buildText ([string]$contract.build.temporaryOutputVariable) 'Temporary output build protocol'
Require-Contains $buildText ([string]$contract.build.promotion) 'Atomic completed-build promotion'
Require-NotContains $buildText '/Fe:blackhole.scr' 'Build script direct release overwrite'
Require-Match $buildText '(?m)^echo\s+Generating shader include\.\.\.' 'Generator preceding compiler selection'

Write-Host 'Milestone 3 canonical GLSL and inertial-sky contract verified.'
