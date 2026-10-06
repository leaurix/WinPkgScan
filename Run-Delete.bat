@echo off
rem ============================================================
rem Run-Delete.bat
rem Deletes the folders marked "Yes" in the Delete column of the
rem scanner's CSV. Moves them to the Recycle Bin and asks before
rem each one.
rem
rem Double-click: uses Orphaned-Appx-Packages.csv on the Desktop.
rem Or drag a CSV file onto this file.
rem Preview only: Run-Delete.bat -WhatIf
rem ============================================================
setlocal
set "SCRIPT=%~dp0Remove-OrphanedAppxFolders.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Remove-OrphanedAppxFolders.ps1 was not found next to this file.
    echo Expected: %SCRIPT%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
