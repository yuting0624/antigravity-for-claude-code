@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "TARGET_SCRIPT=%SCRIPT_DIR%..\scripts\agy-delegate.sh"

where bash >nul 2>&1
if %ERRORLEVEL% equ 0 (
    bash "%TARGET_SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

where sh >nul 2>&1
if %ERRORLEVEL% equ 0 (
    sh "%TARGET_SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

if exist "%ProgramFiles%\Git\bin\bash.exe" (
    "%ProgramFiles%\Git\bin\bash.exe" "%TARGET_SCRIPT%" %*
    exit /b %ERRORLEVEL%
)
if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" (
    "%ProgramFiles(x86)%\Git\bin\bash.exe" "%TARGET_SCRIPT%" %*
    exit /b %ERRORLEVEL%
)
if exist "%LocalAppData%\Programs\Git\bin\bash.exe" (
    "%LocalAppData%\Programs\Git\bin\bash.exe" "%TARGET_SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

echo error: bash or sh is required to run this command, but neither was found on PATH or in standard Git installation paths. >&2
exit /b 1
