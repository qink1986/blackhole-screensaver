[CmdletBinding()]
param(
    [switch]$Check,
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

function Fail([string]$Message) {
    throw "Shader include generation failure: $Message"
}

function Test-ByteSequenceEqual([byte[]]$Left, [byte[]]$Right) {
    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Length; ++$index) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function Convert-CanonicalGlslToIncludeBytes([string]$CanonicalSource) {
    if ($CanonicalSource.Length -eq 0) {
        Fail 'Canonical GLSL source is empty'
    }
    if ($CanonicalSource.IndexOf([char]0) -ge 0) {
        Fail 'Canonical GLSL source contains a NUL byte'
    }
    if ($CanonicalSource.IndexOf("`r") -ge 0) {
        Fail 'Canonical GLSL source must use LF line endings only'
    }
    if (-not $CanonicalSource.EndsWith("`n", [System.StringComparison]::Ordinal)) {
        Fail 'Canonical GLSL source must end with one LF newline'
    }
    if (-not $CanonicalSource.StartsWith("#version 330`n", [System.StringComparison]::Ordinal)) {
        Fail 'Canonical GLSL source must start with #version 330 as its first directive'
    }

    foreach ($character in $CanonicalSource.ToCharArray()) {
        $code = [int][char]$character
        if ($code -gt 127) {
            Fail 'Canonical GLSL source must be ASCII-only until a portable C-source encoding contract exists'
        }
        if ($code -lt 32 -and $character -ne [char]9 -and $character -ne [char]10) {
            Fail 'Canonical GLSL source contains an unsupported control character'
        }
    }

    $lines = $CanonicalSource.Substring(0, $CanonicalSource.Length - 1).Split(@("`n"), [System.StringSplitOptions]::None)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append("/* Generated from blackhole_screensaver.glsl; do not edit. */`n")
    foreach ($line in $lines) {
        [void]$builder.Append('"')
        foreach ($character in $line.ToCharArray()) {
            switch ($character) {
                '\' { [void]$builder.Append('\\') }
                '"' { [void]$builder.Append('\"') }
                "`t" { [void]$builder.Append('\t') }
                default { [void]$builder.Append($character) }
            }
        }
        [void]$builder.Append('\n"')
        [void]$builder.Append("`n")
    }
    return (New-Object System.Text.UTF8Encoding($false)).GetBytes($builder.ToString())
}

$canonicalPath = Join-Path $ProjectRoot 'blackhole_screensaver.glsl'
$outputPath = Join-Path $ProjectRoot 'generated\blackhole_screensaver_frag.inc'
if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
    Fail "Canonical GLSL source is missing: $canonicalPath"
}

[byte[]]$canonicalBytes = [System.IO.File]::ReadAllBytes($canonicalPath)
if ($canonicalBytes.Length -ge 3 -and $canonicalBytes[0] -eq 0xEF -and $canonicalBytes[1] -eq 0xBB -and $canonicalBytes[2] -eq 0xBF) {
    Fail 'Canonical GLSL source must not have a UTF-8 BOM'
}
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
try {
    $canonicalSource = $utf8.GetString($canonicalBytes)
}
catch {
    Fail "Canonical GLSL source is not valid UTF-8: $($_.Exception.Message)"
}
if (-not (Test-ByteSequenceEqual $canonicalBytes ($utf8.GetBytes($canonicalSource)))) {
    Fail 'Canonical GLSL source is not a canonical UTF-8 byte sequence'
}

[byte[]]$expectedBytes = Convert-CanonicalGlslToIncludeBytes $canonicalSource
if ($Check) {
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        Fail "Generated shader include is missing: $outputPath"
    }
    [byte[]]$actualBytes = [System.IO.File]::ReadAllBytes($outputPath)
    if (-not (Test-ByteSequenceEqual $actualBytes $expectedBytes)) {
        Fail 'Generated shader include is stale; run tools\generate-shader-include.ps1'
    }
    Write-Host 'Shader include is current.'
    return
}

$outputDirectory = Split-Path -Parent $outputPath
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$generationId = [Guid]::NewGuid().ToString('N')
$tempPath = Join-Path $outputDirectory ('.blackhole_screensaver_frag.' + $generationId + '.tmp')
$backupPath = Join-Path $outputDirectory ('.blackhole_screensaver_frag.' + $generationId + '.bak')
try {
    [System.IO.File]::WriteAllBytes($tempPath, $expectedBytes)
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        # Same-directory File.Replace is atomic on the Windows filesystem and
        # leaves the old include available if replacement cannot complete.
        [System.IO.File]::Replace($tempPath, $outputPath, $backupPath)
    }
    else {
        [System.IO.File]::Move($tempPath, $outputPath)
    }
}
finally {
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
        Remove-Item -LiteralPath $tempPath -Force
    }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        Remove-Item -LiteralPath $backupPath -Force
    }
}

Write-Host 'Generated shader include.'
