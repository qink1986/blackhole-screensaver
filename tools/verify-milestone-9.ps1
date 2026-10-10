[CmdletBinding()]
param([string]$ProjectRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
function Fail([string]$Message) { throw "M9 static contract failure: $Message" }
function Need([string]$Text, [string]$Needle, [string]$Label) {
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -lt 0) { Fail "$Label is missing: $Needle" }
}
function Need-NotContains([string]$Text, [string]$Needle, [string]$Label) {
    if ($Text.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0) { Fail "$Label unexpectedly contains: $Needle" }
}
function Get-CFunctionBlock([string]$Text, [string]$Name) {
    $signature = [regex]::Match($Text, '(?m)^(?:static\s+)?[^\r\n]*\b' + [regex]::Escape($Name) + '\s*\([^\)]*\)\s*\{')
    if (!$signature.Success) { Fail "could not locate C function $Name" }
    $open = $Text.IndexOf('{', $signature.Index); $depth = 0
    for ($index = $open; $index -lt $Text.Length; ++$index) {
        if ($Text[$index] -eq '{') { ++$depth }
        elseif ($Text[$index] -eq '}') { --$depth; if ($depth -eq 0) { return $Text.Substring($signature.Index, $index - $signature.Index + 1) } }
    }
    Fail "could not delimit C function $Name"
}
function Get-HostPhaseTable([string]$Text, [string]$Name) {
    $pattern = 'static const unsigned int\s+' + [regex]::Escape($Name) + '\[M9_SKY_DIRECTION_COUNT\]\s*=\s*\{\s*([^}]*)\s*\};'
    $match = [regex]::Match($Text, $pattern)
    if (!$match.Success) { Fail "could not locate host phase table $Name" }
    $values = @([regex]::Matches($match.Groups[1].Value, '\d+u?') | ForEach-Object { [int]$_.Value.TrimEnd('u') })
    if ($values.Count -ne 8) { Fail "host phase table $Name must have eight values" }
    return $values
}

$contractPath = Join-Path $ProjectRoot 'tests\milestone-9-contract.json'
$sourcePath = Join-Path $ProjectRoot 'blackhole_screensaver.c'
$shaderPath = Join-Path $ProjectRoot 'blackhole_screensaver.glsl'
$acceptancePath = Join-Path $ProjectRoot 'docs\milestone-9-acceptance.txt'
foreach ($path in @($contractPath, $sourcePath, $shaderPath, $acceptancePath)) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { Fail "required artifact is missing: $path" }
}
$contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
if ($contract.contract -ne 'blackhole-screensaver-milestone-9' -or [int]$contract.version -ne 1 -or
    $contract.scope -ne 'host-owned-discrete-schwarzschild-scene-catalog') { Fail 'contract identity' }
if ([int]$contract.sceneLifecycle.durationMilliseconds -ne 45000 -or
    $contract.sceneLifecycle.transition -ne 'hard-cut-at-fixed-boundary' -or
    $contract.sceneLifecycle.statePolicy -ne 'host-owned-active-scene-immutable-within-interval' -or
    $contract.sceneLifecycle.diskTime -ne 'run-relative-continuous') { Fail 'scene lifecycle contract' }
$angles = @($contract.catalog.inclinationsRadians)
if ($angles.Count -ne 5 -or $angles[0] -ne 0.0 -or [math]::Abs([double]$angles[1] - 0.3926991) -gt 0.0000001 -or
    [math]::Abs([double]$angles[2] - 0.7853982) -gt 0.0000001 -or [math]::Abs([double]$angles[3] - 1.1780972) -gt 0.0000001 -or
    [math]::Abs([double]$angles[4] - 1.5707963) -gt 0.0000001) { Fail 'five pole-to-equator inclinations' }
$positions = @($contract.catalog.positions)
if ($positions.Count -ne 9) { Fail 'nine position grid count' }
$requiredPositions = @('0.33,0.33', '0.5,0.33', '0.66,0.33', '0.33,0.5', '0.5,0.5', '0.66,0.5', '0.33,0.66', '0.5,0.66', '0.66,0.66')
$actualPositions = @($positions | ForEach-Object { '{0},{1}' -f ([double]$_[0]), ([double]$_[1]) })
if (@($actualPositions | Sort-Object -Unique).Count -ne 9 -or @($requiredPositions | Where-Object { $_ -notin $actualPositions }).Count -ne 0) { Fail 'exact 33/50/66 position grid' }
$radii = @($contract.catalog.apparentRadii)
if ($radii.Count -ne 3 -or [double]$radii[0] -ne 0.1000 -or [double]$radii[1] -ne 0.1175 -or [double]$radii[2] -ne 0.1350 -or
    [int]$contract.catalog.skyDirectionCount -ne 8 -or [int]$contract.catalog.catalogSize -ne 1080 -or
    $contract.catalog.selection -ne 'random-cyclic-offset-over-discrete-full-catalog' -or
    $contract.catalog.consecutiveScenes -ne 'inclination-position-radius-and-direction-all-differ' -or
    $contract.catalog.cyclePolicy -ne 'every-descriptor-once-per-cycle-and-cycle-boundary-differs') { Fail 'discrete catalogue policy' }
if ($contract.sky.layoutSeed -ne 'deterministic-per-descriptor-and-launch-seed' -or
    $contract.sky.flowDirection -ne 'one-of-eight-unit-compass-directions-per-active-scene' -or
    $contract.sky.userDensityPolicy -ne 'persisted-m7-baseline-clamped-0.5-to-2.0' -or
    $contract.sky.userSpeedPolicy -ne 'persisted-m7-0-to-5-velocity-only') { Fail 'sky catalogue policy' }
if ([int]$contract.configuration.schemaVersion -ne 3 -or [int]$contract.configuration.addedSettings -ne 0 -or @($contract.configuration.preservedSettings).Count -ne 5) { Fail 'configuration preservation contract' }

$source = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
$shader = [IO.File]::ReadAllText($shaderPath, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
$acceptance = [IO.File]::ReadAllText($acceptancePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
foreach ($anchor in @(
    '#define M9_SCENE_DURATION_MS 45000ULL', '#define M9_INCLINATION_COUNT 5u', '#define M9_POSITION_COUNT 9u',
    '#define M9_APPARENT_RADIUS_COUNT 3u', '#define M9_SKY_DIRECTION_COUNT 8u', '#define M9_SCENE_CATALOG_SIZE',
    'static const GLfloat M9_INCLINATIONS[M9_INCLINATION_COUNT]', '0.0000000f, 0.3926991f, 0.7853982f, 1.1780972f, 1.5707963f',
    'static const M9ScenePosition M9_POSITIONS[M9_POSITION_COUNT]', '{ 0.50f, 0.50f }',
    'static const GLfloat M9_APPARENT_RADII[M9_APPARENT_RADIUS_COUNT]', '0.1000f, 0.1175f, 0.1350f',
    'static const M9SkyFlowDirection M9_SKY_FLOW_DIRECTIONS[M9_SKY_DIRECTION_COUNT]',
    'static M9SceneDescriptor sceneDescriptorAt(unsigned int catalogIndex)', 'static GLfloat sceneSkySeed(unsigned int descriptorIndex)',
    'g_sceneCatalogIndex = nextSceneRandomValue() % M9_SCENE_CATALOG_SIZE;', 'typedef struct ActiveScene',
    'static void beginScene(ULONGLONG startTick)', 'static void advanceSceneTo(ULONGLONG now)',
    'g_sceneCatalogIndex = (g_sceneCatalogIndex + 1u) % M9_SCENE_CATALOG_SIZE;',
    'state.starDensity = (float)cfg_starDensity / 100.0f;', 'state.scene = g_activeScene.scene;',
    'if (uSkyFlowDirection >= 0) glUniform2f(uSkyFlowDirection, state->skyFlowDirectionX, state->skyFlowDirectionY);'
)) { Need $source $anchor 'host M9 scene policy' }
Need-NotContains $source 'M8_OFF_CENTER_POSITION_SLOT_COUNT' 'superseded M8 placement policy'
Need-NotContains $source 'starDensityMultiplier' 'removed per-scene density multiplier'
$beginScene = Get-CFunctionBlock $source 'beginScene'
foreach ($anchor in @('M9SceneDescriptor descriptor = sceneDescriptorAt(g_sceneCatalogIndex);', 'M9_POSITIONS[descriptor.positionIndex]',
    'M9_SKY_FLOW_DIRECTIONS[descriptor.skyDirectionIndex]', 'M9_APPARENT_RADII[descriptor.apparentRadiusIndex]',
    'M9_INCLINATIONS[descriptor.inclinationIndex]', 'g_activeScene.skySeed = sceneSkySeed(g_sceneCatalogIndex);',
    'g_activeScene.startTick = startTick;', 'g_activeScene.endTick = startTick + M9_SCENE_DURATION_MS;')) { Need $beginScene $anchor 'atomic discrete scene commit' }
Need-NotContains $beginScene 'nextSceneRandomValue' 'no per-boundary random scene sampling'
$advanceScene = Get-CFunctionBlock $source 'advanceSceneTo'
Need $advanceScene 'while (now >= g_activeScene.endTick) beginScene(g_activeScene.endTick);' 'delayed-frame boundary advance'
$stateBuilder = Get-CFunctionBlock $source 'makeSceneState'
Need $stateBuilder 'advanceSceneTo(now);' 'stable active scene selection'
Need-NotContains $stateBuilder 'sceneRandom' 'no per-frame random sampling'
foreach ($anchor in @('uniform vec2 uSkyFlowDirection;', 'vec2 skyFlowDirection=normalize(uSkyFlowDirection);', 'float density=clamp(uStarDensity,0.5,2.0);', '#define N_STEPS 48')) { Need $shader $anchor 'shader retained mapping' }
foreach ($token in @($contract.retained.forbiddenTokens)) { Need-NotContains $shader ([string]$token) 'shader forbidden path' }
foreach ($token in @('glTex', 'glGenFramebuffers', 'glBindFramebuffer', 'DesktopSnapshot', 'captureDesktop', 'BitBlt')) { Need-NotContains $source $token 'host forbidden path' }
if (([regex]::Matches($source, '\bglDrawArrays\s*\(')).Count -ne [int]$contract.retained.drawCallCount) { Fail 'draw call count' }
Need $source ([string]$contract.retained.drawCall) 'fullscreen draw form'
foreach ($needle in @('five polar angles', 'nine exact screen centers', 'Every adjacent pair', 'one 45-second interval', 'no scene-catalogue controls')) { Need $acceptance $needle 'M9 acceptance policy' }

# Execute the exact phase tables parsed from the host implementation. This
# proves the real finite cycle has every Cartesian descriptor exactly once and
# no adjacent repeat in any requested dimension.
$inclinationPhases = Get-HostPhaseTable $source 'M9_INCLINATION_PHASE_BY_DIRECTION'
$positionPhases = Get-HostPhaseTable $source 'M9_POSITION_PHASE_BY_DIRECTION'
$radiusPhases = Get-HostPhaseTable $source 'M9_RADIUS_PHASE_BY_DIRECTION'
$descriptorFunction = Get-CFunctionBlock $source 'sceneDescriptorAt'
foreach ($anchor in @(
    'directionCycle = catalogIndex % M9_SKY_DIRECTION_COUNT;',
    'radiusCycle = catalogIndex % M9_APPARENT_RADIUS_COUNT;',
    'positionCycle = catalogIndex % M9_POSITION_COUNT;',
    'inclinationCycle = catalogIndex / M9_POSITION_COUNT;',
    'descriptor.inclinationIndex = (inclinationCycle + M9_INCLINATION_PHASE_BY_DIRECTION[directionCycle]) % M9_INCLINATION_COUNT;',
    'descriptor.positionIndex = (positionCycle + M9_POSITION_PHASE_BY_DIRECTION[directionCycle]) % M9_POSITION_COUNT;',
    'descriptor.apparentRadiusIndex = (radiusCycle + M9_RADIUS_PHASE_BY_DIRECTION[directionCycle]) % M9_APPARENT_RADIUS_COUNT;',
    'descriptor.skyDirectionIndex = directionCycle;'
)) { Need $descriptorFunction $anchor 'host catalogue enumeration' }
$seen = @{}
for ($index = 0; $index -lt 1080; ++$index) {
    $value = $index; $direction = $value % 8; $value = [math]::Floor($value / 8)
    $radius = $value % 3; $value = [math]::Floor($value / 3)
    $position = $value % 9; $inclination = [math]::Floor($value / 9)
    $descriptor = '{0},{1},{2},{3}' -f (($inclination + $inclinationPhases[$direction]) % 5), (($position + $positionPhases[$direction]) % 9), (($radius + $radiusPhases[$direction]) % 3), $direction
    if ($seen.ContainsKey($descriptor)) { Fail "duplicate descriptor in M9 cycle at index $index" }
    $seen[$descriptor] = $index
    if ($index -gt 0) {
        $previous = $seen.GetEnumerator() | Where-Object { $_.Value -eq ($index - 1) } | Select-Object -First 1
        $parts = $descriptor.Split(','); $priorParts = $previous.Key.Split(',')
        for ($dimension = 0; $dimension -lt 4; ++$dimension) { if ($parts[$dimension] -eq $priorParts[$dimension]) { Fail "M9 adjacent catalogue scenes repeat dimension $dimension at index $index" } }
    }
}
if ($seen.Count -ne 1080) { Fail 'incomplete M9 catalogue coverage' }
$firstDescriptor = $null; $lastDescriptor = $null
foreach ($entry in $seen.GetEnumerator()) {
    if ($entry.Value -eq 0) { $firstDescriptor = $entry.Key.Split(',') }
    if ($entry.Value -eq 1079) { $lastDescriptor = $entry.Key.Split(',') }
}
for ($dimension = 0; $dimension -lt 4; ++$dimension) {
    if ($firstDescriptor[$dimension] -eq $lastDescriptor[$dimension]) { Fail "M9 cycle boundary repeats dimension $dimension" }
}
& (Join-Path $ProjectRoot 'tools\generate-shader-include.ps1') -ProjectRoot $ProjectRoot -Check
$hash = (Get-FileHash -LiteralPath $shaderPath -Algorithm SHA256).Hash
if ($hash -ne $contract.canonicalShader.sourceSha256) { Fail "canonical shader hash expected $($contract.canonicalShader.sourceSha256), got $hash" }
Write-Host 'Milestone 9 discrete scene catalogue contract verified.'
