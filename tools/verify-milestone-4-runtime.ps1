[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Executable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$registryKey = 'HKCU\Software\BlackHoleScreensaver'
$registryProviderKey = 'Registry::HKEY_CURRENT_USER\Software\BlackHoleScreensaver'
$backupPath = Join-Path $env:TEMP ('blackhole-m4-registry-' + [Guid]::NewGuid().ToString('N') + '.reg')
$hadOriginalKey = Test-Path -LiteralPath $registryProviderKey

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Milestone4ConfigNative {
    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr hDlg, int nIDDlgItem);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
'@

$WM_CLOSE = 0x0010
$WM_COMMAND = 0x0111
$TBM_GETPOS = 0x0400
$TBM_SETPOS = 0x0405
$CFG_ID_STAR_SLIDER = 201
$CFG_ID_DISK_SLIDER = 202
$CFG_ID_DOPPLER_SLIDER = 203
$CFG_ID_OK = 210
$CFG_ID_CANCEL = 211

function Fail([string]$message) {
    throw "Milestone 4 runtime contract failure: $message"
}

function Invoke-Reg([string[]]$arguments) {
    & reg.exe @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail "reg.exe $($arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Clear-TestKey {
    if (-not (Test-Path -LiteralPath $registryProviderKey)) { return }
    & reg.exe delete $registryKey /f | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $registryProviderKey)) {
        Fail 'Could not clear the temporary configuration registry key'
    }
}

function Set-Dword([string]$name, [int]$value) {
    Invoke-Reg @('add', $registryKey, '/v', $name, '/t', 'REG_DWORD', '/d', [string]$value, '/f')
}

function Set-String([string]$name, [string]$value) {
    Invoke-Reg @('add', $registryKey, '/v', $name, '/t', 'REG_SZ', '/d', $value, '/f')
}

function Assert-Equal([object]$actual, [object]$expected, [string]$label) {
    if ($actual -ne $expected) {
        Fail "$label expected '$expected', got '$actual'"
    }
}

function Assert-Dword([string]$name, [int]$expected) {
    if (-not (Test-Path -LiteralPath $registryProviderKey)) {
        Fail "Registry key is missing while checking $name"
    }
    $actual = [int](Get-ItemPropertyValue -LiteralPath $registryProviderKey -Name $name -ErrorAction Stop)
    Assert-Equal $actual $expected "Registry DWORD $name"
}

function Assert-NoValue([string]$name) {
    if (-not (Test-Path -LiteralPath $registryProviderKey)) { return }
    $properties = Get-ItemProperty -LiteralPath $registryProviderKey
    if ($properties.PSObject.Properties.Name -contains $name) {
        Fail "Registry value $name was unexpectedly written"
    }
}

function Assert-StringValue([string]$name, [string]$expected) {
    if (-not (Test-Path -LiteralPath $registryProviderKey)) {
        Fail "Registry string $name was changed or missing"
    }
    $actual = [string](Get-ItemPropertyValue -LiteralPath $registryProviderKey -Name $name -ErrorAction Stop)
    Assert-Equal $actual $expected "Registry string $name"
}

function Wait-ForConfigWindow([System.Diagnostics.Process]$process) {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) { return $process.MainWindowHandle }
        Start-Sleep -Milliseconds 50
    } while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline)
    Fail "/c did not open a configuration window (exited=$($process.HasExited), exitCode=$($process.ExitCode))"
}

function Start-Config {
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.Arguments = '/c'
    $info.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { Fail 'Could not start /c' }
    return [PSCustomObject]@{ Process = $process; Window = Wait-ForConfigWindow $process }
}

function Get-SliderPosition([IntPtr]$window, [int]$controlId) {
    $slider = [Milestone4ConfigNative]::GetDlgItem($window, $controlId)
    if ($slider -eq [IntPtr]::Zero) { Fail "Missing slider control $controlId" }
    return [int][Milestone4ConfigNative]::SendMessage($slider, $TBM_GETPOS, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
}

function Set-SliderPosition([IntPtr]$window, [int]$controlId, [int]$position) {
    $slider = [Milestone4ConfigNative]::GetDlgItem($window, $controlId)
    if ($slider -eq [IntPtr]::Zero) { Fail "Missing slider control $controlId" }
    [void][Milestone4ConfigNative]::SendMessage($slider, $TBM_SETPOS, [IntPtr]1, [IntPtr]$position)
}

function Assert-Sliders([IntPtr]$window, [int]$star, [int]$disk, [int]$doppler) {
    Assert-Equal (Get-SliderPosition $window $CFG_ID_STAR_SLIDER) $star 'Star Brightness slider'
    Assert-Equal (Get-SliderPosition $window $CFG_ID_DISK_SLIDER) $disk 'Disk Opacity slider'
    Assert-Equal (Get-SliderPosition $window $CFG_ID_DOPPLER_SLIDER) $doppler 'Doppler slider'
}

function Wait-ForExit([System.Diagnostics.Process]$process, [string]$label) {
    if (-not $process.WaitForExit(5000)) {
        Fail "$label did not exit"
    }
    if ($process.ExitCode -ne 0) {
        Fail "$label exited with code $($process.ExitCode)"
    }
}

function Close-Config([PSCustomObject]$config) {
    if (-not [Milestone4ConfigNative]::PostMessage($config.Window, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)) {
        Fail 'Could not close the configuration window'
    }
    Wait-ForExit $config.Process '/c close'
}

function Click-ConfigCommand([PSCustomObject]$config, [int]$commandId) {
    if (-not [Milestone4ConfigNative]::PostMessage($config.Window, $WM_COMMAND, [IntPtr]$commandId, [IntPtr]::Zero)) {
        Fail "Could not send configuration command $commandId"
    }
    Wait-ForExit $config.Process "/c command $commandId"
}

if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    Fail "Executable is missing: $Executable"
}

try {
    if ($hadOriginalKey) {
        Invoke-Reg @('export', $registryKey, $backupPath, '/y')
    }

    Clear-TestKey
    $config = Start-Config
    Assert-Sliders $config.Window 30 90 60
    Close-Config $config
    if (Test-Path -LiteralPath $registryProviderKey) {
        Fail 'Missing-key fallback unexpectedly created a registry key'
    }

    Clear-TestKey
    Set-Dword 'StarBrightness' 7
    Set-Dword 'DiskOpacity' 51
    Set-Dword 'Doppler' 99
    $config = Start-Config
    Assert-Sliders $config.Window 7 51 99
    Click-ConfigCommand $config $CFG_ID_CANCEL
    Assert-NoValue 'ConfigSchemaVersion'
    Assert-Dword 'StarBrightness' 7
    Assert-Dword 'DiskOpacity' 51
    Assert-Dword 'Doppler' 99

    Clear-TestKey
    Set-Dword 'ConfigSchemaVersion' 1
    Set-Dword 'StarBrightness' 0
    Set-Dword 'DiskOpacity' 100
    Set-Dword 'Doppler' 45
    $config = Start-Config
    Assert-Sliders $config.Window 0 100 45
    Close-Config $config
    Assert-Dword 'ConfigSchemaVersion' 1

    Clear-TestKey
    Set-Dword 'StarBrightness' 44
    Set-String 'DiskOpacity' 'not-a-dword'
    Set-Dword 'Doppler' 101
    $config = Start-Config
    Assert-Sliders $config.Window 44 90 60
    Close-Config $config
    Assert-StringValue 'DiskOpacity' 'not-a-dword'
    Assert-Dword 'Doppler' 101
    Assert-NoValue 'ConfigSchemaVersion'

    Clear-TestKey
    Set-Dword 'ConfigSchemaVersion' 2
    Set-Dword 'StarBrightness' 11
    Set-Dword 'DiskOpacity' 22
    Set-Dword 'Doppler' 33
    $config = Start-Config
    Assert-Sliders $config.Window 30 90 60
    Close-Config $config
    Assert-Dword 'ConfigSchemaVersion' 2

    Clear-TestKey
    Set-Dword 'StarBrightness' 1
    Set-Dword 'DiskOpacity' 2
    Set-Dword 'Doppler' 3
    $config = Start-Config
    Set-SliderPosition $config.Window $CFG_ID_STAR_SLIDER 12
    Set-SliderPosition $config.Window $CFG_ID_DISK_SLIDER 34
    Set-SliderPosition $config.Window $CFG_ID_DOPPLER_SLIDER 56
    Click-ConfigCommand $config $CFG_ID_OK
    Assert-Dword 'ConfigSchemaVersion' 1
    Assert-Dword 'StarBrightness' 12
    Assert-Dword 'DiskOpacity' 34
    Assert-Dword 'Doppler' 56

    Write-Host 'Milestone 4 runtime configuration contract verified.'
}
finally {
    Clear-TestKey
    if ($hadOriginalKey) {
        Invoke-Reg @('import', $backupPath)
    }
    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
}
