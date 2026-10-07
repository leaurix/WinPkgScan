@echo off
rem ============================================================
rem Run-Scan.bat
rem Double-click to run the orphaned AppX folder scan.
rem Read-only: nothing is deleted or modified.
rem Also saves a CSV for Remove-OrphanedAppxFolders.ps1 and an HTML report.
rem ============================================================
setlocal
set "SCRIPT=%~dp0Find-OrphanedAppxFolders.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Find-OrphanedAppxFolders.ps1 was not found next to this file.
    echo Expected: %SCRIPT%
    pause
    exit /b 1
)

rem Always save the CSV and the HTML report, unless already passed in.
rem When double-clicked (no arguments), also open the HTML report.
set "EXTRA="
echo.%* | findstr /i /c:"-Csv" >nul || set "EXTRA=%EXTRA% -Csv"
echo.%* | findstr /i /c:"-Html" >nul || set "EXTRA=%EXTRA% -Html"
if "%~1"=="" set "EXTRA=%EXTRA% -Open"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %EXTRA% %*
exit /b %ERRORLEVEL%
