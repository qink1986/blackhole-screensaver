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
    throw "Milestone 2 contract failure: $Message"
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

function Require-Match([string]$Text, [string]$Pattern, [string]$Label) {
    if (-not [regex]::IsMatch($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        Fail "$Label does not match: $Pattern"
    }
}

function Require-OrderedContains([string]$Text, [string[]]$Needles, [string]$Label) {
    $offset = 0
    foreach ($needle in $Needles) {
        $index = $Text.IndexOf($needle, $offset, [System.StringComparison]::Ordinal)
        if ($index -lt 0) {
            Fail "$Label is missing ordered source anchor: $needle"
        }
        $offset = $index + $needle.Length
    }
}

function Normalize-Lf([string]$Text) {
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-LfNormalizedSha256([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((Normalize-Lf $Text))
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '')
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

function Replace-ExactlyOnce([string]$Text, [string]$Before, [string]$After, [string]$Label) {
    $Before = Normalize-Lf $Before
    $After = Normalize-Lf $After
    $first = $Text.IndexOf($Before, [System.StringComparison]::Ordinal)
    if ($first -lt 0) {
        Fail "Immutable pre-Milestone source does not contain expected $Label patch anchor"
    }
    $second = $Text.IndexOf($Before, $first + $Before.Length, [System.StringComparison]::Ordinal)
    if ($second -ge 0) {
        Fail "Immutable pre-Milestone source has ambiguous $Label patch anchors"
    }
    return $Text.Substring(0, $first) + $After + $Text.Substring($first + $Before.Length)
}

$contractPath = Join-Path $ProjectRoot 'tests\milestone-2-contract.json'
$milestoneOneVerifier = Join-Path $ProjectRoot 'tools\verify-milestone-1.ps1'
Require-File $contractPath 'Contract JSON'
Require-File $milestoneOneVerifier 'Milestone 1 verifier'

try {
    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
}
catch {
    Fail "Contract JSON is invalid: $($_.Exception.Message)"
}

if ($contract.contract -ne 'blackhole-screensaver-milestone-2' -or [int]$contract.version -ne 1) {
    Fail 'Unexpected contract identity or version'
}
if ($contract.scope -ne 'host-owned-frame-input-seam-schwarzschild-parity') {
    Fail 'Unexpected contract scope'
}
if ($contract.state.skySeedPolicy -ne 'independent-run-seed-reserved-unconsumed-until-milestone-3') {
    Fail 'Unexpected sky-seed policy'
}

& $milestoneOneVerifier -ProjectRoot $ProjectRoot

$baseline = $contract.preMilestoneBaseline
if ($baseline.lineEndingNormalization -ne 'lf') {
    Fail 'Unexpected pre-Milestone line-ending normalization'
}
$baselineCommit = [string]$baseline.commit
if ($baselineCommit -notmatch '^[0-9a-f]{40}$') {
    Fail 'Pre-Milestone baseline commit must be a full lowercase SHA-1'
}
$repositorySourcePath = [string]$baseline.sourcePath
if ($repositorySourcePath -ne 'blackhole_screensaver.c') {
    Fail 'Unexpected pre-Milestone source path'
}

$sourcePath = Join-Path $ProjectRoot $repositorySourcePath
Require-File $sourcePath 'Authoritative host source'
$source = Normalize-Lf ([System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8))
$baselineSource = Normalize-Lf (Get-GitRevisionText $ProjectRoot $baselineCommit $repositorySourcePath)

$baselineShaderBlock = Get-CStringBlock $baselineSource ([string]$contract.shader.sourceSymbol) "// ============================================================ fullscreen quad =="
$baselineShaderHash = Get-LfNormalizedSha256 $baselineShaderBlock
$expectedShaderHash = ([string]$baseline.shaderSourceSha256).ToUpperInvariant()
if ($expectedShaderHash -notmatch '^[0-9A-F]{64}$') {
    Fail 'Pre-Milestone embedded shader-source SHA-256 is malformed'
}
if ($baselineShaderHash -ne $expectedShaderHash) {
    Fail "Configured pre-Milestone commit does not match the reviewed shaderSource baseline. Expected $expectedShaderHash, got $baselineShaderHash"
}

# Prove the current host is exactly the immutable pre-M2 source plus the small,
# reviewed seam patch below. This protects shader math, registry handling,
# scheduling/fence logic, hidden-first-frame ordering, and all other C regions.
$expectedSource = $baselineSource
$expectedSource = Replace-ExactlyOnce $expectedSource @'
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
$expectedSource = Replace-ExactlyOnce $expectedSource @'
"uniform float uSceneSeed;\n"
"\n";
'@ @'
"uniform float uSceneSeed;\n"
"uniform float uSkySeed;\n"
"\n";
'@ 'fragment header sky-seed declaration'
$expectedSource = Replace-ExactlyOnce $expectedSource @'
static GLint  uTime = -1, uResolution = -1, uStarGain = -1, uDiskOpacity = -1, uDoppler = -1, uSceneSeed = -1;
'@ @'
static GLint  uTime = -1, uResolution = -1, uStarGain = -1, uDiskOpacity = -1, uDoppler = -1, uSceneSeed = -1, uSkySeed = -1;
'@ 'sky-seed uniform location'
$expectedSource = Replace-ExactlyOnce $expectedSource @'
    uSceneSeed  = glGetUniformLocation(shaderProgram, "uSceneSeed");
    if (uSceneSeed >= 0) glUniform1f(uSceneSeed, g_sceneSeed);
'@ @'
    uSceneSeed  = glGetUniformLocation(shaderProgram, "uSceneSeed");
    uSkySeed    = glGetUniformLocation(shaderProgram, "uSkySeed");
'@ 'centralized seed upload'

$baselineRenderFrame = Get-CFunctionBlock $baselineSource ([string]$contract.render.function)
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
$expectedSource = Replace-ExactlyOnce $expectedSource $baselineRenderFrame ($sceneStateHelpers + "`n" + $expectedRenderFrame) 'SceneState frame upload seam'
$expectedSource = Replace-ExactlyOnce $expectedSource @'
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

if ($source -cne $expectedSource) {
    $differenceAt = 0
    $limit = [Math]::Min($source.Length, $expectedSource.Length)
    while ($differenceAt -lt $limit -and $source[$differenceAt] -ceq $expectedSource[$differenceAt]) {
        ++$differenceAt
    }
    $contextStart = [Math]::Max(0, $differenceAt - 48)
    $contextLength = [Math]::Min(120, $limit - $contextStart)
    $actualContext = $source.Substring($contextStart, $contextLength).Replace("`n", "\\n")
    $expectedContext = $expectedSource.Substring($contextStart, $contextLength).Replace("`n", "\\n")
    Fail ("Authoritative host source is not exactly the immutable pre-Milestone source plus the reviewed M2 SceneState patch (first difference at character {0}; actual length {1}, expected length {2}; actual: {3}; expected: {4})" -f $differenceAt, $source.Length, $expectedSource.Length, $actualContext, $expectedContext)
}

$shaderBlock = Get-CStringBlock $source ([string]$contract.shader.sourceSymbol) "// ============================================================ fullscreen quad =="
if ((Normalize-Lf $shaderBlock) -cne (Normalize-Lf $baselineShaderBlock)) {
    Fail 'Embedded shaderSource differs from the immutable pre-Milestone baseline'
}
foreach ($forbidden in $contract.shader.bodyMustNotContain) {
    if ($shaderBlock.IndexOf([string]$forbidden, [System.StringComparison]::Ordinal) -ge 0) {
        Fail "Embedded shaderSource unexpectedly consumes reserved identifier: $forbidden"
    }
}

$headerBlock = Get-CStringBlock $source ([string]$contract.shader.headerSymbol) "// ============================================================ GL helpers =="
Require-Contains $headerBlock ('uniform float ' + $contract.shader.reservedSkyUniform + ';') 'Reserved sky-seed declaration'
Require-Match $source ([regex]::Escape($contract.shader.reservedSkyUniform) + '\s*=\s*glGetUniformLocation\(shaderProgram,\s*"' + [regex]::Escape($contract.shader.reservedSkyUniform) + '"\);') 'Reserved sky-seed lookup'

$stateMatch = [regex]::Match($source, '(?s)typedef\s+struct\s+' + [regex]::Escape([string]$contract.state.structName) + '\s*\{(?<body>.*?)\}\s*' + [regex]::Escape([string]$contract.state.structName) + '\s*;', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
if (-not $stateMatch.Success) {
    Fail "Could not find $($contract.state.structName) definition"
}
$stateBody = $stateMatch.Groups['body'].Value
$fieldMatches = [regex]::Matches($stateBody, '(?m)^\s*(GLfloat)\s+([A-Za-z_][A-Za-z0-9_]*)\s*;', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
if ($fieldMatches.Count -ne @($contract.state.fields).Count) {
    Fail "Expected $(@($contract.state.fields).Count) SceneState fields; found $($fieldMatches.Count)"
}
for ($index = 0; $index -lt $fieldMatches.Count; ++$index) {
    $field = $contract.state.fields[$index]
    if ($fieldMatches[$index].Groups[1].Value -ne $field.type -or $fieldMatches[$index].Groups[2].Value -ne $field.name) {
        Fail "SceneState field $index must be $($field.type) $($field.name)"
    }
}

$builderBlock = Get-CFunctionBlock $source ([string]$contract.state.builder)
foreach ($field in $contract.state.fields) {
    Require-Contains $builderBlock ('state.' + $field.name + ' = ' + $field.expression + ';') ("SceneState builder assignment for " + $field.name)
}

$uploaderBlock = Get-CFunctionBlock $source ([string]$contract.state.uploader)
foreach ($uniform in $contract.shader.activeUniforms) {
    Require-Contains $headerBlock ([string]$uniform.declaration) ("Active uniform declaration for " + $uniform.shaderName)
    Require-Match $source ([regex]::Escape([string]$uniform.location) + '\s*=\s*glGetUniformLocation\(shaderProgram,\s*"' + [regex]::Escape([string]$uniform.shaderName) + '"\);') ("Active uniform lookup for " + $uniform.shaderName)
    Require-Contains $uploaderBlock ([string]$uniform.upload) ("Centralized upload for " + $uniform.shaderName)
}
Require-Match $uploaderBlock ('if\s*\(\s*' + [regex]::Escape([string]$contract.shader.reservedSkyUniform) + '\s*>=\s*0\s*\)\s*glUniform1f\(' + [regex]::Escape([string]$contract.shader.reservedSkyUniform) + ',\s*state->skySeed\);') 'Guarded reserved sky-seed upload'

$sourceWithoutUploader = $source.Remove($source.IndexOf($uploaderBlock, [System.StringComparison]::Ordinal), $uploaderBlock.Length)
if ([regex]::IsMatch($sourceWithoutUploader, '\bglUniform[12]f\s*\(', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
    Fail 'Found a uniform upload outside uploadSceneState'
}

Require-Match $source ('static\s+GLfloat\s+g_sceneSeed\s*;') 'Scene seed global'
Require-Match $source ('static\s+GLfloat\s+g_skySeed\s*;') 'Sky seed global'
Require-Match $source '(?s)g_sceneSeed\s*=\s*makeSceneSeed\(\);\s*g_skySeed\s*=\s*makeSceneSeed\(\);' 'Independent seed initialization'

$renderBlock = Get-CFunctionBlock $source ([string]$contract.render.function)
Require-OrderedContains $renderBlock @(
    [string]$contract.render.timeSample,
    [string]$contract.render.stateSnapshot,
    [string]$contract.render.programBind,
    [string]$contract.render.stateUpload,
    [string]$contract.render.draw
) 'Frame-state construction and upload order'
if ([regex]::Matches($renderBlock, [regex]::Escape([string]$contract.render.stateSnapshot), [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 1) {
    Fail 'renderFrame must build exactly one SceneState snapshot'
}
if ([regex]::Matches($renderBlock, [regex]::Escape([string]$contract.render.stateUpload), [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 1) {
    Fail 'renderFrame must upload exactly one SceneState snapshot'
}
$initShaderBlock = Get-CFunctionBlock $source 'initShader'
$visibleFrameBlock = Get-CFunctionBlock $source 'renderVisibleFrame'
if ($initShaderBlock.IndexOf([string]$contract.state.builder, [System.StringComparison]::Ordinal) -ge 0 -or $visibleFrameBlock.IndexOf([string]$contract.state.builder, [System.StringComparison]::Ordinal) -ge 0) {
    Fail 'SceneState must be built only in renderFrame, not initShader or the skipped-frame gate'
}

Write-Host ("Milestone 2 contract PASS: {0} v{1}" -f $contract.contract, $contract.version)
Write-Host ("  immutable source baseline: {0}" -f $baselineCommit)
Write-Host ("  SceneState: {0} fields, one snapshot and upload per rendered frame" -f @($contract.state.fields).Count)
Write-Host ("  immutable pre-Milestone shaderSource SHA-256: {0}" -f $baselineShaderHash)
Write-Host ("  reserved {0}: declared and guarded; inactive is valid in M2" -f $contract.shader.reservedSkyUniform)
