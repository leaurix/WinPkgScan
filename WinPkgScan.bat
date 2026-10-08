@echo off
rem ============================================================
rem WinPkgScan.bat
rem One menu for everything: double-click to open it.
rem
rem Direct commands (no menu, no pauses), for scripts or Task Scheduler:
rem   WinPkgScan.bat scan     [options]
rem   WinPkgScan.bat preview  [options]
rem   WinPkgScan.bat delete   [options]   e.g. delete -Force
rem   WinPkgScan.bat restore  [options]
rem Options are passed to the PowerShell script.
rem ============================================================
setlocal EnableExtensions
set "HERE=%~dp0"
set "SCAN=%HERE%Find-OrphanedAppxFolders.ps1"
set "REMOVE=%HERE%Remove-OrphanedAppxFolders.ps1"
set "RESTORE=%HERE%Restore-OrphanedAppxFolders.ps1"
set "PS=powershell.exe -NoProfile -ExecutionPolicy Bypass -File"

if not exist "%SCAN%" goto missing
if not exist "%REMOVE%" goto missing
if not exist "%RESTORE%" goto missing

rem ---- Direct commands ------------------------------------------
set "CMD=%~1"
set "REST="
if "%CMD%"=="" goto menu
:collect
shift
if "%~1"=="" goto dispatch
set REST=%REST% %1
goto collect

:dispatch
if /i "%CMD%"=="scan"    goto direct_scan
if /i "%CMD%"=="preview" goto direct_preview
if /i "%CMD%"=="delete"  goto direct_delete
if /i "%CMD%"=="restore" goto direct_restore
echo Unknown command: %CMD%
echo Use: WinPkgScan.bat [scan ^| preview ^| delete ^| restore] [options]
exit /b 2

:direct_scan
%PS% "%SCAN%" -Csv -Html -NoPause %REST%
exit /b %ERRORLEVEL%

:direct_preview
%PS% "%REMOVE%" -WhatIf -NoPause %REST%
exit /b %ERRORLEVEL%

:direct_delete
%PS% "%REMOVE%" -NoPause %REST%
exit /b %ERRORLEVEL%

:direct_restore
%PS% "%RESTORE%" -NoPause %REST%
exit /b %ERRORLEVEL%

rem ---- Menu ------------------------------------------------------
:menu
cls
echo.
echo   WinPkgScan
echo   ==========
echo.
echo   1  Scan and open the HTML report
echo   2  Scan as administrator - extra checks
echo   3  Open the last HTML report
echo   4  Preview delete - changes nothing
echo   5  Delete marked folders - Recycle Bin, asks before each one
echo   6  Restore folders from the last delete
echo   7  Edit exclusions
echo   8  Help - README
echo   0  Exit
echo.
echo   To mark folders: tick them in the HTML report and click Save marked CSV.
echo.
choice /c 123456780 /n /m "  Choose 1-8, or 0 to exit: "
set "PICK=%ERRORLEVEL%"
echo.
if "%PICK%"=="1" goto m_scan
if "%PICK%"=="2" goto m_admin
if "%PICK%"=="3" goto m_open
if "%PICK%"=="4" goto m_preview
if "%PICK%"=="5" goto m_delete
if "%PICK%"=="6" goto m_restore
if "%PICK%"=="7" goto m_exclude
if "%PICK%"=="8" goto m_help
goto end

:m_scan
%PS% "%SCAN%" -Csv -Html -Open -NoPause
goto back

:m_admin
echo Windows will ask for administrator permission. The scan opens in a new window.
set "WPS_SCRIPT=%SCAN%"
powershell.exe -NoProfile -Command "Start-Process -Verb RunAs -FilePath powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File \"' + $env:WPS_SCRIPT + '\" -Csv -Html -Open')"
goto back

:m_open
set "DESKTOP="
for /f "usebackq delims=" %%D in (`powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('Desktop')"`) do set "DESKTOP=%%D"
if exist "%DESKTOP%\Orphaned-Appx-Packages.html" goto m_open_ok
echo No HTML report on your Desktop yet. Choose 1 to scan first.
goto back
:m_open_ok
start "" "%DESKTOP%\Orphaned-Appx-Packages.html"
goto menu

:m_preview
%PS% "%REMOVE%" -WhatIf -NoPause
goto back

:m_delete
%PS% "%REMOVE%" -NoPause
goto back

:m_restore
%PS% "%RESTORE%" -NoPause
goto back

:m_exclude
start "" notepad.exe "%HERE%WinPkgScan.exclude.txt"
goto menu

:m_help
start "" notepad.exe "%HERE%README.md"
goto menu

:back
echo.
pause
goto menu

:missing
echo ERROR: The WinPkgScan scripts were not found next to this file.
echo Keep WinPkgScan.bat in the same folder as the .ps1 files.
pause
exit /b 1

:end
endlocal
exit /b 0
