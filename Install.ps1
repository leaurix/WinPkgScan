<#
.SYNOPSIS
    Installs WinPkgScan for the current user, with Start menu and desktop
    shortcuts to the app. Also uninstalls it.

.DESCRIPTION
    Copies the WinPkgScan files to %LOCALAPPDATA%\Programs\WinPkgScan, adds
    a "WinPkgScan" shortcut to the Start menu and the desktop, and adds
    WinPkgScan to Settings > Apps so it can be uninstalled there.
    No administrator rights are needed.

    Run it again from a newer download to update. Your exclude list in the
    install folder is kept.

    -Uninstall removes the files, the shortcuts and the Settings entry. It
    only removes the WinPkgScan files: anything else in the folder is left.
    Your scan history, settings and exclude list in
    %LOCALAPPDATA%\WinPkgScan are kept unless you add -RemoveData.

.PARAMETER Uninstall
    Remove WinPkgScan instead of installing it.

.PARAMETER InstallPath
    Where to install. Default: %LOCALAPPDATA%\Programs\WinPkgScan

.PARAMETER NoDesktopShortcut
    Do not add a desktop shortcut. The Start menu shortcut is still added.

.PARAMETER NoShortcuts
    Do not add any shortcuts.

.PARAMETER NoUninstallEntry
    Do not add WinPkgScan to Settings > Apps.

.PARAMETER Launch
    Start the app when the install has finished.

.PARAMETER RemoveData
    With -Uninstall: also delete %LOCALAPPDATA%\WinPkgScan (scan history,
    settings, your exclude list and the app's scan results).

.PARAMETER StartMenuPath
    Folder for the Start menu shortcut. Default: your Start menu Programs
    folder.

.PARAMETER DesktopPath
    Folder for the desktop shortcut. Default: your desktop.

.PARAMETER UninstallKey
    Registry key for the Settings > Apps entry.

.PARAMETER NoPause
    Never pause at the end. The script only pauses when it opened its own
    window (Install.bat or Settings > Apps), not when run from an open
    PowerShell prompt.

.EXAMPLE
    .\Install.ps1
    Installs WinPkgScan with Start menu and desktop shortcuts.

.EXAMPLE
    .\Install.ps1 -Uninstall
    Removes WinPkgScan, and keeps your history and settings.

.NOTES
    Version: 1.8.0
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Uninstall,

    [string]$InstallPath,

    [switch]$NoDesktopShortcut,

    [switch]$NoShortcuts,

    [switch]$NoUninstallEntry,

    [switch]$Launch,

    [switch]$RemoveData,

    [string]$StartMenuPath,

    [string]$DesktopPath,

    [string]$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WinPkgScan',

    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = "1.8.0"

# Files that make up WinPkgScan. The first four are required.
$RequiredFiles = @(
    'Find-OrphanedAppxFolders.ps1', 'Remove-OrphanedAppxFolders.ps1',
    'Restore-OrphanedAppxFolders.ps1', 'WinPkgScan-App.ps1'
)
$OptionalFiles = @(
    'WinPkgScan.bat', 'WinPkgScan-App.bat', 'Run-Scan.bat', 'Run-Scan-Unattended.bat', 'Run-Delete.bat',
    'WinPkgScan.exclude.txt', 'WinPkgScan.ico', 'README.md', 'LICENSE', 'Install.ps1', 'Install.bat'
)
$MarkerName   = 'WinPkgScan.install'
$ShortcutName = 'WinPkgScan.lnk'

# Pause at the end only when this script opened its own window, so the
# window does not close before you can read it.
$PauseAtEnd = $false
if (-not $NoPause.IsPresent) {
    try {
        $PauseAtEnd = (-not [Console]::IsInputRedirected) -and
            ([Environment]::CommandLine.IndexOf([System.IO.Path]::GetFileName($PSCommandPath), [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    catch {
        $PauseAtEnd = $false
    }
}

function Exit-Script {
    param([int]$Code = 0)
    if ($PauseAtEnd) {
        Write-Host ""
        Read-Host "Press Enter to exit" | Out-Null
    }
    exit $Code
}

function Get-DefaultInstallPath {
    return Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'WinPkgScan'
}

function Get-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-SamePath {
    param([string]$A, [string]$B)
    return [string]::Equals((Get-FullPath $A), (Get-FullPath $B), [StringComparison]::OrdinalIgnoreCase)
}

function Get-AppLaunchArgument {
    # powershell.exe arguments that start the app without a console window.
    param([string]$Folder)
    return '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + (Join-Path $Folder 'WinPkgScan-App.ps1') + '"'
}

function Get-WindowsPowerShellPath {
    $path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($env:SystemRoot -and (Test-Path -LiteralPath $path)) { return $path }
    return 'powershell.exe'
}

function Get-ShortcutPath {
    # Where the shortcuts go: Start menu always, desktop unless turned off.
    param([string]$StartMenu, [string]$Desktop, [bool]$NoDesktop, [bool]$NoLinks)
    $folders = @()
    if ($NoLinks) { return $folders }
    if (-not $StartMenu) { $StartMenu = [Environment]::GetFolderPath('Programs') }
    if ($StartMenu) { $folders += Join-Path $StartMenu $ShortcutName }
    if (-not $NoDesktop) {
        if (-not $Desktop) { $Desktop = [Environment]::GetFolderPath('Desktop') }
        if ($Desktop) { $folders += Join-Path $Desktop $ShortcutName }
    }
    return $folders
}

function Add-AppShortcut {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Path, [string]$Folder)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Add shortcut')) { return }
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath       = Get-WindowsPowerShellPath
    $link.Arguments        = Get-AppLaunchArgument -Folder $Folder
    $link.WorkingDirectory = $Folder
    $link.Description      = 'Find and safely remove leftover app folders'
    $link.WindowStyle      = 7
    $icon = Join-Path $Folder 'WinPkgScan.ico'
    if (Test-Path -LiteralPath $icon) { $link.IconLocation = "$icon,0" }
    $link.Save()
}

function Test-OurShortcut {
    # True if the shortcut starts the app in this install folder.
    param([string]$Path, [string]$Folder)
    try {
        $shell = New-Object -ComObject WScript.Shell
        $args0 = $shell.CreateShortcut($Path).Arguments
        return ($args0.IndexOf((Join-Path $Folder 'WinPkgScan-App.ps1'), [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    catch {
        return $false
    }
}

function Get-FolderSizeKB {
    param([string]$Folder)
    $bytes = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue)) { $bytes += $f.Length }
    return [int][math]::Ceiling($bytes / 1KB)
}

function Register-UninstallEntry {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Folder)
    if (-not $PSCmdlet.ShouldProcess('Settings > Apps', 'Add WinPkgScan')) { return }
    if (-not (Test-Path -LiteralPath $UninstallKey)) { New-Item -Path $UninstallKey -Force | Out-Null }
    $uninstall = '"' + (Get-WindowsPowerShellPath) + '" -NoProfile -ExecutionPolicy Bypass -File "' +
        (Join-Path $Folder 'Install.ps1') + '" -Uninstall'
    $values = [ordered]@{
        DisplayName     = 'WinPkgScan'
        DisplayVersion  = $ScriptVersion
        Publisher       = 'Louis Yvan Alcayde'
        InstallLocation = $Folder
        UninstallString = $uninstall
        URLInfoAbout    = 'https://github.com/leaurix/WinPkgScan'
        HelpLink        = 'https://github.com/leaurix/WinPkgScan#readme'
    }
    foreach ($key in $values.Keys) {
        New-ItemProperty -Path $UninstallKey -Name $key -Value $values[$key] -PropertyType String -Force | Out-Null
    }
    $icon = Join-Path $Folder 'WinPkgScan.ico'
    if (Test-Path -LiteralPath $icon) {
        New-ItemProperty -Path $UninstallKey -Name 'DisplayIcon' -Value $icon -PropertyType String -Force | Out-Null
    }
    foreach ($flag in 'NoModify', 'NoRepair') {
        New-ItemProperty -Path $UninstallKey -Name $flag -Value 1 -PropertyType DWord -Force | Out-Null
    }
    New-ItemProperty -Path $UninstallKey -Name 'EstimatedSize' -Value (Get-FolderSizeKB $Folder) -PropertyType DWord -Force | Out-Null
}

function Install-WinPkgScanFile {
    param([string]$Source, [string]$Target)
    if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
    $copied = 0
    foreach ($name in @($RequiredFiles) + @($OptionalFiles)) {
        $from = Join-Path $Source $name
        $to   = Join-Path $Target $name
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { continue }
        if ($name -eq 'WinPkgScan.exclude.txt' -and (Test-Path -LiteralPath $to)) {
            Write-Host "  Kept your exclude list: $to"
            continue
        }
        Copy-Item -LiteralPath $from -Destination $to -Force
        $copied++
    }
    Write-InstallMarker -Target $Target
    return $copied
}

function Write-InstallMarker {
    # Uninstall only removes files from a folder with this marker.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Target)
    $marker = Join-Path $Target $MarkerName
    if ($PSCmdlet.ShouldProcess($marker, 'Write install marker')) {
        Set-Content -LiteralPath $marker -Encoding ASCII -Value @(
            'WinPkgScan install folder. Install.ps1 -Uninstall only removes folders with this file.'
            "Version: $ScriptVersion"
            "Installed: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"
        )
    }
}

function Uninstall-WinPkgScanFile {
    # Removes the WinPkgScan files, then the folder if nothing else is left.
    param([string]$Target)
    $removed = 0
    foreach ($name in @($RequiredFiles) + @($OptionalFiles) + @($MarkerName)) {
        $path = Join-Path $Target $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
            $removed++
        }
    }
    if (@(Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $Target -Force
    }
    return $removed
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

if (-not $InstallPath) { $InstallPath = Get-DefaultInstallPath }
$InstallPath = Get-FullPath $InstallPath
$Source = $PSScriptRoot
$Marker = Join-Path $InstallPath $MarkerName
$Shortcuts = @(Get-ShortcutPath -StartMenu $StartMenuPath -Desktop $DesktopPath -NoDesktop $NoDesktopShortcut.IsPresent -NoLinks $NoShortcuts.IsPresent)

Write-Host ""
Write-Host "WinPkgScan $ScriptVersion $(if ($Uninstall) { 'uninstall' } else { 'install' })" -ForegroundColor Cyan
Write-Host "Folder: $InstallPath"
Write-Host ""

try {
    if ($Uninstall) {
        # Never delete from a folder this script did not install into.
        if ((Test-Path -LiteralPath $InstallPath) -and -not (Test-Path -LiteralPath $Marker)) {
            Write-Host "ERROR: $InstallPath is not a WinPkgScan install folder (no $MarkerName file). Nothing was removed." -ForegroundColor Red
            Exit-Script 1
        }
        # The folder cannot be removed while it is the current folder.
        if ((Get-Location).ProviderPath -and (Get-FullPath (Get-Location).ProviderPath).StartsWith($InstallPath, [StringComparison]::OrdinalIgnoreCase)) {
            Set-Location -LiteralPath ([System.IO.Path]::GetTempPath())
        }

        foreach ($link in $Shortcuts) {
            if ((Test-Path -LiteralPath $link) -and (Test-OurShortcut -Path $link -Folder $InstallPath)) {
                Remove-Item -LiteralPath $link -Force
                Write-Host "  Removed shortcut: $link"
            }
        }
        if (-not $NoUninstallEntry -and (Test-Path -LiteralPath $UninstallKey)) {
            Remove-Item -LiteralPath $UninstallKey -Recurse -Force
            Write-Host "  Removed WinPkgScan from Settings > Apps"
        }
        if (Test-Path -LiteralPath $InstallPath) {
            $count = Uninstall-WinPkgScanFile -Target $InstallPath
            Write-Host "  Removed $count file$(if ($count -ne 1) { 's' })"
            if (-not $WhatIfPreference -and (Test-Path -LiteralPath $InstallPath)) {
                Write-Host "  Kept the folder $InstallPath`: it has other files in it." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  WinPkgScan files were not found in $InstallPath."
        }

        $data = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'WinPkgScan' } else { $null }
        if ($RemoveData) {
            if ($data -and (Test-Path -LiteralPath $data)) {
                Remove-Item -LiteralPath $data -Recurse -Force
                Write-Host "  Removed your history and settings: $data"
            }
        }
        elseif ($data -and (Test-Path -LiteralPath $data)) {
            Write-Host "  Kept your history and settings: $data"
        }

        Write-Host ""
        if ($WhatIfPreference) { Write-Host "Preview only: nothing was changed." -ForegroundColor Green }
        else { Write-Host "WinPkgScan was uninstalled." -ForegroundColor Green }
        Exit-Script 0
    }

    # ---- Install ----
    $missing = @($RequiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Source $_) -PathType Leaf) })
    if ($missing.Count -gt 0) {
        Write-Host "ERROR: Missing $($missing -join ', ') next to Install.ps1. Run it from the extracted WinPkgScan folder." -ForegroundColor Red
        Exit-Script 1
    }
    $samePlace = Test-SamePath $Source $InstallPath
    if (-not $samePlace -and (Test-Path -LiteralPath $InstallPath) -and -not (Test-Path -LiteralPath $Marker) -and
        @(Get-ChildItem -LiteralPath $InstallPath -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Host "ERROR: $InstallPath already has other files in it. Choose an empty folder with -InstallPath." -ForegroundColor Red
        Exit-Script 1
    }

    if ($samePlace) {
        Write-InstallMarker -Target $InstallPath
        Write-Host "  Already in the install folder: files not copied."
    }
    else {
        $copied = Install-WinPkgScanFile -Source $Source -Target $InstallPath
        Write-Host "  Copied $copied file$(if ($copied -ne 1) { 's' })"
    }

    foreach ($link in $Shortcuts) {
        Add-AppShortcut -Path $link -Folder $InstallPath
        Write-Host "  Shortcut: $link"
    }
    if (-not $NoUninstallEntry) {
        Register-UninstallEntry -Folder $InstallPath
        Write-Host "  Added to Settings > Apps, where you can uninstall it"
    }

    Write-Host ""
    if ($WhatIfPreference) {
        Write-Host "Preview only: nothing was changed." -ForegroundColor Green
        Exit-Script 0
    }
    Write-Host "WinPkgScan $ScriptVersion is installed." -ForegroundColor Green
    if (-not $NoShortcuts) { Write-Host "Start it from the Start menu: WinPkgScan." }
    Write-Host "To uninstall: Settings > Apps, or run Install.ps1 -Uninstall."

    if ($Launch) {
        Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList (Get-AppLaunchArgument -Folder $InstallPath) `
            -WorkingDirectory $InstallPath -WindowStyle Hidden
    }
    Exit-Script 0
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Exit-Script 1
}
