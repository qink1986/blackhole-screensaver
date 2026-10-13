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
    throw "Milestone 4 contract failure: $Message"
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

$contractPath = Join-Path $ProjectRoot 'tests\milestone-4-contract.json'
Require-File $contractPath 'Contract JSON'
try {
    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
}
catch {
    Fail "Contract JSON is invalid: $($_.Exception.Message)"
}
if ($contract.contract -ne 'blackhole-screensaver-milestone-4' -or [int]$contract.version -ne 1) {
    Fail 'Unexpected contract identity or version'
}
if ($contract.scope -ne 'validated-versioned-configuration-schema') {
    Fail 'Unexpected contract scope'
}

$sourcePath = Join-Path $ProjectRoot ([string]$contract.host.path)
$shaderPath = Join-Path $ProjectRoot ([string]$contract.canonicalShader.path)
$includePath = Join-Path $ProjectRoot ([string]$contract.canonicalShader.generatedInclude)
$generatorPath = Join-Path $ProjectRoot ([string]$contract.canonicalShader.generator)
$buildPath = Join-Path $ProjectRoot ([string]$contract.build.script)
$runtimeProbePath = Join-Path $ProjectRoot 'tools\verify-milestone-4-runtime.ps1'
Require-File $sourcePath 'Authoritative host source'
Require-File $shaderPath 'Canonical GLSL source'
Require-File $includePath 'Generated shader include'
Require-File $generatorPath 'Shader include generator'
Require-File $buildPath 'Build script'
Require-File $runtimeProbePath 'Runtime configuration probe'

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
Require-Contains $shaderText '#define DEMO_N 4' 'Four-look baseline'
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
foreach ($anchor in @($contract.host.sceneStateAnchors)) {
    Require-Contains $source ([string]$anchor) 'Preserved bounded SceneState mapping'
}
foreach ($anchor in @($contract.host.uniformUploadAnchors)) {
    Require-Contains $source ([string]$anchor) 'Centralized configuration uniform upload'
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

Write-Host 'Milestone 4 validated configuration schema contract verified.'
