[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Executable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$registryKey = 'HKCU\Software\BlackHoleScreensaver'
$registryProviderKey = 'Registry::HKEY_CURRENT_USER\Software\BlackHoleScreensaver'
$backupPath = Join-Path $env:TEMP ('blackhole-m7-registry-' + [Guid]::NewGuid().ToString('N') + '.reg')
$hadOriginalKey = Test-Path -LiteralPath $registryProviderKey

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Milestone7ConfigNative {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder className, int maxCount);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr hDlg, int nIDDlgItem);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint command);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern int MapWindowPoints(IntPtr from, IntPtr to, ref RECT rect, uint points);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@

$WM_CLOSE = 0x0010
$WM_COMMAND = 0x0111
$WM_HSCROLL = 0x0114
$SWP_NOMOVE = 0x0002
$SWP_NOZORDER = 0x0004
$GW_OWNER = 4
$TBM_GETPOS = 0x0400
$TBM_SETPOS = 0x0405
$SETTINGS_SLIDER_UNITS = 1000
$CFG_ID_STAR_SLIDER = 201
$CFG_ID_DISK_SLIDER = 202
$CFG_ID_DOPPLER_SLIDER = 203
$CFG_ID_DENSITY_SLIDER = 204
$CFG_ID_SPEED_SLIDER = 205
$CFG_ID_OK = 211
$CFG_ID_CANCEL = 212
$SETTINGS_WND_CLASS = 'BlackHoleSettings'
$RENDERER_WND_CLASS = 'BlackHoleSCR'
$ADJ_ID_STAR_SLIDER = $CFG_ID_STAR_SLIDER
$ADJ_ID_DENSITY_SLIDER = $CFG_ID_DENSITY_SLIDER
$ADJ_ID_SPEED_SLIDER = $CFG_ID_SPEED_SLIDER
$ADJ_ID_SAVE = $CFG_ID_OK
$ADJ_ID_REVERT = $CFG_ID_CANCEL

function Fail([string]$Message) {
    throw "Milestone 7 runtime contract failure: $Message"
}

function Invoke-Reg([string[]]$Arguments) {
    & reg.exe @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "reg.exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

function Clear-TestKey {
    if (Test-Path -LiteralPath $registryProviderKey) {
        & reg.exe delete $registryKey /f | Out-Null
        if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $registryProviderKey)) { Fail 'could not clear temporary registry key' }
    }
}

function Set-Dword([string]$Name, [int]$Value) {
    Invoke-Reg @('add', $registryKey, '/v', $Name, '/t', 'REG_DWORD', '/d', [string]$Value, '/f')
}

function Set-String([string]$Name, [string]$Value) {
    Invoke-Reg @('add', $registryKey, '/v', $Name, '/t', 'REG_SZ', '/d', $Value, '/f')
}

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Label) {
    if ($Actual -ne $Expected) { Fail "$Label expected '$Expected', got '$Actual'" }
}

function Assert-Dword([string]$Name, [int]$Expected) {
    if (!(Test-Path -LiteralPath $registryProviderKey)) { Fail "registry key is missing while checking $Name" }
    $actual = [int](Get-ItemPropertyValue -LiteralPath $registryProviderKey -Name $Name -ErrorAction Stop)
    Assert-Equal $actual $Expected "registry DWORD $Name"
}

function Assert-NoValue([string]$Name) {
    if (!(Test-Path -LiteralPath $registryProviderKey)) { return }
    if ((Get-ItemProperty -LiteralPath $registryProviderKey).PSObject.Properties.Name -contains $Name) {
        Fail "registry value $Name was unexpectedly written"
    }
}

$script:windowSearchProcessId = 0
$script:windowSearchClassName = ''
$script:windowSearchResult = [IntPtr]::Zero
$script:windowSearchCallback = [Milestone7ConfigNative+EnumWindowsProc]{
    param([IntPtr]$candidate, [IntPtr]$unused)
    [uint32]$owner = 0
    [void][Milestone7ConfigNative]::GetWindowThreadProcessId($candidate, [ref]$owner)
    if ($owner -ne $script:windowSearchProcessId) { return $true }
    $classBuffer = New-Object Text.StringBuilder 128
    [void][Milestone7ConfigNative]::GetClassName($candidate, $classBuffer, $classBuffer.Capacity)
    if ($classBuffer.ToString() -eq $script:windowSearchClassName) {
        $script:windowSearchResult = $candidate
        return $false
    }
    return $true
}

function Find-ProcessWindow([System.Diagnostics.Process]$Process, [string]$ClassName) {
    $Process.Refresh()
    if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
        $classBuffer = New-Object Text.StringBuilder 128
        [void][Milestone7ConfigNative]::GetClassName($Process.MainWindowHandle, $classBuffer, $classBuffer.Capacity)
        if ($classBuffer.ToString() -eq $ClassName) { return $Process.MainWindowHandle }
    }
    return [IntPtr]::Zero
}

function Wait-ForSettingsPalette([System.Diagnostics.Process]$Process, [string]$Label) {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            $owner = $Process.MainWindowHandle
            $script:windowSearchProcessId = $Process.Id
            $script:windowSearchClassName = $SETTINGS_WND_CLASS
            $script:windowSearchResult = [IntPtr]::Zero
            [void][Milestone7ConfigNative]::EnumWindows($script:windowSearchCallback, [IntPtr]::Zero)
            if ($script:windowSearchResult -ne [IntPtr]::Zero -and
                [Milestone7ConfigNative]::GetWindow($script:windowSearchResult, $GW_OWNER) -eq $owner) {
                return $script:windowSearchResult
            }
        }
        Start-Sleep -Milliseconds 50
    } while (!$Process.HasExited -and [DateTime]::UtcNow -lt $deadline)
    if ($Process.HasExited) { Fail "$Label did not open (exited=$($Process.HasExited), exitCode=$($Process.ExitCode))" }
    Fail "$Label did not open"
}

function Wait-ForWindow([System.Diagnostics.Process]$Process, [string]$ClassName, [string]$Label) {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $window = Find-ProcessWindow $Process $ClassName
        if ($window -ne [IntPtr]::Zero) { return $window }
        Start-Sleep -Milliseconds 50
    } while (!$Process.HasExited -and [DateTime]::UtcNow -lt $deadline)
    Fail "$Label did not open (exited=$($Process.HasExited), exitCode=$($Process.ExitCode))"
}

function Start-Window([string]$Arguments, [string]$ClassName, [string]$Label) {
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (!$process.Start()) { Fail "could not start $Label" }
    return [PSCustomObject]@{ Process = $process; Window = Wait-ForWindow $process $ClassName $Label }
}

function Wait-ForExit([System.Diagnostics.Process]$Process, [string]$Label) {
    if (!$Process.WaitForExit(5000)) { Fail "$Label did not exit" }
    if ($Process.ExitCode -ne 0) { Fail "$Label exited with code $($Process.ExitCode)" }
}

function Close-Window([PSCustomObject]$Window, [string]$Label) {
    if (![Milestone7ConfigNative]::PostMessage($Window.Window, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)) { Fail "could not close $Label" }
    Wait-ForExit $Window.Process $Label
}

function Get-Slider([IntPtr]$Window, [int]$ControlId) {
    $slider = [Milestone7ConfigNative]::GetDlgItem($Window, $ControlId)
    if ($slider -eq [IntPtr]::Zero) { Fail "slider $ControlId is missing" }
    return $slider
}

function Get-SliderPosition([IntPtr]$Window, [int]$ControlId) {
    return [int][Milestone7ConfigNative]::SendMessage((Get-Slider $Window $ControlId), $TBM_GETPOS, [IntPtr]::Zero, [IntPtr]::Zero).ToInt64()
}

function Set-SliderPosition([IntPtr]$Window, [int]$ControlId, [int]$Position) {
    $slider = Get-Slider $Window $ControlId
    [void][Milestone7ConfigNative]::SendMessage($slider, $TBM_SETPOS, [IntPtr]1, [IntPtr]$Position)
    [void][Milestone7ConfigNative]::SendMessage($Window, $WM_HSCROLL, [IntPtr]::Zero, $slider)
}

function To-NormalizedPosition([int]$Value, [int]$Minimum, [int]$Maximum) {
    return [int](($Value - $Minimum) * $SETTINGS_SLIDER_UNITS / ($Maximum - $Minimum))
}

function Assert-Sliders([IntPtr]$Window, [int]$Star, [int]$Disk, [int]$Doppler, [int]$Density, [int]$Speed) {
    Assert-Equal (Get-SliderPosition $Window $CFG_ID_STAR_SLIDER) (To-NormalizedPosition $Star 0 100) 'star brightness slider'
    Assert-Equal (Get-SliderPosition $Window $CFG_ID_DISK_SLIDER) (To-NormalizedPosition $Disk 0 100) 'disk opacity slider'
    Assert-Equal (Get-SliderPosition $Window $CFG_ID_DOPPLER_SLIDER) (To-NormalizedPosition $Doppler 0 100) 'Doppler slider'
    Assert-Equal (Get-SliderPosition $Window $CFG_ID_DENSITY_SLIDER) (To-NormalizedPosition $Density 50 200) 'star density slider'
    Assert-Equal (Get-SliderPosition $Window $CFG_ID_SPEED_SLIDER) (To-NormalizedPosition $Speed 0 500) 'sky flow speed slider'
}

function Set-NormalizedSliderValue([IntPtr]$Window, [int]$ControlId, [int]$Value, [int]$Minimum, [int]$Maximum) {
    Set-SliderPosition $Window $ControlId (To-NormalizedPosition $Value $Minimum $Maximum)
}

function Send-Command([PSCustomObject]$Window, [int]$Command) {
    if (![Milestone7ConfigNative]::PostMessage($Window.Window, $WM_COMMAND, [IntPtr]$Command, [IntPtr]::Zero)) { Fail "could not send command $Command" }
}

function Click-Command([PSCustomObject]$Window, [int]$Command, [string]$Label) {
    Send-Command $Window $Command
    Wait-ForExit $Window.Process $Label
}

function Get-ChildRect([IntPtr]$Window, [int]$ControlId, [string]$Label) {
    $control = [Milestone7ConfigNative]::GetDlgItem($Window, $ControlId)
    if ($control -eq [IntPtr]::Zero) { Fail "$Label control $ControlId is missing" }
    $rect = New-Object Milestone7ConfigNative+RECT
    if (![Milestone7ConfigNative]::GetWindowRect($control, [ref]$rect)) { Fail "could not read $Label control $ControlId rectangle" }
    [void][Milestone7ConfigNative]::MapWindowPoints([IntPtr]::Zero, $Window, [ref]$rect, 2)
    return $rect
}

function Assert-ControlsInsideClient([IntPtr]$Window, [int[]]$ControlIds, [string]$Label) {
    $client = New-Object Milestone7ConfigNative+RECT
    if (![Milestone7ConfigNative]::GetClientRect($Window, [ref]$client)) { Fail "could not read $Label client rectangle" }
    $rectangles = @()
    foreach ($controlId in $ControlIds) {
        $rect = Get-ChildRect $Window $controlId $Label
        if ($rect.Left -lt 0 -or $rect.Top -lt 0 -or $rect.Right -gt $client.Right -or $rect.Bottom -gt $client.Bottom) {
            Fail "$Label control $controlId is outside the client area"
        }
        $rectangles += [PSCustomObject]@{ Id = $controlId; Rect = $rect }
    }
    for ($left = 0; $left -lt $rectangles.Count; ++$left) {
        for ($right = $left + 1; $right -lt $rectangles.Count; ++$right) {
            $a = $rectangles[$left].Rect
            $b = $rectangles[$right].Rect
            if ($a.Left -lt $b.Right -and $a.Right -gt $b.Left -and $a.Top -lt $b.Bottom -and $a.Bottom -gt $b.Top) {
                Fail "$Label controls $($rectangles[$left].Id) and $($rectangles[$right].Id) overlap"
            }
        }
    }
}

function Assert-RejectedMode([string]$Arguments) {
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (!$process.Start()) { Fail "could not start rejected mode $Arguments" }
    if (!$process.WaitForExit(3000)) {
        Stop-Process -Id $process.Id -Force
        Fail "malformed mode $Arguments did not reject"
    }
    if ($process.ExitCode -ne 0) { Fail "malformed mode $Arguments exited with code $($process.ExitCode)" }
}

if (!(Test-Path -LiteralPath $Executable -PathType Leaf)) { Fail "executable is missing: $Executable" }

try {
    if ($hadOriginalKey) { Invoke-Reg @('export', $registryKey, $backupPath, '/y') }

    # Strict mode parsing must not let malformed requests fall into fullscreen.
    Assert-RejectedMode '/p 0'
    Assert-RejectedMode '/p123'
    Assert-RejectedMode '/w unexpected'
    Assert-RejectedMode '/d unexpected'

    # Missing marker/defaults: the shared /c settings window remains read-only.
    Clear-TestKey
    $config = Start-Window '/c' $SETTINGS_WND_CLASS '/c missing-key configuration'
    Assert-Sliders $config.Window 30 90 60 100 100
    Assert-ControlsInsideClient $config.Window @((201..212) + (251..255)) '/c initial layout'
    if (![Milestone7ConfigNative]::SetWindowPos($config.Window, [IntPtr]::Zero, 0, 0, 600, 420, $SWP_NOMOVE -bor $SWP_NOZORDER)) { Fail 'could not resize /c settings window' }
    Start-Sleep -Milliseconds 150
    Assert-ControlsInsideClient $config.Window @((201..212) + (251..255)) '/c resized layout'
    Close-Window $config '/c missing-key close'
    if (Test-Path -LiteralPath $registryProviderKey) { Fail 'missing-key fallback unexpectedly created a registry key' }

    # Both legacy forms read only the legacy values, ignoring any stray v2 data.
    Clear-TestKey
    Set-Dword 'StarBrightness' 7
    Set-Dword 'DiskOpacity' 51
    Set-Dword 'Doppler' 99
    Set-Dword 'StarDensity' 200
    Set-Dword 'SkyFlowSpeed' 50
    $config = Start-Window '/c' $SETTINGS_WND_CLASS '/c unmarked legacy configuration'
    Assert-Sliders $config.Window 7 51 99 100 100
    Click-Command $config $CFG_ID_CANCEL '/c unmarked legacy cancel'
    Assert-NoValue 'ConfigSchemaVersion'
    Assert-Dword 'StarDensity' 200

    Clear-TestKey
    Set-Dword 'ConfigSchemaVersion' 1
    Set-Dword 'StarBrightness' 0
    Set-Dword 'DiskOpacity' 100
    Set-Dword 'Doppler' 45
    Set-Dword 'StarDensity' 200
    Set-Dword 'SkyFlowSpeed' 50
    $config = Start-Window '/c' $SETTINGS_WND_CLASS '/c schema-v1 configuration'
    Assert-Sliders $config.Window 0 100 45 100 100
    Close-Window $config '/c schema-v1 close'
    Assert-Dword 'ConfigSchemaVersion' 1

    # Schema v2 remains compatible, including its historical 50..200% speed range.
    Clear-TestKey
    Set-Dword 'ConfigSchemaVersion' 2
    Set-Dword 'StarBrightness' 12
    Set-Dword 'DiskOpacity' 34
    Set-Dword 'Doppler' 56
    Set-Dword 'StarDensity' 200
    Set-Dword 'SkyFlowSpeed' 50
    $config = Start-Window '/c' $SETTINGS_WND_CLASS '/c schema-v2 configuration'
    Assert-Sliders $config.Window 12 34 56 200 50
    Close-Window $config '/c schema-v2 close'

    # Schema v3 independently defaults malformed/out-of-range fields while
    # accepting a stopped (0%) or fast (500%) sky flow.
    Clear-TestKey
    Set-Dword 'ConfigSchemaVersion' 3
    Set-Dword 'StarBrightness' 12
    Set-String 'DiskOpacity' 'bad'
    Set-Dword 'Doppler' 56
    Set-Dword 'StarDensity' 49
    Set-Dword 'SkyFlowSpeed' 500
    $config = Start-Window '/c' $SETTINGS_WND_CLASS '/c schema-v3 configuration'
    Assert-Sliders $config.Window 12 90 56 100 500
    Close-Window $config '/c schema-v3 close'

    Clear-TestKey
    Set-Dword 'ConfigSchemaVersion' 3
    Set-Dword 'SkyFlowSpeed' 501
    $config = Start-Window '/c' $SETTINGS_WND_CLASS '/c schema-v3 speed ceiling configuration'
    Assert-Sliders $config.Window 30 90 60 100 100
    Close-Window $config '/c schema-v3 speed ceiling close'

    # Marker zero is deliberately invalid after an interrupted v3 save.
    Clear-TestKey
    Set-Dword 'ConfigSchemaVersion' 0
    Set-Dword 'StarBrightness' 12
    Set-Dword 'StarDensity' 200
    $config = Start-Window '/c' $SETTINGS_WND_CLASS '/c interrupted-save configuration'
    Assert-Sliders $config.Window 30 90 60 100 100
    Close-Window $config '/c interrupted-save close'

    # Invalid current marker or future marker defaults the entire schema.
    Clear-TestKey
    Set-String 'ConfigSchemaVersion' 'bad'
    Set-Dword 'StarBrightness' 1
    $config = Start-Window '/c' $SETTINGS_WND_CLASS '/c wrong-type schema configuration'
    Assert-Sliders $config.Window 30 90 60 100 100
    Close-Window $config '/c wrong-type schema close'

    Clear-TestKey
    Set-Dword 'ConfigSchemaVersion' 4
    Set-Dword 'StarBrightness' 1
    $config = Start-Window '/c' $SETTINGS_WND_CLASS '/c future schema configuration'
    Assert-Sliders $config.Window 30 90 60 100 100
    Close-Window $config '/c future schema close'

    # Explicit /c OK maps normalized sliders to physical values and publishes v3 last.
    Clear-TestKey
    $config = Start-Window '/c' $SETTINGS_WND_CLASS '/c persistence configuration'
    Set-NormalizedSliderValue $config.Window $CFG_ID_STAR_SLIDER 12 0 100
    Set-NormalizedSliderValue $config.Window $CFG_ID_DISK_SLIDER 34 0 100
    Set-NormalizedSliderValue $config.Window $CFG_ID_DOPPLER_SLIDER 56 0 100
    Set-NormalizedSliderValue $config.Window $CFG_ID_DENSITY_SLIDER 200 50 200
    Set-NormalizedSliderValue $config.Window $CFG_ID_SPEED_SLIDER 500 0 500
    Click-Command $config $CFG_ID_OK '/c OK'
    Assert-Dword 'ConfigSchemaVersion' 3
    Assert-Dword 'StarBrightness' 12
    Assert-Dword 'DiskOpacity' 34
    Assert-Dword 'Doppler' 56
    Assert-Dword 'StarDensity' 200
    Assert-Dword 'SkyFlowSpeed' 500

    # /w owns a pure renderer plus a floating owned settings window. The shared
    # settings controls update it live; Save/Revert/close preserve snapshot rules.
    $adjustment = Start-Window '/w' $RENDERER_WND_CLASS '/w renderer window'
    $palette = Wait-ForSettingsPalette $adjustment.Process '/w floating settings window'
    Assert-Equal ([Milestone7ConfigNative]::GetWindow($palette, $GW_OWNER).ToInt64()) $adjustment.Window.ToInt64() '/w palette owner'
    Assert-Equal (Get-SliderPosition $palette $ADJ_ID_STAR_SLIDER) 120 '/w initial star brightness'
    Assert-Equal (Get-SliderPosition $palette $ADJ_ID_DENSITY_SLIDER) 1000 '/w initial star density'
    Assert-Equal (Get-SliderPosition $palette $ADJ_ID_SPEED_SLIDER) 1000 '/w initial sky speed'
    Assert-ControlsInsideClient $palette @((201..212) + (251..255)) '/w initial floating layout'
    if (![Milestone7ConfigNative]::SetWindowPos($palette, [IntPtr]::Zero, 0, 0, 600, 420, $SWP_NOMOVE -bor $SWP_NOZORDER)) { Fail 'could not resize /w palette' }
    Start-Sleep -Milliseconds 150
    Assert-ControlsInsideClient $palette @((201..212) + (251..255)) '/w resized floating layout'
    $paletteWindow = [PSCustomObject]@{ Process = $adjustment.Process; Window = $palette }
    Set-NormalizedSliderValue $palette $ADJ_ID_STAR_SLIDER 88 0 100
    Set-NormalizedSliderValue $palette $ADJ_ID_DENSITY_SLIDER 50 50 200
    Set-NormalizedSliderValue $palette $ADJ_ID_SPEED_SLIDER 0 0 500
    Send-Command $paletteWindow $ADJ_ID_SAVE
    Start-Sleep -Milliseconds 100
    Assert-Dword 'StarBrightness' 88
    Assert-Dword 'StarDensity' 50
    Assert-Dword 'SkyFlowSpeed' 0
    Set-NormalizedSliderValue $palette $ADJ_ID_STAR_SLIDER 12 0 100
    Set-NormalizedSliderValue $palette $ADJ_ID_DENSITY_SLIDER 200 50 200
    Set-NormalizedSliderValue $palette $ADJ_ID_SPEED_SLIDER 500 0 500
    Send-Command $paletteWindow $ADJ_ID_REVERT
    Start-Sleep -Milliseconds 100
    Assert-Equal (Get-SliderPosition $palette $ADJ_ID_STAR_SLIDER) 880 '/w reverted saved star brightness'
    Assert-Equal (Get-SliderPosition $palette $ADJ_ID_DENSITY_SLIDER) 0 '/w reverted saved star density'
    Assert-Equal (Get-SliderPosition $palette $ADJ_ID_SPEED_SLIDER) 0 '/w reverted saved sky speed'
    Set-NormalizedSliderValue $palette $ADJ_ID_STAR_SLIDER 77 0 100
    Close-Window $paletteWindow '/w floating-settings close'
    Assert-Dword 'StarBrightness' 88
    Assert-Dword 'StarDensity' 50
    Assert-Dword 'SkyFlowSpeed' 0

    Write-Host 'Milestone 7 runtime configuration and /w adjustment contract verified.'
}
finally {
    Clear-TestKey
    if ($hadOriginalKey) { Invoke-Reg @('import', $backupPath) }
    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
}
