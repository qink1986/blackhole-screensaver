[CmdletBinding()]
param([string]$ProjectRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }

function Fail([string]$Message) { throw "M8 static contract failure: $Message" }
function Need([string]$Text, [string]$Needle, [string]$Label) {
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -lt 0) { Fail "$Label is missing: $Needle" }
}
function Need-NotContains([string]$Text, [string]$Needle, [string]$Label) {
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0) { Fail "$Label unexpectedly contains: $Needle" }
}
function Need-Match([string]$Text, [string]$Pattern, [string]$Label) {
    if (-not [regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) { Fail "$Label does not match: $Pattern" }
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

$contractPath = Join-Path $ProjectRoot 'tests\milestone-8-contract.json'
$sourcePath = Join-Path $ProjectRoot 'blackhole_screensaver.c'
$shaderPath = Join-Path $ProjectRoot 'blackhole_screensaver.glsl'
$acceptancePath = Join-Path $ProjectRoot 'docs\milestone-8-acceptance.txt'
foreach ($path in @($contractPath, $sourcePath, $shaderPath, $acceptancePath)) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { Fail "required artifact is missing: $path" }
}

$contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
if ($contract.contract -ne 'blackhole-screensaver-milestone-8' -or [int]$contract.version -ne 1) { Fail 'contract identity' }
if ($contract.scope -ne 'bounded-randomized-schwarzschild-scenes-with-off-center-north-hemisphere-views') { Fail 'contract scope' }
if ([int]$contract.sceneLifecycle.durationMilliseconds -ne 45000 -or
    $contract.sceneLifecycle.transition -ne 'hard-cut-at-fixed-boundary' -or
    $contract.sceneLifecycle.statePolicy -ne 'host-owned-active-scene-immutable-within-interval' -or
    $contract.sceneLifecycle.diskTime -ne 'run-relative-continuous') { Fail 'scene lifecycle contract' }
if ([double]$contract.sceneRange.apparentRadius[0] -ne 0.100 -or
    [double]$contract.sceneRange.apparentRadius[1] -ne 0.135 -or
    [double]$contract.sceneRange.inclination[0] -ne 0.050 -or
    [double]$contract.sceneRange.inclination[1] -ne 1.480 -or
    [double]$contract.sceneRange.roll[0] -ne 0.00 -or
    [double]$contract.sceneRange.roll[1] -ne 0.78 -or
    $contract.sceneRange.hemisphere -ne 'north-only-no-flip' -or
    [math]::Abs([double]$contract.sceneRange.equatorialLimitRadians - 1.5707963) -gt 0.0000001 -or
    [double]$contract.sceneRange.inclination[1] -ge [double]$contract.sceneRange.equatorialLimitRadians) { Fail 'north-hemisphere scene-range contract' }
if (@($contract.positionSlots).Count -ne 4 -or
    [double]$contract.positionSlots[0].centerX[0] -ne 0.30 -or [double]$contract.positionSlots[0].centerX[1] -ne 0.42 -or
    [double]$contract.positionSlots[0].centerY[0] -ne 0.33 -or [double]$contract.positionSlots[0].centerY[1] -ne 0.47 -or
    [double]$contract.positionSlots[1].centerX[0] -ne 0.58 -or [double]$contract.positionSlots[1].centerX[1] -ne 0.70 -or
    [double]$contract.positionSlots[1].centerY[0] -ne 0.33 -or [double]$contract.positionSlots[1].centerY[1] -ne 0.47 -or
    [double]$contract.positionSlots[2].centerX[0] -ne 0.30 -or [double]$contract.positionSlots[2].centerX[1] -ne 0.42 -or
    [double]$contract.positionSlots[2].centerY[0] -ne 0.53 -or [double]$contract.positionSlots[2].centerY[1] -ne 0.67 -or
    [double]$contract.positionSlots[3].centerX[0] -ne 0.58 -or [double]$contract.positionSlots[3].centerX[1] -ne 0.70 -or
    [double]$contract.positionSlots[3].centerY[0] -ne 0.53 -or [double]$contract.positionSlots[3].centerY[1] -ne 0.67 -or
    [double]$contract.screenCenterForbidden[0] -ne 0.50 -or [double]$contract.screenCenterForbidden[1] -ne 0.50) { Fail 'off-center position-slot contract' }
if ([double]$contract.baselineScene.temperature -ne 5500.0 -or
    [double]$contract.baselineScene.innerRadius -ne 1.80 -or
    [double]$contract.baselineScene.outerRadius -ne 8.00 -or
    [double]$contract.baselineScene.baselineOpacity -ne 0.90 -or
    [double]$contract.baselineScene.baselineDoppler -ne 0.60 -or
    [double]$contract.baselineScene.beam -ne 2.50 -or
    [double]$contract.baselineScene.gain -ne 2.20 -or
    [double]$contract.baselineScene.contrast -ne 1.60 -or
    [double]$contract.baselineScene.wind -ne 7.00 -or
    [double]$contract.baselineScene.materialSpeed -ne 5.00 -or
    [double]$contract.baselineScene.exposure -ne 1.40) { Fail 'fixed baseline scene contract' }
if ([int]$contract.configuration.schemaVersion -ne 3 -or [int]$contract.configuration.addedSettings -ne 0 -or @($contract.configuration.preservedSettings).Count -ne 5 -or $contract.configuration.settingsWindow -ne 'BlackHoleSettings') { Fail 'configuration preservation contract' }

$source = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
$shader = [IO.File]::ReadAllText($shaderPath, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
$acceptance = [IO.File]::ReadAllText($acceptancePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")

foreach ($anchor in @(
    '#define M8_SCENE_DURATION_MS 45000ULL',
    '#define M8_OFF_CENTER_POSITION_SLOT_COUNT 4u',
    'typedef struct ActiveScene', 'static ActiveScene g_activeScene;',
    'static const M8SceneRange M8_NORTH_HEMISPHERE_RANGE',
    '0.100f, 0.135f, 0.050f, 1.480f, 0.00f, 0.78f',
    'static const M8ScenePositionRange M8_OFF_CENTER_POSITION_SLOTS',
    '{ 0.30f, 0.42f, 0.33f, 0.47f }',
    '{ 0.58f, 0.70f, 0.33f, 0.47f }',
    '{ 0.30f, 0.42f, 0.53f, 0.67f }',
    '{ 0.58f, 0.70f, 0.53f, 0.67f }',
    '0.50f, 0.50f, 0.120f,',
    '5500.0f, 1.50f, 0.35f, 1.80f, 8.00f,',
    '0.90f, 0.60f, 2.50f, 2.20f, 1.60f, 7.00f, 5.00f, 1.40f',
    'static void beginScene(ULONGLONG startTick)',
    'static void advanceSceneTo(ULONGLONG now)',
    'g_activeScene.starDensityMultiplier = sceneRandomRange(0.85f, 1.15f);',
    'uSkyFlowDirection = glGetUniformLocation(shaderProgram, "uSkyFlowDirection");',
    'if (uSkyFlowDirection >= 0) glUniform2f(uSkyFlowDirection, state->skyFlowDirectionX, state->skyFlowDirectionY);',
    'state.starDensity = (float)cfg_starDensity / 100.0f;',
    'state.starDensity *= g_activeScene.starDensityMultiplier;',
    'g_sceneRandomState = makeSceneRandomState();', 'beginScene(g_tick0);'
)) { Need $source $anchor 'host M8 scene policy' }

$beginScene = Get-CFunctionBlock $source 'beginScene'
Need $beginScene 'positionIndex = nextSceneRandomValue() % M8_OFF_CENTER_POSITION_SLOT_COUNT;' 'random bounded off-center placement selection'
Need $beginScene 'g_activeScene.scene.apparentRadius = sceneRandomRange(range->apparentRadiusMinimum, range->apparentRadiusMaximum);' 'random bounded apparent radius'
Need $beginScene 'g_activeScene.scene.inclination = sceneRandomRange(range->inclinationMinimum, range->inclinationMaximum);' 'random north-hemisphere inclination'
Need $beginScene 'g_activeScene.startTick = startTick;' 'scene fixed start tick'
Need $beginScene 'g_activeScene.endTick = startTick + M8_SCENE_DURATION_MS;' 'scene fixed end tick'
Need $beginScene 'g_activeScene.skyFlowDirectionX = cosf(skyFlowAngle);' 'scene unit flow X'
Need $beginScene 'g_activeScene.skyFlowDirectionY = sinf(skyFlowAngle);' 'scene unit flow Y'
$advanceScene = Get-CFunctionBlock $source 'advanceSceneTo'
Need $advanceScene 'while (now >= g_activeScene.endTick) beginScene(g_activeScene.endTick);' 'delayed-frame boundary advance'
$stateBuilder = Get-CFunctionBlock $source 'makeSceneState'
Need $stateBuilder 'advanceSceneTo(now);' 'state selects stable active scene'
Need $stateBuilder 'state.scene = g_activeScene.scene;' 'scene snapshot copy'
Need $stateBuilder 'state.skySeed = g_activeScene.skySeed;' 'sky seed snapshot copy'
Need $stateBuilder 'state.skyFlowDirectionX = g_activeScene.skyFlowDirectionX;' 'sky flow X snapshot copy'
Need $stateBuilder 'state.skyFlowDirectionY = g_activeScene.skyFlowDirectionY;' 'sky flow Y snapshot copy'
Need-NotContains $stateBuilder 'sceneRandom' 'no per-frame random sampling'

$loadConfig = Get-CFunctionBlock $source 'loadConfig'
foreach ($anchor in @(
    'schemaStatus == CONFIG_REGISTRY_VALUE_MISSING', 'schemaVersion == 1u',
    'schemaVersion == 2u', 'schemaVersion == CONFIG_SCHEMA_VERSION',
    '"StarDensity"', '"SkyFlowSpeed"'
)) { Need $loadConfig $anchor 'M7 schema-v3 loading compatibility' }
Need-NotContains $loadConfig 'RegSetValueExA' 'configuration loading must not persist'
$saveConfig = Get-CFunctionBlock $source 'saveConfig'
foreach ($anchor in @(
    'writeRegistryDword(key, REG_VALUE_CONFIG_SCHEMA_VERSION, 0)',
    'writeRegistryDword(key, "StarBrightness"',
    'writeRegistryDword(key, "DiskOpacity"',
    'writeRegistryDword(key, "Doppler"',
    'writeRegistryDword(key, "StarDensity"',
    'writeRegistryDword(key, "SkyFlowSpeed"',
    'writeRegistryDword(key, REG_VALUE_CONFIG_SCHEMA_VERSION, CONFIG_SCHEMA_VERSION)'
)) { Need $saveConfig $anchor 'M7 save ordering compatibility' }
foreach ($anchor in @(
    '#define CONFIG_SCHEMA_VERSION 3u', '#define CONFIG_STAR_DENSITY_MIN 50',
    '#define CONFIG_STAR_DENSITY_MAX 200', '#define CONFIG_SKY_FLOW_SPEED_MIN 0',
    '#define CONFIG_SKY_FLOW_SPEED_MAX 500', '#define SETTINGS_SLIDER_UNITS 1000',
    'static LRESULT CALLBACK SettingsWndProc', 'SETTINGS_WINDOW_CONFIG',
    'SETTINGS_WINDOW_ADJUSTMENT', 'WS_EX_TOOLWINDOW', 'showAdjustmentSettings',
    'sprintf(buffer, "%.3f"'
)) { Need $source $anchor 'M7 settings implementation compatibility' }
Need-NotContains $source 'TBS_TOOLTIPS' 'raw slider tooltip remains disabled'

foreach ($setting in @($contract.configuration.preservedSettings)) {
    Need $source ('"' + $setting.registry + '"') ('retained M7 registry setting ' + $setting.registry)
}

foreach ($anchor in @(
    'uniform vec2 uSkyFlowDirection;',
    'vec2 skyFlowDirection=normalize(uSkyFlowDirection);',
    'SKY_FLOW_SPEED*clamp(uSkyFlowSpeed,0.0,5.0)',
    'float density=clamp(uStarDensity,0.5,2.0);',
    '#define N_STEPS 48'
)) { Need $shader $anchor 'shader M8 mapping or retained policy' }
foreach ($token in @($contract.retained.forbiddenTokens)) { Need-NotContains $shader ([string]$token) 'shader forbidden path' }
foreach ($token in @('glTex', 'glGenFramebuffers', 'glBindFramebuffer', 'DesktopSnapshot', 'captureDesktop', 'BitBlt')) { Need-NotContains $source $token 'host forbidden path' }
if (([regex]::Matches($source, '\bglDrawArrays\s*\(')).Count -ne [int]$contract.retained.drawCallCount) { Fail 'draw call count' }
Need $source ([string]$contract.retained.drawCall) 'fullscreen draw form'
Need $acceptance 'north-pole / face-on view' 'documented north-pole policy'
Need $acceptance 'never in the screen center' 'documented off-center placement policy'
Need $acceptance 'without crossing the' 'documented no-flip inclination policy'
Need $acceptance 'one `glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)`' 'documented one-draw policy'
Need $acceptance 'No registry schema, persistence field, or settings control is' 'documented M7 settings preservation'

& (Join-Path $ProjectRoot 'tools\generate-shader-include.ps1') -ProjectRoot $ProjectRoot -Check
$hash = (Get-FileHash -LiteralPath $shaderPath -Algorithm SHA256).Hash
if ($hash -ne $contract.canonicalShader.sourceSha256) { Fail "canonical shader hash expected $($contract.canonicalShader.sourceSha256), got $hash" }

Write-Host 'Milestone 8 bounded scene contract verified.'
