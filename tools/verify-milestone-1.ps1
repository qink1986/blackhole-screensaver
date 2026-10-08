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
    throw "Milestone 1 contract failure: $Message"
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

function Get-CStringBlock([string]$Text, [string]$Symbol) {
    $pattern = '(?s)static\s+const\s+char\*\s+' + [regex]::Escape($Symbol) + '\s*=\s*(?<body>.*?);\r?\n\r?\n'
    $match = [regex]::Match($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        Fail "Could not isolate C string block for $Symbol"
    }
    return $match.Value
}

function Get-LfNormalizedSha256([string]$Path) {
    [byte[]]$sourceBytes = [System.IO.File]::ReadAllBytes($Path)
    $normalized = New-Object System.IO.MemoryStream
    try {
        for ($index = 0; $index -lt $sourceBytes.Length; ++$index) {
            if ($sourceBytes[$index] -eq 13) {
                $normalized.WriteByte(10)
                if (($index + 1) -lt $sourceBytes.Length -and $sourceBytes[$index + 1] -eq 10) {
                    ++$index
                }
            } else {
                $normalized.WriteByte($sourceBytes[$index])
            }
        }
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($hasher.ComputeHash($normalized.ToArray()))).Replace('-', '')
        }
        finally {
            $hasher.Dispose()
        }
    }
    finally {
        $normalized.Dispose()
    }
}

$contractPath = Join-Path $ProjectRoot 'tests\milestone-1-contract.json'
Require-File $contractPath 'Contract JSON'

try {
    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
}
catch {
    Fail "Contract JSON is invalid: $($_.Exception.Message)"
}

if ($contract.contract -ne 'blackhole-screensaver-milestone-1' -or [int]$contract.version -ne 1) {
    Fail 'Unexpected contract identity or version'
}
if ($contract.scope -ne 'frozen-no-visual-change-foundation') {
    Fail 'Unexpected contract scope'
}
if ($contract.runtimeBaseline.algorithm -ne 'SHA256' -or $contract.runtimeBaseline.lineEndingNormalization -ne 'lf' -or [string]::IsNullOrWhiteSpace($contract.runtimeBaseline.updateRule)) {
    Fail 'Runtime baseline metadata is incomplete'
}

$sourcePath = Join-Path $ProjectRoot $contract.sourceOfTruth.hostFile
$referencePath = Join-Path $ProjectRoot $contract.sourceOfTruth.referenceShader
Require-File $sourcePath 'Authoritative host source'
Require-File $referencePath 'Legacy reference shader'
$source = Get-Content -LiteralPath $sourcePath -Raw

$expectedHash = ([string]$contract.runtimeBaseline.hostSourceSha256).ToUpperInvariant()
if ($expectedHash -notmatch '^[0-9A-F]{64}$') {
    Fail 'Runtime baseline SHA-256 is malformed'
}
$actualHash = Get-LfNormalizedSha256 $sourcePath
if ($actualHash -ne $expectedHash) {
    Fail "Authoritative host source differs from frozen baseline. Expected $expectedHash, got $actualHash"
}

if ($contract.sourceOfTruth.referenceRole -ne 'legacy-reference-only') {
    Fail 'Unexpected standalone shader role'
}
$embeddedSymbol = [string]$contract.sourceOfTruth.embeddedShaderSymbol
$headerSymbol = [string]$contract.sourceOfTruth.fragmentHeaderSymbol
$embeddedShaderBlock = Get-CStringBlock $source $embeddedSymbol
$fragmentHeaderBlock = Get-CStringBlock $source $headerSymbol
Require-Contains $source ('sprintf(fullFrag, "%s%s", ' + $headerSymbol + ', ' + $embeddedSymbol + ');') 'Fragment shader assembly contract'
foreach ($anchor in $contract.sourceOfTruth.requiredSourceAnchors) {
    Require-Contains $source ([string]$anchor) 'Runtime source-of-truth contract'
}

Require-Contains $fragmentHeaderBlock ('#version ' + $contract.shader.glslVersion) 'Fragment GLSL version contract'
foreach ($uniform in $contract.shader.uniforms) {
    Require-Contains $fragmentHeaderBlock ([string]$uniform.declaration) ("Fragment uniform declaration for " + $uniform.name)
    $locationPattern = [regex]::Escape([string]$uniform.hostLocation) + '\s*=\s*glGetUniformLocation\(\s*shaderProgram\s*,\s*"' + [regex]::Escape([string]$uniform.name) + '"\s*\)'
    Require-Match $source $locationPattern ("Host uniform location for " + $uniform.name)
}
foreach ($anchor in $contract.shader.requiredSourceAnchors) {
    Require-Contains $embeddedShaderBlock ([string]$anchor) 'Embedded shader baseline contract'
}
foreach ($token in $contract.shader.forbiddenTokens) {
    if ($source.IndexOf([string]$token, [System.StringComparison]::Ordinal) -ge 0) {
        Fail "Baseline source contains forbidden token: $token"
    }
}

Require-Contains $source ([string]$contract.configuration.registryKeySourceAnchor) 'Registry key contract'
foreach ($value in $contract.configuration.values) {
    $variable = [regex]::Escape([string]$value.variable)
    $default = [regex]::Escape([string]$value.default)
    Require-Match $source ('static\s+int\s+' + $variable + '\s*=\s*' + $default + '\s*;') ("Default for " + $value.registryValue)
    Require-Contains $source ('RegQueryValueExA(key, "' + $value.registryValue + '"') ("Registry read for " + $value.registryValue)
    Require-Contains $source ('RegSetValueExA(key, "' + $value.registryValue + '"') ("Registry write for " + $value.registryValue)
    $stateField = [regex]::Escape([string]$value.sceneStateField)
    Require-Match $source ('state\.' + $stateField + '\s*=\s*\(float\)' + $variable + '\s*/\s*100\.0f\s*;') ("SceneState normalization for " + $value.registryValue)
}

$rangeAnchor = 'MAKELONG(' + $contract.configuration.uiMinimum + ', ' + $contract.configuration.uiMaximum + ')'
$rangeCount = [regex]::Matches($source, [regex]::Escape($rangeAnchor), [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
if ($rangeCount -lt @($contract.configuration.values).Count) {
    Fail "Expected at least $(@($contract.configuration.values).Count) UI range anchors '$rangeAnchor'; found $rangeCount"
}

$frameInterval = [int]$contract.scheduling.frameIntervalMs
$cooldownMax = [int]$contract.scheduling.cooldownMaxMs
Require-Match $source ('#define\s+FRAME_INTERVAL_MS\s+' + [regex]::Escape([string]$frameInterval) + '\b') 'Frame submission interval contract'
Require-Match $source ('#define\s+FRAME_COOLDOWN_MAX_MS\s+' + [regex]::Escape([string]$cooldownMax) + 'ULL\b') 'Maximum frame cooldown contract'
Require-Match $source '#define\s+FRAME_COOLDOWN_TRIGGER_MS\s+\(2ULL\s*\*\s*FRAME_INTERVAL_MS\)' 'Frame cooldown trigger contract'
foreach ($anchor in $contract.scheduling.requiredSourceAnchors) {
    Require-Contains $source ([string]$anchor) 'Frame scheduling contract'
}
Require-Match $source '(?s)static\s+void\s+renderVisibleFrame\(void\)\s*\{\s*ULONGLONG\s+now\s*=\s*GetTickCount64\(\);\s*if\s*\(\s*!previousFrameComplete\(now\)\s*\)\s*return;\s*if\s*\(\s*now\s*<\s*g_nextFrameEligibleTick\s*\)\s*return;\s*renderFrame\(1\);\s*\}' 'One-frame render gate'
Require-Match $source '(?s)case\s+WM_TIMER\s*:.*?renderVisibleFrame\(\);\s*return\s+0;' 'Timer-to-render gate'
Require-Match $source '(?s)int\s+initialFramePresented\s*=\s*renderFrame\(1\);\s*if\s*\(\s*!initialFramePresented\s*\)\s*\{.*?return\s+1;\s*\}\s*glFinish\(\);.*?g_frameFence\s*=\s*NULL;\s*resetFrameSchedule\(GetTickCount64\(\)\);\s*if\s*\(g_fullscreen\)\s*hideCursor\(\);\s*ShowWindow\(hwnd,\s*g_fullscreen\s*\?\s*SW_SHOWNOACTIVATE\s*:\s*SW_SHOW\);' 'Hidden first-frame ordering'

foreach ($anchor in $contract.modes.requiredSourceAnchors) {
    Require-Contains $source ([string]$anchor) 'Screensaver mode contract'
}
Require-Match $source '(?s)if\s*\(_strnicmp\(cl,\s*"/s",\s*2\)\s*==\s*0\)\s*\{.*?if\s*\(\*end\s*!=\s*0\)\s*return\s+0;\s*\}' '/s standalone mode behavior'
Require-Match $source '(?s)else\s+if\s*\(_strnicmp\(cl,\s*"/p",\s*2\)\s*==\s*0\)\s*\{\s*isPreview\s*=\s*1;.*?previewParent\s*=\s*\(HWND\)\(LONG_PTR\)atol\(cl\);\s*\}' '/p preview mode behavior'
Require-Match $source '(?s)else\s+if\s*\(_strnicmp\(cl,\s*"/c",\s*2\)\s*==\s*0.*?showConfigDialog\(hInstance\);\s*return\s+0;\s*\}' '/c configuration mode behavior'
Require-Match $source '(?s)else\s+if\s*\(_strnicmp\(cl,\s*"/d",\s*2\)\s*==\s*0\)\s*\{.*?g_preview\s*=\s*0;\s*\}' '/d debug mode behavior'

Write-Host ("Milestone 1 contract PASS: {0} v{1}" -f $contract.contract, $contract.version)
Write-Host ("  runtime shader: {0}::{1}" -f $contract.sourceOfTruth.hostFile, $embeddedSymbol)
Write-Host ("  frozen LF-normalized host SHA-256: {0}" -f $actualHash)
Write-Host ("  baseline: GLSL {0}, {1} uniforms, {2} persisted controls, {3} ms submission cap" -f $contract.shader.glslVersion, @($contract.shader.uniforms).Count, @($contract.configuration.values).Count, $frameInterval)
