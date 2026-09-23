@echo off
rem ============================================================
rem Run-Scan.bat
rem Double-click to run the orphaned AppX folder scan.
rem Read-only: nothing is deleted or modified.
rem ============================================================
setlocal
set "SCRIPT=%~dp0Find-OrphanedAppxFolders.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Find-OrphanedAppxFolders.ps1 was not found next to this file.
    echo Expected: %SCRIPT%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%