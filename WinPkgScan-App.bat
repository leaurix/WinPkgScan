@echo off
rem ============================================================
rem WinPkgScan-App.bat
rem Opens the WinPkgScan app (preview): scan, tick folders,
rem preview, move to the Recycle Bin and restore, in one window.
rem ============================================================
setlocal
set "APP=%~dp0WinPkgScan-App.ps1"

if not exist "%APP%" goto missing

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%APP%"
exit /b 0

:missing
echo ERROR: WinPkgScan-App.ps1 was not found next to this file.
echo Keep WinPkgScan-App.bat in the same folder as the .ps1 files.
pause
exit /b 1
