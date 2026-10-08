@echo off
REM Build script for Black Hole Windows Screensaver.
REM Generates the canonical GLSL C include, then uses an active MSVC Developer
REM Prompt when available or locates MSVC before falling back to MinGW-w64/Zig.
REM A compiler or generator failure never replaces the existing blackhole.scr.

setlocal EnableExtensions
pushd "%~dp0" >nul || exit /b 1

REM The generated include is checked in for direct compiler use, but build.bat
REM always refreshes it atomically from the canonical GLSL source first.
echo Generating shader include...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\generate-shader-include.ps1
if errorlevel 1 goto :build_failed

REM Create a collision-resistant sibling output so failed compilers cannot
REM truncate or replace the release artifact. A same-directory move promotes
REM it only after successful compilation/linking.
:make_build_temp
set "BUILD_TOKEN="
for /f "usebackq delims=" %%I in (`powershell.exe -NoProfile -Command "[System.IO.Path]::GetRandomFileName()" 2^>nul`) do if not defined BUILD_TOKEN set "BUILD_TOKEN=%%I"
if not defined BUILD_TOKEN (
    echo ERROR: Could not create a temporary build name.
    goto :build_failed
)
set "BUILD_TMP=blackhole-%BUILD_TOKEN%.scr"
if exist "%BUILD_TMP%" goto :make_build_temp

REM Prefer an already-configured MSVC environment.
where cl >nul 2>&1
if not errorlevel 1 goto :build_msvc

REM Explorer and a normal cmd.exe do not inherit VsDevCmd. Discover MSVC so a
REM double-clicked build.bat does not use stale output after a failed build.
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
    /Fe:"%BUILD_TMP%" ^
    blackhole_screensaver.c opengl32.lib user32.lib gdi32.lib advapi32.lib shell32.lib ^
    /link /SUBSYSTEM:WINDOWS /ENTRY:WinMainCRTStartup
if errorlevel 1 goto :build_failed
goto :build_succeeded

:build_gcc
echo Building with MinGW...
gcc -O2 -Wall -mwindows ^
    -DWIN32_LEAN_AND_MEAN -D_CRT_SECURE_NO_WARNINGS ^
    -o "%BUILD_TMP%" ^
    blackhole_screensaver.c -lglu32 -lopengl32 -luser32 -lgdi32 -ladvapi32 -lshell32
if errorlevel 1 goto :build_failed
goto :build_succeeded

:build_zig
echo Building with Zig...
zig cc -O2 -target x86_64-windows-gnu ^
    -DWIN32_LEAN_AND_MEAN -D_CRT_SECURE_NO_WARNINGS ^
    -o "%BUILD_TMP%" ^
    blackhole_screensaver.c -lglu32 -lopengl32 -luser32 -lgdi32 -ladvapi32 -lshell32
if errorlevel 1 goto :build_failed
goto :build_succeeded

:build_succeeded
if not exist "%BUILD_TMP%" (
    echo ERROR: Compiler reported success but did not create %BUILD_TMP%.
    goto :build_failed
)
move /y "%BUILD_TMP%" blackhole.scr >nul
if errorlevel 1 (
    echo ERROR: Could not promote the completed temporary build.
    goto :build_failed
)
if exist "%BUILD_TMP%.manifest" del /q "%BUILD_TMP%.manifest" >nul 2>&1
echo.
echo Build successful: blackhole.scr
echo Copy to %%SYSTEMROOT%%\System32\ and double-click to install.
popd
endlocal
exit /b 0

:build_failed
if defined BUILD_TMP if exist "%BUILD_TMP%" del /q "%BUILD_TMP%" >nul 2>&1
if defined BUILD_TMP if exist "%BUILD_TMP%.manifest" del /q "%BUILD_TMP%.manifest" >nul 2>&1
echo.
echo ERROR: Build failed. blackhole.scr was not refreshed.
popd
endlocal
exit /b 1
