@echo off
rem ============================================================
rem Install.bat
rem Installs WinPkgScan for you (no administrator rights needed):
rem copies it to %LOCALAPPDATA%\Programs\WinPkgScan, adds Start menu
rem and desktop shortcuts, and starts the app.
rem
rem   Install.bat                       install or update
rem   Install.bat -NoDesktopShortcut    Start menu shortcut only
rem   Install.bat -Uninstall            remove it again
rem ============================================================
setlocal
set "INSTALLER=%~dp0Install.ps1"

if not exist "%INSTALLER%" goto missing

rem -Launch starts the app after installing. It is ignored with -Uninstall.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Launch %*
exit /b %ERRORLEVEL%

:missing
echo ERROR: Install.ps1 was not found next to this file.
echo Extract the whole WinPkgScan zip, then run Install.bat from that folder.
pause
exit /b 1
