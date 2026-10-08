<#
.SYNOPSIS
    Puts folders removed by Remove-OrphanedAppxFolders.ps1 back from the
    Recycle Bin.

.DESCRIPTION
    Reads a delete log (WinPkgScan-DeleteLog-*.csv) and restores every
    folder with the action "Recycled" to where it was.

    - Folders deleted with -Permanent cannot be restored.
    - A folder is skipped if something already exists at its original path,
      or if it is no longer in the Recycle Bin.
    - Only folders from your own %LOCALAPPDATA%\Packages are restored.

.PARAMETER LogPath
    The delete log to read. If not given, the newest
    WinPkgScan-DeleteLog-*.csv on your Desktop or in your Downloads folder
    is used.

.PARAMETER SearchFolder
    Folders to look in when -LogPath is not given. Defaults to your Desktop
    and Downloads folders.

.PARAMETER Name
    Only restore folders whose name matches. Wildcards allowed.

.PARAMETER NoPause
    Skip the "Press Enter to exit" prompt.

.EXAMPLE
    .\Restore-OrphanedAppxFolders.ps1 -WhatIf
    Shows what would be restored from the newest delete log.

.EXAMPLE
    .\Restore-OrphanedAppxFolders.ps1 -Name 'Contoso.*'

.NOTES
    Version: 1.6.0
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Position = 0)]
    [string]$LogPath,

    [string[]]$SearchFolder,

    [string[]]$Name,

    [switch]$NoPause
)

$ScriptVersion = "1.6.0"
$PauseAtEnd    = -not $NoPause.IsPresent

function Exit-Script {
    param([int]$Code = 0)
    if ($PauseAtEnd) {
        Write-Host ""
        Read-Host "Press Enter to exit" | Out-Null
    }
    exit $Code
}

function Get-DesktopFolder {
    $path = [Environment]::GetFolderPath("Desktop")
    if ([string]::IsNullOrWhiteSpace($path)) { $path = Join-Path $env:USERPROFILE "Desktop" }
    return $path
}

function Get-DownloadsFolder {
    # The Downloads folder can be moved, so ask Windows where it is.
    $key  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
    $name = '{374DE290-123F-4565-9164-39C4925E467B}'
    try {
        $value = (Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name
        if ($value) { return $value }
    }
    catch {
        Write-Verbose "Downloads folder not found in the registry: $($_.Exception.Message)"
    }
    $base = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    return Join-Path $base "Downloads"
}

function Find-NewestFile {
    param([string[]]$Folders, [string[]]$Patterns)
    $found = foreach ($folder in $Folders) {
        if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) {
            foreach ($pattern in $Patterns) {
                Get-ChildItem -LiteralPath $folder -Filter $pattern -File -ErrorAction SilentlyContinue
            }
        }
    }
    return $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Read-CsvFile {
    # Reads a CSV saved by WinPkgScan, a browser or Excel. Detects the text
    # encoding (UTF-8 with or without BOM, UTF-16, or Excel's ANSI code page)
    # and the separator ("," or ";").
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    else {
        try {
            $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
        }
        catch {
            $codePage = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
            $text = [System.Text.Encoding]::GetEncoding($codePage).GetString($bytes)
        }
    }
    $rows = @($text | ConvertFrom-Csv)
    if ($rows.Count -gt 0 -and -not ($rows[0].PSObject.Properties.Name -contains 'FullPath')) {
        $rows = @($text | ConvertFrom-Csv -Delimiter ';')
    }
    return , $rows
}

function Get-RecycleBinFolder {
    # Every folder in the Recycle Bin, with where it came from.
    $shell = New-Object -ComObject Shell.Application
    $bin   = $shell.Namespace(10)
    foreach ($entry in @($bin.Items())) {
        $from = $entry.ExtendedProperty('System.Recycle.DeletedFrom')
        if (-not $from) { $from = $bin.GetDetailsOf($entry, 1) }
        if (-not $from) { continue }
        $when = $entry.ExtendedProperty('System.Recycle.DateDeleted')
        [PSCustomObject]@{
            OriginalPath = Join-Path $from $entry.Name
            DateDeleted  = if ($when) { [datetime]$when } else { [datetime]::MinValue }
            Entry        = $entry
        }
    }
}

$PackagesPath = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Packages"))

$LogPicked = $false
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    if (-not $SearchFolder) {
        $SearchFolder = @((Get-DesktopFolder), (Get-DownloadsFolder)) | Select-Object -Unique
    }
    $newest = Find-NewestFile -Folders $SearchFolder -Patterns 'WinPkgScan-DeleteLog-*.csv'
    if ($newest) {
        $LogPath   = $newest.FullName
        $LogPicked = $true
    }
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " AppData\Local\Packages Folder Restore v$ScriptVersion" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
    Write-Host "ERROR: No delete log was found." -ForegroundColor Red
    Write-Host "Delete logs are named WinPkgScan-DeleteLog-<date-time>.csv and are saved"
    Write-Host "next to the CSV you deleted from. Use -LogPath to choose one."
    Exit-Script 1
}

Write-Host "Log:  $LogPath"
if ($LogPicked) {
    Write-Host "      (newest delete log found; use -LogPath to choose another)" -ForegroundColor Gray
}
if ($WhatIfPreference) {
    Write-Host "WhatIf: on (nothing will be restored)" -ForegroundColor Yellow
}
Write-Host ""

try {
    $Rows = Read-CsvFile -Path $LogPath
}
catch {
    Write-Host "ERROR: Could not read the delete log: $($_.Exception.Message)" -ForegroundColor Red
    Exit-Script 1
}

if ($Rows.Count -gt 0 -and -not ($Rows[0].PSObject.Properties.Name -contains 'Action')) {
    Write-Host "ERROR: This is not a WinPkgScan delete log (no Action column)." -ForegroundColor Red
    Exit-Script 1
}

$Recycled  = @($Rows | Where-Object { $_.Action -eq 'Recycled' })
$Permanent = @($Rows | Where-Object { $_.Action -eq 'Deleted' })
if ($Name) {
    $Recycled = @($Recycled | Where-Object { $n = $_.FolderName; @($Name | Where-Object { $n -like $_ }).Count -gt 0 })
}

Write-Host "Moved to Recycle Bin in this log: $($Recycled.Count)"
if ($Permanent.Count -gt 0) {
    Write-Host "Permanently deleted (cannot be restored): $($Permanent.Count)" -ForegroundColor Yellow
}
Write-Host ""

if ($Recycled.Count -eq 0) {
    Write-Host "Nothing to restore." -ForegroundColor Green
    Exit-Script 0
}

try {
    $InBin = @(Get-RecycleBinFolder)
}
catch {
    Write-Host "ERROR: Could not open the Recycle Bin: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Restore needs Windows. You can also restore the folders by hand from the Recycle Bin."
    Exit-Script 1
}

$Results = New-Object System.Collections.Generic.List[object]

foreach ($Row in $Recycled) {
    $target = [System.IO.Path]::GetFullPath("$($Row.FullPath)").TrimEnd('\', '/')
    $action = $null
    $reason = ""

    if (-not [string]::Equals([System.IO.Path]::GetDirectoryName($target), $PackagesPath, [StringComparison]::OrdinalIgnoreCase)) {
        $action = "Skipped"; $reason = "Not in your Packages folder"
    }
    elseif (Test-Path -LiteralPath $target) {
        $action = "Skipped"; $reason = "Something already exists at the original path"
    }

    if (-not $action) {
        # If the same folder was recycled more than once, restore the newest.
        $match = $InBin |
            Where-Object { [string]::Equals($_.OriginalPath.TrimEnd('\', '/'), $target, [StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object DateDeleted -Descending |
            Select-Object -First 1
        if (-not $match) {
            $action = "Skipped"; $reason = "Not in the Recycle Bin (emptied or already restored?)"
        }
        elseif ($PSCmdlet.ShouldProcess($target, "Restore from Recycle Bin")) {
            try {
                $match.Entry.InvokeVerb('undelete')
                for ($i = 0; $i -lt 20 -and -not (Test-Path -LiteralPath $target); $i++) {
                    Start-Sleep -Milliseconds 250
                }
                if (Test-Path -LiteralPath $target) { $action = "Restored" }
                else { $action = "Failed"; $reason = "Folder did not reappear" }
            }
            catch {
                $action = "Failed"; $reason = $_.Exception.Message
            }
        }
        elseif ($WhatIfPreference) {
            $action = "WhatIf"
        }
        else {
            $action = "Skipped"; $reason = "Not confirmed"
        }
    }

    $colour = switch ($action) {
        'Restored' { 'Green' }
        'WhatIf'   { 'Yellow' }
        'Failed'   { 'Red' }
        default    { 'Gray' }
    }
    $line = "{0,-9} {1}" -f $action, $Row.FolderName
    if ($reason) { $line += "  ($reason)" }
    Write-Host $line -ForegroundColor $colour
    $Results.Add([PSCustomObject]@{ Action = $action; FolderName = $Row.FolderName })
}

$restored = @($Results | Where-Object Action -eq 'Restored').Count
$failed   = @($Results | Where-Object Action -eq 'Failed').Count
$skipped  = @($Results | Where-Object Action -eq 'Skipped').Count

Write-Host ""
Write-Host "Restored: $restored   Skipped: $skipped   Failed: $failed"

if ($failed -gt 0) { Exit-Script 1 }
Exit-Script 0
