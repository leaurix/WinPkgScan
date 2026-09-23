@echo off
rem ============================================================
rem Run-Scan-Unattended.bat
rem For Task Scheduler or scripts: runs without the final prompt.
rem Optional: pass -ReportPath "C:\path\report.txt"
rem Exit code: 0 = success, 1 = error.
rem ============================================================
setlocal
set "SCRIPT=%~dp0Find-OrphanedAppxFolders.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Find-OrphanedAppxFolders.ps1 was not found next to this file.
    exit /b 1
)

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT%" -NoPause %*
exit /b %ERRORLEVEL%