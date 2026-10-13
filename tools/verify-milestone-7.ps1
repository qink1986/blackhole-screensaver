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
if ($contract.contract -ne 'blackhole-screensaver-milestone-7' -or [int]$contract.version -ne 2 -or [int]$contract.schema.version -ne 3) {
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
    '#define CONFIG_SCHEMA_VERSION 3u',
    '#define CONFIG_STAR_DENSITY_MIN 50',
    '#define CONFIG_STAR_DENSITY_MAX 200',
    '#define CONFIG_SKY_FLOW_SPEED_MIN 0',
    '#define CONFIG_SKY_FLOW_SPEED_MAX 500',
    '#define SETTINGS_SLIDER_UNITS 1000',
    '#define CONFIG_DEFAULT_STAR_DENSITY 100',
    '#define CONFIG_DEFAULT_SKY_FLOW_SPEED 100',
    '"StarDensity"', '"SkyFlowSpeed"',
    'static ConfigValues makeDefaultConfig(void)',
    'static void loadConfig(void)', 'static int saveConfig(const ConfigValues* config)',
    'static LRESULT CALLBACK SettingsWndProc', '/w', 'SETTINGS_WND_CLASS',
    'SETTINGS_WINDOW_CONFIG', 'SETTINGS_WINDOW_ADJUSTMENT', 'WS_EX_TOOLWINDOW',
    'WM_SIZE', 'createSettingsWindow', 'showAdjustmentSettings'
)) { Need $source $anchor 'host schema or adjustment policy' }

$load = Get-CFunctionBlock $source 'loadConfig'
Need $load 'schemaStatus == CONFIG_REGISTRY_VALUE_MISSING' 'unmarked legacy branch'
Need $load 'schemaVersion == 1u' 'schema v1 branch'
Need $load 'schemaVersion == 2u' 'schema v2 compatibility branch'
Need $load 'schemaVersion == CONFIG_SCHEMA_VERSION' 'schema v3 branch'
Need $load '"StarDensity"' 'schema v3 density read'
Need $load '"SkyFlowSpeed"' 'schema v3 speed read'
Need-NotContains $load 'RegSetValueExA' 'load must not write'
Need-NotContains $load 'RegCreateKeyExA' 'load must not create key'

$save = Get-CFunctionBlock $source 'saveConfig'
Need-Match $save 'ok\s*=\s*writeRegistryDword\(key,\s*REG_VALUE_CONFIG_SCHEMA_VERSION,\s*0\s*\)' 'invalid marker first'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*"StarBrightness"' 'short-circuit first setting write'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*"DiskOpacity"' 'short-circuit second setting write'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*"Doppler"' 'short-circuit third setting write'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*"StarDensity"' 'short-circuit fourth setting write'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*"SkyFlowSpeed"' 'short-circuit fifth setting write'
Need-Match $save 'if\s*\(ok\)\s*ok\s*=\s*writeRegistryDword\(key,\s*REG_VALUE_CONFIG_SCHEMA_VERSION,\s*CONFIG_SCHEMA_VERSION\s*\)' 'schema v3 marker last'

$settingsWindow = Get-CFunctionBlock $source 'SettingsWndProc'
Need $settingsWindow 'if (!saveConfig(&pending))' 'settings save failure stays open'
Need $settingsWindow 'SETTINGS_WINDOW_ADJUSTMENT' 'unified /w settings mode'
Need $settingsWindow 'CFG_ID_CANCEL' 'settings cancel or revert control'
Need $settingsWindow 'PostMessage(owner, WM_CLOSE, 0, 0)' 'palette close owns /w session shutdown'
Need $source 'MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST)' 'owned palette monitor placement'
Need $source 'MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST)' '/c monitor work-area placement'
Need $source 'layoutSettingsControls(hwnd, LOWORD(lp), HIWORD(lp))' 'shared client-relative resize layout'
Need $source 'setSettingsMinimumTrackSize(mode, (MINMAXINFO*)lp)' 'DPI-aware minimum settings-window size'
Need $source 'settingsScale(SETTINGS_CLIENT_WIDTH, dpi)' 'DPI-scaled settings client width'
Need $source 'settingValueFromSlider' 'normalized slider-to-value mapping'
Need $source 'settingSliderPosition' 'normalized value-to-slider mapping'
Need $source 'sprintf(buffer, "%.3f"' 'normalized slider value label'
Need-NotContains $source 'TBS_TOOLTIPS' 'raw implementation-unit slider tooltips'

foreach ($anchor in @(
    'uStarDensity', 'uSkyFlowSpeed',
    'state.starDensity = (float)cfg_starDensity / 100.0f;',
    'state.skyFlowSpeed = (float)cfg_skyFlowSpeed / 100.0f;',
    'glUniform1f(uStarDensity, state->starDensity)',
    'glUniform1f(uSkyFlowSpeed, state->skyFlowSpeed)'
)) { Need $source $anchor 'host-to-shader mapping' }

$window = Get-CFunctionBlock $source 'WndProc'
Need $window 'if (!g_preview && !g_adjustmentMode && shouldExit())' '/w input-exit isolation'
Need $window 'if (g_adjustmentMode && g_adjustmentDirty) applyConfig(&g_adjustmentSnapshot)' 'unsaved /w close reversion'
Need $window 'if (g_settingsWindow && IsWindow(g_settingsWindow)) DestroyWindow(g_settingsWindow)' 'renderer-owned palette teardown'
Need $settingsWindow 'setSettingsControls(hwnd, &g_adjustmentSnapshot)' '/w explicit reversion'
Need $settingsWindow 'g_adjustmentSnapshot = pending;' '/w save snapshot update'
Need $source 'style = WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN;' 'separate OpenGL renderer surface'
Need $source "if (commandLine[2] != ' ' && commandLine[2] != '\t') return 0;" 'strict /p separator'
Need $source 'static int parsePreviewParent(char* text, HWND* parent)' 'validated preview parent parsing'

foreach ($anchor in @(
    'uniform float uStarDensity;', 'uniform float uSkyFlowSpeed;',
    'gl_FragCoord.xy',
    'SKY_FLOW_SPEED*clamp(uSkyFlowSpeed,0.0,5.0)',
    'float density=clamp(uStarDensity,0.5,2.0);',
    'if(density==1.0){',
    'field+=cellStars(skyTangent,10.0,0.400,3.0,core*1.18,gatherNeighbors);',
    'field+=cellStars(skyTangent,17.0,0.680,19.0,core*0.92,gatherNeighbors);',
    'field+=cellStars(skyTangent,27.0,0.840,43.0,core*0.72,gatherNeighbors);',
    'field+=cellStars(skyTangent,41.0,0.920,71.0,core*0.58,gatherNeighbors);',
    '#define N_STEPS 48'
)) { Need $shader $anchor 'shader baseline or safe mapping' }
Need-Match $shader '1\.0-min\(\(1\.0-0\.400\)\*density,1\.0\)' 'occupancy scaling rather than threshold scaling'
Need-NotContains $shader 'uViewportOriginY' 'full-window /w renderer coordinates'
Need-NotContains $shader 'sampler2D' 'single-pass shader'
foreach ($forbidden in @('fwidth', 'dFdx', 'dFdy')) { Need-NotContains $shader $forbidden 'derivative-free shader' }

if (([regex]::Matches($source, '\bglDrawArrays\s*\(')).Count -ne 1) { Fail 'renderer must retain one glDrawArrays call' }
if (([regex]::Matches($source, '\bSwapBuffers\s*\(')).Count -ne 1) { Fail 'renderer must retain one SwapBuffers call' }
Need $acceptance '100% density and sky speed' 'M7 default visual-baseline acceptance'
Need $acceptance 'one draw per frame' 'M7 one-pass acceptance'
foreach ($anchor in @(
    "'missing-key fallback unexpectedly created a registry key'",
    "unmarked legacy", "schema-v1", "schema-v2", "schema-v3", "speed ceiling",
    "interrupted-save", "wrong-type schema", "future schema", "'ConfigSchemaVersion'",
    'SETTINGS_WND_CLASS', 'floating settings window', 'floating-settings close', 'SetWindowPos',
    'Assert-ControlsInsideClient', 'GetWindow($palette, $GW_OWNER)', "'StarDensity'", "'SkyFlowSpeed'",
    "'/p 0'", "'/p123'", "'/w unexpected'", "'/d unexpected'"
)) { Need $runtime $anchor 'M7 runtime coverage' }

& (Join-Path $ProjectRoot 'tools\generate-shader-include.ps1') -ProjectRoot $ProjectRoot -Check
$hash = (Get-FileHash $shaderPath -Algorithm SHA256).Hash
if ($hash -ne $contract.canonicalShader.sourceSha256) { Fail 'canonical shader hash' }

Write-Host 'Milestone 7 configuration and live-adjustment contract verified.'
