<#
.SYNOPSIS
    Deletes the orphaned AppX folders you marked in the scanner's CSV.

.DESCRIPTION
    Reads the CSV made by Find-OrphanedAppxFolders.ps1 (-Csv) and deletes
    only the rows where the Delete column is Yes (also accepts Y, True, 1, X).

    Each marked folder is checked again before anything is deleted. A folder
    is skipped if any check fails:
      - It must be directly inside %LOCALAPPDATA%\Packages of the current user.
      - The FolderName and FullPath columns must match.
      - It must still exist and must not be a link or junction.
      - It must not be registered to an installed app right now.
      - It must not match an exclude pattern.
      - It must not be a Windows component (_cw5n1h2txyewy or
        windows_ie_ac_*), unless -IncludeWindowsComponents.
      - It must be package-named (Name_publisherid), unless -IncludeOtherFolders.
      - It must not contain any links or junctions.
      - Nothing in it may have changed in the last -MinAgeDays days.

    Folders go to the Recycle Bin by default, so they can be restored.
    You are asked to confirm each folder unless you use -Force.
    Every action is written to a log CSV.

.PARAMETER CsvPath
    The CSV with your Delete marks. If not given, the newest of these is
    used: Orphaned-Appx-Packages.csv (made by the scanner, marked in Excel)
    and WinPkgScan-marked*.csv (saved from the HTML report), looked for on
    your Desktop and in your Downloads folder.

.PARAMETER SearchFolder
    Folders to look in when -CsvPath is not given. Defaults to your Desktop
    and Downloads folders.

.PARAMETER AdminChecks
    Auto (default): when running as administrator, also skip folders whose
    app Windows still knows for you in an unfinished state (staged or
    pending). On: always try. Off: never.

.PARAMETER Permanent
    Delete permanently instead of moving to the Recycle Bin.

.PARAMETER MinAgeDays
    Skip folders with anything modified in the last N days. Default 30.
    Use 0 to turn this check off.

.PARAMETER IncludeOtherFolders
    Also allow folders that are not package-named (the scanner's
    "Other folders"). These are often used by Windows itself.

.PARAMETER IncludeWindowsComponents
    Also allow Windows component folders (publisher _cw5n1h2txyewy, or
    windows_ie_ac_*). Not recommended: these belong to Windows.

.PARAMETER Exclude
    Folder names never to delete. Wildcards allowed.

.PARAMETER ExcludeFile
    A text file with one exclude pattern per line (# starts a comment).
    Defaults to WinPkgScan.exclude.txt next to this script.

.PARAMETER LogPath
    Where to save the log CSV. Defaults to a timestamped file next to the
    input CSV.

.PARAMETER Force
    Do not ask before each folder (same as -Confirm:$false). Use with care.

.PARAMETER NoPause
    Skip the "Press Enter to exit" prompt. For scheduled/unattended runs.

.EXAMPLE
    .\Remove-OrphanedAppxFolders.ps1 -WhatIf
    Shows what would be deleted. Nothing is changed.

.EXAMPLE
    .\Remove-OrphanedAppxFolders.ps1
    Moves the marked folders to the Recycle Bin, asking before each one.

.EXAMPLE
    .\Remove-OrphanedAppxFolders.ps1 -CsvPath C:\Temp\report.csv -Force -NoPause
    Unattended run: no prompts.

.NOTES
    Version: 1.6.0
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)]
    [string]$CsvPath,

    [string[]]$SearchFolder,

    [ValidateSet('Auto', 'On', 'Off')]
    [string]$AdminChecks = 'Auto',

    [switch]$Permanent,

    [ValidateRange(0, 36500)]
    [int]$MinAgeDays = 30,

    [switch]$IncludeOtherFolders,

    [switch]$IncludeWindowsComponents,

    [string[]]$Exclude,

    [string]$ExcludeFile,

    [string]$LogPath,

    [switch]$Force,

    [switch]$NoPause
)

$ScriptVersion = "1.6.0"
$PauseAtEnd    = -not $NoPause.IsPresent

# -Force skips the per-folder prompt, unless -Confirm was given explicitly.
if ($Force.IsPresent -and -not $PSBoundParameters.ContainsKey('Confirm')) {
    $ConfirmPreference = 'None'
}

function Exit-Script {
    param([int]$Code = 0)
    if ($PauseAtEnd) {
        Write-Host ""
        Read-Host "Press Enter to exit" | Out-Null
    }
    exit $Code
}

function Get-FolderInfo {
    # Total size, newest write time and whether any link or junction is
    # inside, in one pass.
    param([System.IO.DirectoryInfo]$Folder)
    $size     = [long]0
    $newest   = $Folder.LastWriteTime
    $hasLinks = $false
    foreach ($entry in (Get-ChildItem -LiteralPath $Folder.FullName -Recurse -Force -ErrorAction SilentlyContinue)) {
        if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $hasLinks = $true }
        if (-not $entry.PSIsContainer) { $size += $entry.Length }
        if ($entry.LastWriteTime -gt $newest) { $newest = $entry.LastWriteTime }
    }
    [PSCustomObject]@{
        SizeMB   = [math]::Round(($size / 1MB), 2)
        Newest   = $newest
        HasLinks = $hasLinks
    }
}

function Test-MarkedForDelete {
    param([string]$Value)
    if ($null -eq $Value) { return $false }
    return $Value.Trim() -match '^(yes|y|true|1|x)$'
}

function Get-ExcludePattern {
    # Patterns from -Exclude plus the exclude file (one per line, # = comment).
    param([string[]]$FromParameter, [string]$File, [bool]$FileWasGiven)
    $patterns = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($FromParameter)) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { $patterns.Add($p.Trim()) }
    }
    if (Test-Path -LiteralPath $File -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $File)) {
            $t = $line.Trim()
            if ($t -and -not $t.StartsWith('#')) { $patterns.Add($t) }
        }
    }
    elseif ($FileWasGiven) {
        Write-Host "WARNING: Exclude file not found: $File" -ForegroundColor Yellow
    }
    return , $patterns.ToArray()
}

function Get-MatchingPattern {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        if ($Name -like $p) { return $p }
    }
    return $null
}

function Test-WindowsComponent {
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    return $n.EndsWith('_cw5n1h2txyewy') -or $n -like 'windows_ie_ac_*'
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-CurrentUserSid {
    $sid = $null
    try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $sid = $null }
    # Only used by the test suite on non-Windows systems, where there is no SID.
    if (-not $sid) { $sid = $env:WINPKGSCAN_TEST_SID }
    return $sid
}

function Get-RegisteredPackage {
    # All package types (main, framework, optional, resource, bundle), so no
    # registered package family is missed. Falls back if the filter is unsupported.
    try {
        return @(Get-AppxPackage -PackageTypeFilter All -ErrorAction Stop)
    }
    catch {
        return @(Get-AppxPackage -ErrorAction Stop)
    }
}

function Get-AdminPackageInfo {
    # Needs administrator rights. Returns:
    #   ForMe:       families Windows knows for this user in any state
    #                (installed, staged, pending), even if not listed above
    #   OtherUsers:  family -> number of other user accounts that have it
    #   Provisioned: families provisioned for new users
    param([string]$Sid)

    $forMe = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $other = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::OrdinalIgnoreCase)
    $prov  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    try {
        $all = @(Get-AppxPackage -AllUsers -PackageTypeFilter All -ErrorAction Stop)
    }
    catch {
        $all = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
    }

    foreach ($p in $all) {
        $family = "$($p.PackageFamilyName)"
        if (-not $family) { continue }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($u in @($p.PackageUserInformation)) {
            if ($null -eq $u) { continue }
            # Works with live objects and with text from PowerShell 7's
            # Windows PowerShell compatibility layer.
            $text = if ($u.UserSecurityId) {
                if ($u.UserSecurityId.Sid) { "$($u.UserSecurityId.Sid)" } else { "$($u.UserSecurityId)" }
            }
            else { "$u" }
            $m = [regex]::Match($text, 'S-1-[0-9-]+')
            if (-not $m.Success) { continue }
            $userSid = $m.Value
            if ($Sid -and $userSid -eq $Sid) {
                [void]$forMe.Add($family)
            }
            elseif ($userSid.StartsWith('S-1-5-21-') -and $seen.Add($userSid)) {
                if ($other.ContainsKey($family)) { $other[$family] = $other[$family] + 1 } else { $other[$family] = 1 }
            }
        }
    }

    try {
        foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)) {
            if ($p.DisplayName -and $p.PublisherId) {
                [void]$prov.Add("$($p.DisplayName)_$($p.PublisherId)")
            }
        }
    }
    catch {
        Write-Verbose "Could not read provisioned packages: $($_.Exception.Message)"
    }

    [PSCustomObject]@{
        ForMe       = $forMe
        OtherUsers  = $other
        Provisioned = $prov
    }
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

$PackagesPath = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Packages"))

if ([string]::IsNullOrWhiteSpace($ExcludeFile)) {
    $ExcludeFile = Join-Path $PSScriptRoot "WinPkgScan.exclude.txt"
    $ExcludeFileGiven = $false
}
else {
    $ExcludeFileGiven = $true
}
$ExcludePatterns = Get-ExcludePattern -FromParameter $Exclude -File $ExcludeFile -FileWasGiven $ExcludeFileGiven

# Package folders end in "_" + a 13-character publisher ID.
$PackageNamePattern = '^.+_[0-9a-hjkmnp-tv-z]{13}$'

$CsvPicked = $false
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    if (-not $SearchFolder) {
        $SearchFolder = @((Get-DesktopFolder), (Get-DownloadsFolder)) | Select-Object -Unique
    }
    $newest = Find-NewestFile -Folders $SearchFolder -Patterns 'Orphaned-Appx-Packages.csv', 'WinPkgScan-marked*.csv'
    if ($newest) {
        $CsvPath   = $newest.FullName
        $CsvPicked = $true
    }
    else {
        $CsvPath = Join-Path $SearchFolder[0] "Orphaned-Appx-Packages.csv"
    }
}

$Mode = if ($Permanent) { "PERMANENT DELETE" } else { "Move to Recycle Bin" }

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " AppData\Local\Packages Orphan Remover v$ScriptVersion" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "CSV:            $CsvPath"
if ($CsvPicked) {
    Write-Host "                (newest marked file found; use -CsvPath to choose another)" -ForegroundColor Gray
}
Write-Host "Mode:           $Mode" -ForegroundColor $(if ($Permanent) { 'Red' } else { 'White' })
Write-Host "Skip if newer:  $(if ($MinAgeDays -gt 0) { "$MinAgeDays days" } else { 'off' })"
Write-Host "Other folders:  $(if ($IncludeOtherFolders) { 'allowed' } else { 'skipped' })"
Write-Host "Windows parts:  $(if ($IncludeWindowsComponents) { 'ALLOWED' } else { 'skipped' })" -ForegroundColor $(if ($IncludeWindowsComponents) { 'Red' } else { 'White' })
Write-Host "Exclusions:     $(if ($ExcludePatterns.Count -gt 0) { $ExcludePatterns -join ', ' } else { 'none' })"
if ($WhatIfPreference) {
    Write-Host "WhatIf:         on (nothing will be deleted)" -ForegroundColor Yellow
}
Write-Host ""

# ------------------------------------------------------------
# Read the CSV
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
    Write-Host "ERROR: CSV file was not found." -ForegroundColor Red
    Write-Host "Scan first (Run-Scan.bat), then mark folders in the HTML report and"
    Write-Host "click Save marked CSV, or type Yes in the Delete column in Excel."
    Exit-Script 1
}

try {
    $Rows = Read-CsvFile -Path $CsvPath
}
catch {
    Write-Host "ERROR: Could not read the CSV file." -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host "If it is open in Excel, close it and try again."
    Exit-Script 1
}

$Columns = if ($Rows.Count -gt 0) { @($Rows[0].PSObject.Properties.Name) } else { @() }
foreach ($required in 'FolderName', 'FullPath', 'Delete') {
    if ($Columns -notcontains $required) {
        Write-Host "ERROR: The CSV has no '$required' column." -ForegroundColor Red
        if ($required -eq 'Delete') {
            Write-Host "Add a column named Delete and type Yes on each row to remove."
        }
        else {
            Write-Host "Use the CSV made by Find-OrphanedAppxFolders.ps1 -Csv."
        }
        Exit-Script 1
    }
}

$Marked = @($Rows | Where-Object { Test-MarkedForDelete $_.Delete })
Write-Host "Rows in CSV:        $($Rows.Count)"
Write-Host "Rows marked Delete: $($Marked.Count)"
Write-Host ""

if ($Marked.Count -eq 0) {
    Write-Host "Nothing to do. Type Yes in the Delete column for each folder to remove." -ForegroundColor Green
    Exit-Script 0
}

# ------------------------------------------------------------
# Get currently registered AppX packages
# ------------------------------------------------------------

Write-Host "Reading installed AppX packages..." -ForegroundColor Yellow
try {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Import-Module Appx -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue
    }
    $InstalledPackages = Get-RegisteredPackage
}
catch {
    Write-Host "ERROR: Could not read installed AppX packages." -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host "Nothing was deleted." -ForegroundColor Green
    Exit-Script 1
}

$InstalledFamilyNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($Package in $InstalledPackages) {
    if (-not [string]::IsNullOrWhiteSpace($Package.PackageFamilyName)) {
        [void]$InstalledFamilyNames.Add($Package.PackageFamilyName)
    }
}

if ($InstalledFamilyNames.Count -eq 0) {
    Write-Host "ERROR: No registered AppX packages were returned." -ForegroundColor Red
    Write-Host "Nothing was deleted, to avoid removing folders of installed apps." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "Registered packages found: $($InstalledFamilyNames.Count)"

$AdminInfo = $null
$UseAdmin  = ($AdminChecks -eq 'On') -or ($AdminChecks -eq 'Auto' -and (Test-IsAdministrator))
if ($UseAdmin) {
    try {
        $AdminInfo = Get-AdminPackageInfo -Sid (Get-CurrentUserSid)
        Write-Host "Administrator checks:      on"
    }
    catch {
        Write-Host "WARNING: Administrator checks failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host ""

if (-not $Permanent) {
    Add-Type -AssemblyName Microsoft.VisualBasic
}

# ------------------------------------------------------------
# Check and delete each marked folder
# ------------------------------------------------------------

$Cutoff = (Get-Date).AddDays(-$MinAgeDays)
$Log    = New-Object System.Collections.Generic.List[object]

foreach ($Row in $Marked) {

    $name   = "$($Row.FolderName)".Trim()
    $raw    = "$($Row.FullPath)".Trim()
    $action = $null
    $reason = ""
    $sizeMB = ""
    $full   = $raw

    # 1. Path must be directly inside this user's Packages folder.
    try {
        $full = [System.IO.Path]::GetFullPath($raw).TrimEnd('\', '/')
    }
    catch {
        $action = "Skipped"; $reason = "Invalid path"
    }

    if (-not $action) {
        $parent = [System.IO.Path]::GetDirectoryName($full)
        $leaf   = [System.IO.Path]::GetFileName($full)
        if ([string]::IsNullOrWhiteSpace($raw) -or
            -not [string]::Equals($parent, $PackagesPath, [StringComparison]::OrdinalIgnoreCase)) {
            $action = "Skipped"; $reason = "Not directly inside $PackagesPath"
        }
        elseif (-not [string]::Equals($leaf, $name, [StringComparison]::OrdinalIgnoreCase)) {
            $action = "Skipped"; $reason = "FolderName and FullPath do not match"
        }
    }

    # 2. Must still exist, and must not be a link or junction.
    $item = $null
    if (-not $action) {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            $action = "Skipped"; $reason = "Folder not found (already removed?)"
        }
        elseif (-not $item.PSIsContainer) {
            $action = "Skipped"; $reason = "Not a folder"
        }
        elseif ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            $action = "Skipped"; $reason = "Link or junction (not followed)"
        }
    }

    # 3. Must not belong to an installed app, be excluded, be a Windows
    #    component, or (by default) be a non-package folder.
    if (-not $action) {
        $excludedBy = Get-MatchingPattern -Name $item.Name -Patterns $ExcludePatterns
        if ($InstalledFamilyNames.Contains($item.Name)) {
            $action = "Skipped"; $reason = "Registered to an installed app"
        }
        elseif ($AdminInfo -and $AdminInfo.ForMe.Contains($item.Name)) {
            $action = "Skipped"; $reason = "App still known to Windows for you (staged or pending)"
        }
        elseif ($excludedBy) {
            $action = "Skipped"; $reason = "Excluded by pattern '$excludedBy'"
        }
        elseif (-not $IncludeWindowsComponents -and (Test-WindowsComponent $item.Name)) {
            $action = "Skipped"; $reason = "Windows component (keep)"
        }
        elseif (-not $IncludeOtherFolders -and $item.Name.ToLowerInvariant() -notmatch $PackageNamePattern) {
            $action = "Skipped"; $reason = "Not a package-named folder (use -IncludeOtherFolders)"
        }
    }

    # 4. Must not have been modified recently.
    if (-not $action) {
        $info   = Get-FolderInfo -Folder $item
        $sizeMB = $info.SizeMB
        # Windows PowerShell 5.1 can follow a junction inside a folder and
        # delete the target's contents, so never delete such folders.
        if ($info.HasLinks) {
            $action = "Skipped"; $reason = "Contains links or junctions (delete manually)"
        }
        elseif ($MinAgeDays -gt 0 -and $info.Newest -gt $Cutoff) {
            $action = "Skipped"
            $reason = "Modified $($info.Newest.ToString('yyyy-MM-dd')), within $MinAgeDays days"
        }
    }

    # 5. Confirm and delete.
    if (-not $action) {
        $verb = if ($Permanent) { "Permanently delete ($sizeMB MB)" } else { "Move to Recycle Bin ($sizeMB MB)" }
        # ShouldProcess asks the user. It throws if nobody can answer
        # (e.g. a scheduled task), so treat that as "not confirmed".
        $confirmed = $false
        $askFailed = $false
        try {
            $confirmed = $PSCmdlet.ShouldProcess($full, $verb)
        }
        catch {
            $askFailed = $true
        }

        if ($askFailed) {
            $action = "Skipped"; $reason = "Could not ask for confirmation (use -Force for unattended runs)"
        }
        elseif ($confirmed) {
            try {
                if ($Permanent) {
                    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop -Confirm:$false -WhatIf:$false
                    $action = "Deleted"
                }
                else {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                        $full,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                        [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException)
                    $action = "Recycled"
                }
                if (Test-Path -LiteralPath $full) {
                    $action = "Failed"; $reason = "Folder still exists after delete"
                }
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
        'Recycled' { 'Green' }
        'Deleted'  { 'Green' }
        'WhatIf'   { 'Yellow' }
        'Failed'   { 'Red' }
        default    { 'Gray' }
    }
    $line = "{0,-9} {1}" -f $action, $name
    if ($reason) { $line += "  ($reason)" }
    Write-Host $line -ForegroundColor $colour

    $Log.Add([PSCustomObject]@{
        Time       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Action     = $action
        FolderName = $name
        SizeMB     = $sizeMB
        FullPath   = $full
        Reason     = $reason
    })
}

# ------------------------------------------------------------
# Summary and log
# ------------------------------------------------------------

function Get-ActionCount {
    param([string]$Name)
    return @($Log | Where-Object Action -eq $Name).Count
}

$Removed = @($Log | Where-Object { $_.Action -in 'Recycled', 'Deleted' })
$FreedMB = 0
if ($Removed.Count -gt 0) {
    $FreedMB = [math]::Round((($Removed | Measure-Object -Property SizeMB -Sum).Sum), 2)
}
$FailedCount = Get-ActionCount 'Failed'

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Moved to Recycle Bin: $(Get-ActionCount 'Recycled')"
Write-Host "Permanently deleted:  $(Get-ActionCount 'Deleted')"
if ($WhatIfPreference) {
    Write-Host "Would be removed:     $(Get-ActionCount 'WhatIf')"
}
Write-Host "Skipped:              $(Get-ActionCount 'Skipped')"
Write-Host "Failed:               $FailedCount"
Write-Host "Space freed:          $FreedMB MB"

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $csvDir  = Split-Path -Path ([System.IO.Path]::GetFullPath($CsvPath)) -Parent
    $LogPath = Join-Path $csvDir ("WinPkgScan-DeleteLog-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

try {
    $logDir = Split-Path -Path $LogPath -Parent
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false -Confirm:$false | Out-Null
    }
    $Log | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8 -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
    Write-Host ""
    Write-Host "Log saved:" -ForegroundColor Green
    Write-Host $LogPath
}
catch {
    Write-Host ""
    Write-Host "WARNING: Could not save the log: $($_.Exception.Message)" -ForegroundColor Yellow
}

if (Get-ActionCount 'Recycled') {
    Write-Host ""
    Write-Host "Removed folders can be restored from the Recycle Bin." -ForegroundColor Green
}

if ($FailedCount -gt 0) {
    Exit-Script 1
}
Exit-Script 0
