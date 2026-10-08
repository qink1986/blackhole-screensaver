[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Executable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Milestone6SmokeNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    public static extern IntPtr OpenEvent(uint desiredAccess, bool inheritHandle, string name);
    [DllImport("kernel32.dll")]
    public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr handle);
}
'@

$SYNCHRONIZE = 0x00100000
$WAIT_OBJECT_0 = 0

function Fail([string]$Message) {
    throw "Milestone 6 runtime contract failure: $Message"
}

if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    Fail "Executable is missing: $Executable"
}

# /d uses the normal non-preview renderer. The host sets this event only after
# an OpenGL 3.3 context has compiled/linked the embedded canonical shader and
# completed its hidden first present. Unlike process liveness, this cannot pass
# when an initialization-error dialog has kept a failed process alive.
$eventName = 'Local\BlackHoleM6ShaderSmoke-' + [Guid]::NewGuid().ToString('N')
$previousEventName = [Environment]::GetEnvironmentVariable('BLACKHOLE_SHADER_SMOKE_EVENT', 'Process')
$eventHandle = [IntPtr]::Zero
$process = $null
$passed = $false
try {
    [Environment]::SetEnvironmentVariable('BLACKHOLE_SHADER_SMOKE_EVENT', $eventName, 'Process')
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $Executable) -ArgumentList '/d' -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) {
            Fail "/d exited before shader compile/link and first-present confirmation with code $($process.ExitCode)"
        }
        if ($eventHandle -eq [IntPtr]::Zero) {
            $eventHandle = [Milestone6SmokeNative]::OpenEvent($SYNCHRONIZE, $false, $eventName)
        }
        if ($eventHandle -ne [IntPtr]::Zero -and [Milestone6SmokeNative]::WaitForSingleObject($eventHandle, 0) -eq $WAIT_OBJECT_0) {
            $passed = $true
            break
        }
        Start-Sleep -Milliseconds 50
    }
    if (-not $passed) {
        Fail '/d did not confirm OpenGL shader compile/link and hidden first present within five seconds'
    }
}
finally {
    if ($eventHandle -ne [IntPtr]::Zero) {
        [void][Milestone6SmokeNative]::CloseHandle($eventHandle)
    }
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
    [Environment]::SetEnvironmentVariable('BLACKHOLE_SHADER_SMOKE_EVENT', $previousEventName, 'Process')
}

Write-Host 'Milestone 6 OpenGL shader compile/link and first-present smoke verified.'
