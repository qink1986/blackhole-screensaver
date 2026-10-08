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
    throw "Milestone 6 contract failure: $Message"
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

function Get-CFunctionBlock([string]$Text, [string]$Name) {
    $signature = [regex]::Match($Text, '(?m)^(?:static\s+)?[^\r\n]*\b' + [regex]::Escape($Name) + '\s*\([^\)]*\)\s*\{', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $signature.Success) {
        Fail "Could not find C function $Name"
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
    Fail "Could not delimit C function $Name"
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

$contractPath = Join-Path $ProjectRoot 'tests\milestone-6-contract.json'
Require-File $contractPath 'Contract JSON'
try {
    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
}
catch {
    Fail "Contract JSON is invalid: $($_.Exception.Message)"
}
if ($contract.contract -ne 'blackhole-screensaver-milestone-6' -or [int]$contract.version -ne 4) {
    Fail 'Unexpected contract identity or version'
}
if ($contract.scope -ne 'named-static-schwarzschild-scene-with-impact-arcs-and-slim-disk') {
    Fail 'Unexpected contract scope'
}
if ($contract.relativeMotion.bodyComposition -ne 'fixed' -or
    $contract.relativeMotion.backgroundMapping -ne 'seeded-random-world-direction-translation' -or
    [math]::Abs([double]$contract.relativeMotion.backgroundSkyFlowSpeed - 0.075) -gt 0.000001 -or
    [math]::Abs([double]$contract.relativeMotion.flowDistancePerPhase - 0.2247) -gt 0.000001 -or
    $contract.relativeMotion.directionSeed -ne 'uSkySeed' -or
    $contract.relativeMotion.directionLifetime -ne 'one-direction-per-screensaver-launch') {
    Fail 'Unexpected M6 relative-motion policy'
}
if ([int]$contract.frameScheduling.submissionIntervalMs -ne 10 -or
    -not [bool]$contract.frameScheduling.oneFrameFence -or
    [int]$contract.frameScheduling.cooldownDivisor -ne 4 -or
    $contract.frameScheduling.policy -ne 'fractional-rest-after-fence') {
    Fail 'Unexpected M6 frame-scheduling policy'
}
if ($contract.lensStarSeamGather.scope -ne 'lensed-path-catalogue-seams-only' -or
    [double]$contract.lensStarSeamGather.directSkyGather -ne 0.0 -or
    $contract.lensStarSeamGather.cellGather -ne '3x3-near-cell-edge' -or
    [math]::Abs([double]$contract.lensStarSeamGather.edgeReachInMaxSpriteTails - 2.30) -gt 0.000001 -or
    $contract.lensStarSeamGather.starAppearance -ne 'unchanged') {
    Fail 'Unexpected M6 lens-star-seam-gather policy'
}
if ($contract.lensExitContinuity.nonCapturedSkyFallback -ne 'direct-sky' -or
    $contract.lensExitContinuity.sourceProjection -ne 'bounded-negative-exit-z' -or
    [math]::Abs([double]$contract.lensExitContinuity.minimumExitZ + 0.0200) -gt 0.000001 -or
    $contract.lensExitContinuity.projectionWeightRange.Count -ne 2 -or
    [math]::Abs([double]$contract.lensExitContinuity.projectionWeightRange[0] + 0.0200) -gt 0.000001 -or
    [math]::Abs([double]$contract.lensExitContinuity.projectionWeightRange[1] + 0.0050) -gt 0.000001) {
    Fail 'Unexpected M6 lensed-exit continuity policy'
}
if ($contract.innerDiskCavity.model -ne 'non-emissive-smooth-plunging-occluder' -or
    $contract.innerDiskCavity.radiusPolicy -ne 'below-rin' -or
    $contract.innerDiskCavity.transmissionRangeInRin.Count -ne 2 -or
    [math]::Abs([double]$contract.innerDiskCavity.transmissionRangeInRin[0] - 0.82) -gt 0.000001 -or
    [math]::Abs([double]$contract.innerDiskCavity.transmissionRangeInRin[1] - 0.98) -gt 0.000001 -or
    $contract.innerDiskCavity.emission -ne 'none') {
    Fail 'Unexpected M6 inner-disk cavity policy'
}
if ($contract.innerFlowSkyOccluder.model -ne 'smooth-ray-space-background-occluder' -or
    $contract.innerFlowSkyOccluder.radiusRangeInBCrit.Count -ne 2 -or
    [math]::Abs([double]$contract.innerFlowSkyOccluder.radiusRangeInBCrit[0] - 1.42) -gt 0.000001 -or
    [math]::Abs([double]$contract.innerFlowSkyOccluder.radiusRangeInBCrit[1] - 1.72) -gt 0.000001 -or
    $contract.innerFlowSkyOccluder.scope -ne 'sky-only' -or
    $contract.innerFlowSkyOccluder.diskEmission -ne 'preserved') {
    Fail 'Unexpected M6 inner-flow sky-occluder policy'
}
if ($contract.impactArcMaterial.model -ne 'three-staggered-deterministic-disk-space-impact-arcs' -or
    $contract.impactArcMaterial.materialSeed -ne 'uSceneSeed' -or
    $contract.impactArcMaterial.descriptorState -ne 'reconstructed-from-time-and-seed' -or
    [int]$contract.impactArcMaterial.candidateCount -ne 3 -or
    [math]::Abs([double]$contract.impactArcMaterial.slotSeconds - 11.0) -gt 0.000001 -or
    $contract.impactArcMaterial.lifetimeSeconds.Count -ne 2 -or
    [math]::Abs([double]$contract.impactArcMaterial.lifetimeSeconds[0] - 18.0) -gt 0.000001 -or
    [math]::Abs([double]$contract.impactArcMaterial.lifetimeSeconds[1] - 22.0) -gt 0.000001 -or
    $contract.impactArcMaterial.inflow -ne 'exponential-inward' -or
    [math]::Abs([double]$contract.impactArcMaterial.inflowRate - 0.0100) -gt 0.000001 -or
    $contract.impactArcMaterial.differentialShear -ne 'birth-radius-dependent-kepler-like-phase' -or
    $contract.impactArcMaterial.birthRadialRange.Count -ne 2 -or
    [math]::Abs([double]$contract.impactArcMaterial.birthRadialRange[0] - 0.34) -gt 0.000001 -or
    [math]::Abs([double]$contract.impactArcMaterial.birthRadialRange[1] - 0.82) -gt 0.000001 -or
    $contract.impactArcMaterial.birthAngularHalfTurnsRange.Count -ne 2 -or
    [math]::Abs([double]$contract.impactArcMaterial.birthAngularHalfTurnsRange[0] - 0.010) -gt 0.000001 -or
    [math]::Abs([double]$contract.impactArcMaterial.birthAngularHalfTurnsRange[1] - 0.020) -gt 0.000001 -or
    $contract.impactArcMaterial.globalMacroReplay -ne 'forbidden' -or
    $contract.impactArcMaterial.baseDisk -ne 'continuous-wrapped-filaments' -or
    $contract.impactArcMaterial.rendering -ne 'bounded-density-modulation-at-slim-disk-entry') {
    Fail 'Unexpected deterministic impact-arc material policy'
}
if ($contract.slimDiskGeometry.model -ne 'analytic-finite-constant-thickness-disk-body' -or
    [math]::Abs([double]$contract.slimDiskGeometry.halfThickness - 0.0350) -gt 0.000001 -or
    $contract.slimDiskGeometry.boundary -ne 'two-height-faces-and-outer-rim' -or
    $contract.slimDiskGeometry.intersection -ne 'bounded-analytic-chord-query' -or
    $contract.slimDiskGeometry.entryPolicy -ne 'once-per-outside-to-inside-contiguous-visit' -or
    $contract.slimDiskGeometry.contactCoordinate -ne 'normal-projected-disk-space' -or
    $contract.slimDiskGeometry.innerCavity -ne 'non-emissive-entry-occluder' -or
    [bool]$contract.slimDiskGeometry.volumeRayMarching -or
    [int]$contract.slimDiskGeometry.additionalPasses -ne 0 -or
    $contract.slimDiskGeometry.geodesicStepBudget -ne 'unchanged-48-step-loop') {
    Fail 'Unexpected analytic slim-disk geometry policy'
}
$sourcePath = Join-Path $ProjectRoot ([string]$contract.host.path)
$shaderPath = Join-Path $ProjectRoot ([string]$contract.canonicalShader.path)
$includePath = Join-Path $ProjectRoot ([string]$contract.canonicalShader.generatedInclude)
$generatorPath = Join-Path $ProjectRoot ([string]$contract.canonicalShader.generator)
$buildPath = Join-Path $ProjectRoot ([string]$contract.build.script)
$runtimeProbePath = Join-Path $ProjectRoot 'tools\verify-milestone-4-runtime.ps1'
$sceneRuntimeProbePath = Join-Path $ProjectRoot 'tools\verify-milestone-6-runtime.ps1'
$acceptancePath = Join-Path $ProjectRoot 'docs\milestone-6-acceptance.txt'
Require-File $sourcePath 'Authoritative host source'
Require-File $shaderPath 'Canonical GLSL source'
Require-File $includePath 'Generated shader include'
Require-File $generatorPath 'Shader include generator'
Require-File $buildPath 'Build script'
Require-File $runtimeProbePath 'Runtime configuration probe'
Require-File $sceneRuntimeProbePath 'OpenGL shader compile/link smoke probe'
Require-File $acceptancePath 'M6 manual acceptance guide'
$sceneRuntimeProbe = [System.IO.File]::ReadAllText($sceneRuntimeProbePath, [System.Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
Require-Contains $sceneRuntimeProbe "BLACKHOLE_SHADER_SMOKE_EVENT" 'Explicit post-initialization shader smoke signal'
Require-Contains $sceneRuntimeProbe 'WaitForSingleObject' 'Signaled shader smoke event wait'
Require-Contains $sceneRuntimeProbe '$passed = $true' 'Event-gated shader smoke acceptance'
Require-NotContains $sceneRuntimeProbe 'Start-Sleep -Milliseconds 1250' 'Liveness-only shader smoke acceptance'
$acceptance = [System.IO.File]::ReadAllText($acceptancePath, [System.Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
Require-Contains $acceptance 'M6 requires visible relative motion:' 'M6 relative-motion acceptance rule'
Require-Contains $acceptance 'SKY_FLOW_SPEED = 0.0750' 'M6 reviewed background-flow speed'
Require-Contains $acceptance 'random direction once per screensaver launch' 'M6 seeded sky-direction rule'
Require-Contains $acceptance 'must not rotate around the' 'M6 non-orbital background rule'
Require-Contains $acceptance 'reversed secondary image may move locally opposite' 'M6 lensed parity-motion allowance'
Require-Contains $acceptance 'direct-sky stars or clusters translate' 'M6 manual translational-motion check'
Require-Contains $acceptance 'gather adjacent procedural' 'M6 lensed-star seam-gather scope'
Require-Contains $acceptance 'entry/exit flash' 'M6 lensed-star seam-flicker rule'
Require-Contains $acceptance 'apparent size and must not disappear' 'M6 unchanged-star visual criterion'
Require-Contains $acceptance 'three candidate analytic impact arcs' 'M6 bounded impact-arc count'
Require-Contains $acceptance 'no 36-second global macro replay' 'M6 no global material replay'
Require-Contains $acceptance 'visibly radius-dependent shear' 'M6 impact-arc shear acceptance'
Require-Contains $acceptance 'drift inward, and fade independently' 'M6 impact-arc lifecycle acceptance'
Require-Contains $acceptance 'finite analytic body with a constant half-thickness' 'M6 slim-disk geometry'
Require-Contains $acceptance 'does not subdivide or consume the fixed 48-step geodesic budget' 'M6 slim-disk fixed-step preservation'
Require-Contains $acceptance 'exit does not double emission or opacity' 'M6 slim-disk entry-only integration'
Require-Contains $acceptance 'slight stable vertical rim/upper-lower extent' 'M6 slim-disk visual acceptance'

$source = [System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
$shaderBytes = [System.IO.File]::ReadAllBytes($shaderPath)
if ($shaderBytes.Length -lt 1) {
    Fail 'Canonical GLSL source is empty'
}
if ($shaderBytes.Length -ge 3 -and $shaderBytes[0] -eq 0xef -and $shaderBytes[1] -eq 0xbb -and $shaderBytes[2] -eq 0xbf) {
    Fail 'Canonical GLSL source must not contain a UTF-8 BOM'
}
foreach ($byte in $shaderBytes) {
    if ($byte -eq 13 -or $byte -eq 0 -or $byte -gt 127) {
        Fail 'Canonical GLSL must be ASCII, LF-only, and NUL-free'
    }
}
$shaderHash = [System.BitConverter]::ToString(([System.Security.Cryptography.SHA256]::Create().ComputeHash($shaderBytes))).Replace('-', '')
if ($shaderHash -ne ([string]$contract.canonicalShader.sourceSha256).ToUpperInvariant()) {
    Fail 'Canonical GLSL source does not match its reviewed SHA-256'
}
$shaderText = [System.Text.Encoding]::UTF8.GetString($shaderBytes)
Require-Contains $shaderText '#define N_STEPS 48' '48-step Schwarzschild baseline'
Require-Contains $shaderText 'uniform vec2 uSceneCenter;' 'Host-owned static scene center'
Require-Contains $shaderText 'uniform float uApparentRadius;' 'Host-owned static apparent radius'
Require-Contains $shaderText 'uniform vec4 uDiskLookA;' 'Host-owned static disk look'
Require-Contains $shaderText 'DiskLook L=DiskLook(' 'Static scene disk look consumption'
Require-Contains $shaderText 'float rh=uApparentRadius;' 'Static apparent radius consumption'
Require-Contains $shaderText 'vec2 center=uSceneCenter;' 'Static center consumption'
Require-Contains $shaderText 'const float DISK_HALF_THICKNESS = 0.0350;' 'Slim-disk constant half-thickness'
Require-Contains $shaderText 'float diskBodyField(vec3 point,vec3 normal,float rout){' 'Finite slim-disk body helper'
Require-Contains $shaderText 'return max(abs(height)-DISK_HALF_THICKNESS,rc-rout);' 'Slim-disk height-face and outer-rim boundary'
Require-Contains $shaderText 'float diskEntryCandidate(' 'Slim-disk candidate-entry classifier'
Require-Contains $shaderText 'float diskBodyEntry(vec3 x0,vec3 x1,vec3 normal,float rout){' 'Slim-disk analytic chord query'
Require-Contains $shaderText '(DISK_HALF_THICKNESS-s0)/ds' 'Slim-disk upper-face intersection'
Require-Contains $shaderText '(-DISK_HALF_THICKNESS-s0)/ds' 'Slim-disk lower-face intersection'
Require-Contains $shaderText 'float discriminant=qb*qb-4.0*qa*qc;' 'Slim-disk outer-rim quadratic'
Require-Contains $shaderText 'float diskEntry=diskBodyEntry(xPrev,x,n,rout);' 'Slim-disk chord intersection call'
Require-Contains $shaderText 'if(diskEntry<=1.0&&trans>0.02)' 'Slim-disk outside-to-inside integration'
Require-Contains $shaderText 'float diskHeight=dot(xc,n);vec3 diskPoint=xc-n*diskHeight;' 'Slim-disk normal-projected contact coordinate'
Require-Contains $shaderText 'float phi=atan(dot(diskPoint,e2),diskPoint.x)' 'Slim-disk projected azimuth'
Require-Contains $shaderText 'vec3 gasdir=normalize(cross(n,diskPoint))*sdir;' 'Slim-disk projected orbital direction'
Require-Contains $shaderText 'xPrev=x;' 'Slim-disk contiguous-chord tracking'
Require-NotContains $shaderText 'dt=min(dt,1.10*min(tHeight,tRim));' 'Rejected boundary substepping'
Require-NotContains $shaderText 's*sPrev<0.0' 'Rejected infinitesimal disk-plane crossing'
Require-Contains $shaderText 'const float IMPACT_ARC_SLOT_SECONDS = 11.0000;' 'Impact-arc stagger interval'
Require-Contains $shaderText 'const float IMPACT_ARC_LIFETIME_MIN = 18.0000;' 'Impact-arc minimum lifetime'
Require-Contains $shaderText 'const float IMPACT_ARC_LIFETIME_MAX = 22.0000;' 'Impact-arc maximum lifetime'
Require-Contains $shaderText 'const float IMPACT_ARC_INFLOW_RATE = 0.0100;' 'Impact-arc inward drift rate'
Require-Contains $shaderText 'float diskImpactArc(' 'Deterministic impact-arc descriptor'
Require-Contains $shaderText 'float birthCoordinate=radial*exp(IMPACT_ARC_INFLOW_RATE*max(age,0.0));' 'Impact-arc birth-coordinate inward drift'
Require-Contains $shaderText 'float orbitalPhase=hPhase-age*DISK_MATERIAL_RATE*abs(materialSpeed)*0.12*sampleKep*sampleGloc*sdir;' 'Impact-arc birth-radius differential shear'
Require-Contains $shaderText 'float impactArcExcess=diskImpactArc(rc,turns,rin,rout,b,W,sdir,abs(L.speed),impactSlot)' 'First impact-arc descriptor'
Require-Contains $shaderText '+diskImpactArc(rc,turns,rin,rout,b,W,sdir,abs(L.speed),impactSlot-1.0)' 'Second impact-arc descriptor'
Require-Contains $shaderText '+diskImpactArc(rc,turns,rin,rout,b,W,sdir,abs(L.speed),impactSlot-2.0);' 'Third impact-arc descriptor'
Require-Contains $shaderText 'float density=band*streaks*impactArcDensity;' 'Impact-arc density consumption'
Require-NotContains $shaderText 'MACRO_CYCLE_SEC' 'Rejected synchronized macro replay'
Require-NotContains $shaderText 'MACRO_FADE_SEC' 'Rejected synchronized macro fade'
Require-NotContains $shaderText 'diskMacroDensity' 'Rejected macro density helper'
Require-Contains $shaderText 'if(rc<rin){' 'M6 inner-disk plunging-region crossing'
Require-Contains $shaderText 'float innerCavityTransmission=smoothstep(rin*0.82,rin*0.98,rc);' 'M6 smooth inner-cavity occlusion'
Require-Contains $shaderText 'trans*=innerCavityTransmission;' 'M6 non-emissive inner-cavity transmission'
Require-Contains $shaderText '}else if(rc<rout){' 'M6 outer emissive-disk continuation'
Require-Contains $shaderText 'const float INNER_FLOW_SKY_OCCLUDER_START = 1.4200;' 'M6 inner-flow sky occluder start'
Require-Contains $shaderText 'const float INNER_FLOW_SKY_OCCLUDER_END = 1.7200;' 'M6 inner-flow sky occluder end'
Require-Contains $shaderText 'float innerFlowSkyTransmission=smoothstep(' 'M6 smooth ray-space sky occluder'
Require-Contains $shaderText 'B_CRIT*INNER_FLOW_SKY_OCCLUDER_START,B_CRIT*INNER_FLOW_SKY_OCCLUDER_END,b);' 'M6 inner-flow sky occluder bounds'
Require-Contains $shaderText 'sky*=innerFlowSkyTransmission;' 'M6 sky-only inner-flow occlusion'
Require-Contains $shaderText 'vec3 col=sky*trans+(vec3(1.0)-exp(-emitc*L.expo));' 'M6 disk emission preserved after sky occlusion'
Require-Contains $shaderText 'const float SKY_FLOW_SPEED = 0.0750;' 'Reviewed visible background-flow speed'
Require-Contains $shaderText 'const float SKY_FLOW_DISTANCE_PER_PHASE = 0.2247;' 'Reviewed world-sky flow distance'
Require-Contains $shaderText 'vec2 streakA=vec2(rc*2.8,turns*19.0+swirl*3.0);' 'Restored primary disk filament band'
Require-Contains $shaderText 'vec2 streakB=vec2(rc*1.0,turns*9.0+swirl*1.5+7.0);' 'Restored secondary disk filament band'
Require-Contains $shaderText 'float streaks=filteredVnoiseWrapY(streakA,19.0,footprintA)*0.65' 'Restored disk filament density'
Require-NotContains $shaderText 'STAR_LENS_FILTER_GAIN' 'Rejected lensed-star softening filter'
foreach ($legacyToken in @('DEMO_N', 'DEMO_TOUR', 'demoLook', 'demoSize', 'mixLook', 'sceneAt', 'lissa', 'DRIFT_SPEED')) {
    Require-NotContains $shaderText $legacyToken 'Legacy body-presentation path'
}
if ([regex]::Matches($shaderText, '\buSceneSeed\b', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 8) {
    Fail 'uSceneSeed must be restricted to the uniform and seven impact-arc seed hashes'
}
$impactArcBlock = Get-GlslFunctionBlock $shaderText 'diskImpactArc'
Require-Contains $impactArcBlock 'uSceneSeed' 'Material-only scene seed use'
foreach ($forbiddenShaderToken in @('fwidth', 'dFdx', 'dFdy', 'sampler2D')) {
    Require-NotContains $shaderText $forbiddenShaderToken 'Derivative-free single-pass shader'
}

# Preserve M3's world-direction sky boundary while changing the presentation
# scene. Direct sky must never read body position, size, roll, look, or seed.
$starSpriteBlock = Get-GlslFunctionBlock $shaderText 'starSprite'
$cellStarsBlock = Get-GlslFunctionBlock $shaderText 'cellStars'
$starsBlock = Get-GlslFunctionBlock $shaderText 'stars'
$spaceBlock = Get-GlslFunctionBlock $shaderText 'spaceBackground'
$skyBlock = Get-GlslFunctionBlock $shaderText 'skyRadiance'
$coordinatesBlock = Get-GlslFunctionBlock $shaderText 'skyCoordinates'
$lensBlock = Get-GlslFunctionBlock $shaderText 'lensedWorldDirection'
$viewBlock = Get-GlslFunctionBlock $shaderText 'viewWorldDirection'
Require-Contains $starsBlock 'uSkySeed' 'Inertial star catalogue seed use'
Require-Contains $starsBlock 'skyCoordinates(worldDir)' 'Star catalogue shared world-sky coordinates'
Require-Contains $spaceBlock 'skyCoordinates(worldDir)' 'Background shared world-sky coordinates'
Require-Contains $skyBlock 'return spaceBackground(worldDir)+stars(worldDir,gatherNeighbors)*starGain;' 'Unified inertial sky sample'
Require-Contains $starSpriteBlock 'float spark=1.0-smoothstep(radius*radius,(radius*1.70)*(radius*1.70),dist2);' 'Unchanged point-sprite footprint'
Require-Contains $starSpriteBlock 'return tint*spark*strength;' 'Unchanged point-sprite energy'
Require-Contains $cellStarsBlock 'for(int offsetY=-1;offsetY<=1;offsetY++){' 'Lensed cell-neighborhood gather rows'
Require-Contains $cellStarsBlock 'for(int offsetX=-1;offsetX<=1;offsetX++){' 'Lensed cell-neighborhood gather columns'
Require-Contains $cellStarsBlock 'if(gatherNeighbors<=0.0)return cellStar(skyTangent,cell,cells,threshold,layerSeed,core);' 'Unchanged direct-sky single-cell path'
Require-Contains $cellStarsBlock 'float seamReach=core*cells*2.30;' 'Lensed catalogue seam reach'
Require-Contains $cellStarsBlock 'if(nearestCellEdge>=seamReach)return cellStar(skyTangent,cell,cells,threshold,layerSeed,core);' 'Bounded lensed seam gather'
Require-Contains $coordinatesBlock 'float skyTime=iTime*SKY_FLOW_SPEED;' 'World-sky flow timing'
Require-Contains $coordinatesBlock 'float skyFlowAngle=6.2831853*hash21(vec2(uSkySeed*107.0,59.0));' 'Per-launch sky direction seed'
Require-Contains $coordinatesBlock 'vec2 skyFlowDirection=vec2(cos(skyFlowAngle),sin(skyFlowAngle));' 'Fixed random world-sky direction'
Require-Contains $coordinatesBlock 'vec2 skyDrift=skyTime*SKY_FLOW_DISTANCE_PER_PHASE*skyFlowDirection+skySeedOffset;' 'World-sky translational drift'
Require-Contains $coordinatesBlock 'return worldTangent-skyDrift;' 'World-sky translation mapping'
Require-NotContains $coordinatesBlock 'skyTwist' 'No sky rotation around the body'
Require-NotContains $coordinatesBlock 'rot(' 'No sky rotation mapping'
Require-Contains $viewBlock 'return normalize(vec3((uv-0.5)*vec2(aspect,1.0),-1.0));' 'Direct world direction mapping'
foreach ($bodyToken in @('uSceneSeed', 'uSceneCenter', 'uApparentRadius', 'uDiskLook', 'uSceneExposure', 'center', 'L.roll')) {
    Require-NotContains $starsBlock $bodyToken 'Inertial star catalogue body isolation'
    Require-NotContains $spaceBlock $bodyToken 'Inertial background body isolation'
    Require-NotContains $skyBlock $bodyToken 'Unified inertial sky body isolation'
    Require-NotContains $coordinatesBlock $bodyToken 'World-sky coordinates body isolation'
}
Require-Contains $lensBlock 'float safeExitZ=min(localExitDir.z,-0.0200);' 'Bounded escaping-ray source-plane denominator'
Require-Contains $lensBlock 'float sourceTravel=(-LENS_DEPTH-localExitPoint.z)/safeExitZ;' 'Bounded escaping-ray source-plane projection'
Require-Contains $lensBlock 'vec3 sourceHit=localExitPoint+localExitDir*sourceTravel;' 'Escaping-ray source-plane hit'
Require-Contains $lensBlock 'vec2 sourceLensTangent=rot(sourceHit.xy,-roll)/lensScale;' 'Lens-space inverse transform'
Require-Contains $lensBlock 'vec2 viewTangent=viewWorldDir.xy/max(-viewWorldDir.z,0.05);' 'Lensed identity view tangent'
Require-Contains $lensBlock 'vec2 centerTangent=viewTangent-localImageTangent;' 'Lensed identity local tangent removal'
Require-Contains $lensBlock 'return normalize(vec3(centerTangent+sourceScreenTangent,-1.0));' 'Lensed identity source restoration'
Require-Contains $shaderText 'lensedWorldDirection(viewWorldDir,p,x,v,L.roll,W)' 'M3 lens-scale call shape'
Require-Contains $shaderText 'vec3 plainBg=skyRadiance(viewWorldDir,skyGain,0.0);' 'Unfiltered M3 direct directional sky'
Require-Contains $shaderText 'vec3 sky=captured?vec3(0.0):plainBg;' 'Captured-ray shadow with noncaptured direct fallback'
Require-Contains $shaderText 'float exitProjectionWeight=1.0-smoothstep(-0.0200,-0.0050,v.z);' 'Narrow continuous lensed-exit projection weight'
Require-Contains $shaderText 'float skyLensBlend=lensBlend*exitProjectionWeight;' 'Continuous lensed-exit sky blend'
Require-Contains $shaderText 'float lensStarGather=step(0.001,skyLensBlend);' 'Lensed path catalogue-seam guard'
Require-Contains $shaderText 'if(!captured){' 'Noncaptured lensed-sky guard'
Require-Contains $shaderText 'vec3 sampledWorldDir=normalize(mix(viewWorldDir,lensedWorldDir,skyLensBlend));' 'Continuous lensed sky direction remap'
Require-Contains $shaderText 'sky=skyRadiance(sampledWorldDir,skyGain,lensStarGather);' 'Seam-safe lensed directional sky sample'
if ([regex]::Matches($shaderText, '\bskyRadiance\s*\(', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 3) {
    Fail 'Canonical GLSL must have one skyRadiance definition and exactly two sampling paths'
}
if ([regex]::Matches($shaderText, '\bstars\s*\(', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 2) {
    Fail 'Canonical GLSL must route all star sampling through skyRadiance'
}
Test-ByteEquality (Get-GeneratedIncludeBytes ([System.IO.File]::ReadAllBytes($includePath))) $shaderBytes 'Generated include decoded GLSL'
& $generatorPath -ProjectRoot $ProjectRoot -Check
if (-not $?) {
    Fail 'Shader include generator check did not complete successfully'
}

foreach ($anchor in @($contract.host.schemaAnchors)) {
    Require-Contains $source ([string]$anchor) 'Configuration schema declaration'
}
foreach ($functionName in @($contract.host.requiredFunctions)) {
    [void](Get-CFunctionBlock $source ([string]$functionName))
}
foreach ($anchor in @($contract.host.requiredAnchors)) {
    Require-Contains $source ([string]$anchor) 'Configuration schema behavior'
}

$readDwordBlock = Get-CFunctionBlock $source 'readRegistryDword'
Require-Contains $readDwordBlock 'if (result == ERROR_FILE_NOT_FOUND) return CONFIG_REGISTRY_VALUE_MISSING;' 'Missing-value distinction'
Require-Contains $readDwordBlock 'if (type != REG_DWORD || bytes != sizeof(DWORD)) return CONFIG_REGISTRY_VALUE_INVALID;' 'Registry DWORD type and size validation'
$validatedReadBlock = Get-CFunctionBlock $source 'readValidatedConfigValue'
Require-Contains $validatedReadBlock 'if (value > (DWORD)CONFIG_VALUE_MAX) return fallback;' 'Safe unsigned range validation before conversion'
$loadBlock = Get-CFunctionBlock $source 'loadConfig'
Require-Contains $loadBlock 'if (schemaStatus == CONFIG_REGISTRY_VALUE_MISSING)' 'Legacy schema migration branch'
Require-Contains $loadBlock 'else if (schemaStatus == CONFIG_REGISTRY_VALUE_VALID && schemaVersion == CONFIG_SCHEMA_VERSION)' 'Current schema branch'
Require-NotContains $loadBlock 'RegSetValueExA' 'Read-only configuration load'
Require-NotContains $loadBlock 'RegCreateKeyExA' 'Read-only configuration load'
$saveBlock = Get-CFunctionBlock $source 'saveConfig'
Require-Contains $saveBlock 'writeRegistryDword(key, "StarBrightness"' 'Star brightness persistence'
Require-Contains $saveBlock 'writeRegistryDword(key, "DiskOpacity"' 'Disk opacity persistence'
Require-Contains $saveBlock 'writeRegistryDword(key, "Doppler"' 'Doppler persistence'
Require-Contains $saveBlock 'writeRegistryDword(key, REG_VALUE_CONFIG_SCHEMA_VERSION, CONFIG_SCHEMA_VERSION)' 'Version-marker persistence'
Require-Match $saveBlock '(?s)StarBrightness.*DiskOpacity.*Doppler.*REG_VALUE_CONFIG_SCHEMA_VERSION' 'Version marker written after control values'

$configWndProcBlock = Get-CFunctionBlock $source 'ConfigWndProc'
Require-Contains $configWndProcBlock 'if (!saveConfig(&pending))' 'Save failure stays in configuration dialog'
Require-Contains $configWndProcBlock 'MessageBoxA(hwnd, "Settings could not be saved."' 'Save failure feedback'
Require-Match $configWndProcBlock '(?s)if\s*\(id\s*==\s*CFG_ID_CANCEL\)\s*\{\s*DestroyWindow\(hwnd\);\s*return\s+0;\s*\}' 'Cancel without persistence'

foreach ($value in @($contract.configuration.values)) {
    $variable = [regex]::Escape([string]$value.variable)
    $default = [regex]::Escape([string]$value.default)
    Require-Match $source ('static\s+int\s+' + $variable + '\s*=\s*CONFIG_DEFAULT_') ("Schema-backed default for " + $value.registryValue)
    Require-Contains $loadBlock ('readValidatedConfigValue(key, "' + [string]$value.registryValue + '"') ("Validated registry read for " + $value.registryValue)
    Require-Contains $saveBlock ('writeRegistryDword(key, "' + [string]$value.registryValue + '"') ("Validated registry write for " + $value.registryValue)
}
Require-Contains $source 'typedef struct StaticSchwarzschildScene {' 'Named M6 scene model'
Require-Contains $source 'static const StaticSchwarzschildScene STATIC_SCHWARZSCHILD' 'Named static Schwarzschild scene'
Require-Contains $source 'g_skySeed = makeSceneSeed();' 'Per-launch sky-flow seed initialization'
Require-Contains $source 'if (uSkySeed >= 0)     glUniform1f(uSkySeed, state->skySeed);' 'Per-frame sky-flow seed upload'
Require-Contains $source '#define FRAME_INTERVAL_MS 10' '100 FPS submission-attempt cap'
Require-Contains $source '#define FRAME_COOLDOWN_DIVISOR 4ULL' 'Fractional post-fence cooldown'
Require-Match $source '(?s)STATIC_SCHWARZSCHILD\s*=\s*\{\s*0\.50f,\s*0\.50f,\s*0\.120f,\s*5500\.0f,\s*1\.50f,\s*0\.35f,\s*1\.80f,\s*8\.00f,\s*0\.90f,\s*0\.60f,\s*2\.50f,\s*2\.20f,\s*1\.60f,\s*7\.00f,\s*5\.00f,\s*1\.40f' 'Approved static scene constants'
foreach ($anchor in @($contract.host.sceneStateAnchors)) {
    Require-Contains $source ([string]$anchor) 'Preserved bounded SceneState mapping'
}
foreach ($anchor in @($contract.host.uniformUploadAnchors)) {
    Require-Contains $source ([string]$anchor) 'Centralized configuration uniform upload'
}
$frameScheduleBlock = Get-CFunctionBlock $source 'completeFrameSchedule'
Require-Contains $frameScheduleBlock 'cooldown = (elapsed - FRAME_INTERVAL_MS) / FRAME_COOLDOWN_DIVISOR;' 'Fractional cooldown avoids doubled frame intervals'
Require-Contains $frameScheduleBlock 'if (cooldown > FRAME_COOLDOWN_MAX_MS) cooldown = FRAME_COOLDOWN_MAX_MS;' 'Bounded cooldown policy'
$previousFrameBlock = Get-CFunctionBlock $source 'previousFrameComplete'
Require-Contains $previousFrameBlock 'p_glClientWaitSync(g_frameFence, 0, 0);' 'Non-blocking one-frame fence polling'
$uploadSceneBlock = Get-CFunctionBlock $source 'uploadSceneState'
$renderFrameBlock = Get-CFunctionBlock $source 'renderFrame'
Require-Contains $renderFrameBlock 'uploadSceneState(&state);' 'Single static-scene upload boundary'
Require-NotContains $renderFrameBlock 'glUniform' 'No render-frame body uniform override'
foreach ($uniformName in @('uSceneCenter', 'uApparentRadius', 'uDiskLookA', 'uDiskLookB', 'uDiskLookC', 'uSceneExposure')) {
    $uploadPattern = '\bglUniform(?:1f|2f|4f)\(' + [regex]::Escape($uniformName) + '\b'
    if ([regex]::Matches($uploadSceneBlock, $uploadPattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 1) {
        Fail "Static scene uniform $uniformName must be uploaded exactly once through uploadSceneState"
    }
    if ([regex]::Matches($source, $uploadPattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 1) {
        Fail "Static scene uniform $uniformName must not be uploaded outside uploadSceneState"
    }
}
foreach ($m5Token in @('QUALITY_', 'GPU_CALIBRATION', 'GL_TIME_ELAPSED', 'glBeginQuery', 'glEndQuery', 'glGetQueryObject', 'uQuality', 'uStepCount', 'calibrat', 'benchmark')) {
    Require-NotContains $source $m5Token 'Deferred M5 GPU quality/calibration scope'
    Require-NotContains $shaderText $m5Token 'Deferred M5 GPU quality/calibration scope'
}
if ([regex]::Matches($shaderText, '(?m)^#define\s+N_STEPS\s+48\s*$', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 1) {
    Fail 'M5 must not replace the fixed 48-step renderer with runtime-selected detail'
}
if ([regex]::Matches($shaderText, '\bfor\s*\(\s*int\s+i\s*=\s*0\s*;\s*i\s*<\s*N_STEPS\s*;', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 1) {
    Fail 'M5 must not add another runtime-selected ray-march loop'
}
foreach ($anchor in @($contract.host.renderAnchors)) {
    Require-Contains $source ([string]$anchor) 'Preserved renderer boundary'
}
foreach ($token in @($contract.host.forbiddenTokens)) {
    Require-NotContains $source ([string]$token) 'Host source'
}
if ([regex]::Matches($source, '\bglDrawArrays\s*\(', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 1) {
    Fail 'Host must retain exactly one glDrawArrays call'
}
if ([regex]::Matches($source, '\bSwapBuffers\s*\(', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 1) {
    Fail 'Host must retain exactly one SwapBuffers call'
}

$buildText = [System.IO.File]::ReadAllText($buildPath, [System.Text.Encoding]::UTF8).Replace("`r`n", "`n").Replace("`r", "`n")
Require-Contains $buildText ([string]$contract.build.generatorInvocation) 'Build-time canonical shader generation'
Require-Contains $buildText ([string]$contract.build.temporaryOutputVariable) 'Temporary output build protocol'
Require-Contains $buildText ([string]$contract.build.promotion) 'Completed-build promotion'
Require-NotContains $buildText '/Fe:blackhole.scr' 'Direct release overwrite'

Write-Host 'Milestone 6 static Schwarzschild scene contract verified.'
