[CmdletBinding()]
param([string]$ProjectRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }

function Fail([string]$Message) {
    throw "M7 static contract failure: $Message"
}

function Need([string]$Text, [string]$Needle, [string]$Label) {
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -lt 0) {
        Fail "$Label ($Needle)"
    }
}

function Need-Match([string]$Text, [string]$Pattern, [string]$Label) {
    if (-not [regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) {
        Fail "$Label ($Pattern)"
    }
}

function Need-NotContains([string]$Text, [string]$Needle, [string]$Label) {
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0) {
        Fail "$Label unexpectedly contains $Needle"
    }
}

function Get-CFunctionBlock([string]$Text, [string]$Name) {
    $signature = [regex]::Match($Text, '(?m)^(?:static\s+)?[^\r\n]*\b' + [regex]::Escape($Name) + '\s*\([^\)]*\)\s*\{')
    if (!$signature.Success) { Fail "could not locate C function $Name" }
    $open = $Text.IndexOf('{', $signature.Index)
    $depth = 0
    for ($index = $open; $index -lt $Text.Length; ++$index) {
        if ($Text[$index] -eq '{') { ++$depth }
        elseif ($Text[$index] -eq '}') {
            --$depth
            if ($depth -eq 0) { return $Text.Substring($signature.Index, $index - $signature.Index + 1) }
        }
    }
    Fail "could not delimit C function $Name"
}

$contract = Get-Content (Join-Path $ProjectRoot 'tests\milestone-7-contract.json') -Raw | ConvertFrom-Json
if ($contract.contract -ne 'blackhole-screensaver-milestone-7' -or [int]$contract.version -ne 1 -or [int]$contract.schema.version -ne 2) {
    Fail 'contract identity'
}

$sourcePath = Join-Path $ProjectRoot 'blackhole_screensaver.c'
$shaderPath = Join-Path $ProjectRoot 'blackhole_screensaver.glsl'
$includePath = Join-Path $ProjectRoot 'generated\blackhole_screensaver_frag.inc'
$acceptancePath = Join-Path $ProjectRoot 'docs\milestone-7-acceptance.txt'
$runtimePath = Join-Path $ProjectRoot 'tools\verify-milestone-7-runtime.ps1'
$runtime = [IO.File]::ReadAllText($runtimePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
foreach ($path in @($sourcePath, $shaderPath, $includePath, $acceptancePath, $runtimePath)) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { Fail "required artifact is missing: $path" }
}

$source = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
$shader = [IO.File]::ReadAllText($shaderPath, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
$acceptance = [IO.File]::ReadAllText($acceptancePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")

foreach ($anchor in @(
    '#define CONFIG_SCHEMA_VERSION 2u',
    '#define CONFIG_V2_VALUE_MIN 50',
    '#define CONFIG_V2_VALUE_MAX 200',
    '#define CONFIG_DEFAULT_STAR_DENSITY 100',
    '#define CONFIG_DEFAULT_SKY_FLOW_SPEED 100',
    '"StarDensity"', '"SkyFlowSpeed"',
    'static ConfigValues makeDefaultConfig(void)',
    'static void loadConfig(void)', 'static int saveConfig(const ConfigValues* config)',
    'static LRESULT CALLBACK ConfigWndProc', '/w', 'ADJ_ID_SAVE', 'ADJ_ID_REVERT',
    'WM_GETMINMAXINFO', 'WM_SIZE', 'ADJUST_PANEL_HEIGHT'
)) { Need $source $anchor 'host schema or adjustment policy' }

$load = Get-CFunctionBlock $source 'loadConfig'
Need $load 'schemaStatus == CONFIG_REGISTRY_VALUE_MISSING' 'unmarked legacy branch'
Need $load 'schemaVersion == 1u' 'schema v1 branch'
Need $load 'schemaVersion == CONFIG_SCHEMA_VERSION' 'schema v2 branch'
Need $load '"StarDensity"' 'schema v2 density read'
Need $load '"SkyFlowSpeed"' 'schema v2 speed read'
Need-NotContains $load 'RegSetValueExA' 'load must not write'
Need-NotContains $load 'RegCreateKeyExA' 'load must not create key'

$save = Get-CFunctionBlock $source 'saveConfig'
Need-Match $save 'ok\s*=\s*writeRegistryDword\(key,\s*REG_VALUE_CONFIG_SCHEMA_VERSION,\s*0\s*\)' 'invalid marker first'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*"StarBrightness"' 'short-circuit first setting write'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*"DiskOpacity"' 'short-circuit second setting write'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*"Doppler"' 'short-circuit third setting write'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*"StarDensity"' 'short-circuit fourth setting write'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*"SkyFlowSpeed"' 'short-circuit fifth setting write'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*REG_VALUE_CONFIG_SCHEMA_VERSION,\s*CONFIG_SCHEMA_VERSION\s*\)' 'schema v2 marker last'

$configWindow = Get-CFunctionBlock $source 'ConfigWndProc'
Need $configWindow 'if (!saveConfig(&pending))' 'configuration save failure stays open'
Need $configWindow 'CFG_ID_CANCEL' 'configuration cancel control'

foreach ($anchor in @(
    'uStarDensity', 'uSkyFlowSpeed', 'uViewportOriginY',
    'state.starDensity = (float)cfg_starDensity / 100.0f;',
    'state.skyFlowSpeed = (float)cfg_skyFlowSpeed / 100.0f;',
    'state.viewportOriginY = g_adjustmentMode ? (GLfloat)ADJUST_PANEL_HEIGHT : 0.0f;',
    'glUniform1f(uStarDensity, state->starDensity)',
    'glUniform1f(uSkyFlowSpeed, state->skyFlowSpeed)',
    'glUniform1f(uViewportOriginY, state->viewportOriginY)'
)) { Need $source $anchor 'host-to-shader mapping' }

$window = Get-CFunctionBlock $source 'WndProc'
Need $window 'if (!g_preview && !g_adjustmentMode && shouldExit())' '/w input-exit isolation'
Need $window 'if (g_adjustmentMode && g_adjustmentDirty) applyConfig(&g_adjustmentSnapshot)' 'unsaved /w close reversion'
Need $window 'setControlsConfig(hwnd, ADJ_ID_STAR_SLIDER, ADJ_ID_STAR_LABEL, &g_adjustmentSnapshot)' '/w explicit reversion'
Need $window 'g_adjustmentSnapshot = config;' '/w save snapshot update'
Need $window 'g_H = clientHeight - ADJUST_PANEL_HEIGHT;' '/w reserved preview height'
Need $source "if (commandLine[2] != ' ' && commandLine[2] != '\t') return 0;" 'strict /p separator'
Need $source 'static int parsePreviewParent(char* text, HWND* parent)' 'validated preview parent parsing'

foreach ($anchor in @(
    'uniform float uStarDensity;', 'uniform float uSkyFlowSpeed;', 'uniform float uViewportOriginY;',
    'gl_FragCoord.xy-vec2(0.0,uViewportOriginY)',
    'SKY_FLOW_SPEED*clamp(uSkyFlowSpeed,0.5,2.0)',
    'float density=clamp(uStarDensity,0.5,2.0);',
    'if(density==1.0){',
    'field+=cellStars(skyTangent,10.0,0.400,3.0,core*1.18,gatherNeighbors);',
    'field+=cellStars(skyTangent,17.0,0.680,19.0,core*0.92,gatherNeighbors);',
    'field+=cellStars(skyTangent,27.0,0.840,43.0,core*0.72,gatherNeighbors);',
    'field+=cellStars(skyTangent,41.0,0.920,71.0,core*0.58,gatherNeighbors);',
    '#define N_STEPS 48'
)) { Need $shader $anchor 'shader baseline or safe mapping' }
Need-Match $shader '1\.0-min\(\(1\.0-0\.400\)\*density,1\.0\)' 'occupancy scaling rather than threshold scaling'
Need-NotContains $shader 'sampler2D' 'single-pass shader'
foreach ($forbidden in @('fwidth', 'dFdx', 'dFdy')) { Need-NotContains $shader $forbidden 'derivative-free shader' }

if (([regex]::Matches($source, '\bglDrawArrays\s*\(')).Count -ne 1) { Fail 'renderer must retain one glDrawArrays call' }
if (([regex]::Matches($source, '\bSwapBuffers\s*\(')).Count -ne 1) { Fail 'renderer must retain one SwapBuffers call' }
Need $acceptance 'At 100% density and sky speed' 'M7 default visual-baseline acceptance'
Need $acceptance 'one draw per frame' 'M7 one-pass acceptance'
foreach ($anchor in @(
    "'missing-key fallback unexpectedly created a registry key'",
    "unmarked legacy", "schema-v1", "schema-v2", "mixed bad-fields",
    "interrupted-save", "wrong-type schema", "future schema", "'ConfigSchemaVersion'",
    "ADJ_ID_SAVE", "ADJ_ID_REVERT", "unsaved close", "SetWindowPos",
    "Assert-ControlsInsideClient", "'StarDensity'", "'SkyFlowSpeed'",
    "'/p 0'", "'/p123'", "'/w unexpected'", "'/d unexpected'"
)) { Need $runtime $anchor 'M7 runtime coverage' }

& (Join-Path $ProjectRoot 'tools\generate-shader-include.ps1') -ProjectRoot $ProjectRoot -Check
$hash = (Get-FileHash $shaderPath -Algorithm SHA256).Hash
if ($hash -ne $contract.canonicalShader.sourceSha256) { Fail 'canonical shader hash' }

Write-Host 'Milestone 7 configuration and live-adjustment contract verified.'
