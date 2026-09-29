@echo off
REM Build script for Black Hole Windows Screensaver.
REM Uses an active MSVC Developer Prompt when available, otherwise locates a
REM installed Visual Studio toolchain before falling back to MinGW-w64 or Zig.

setlocal EnableExtensions
pushd "%~dp0" >nul || exit /b 1

REM Prefer an already-configured MSVC environment.
where cl >nul 2>&1
if not errorlevel 1 goto :build_msvc

REM Explorer and a normal cmd.exe do not inherit VsDevCmd. Discover MSVC so a
REM double-clicked build.bat creates a fresh .scr instead of using stale output.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :try_gcc

for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSINSTALL=%%I"
if not defined VSINSTALL goto :try_gcc
if not exist "%VSINSTALL%\Common7\Tools\VsDevCmd.bat" goto :try_gcc

echo Preparing MSVC environment...
call "%VSINSTALL%\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64 >nul
where cl >nul 2>&1
if not errorlevel 1 goto :build_msvc

:try_gcc
where gcc >nul 2>&1
if not errorlevel 1 goto :build_gcc

:try_zig
where zig >nul 2>&1
if not errorlevel 1 goto :build_zig

echo ERROR: No compiler found. Install one of:
echo   - Visual Studio Build Tools (C++ desktop tools)
echo   - MinGW-w64 (gcc)
echo   - Zig (zig cc)
goto :build_failed

:build_msvc
echo Building with MSVC...
cl /O2 /W3 /nologo ^
    /DWIN32_LEAN_AND_MEAN /D_CRT_SECURE_NO_WARNINGS ^
    /DGL_GLEXT_PROTOTYPES ^
    /Fe:blackhole.scr ^
    blackhole_screensaver.c opengl32.lib user32.lib gdi32.lib advapi32.lib shell32.lib ^
    /link /SUBSYSTEM:WINDOWS /ENTRY:WinMainCRTStartup
if errorlevel 1 goto :build_failed
goto :build_succeeded

:build_gcc
echo Building with MinGW...
gcc -O2 -Wall -mwindows ^
    -DWIN32_LEAN_AND_MEAN -D_CRT_SECURE_NO_WARNINGS ^
    -o blackhole.scr ^
    blackhole_screensaver.c -lglu32 -lopengl32 -luser32 -lgdi32 -ladvapi32 -lshell32
if errorlevel 1 goto :build_failed
goto :build_succeeded

:build_zig
echo Building with Zig...
zig cc -O2 -target x86_64-windows-gnu ^
    -DWIN32_LEAN_AND_MEAN -D_CRT_SECURE_NO_WARNINGS ^
    -o blackhole.scr ^
    blackhole_screensaver.c -lglu32 -lopengl32 -luser32 -lgdi32 -ladvapi32 -lshell32
if errorlevel 1 goto :build_failed
goto :build_succeeded

:build_succeeded
echo.
echo Build successful: blackhole.scr
echo Copy to %%SYSTEMROOT%%\System32\ and double-click to install.
popd
endlocal
exit /b 0

:build_failed
echo.
echo ERROR: Build failed. blackhole.scr was not refreshed.
popd
endlocal
exit /b 1
