<#
.SYNOPSIS
    Finds leftover folders in %LOCALAPPDATA%\Packages whose app is no
    longer installed for the current Windows user.

.DESCRIPTION
    Compares every folder in %LOCALAPPDATA%\Packages against the Package
    Family Names registered for the current user (Get-AppxPackage).

    Unmatched folders are split into two groups:
      - Orphaned package folders: named like a package
        (Name_publisherid) but not currently registered.
      - Other folders: not named like a package at all
        (e.g. windows_ie_ac_001). Listed separately for review.

    SAFETY: read-only. Nothing is deleted, uninstalled or modified.

.PARAMETER NoPause
    Skip the "Press Enter to exit" prompt. For scheduled/unattended runs.

.PARAMETER ReportPath
    Custom location for the text report. Defaults to the user's Desktop
    (OneDrive-redirected Desktops are detected).

.PARAMETER Csv
    Also save the results as a CSV file next to the text report.

.EXAMPLE
    .\Find-OrphanedAppxFolders.ps1

.EXAMPLE
    .\Find-OrphanedAppxFolders.ps1 -NoPause -Csv -ReportPath "C:\Temp\report.txt"

.NOTES
    Version: 1.2.0
#>

[CmdletBinding()]
param(
    [switch]$NoPause,
    [string]$ReportPath,
    [switch]$Csv
)

$ScriptVersion = "1.2.0"

function Exit-Script {
    param([int]$Code = 0)
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "Press Enter to exit" | Out-Null
    }
    exit $Code
}

function Write-ResultTable {
    param([object[]]$Items)
    # Out-String with a fixed width keeps the table visible
    # even when output is redirected to a file or log.
    $Items |
        Format-Table FolderName,
            @{Name = "Size (MB)"; Expression = { $_.SizeMB }},
            @{Name = "Last Modified"; Expression = { $_.LastModified }} -AutoSize |
        Out-String -Width 250 |
        Write-Host
}

function Add-ReportSection {
    param(
        [System.Collections.Generic.List[string]]$Report,
        [string]$Title,
        [object[]]$Items,
        [string]$EmptyText
    )
    $Report.Add("============================================================")
    $Report.Add(" $Title")
    $Report.Add("============================================================")
    $Report.Add("")
    if ($Items.Count -eq 0) {
        $Report.Add($EmptyText)
        $Report.Add("")
        return
    }
    foreach ($Item in $Items) {
        $Report.Add("Folder        : $($Item.FolderName)")
        $Report.Add("Size          : $($Item.SizeMB) MB")
        $Report.Add("Last Modified : $($Item.LastModified)")
        $Report.Add("Path          : $($Item.FullPath)")
        $Report.Add("Status        : $($Item.Status)")
        $Report.Add("")
    }
}

$PackagesPath = Join-Path $env:LOCALAPPDATA "Packages"

# Package folders end in "_" + a 13-character publisher ID
# (lowercase base32: digits and letters except i, l, o, u).
$PackageNamePattern = '^.+_[0-9a-hjkmnp-tv-z]{13}$'

# Resolve the actual Desktop, including OneDrive-redirected Desktops.
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $DesktopPath = [Environment]::GetFolderPath("Desktop")
    if ([string]::IsNullOrWhiteSpace($DesktopPath)) {
        $DesktopPath = Join-Path $env:USERPROFILE "Desktop"
    }
    $ReportPath = Join-Path $DesktopPath "Orphaned-Appx-Packages.txt"
}
$CsvPath = [System.IO.Path]::ChangeExtension($ReportPath, ".csv")

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " AppData\Local\Packages Orphan Scanner v$ScriptVersion" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# Check Packages directory
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $PackagesPath)) {
    Write-Host "ERROR: Packages directory was not found." -ForegroundColor Red
    Write-Host $PackagesPath
    Exit-Script 1
}

Write-Host "Packages directory:" -ForegroundColor Gray
Write-Host "  $PackagesPath"
Write-Host ""

# ------------------------------------------------------------
# Get currently registered AppX packages
# ------------------------------------------------------------

Write-Host "Reading installed AppX packages..." -ForegroundColor Yellow

try {
    # PowerShell 7+ needs the Appx module loaded via Windows PowerShell.
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Import-Module Appx -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue
    }
    $InstalledPackages = @(Get-AppxPackage -ErrorAction Stop)
}
catch {
    Write-Host "ERROR: Could not read installed AppX packages." -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host "Scan aborted to avoid flagging every folder as orphaned." -ForegroundColor Red
    Exit-Script 1
}

# Case-insensitive lookup of Package Family Names.
$InstalledFamilyNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($Package in $InstalledPackages) {
    if (-not [string]::IsNullOrWhiteSpace($Package.PackageFamilyName)) {
        [void]$InstalledFamilyNames.Add($Package.PackageFamilyName)
    }
}

# A normal Windows install always has registered packages.
# Zero results means the query failed silently.
if ($InstalledFamilyNames.Count -eq 0) {
    Write-Host "ERROR: No registered AppX packages were returned." -ForegroundColor Red
    Write-Host "Scan aborted to avoid flagging every folder as orphaned." -ForegroundColor Red
    Exit-Script 1
}

Write-Host "Registered packages found: $($InstalledFamilyNames.Count)"
Write-Host ""

# ------------------------------------------------------------
# Scan ONLY the Packages directory
# ------------------------------------------------------------

Write-Host "Scanning package folders..." -ForegroundColor Yellow
Write-Host ""

$Folders = @(
    Get-ChildItem -LiteralPath $PackagesPath -Directory -Force -ErrorAction SilentlyContinue
)

$Results = New-Object System.Collections.Generic.List[object]

foreach ($Folder in $Folders) {

    if ($InstalledFamilyNames.Contains($Folder.Name)) {
        continue
    }

    # One pass: total size and newest write time.
    # Inaccessible files are skipped, so size may be understated.
    $SizeBytes = [long]0
    $Newest = $Folder.LastWriteTime
    try {
        foreach ($File in (Get-ChildItem -LiteralPath $Folder.FullName -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $SizeBytes += $File.Length
            if ($File.LastWriteTime -gt $Newest) { $Newest = $File.LastWriteTime }
        }
    }
    catch { }

    $IsPackageNamed = $Folder.Name -cmatch $PackageNamePattern -or
                      $Folder.Name.ToLowerInvariant() -cmatch $PackageNamePattern

    $Results.Add(
        [PSCustomObject]@{
            Category     = if ($IsPackageNamed) { "Orphaned package" } else { "Other folder" }
            FolderName   = $Folder.Name
            SizeMB       = [math]::Round(($SizeBytes / 1MB), 2)
            LastModified = $Newest.ToString("yyyy-MM-dd")
            FullPath     = $Folder.FullName
            Status       = if ($IsPackageNamed) { "NOT CURRENTLY REGISTERED" } else { "NOT A PACKAGE-NAMED FOLDER" }
        }
    )
}

$Orphans = @($Results | Where-Object { $_.Category -eq "Orphaned package" } | Sort-Object SizeMB -Descending)
$Others  = @($Results | Where-Object { $_.Category -eq "Other folder" }     | Sort-Object SizeMB -Descending)

function Get-TotalMB {
    param([object[]]$Items)
    if ($Items.Count -eq 0) { return 0 }
    return [math]::Round((($Items | Measure-Object -Property SizeMB -Sum).Sum), 2)
}
$OrphanMB = Get-TotalMB $Orphans
$OtherMB  = Get-TotalMB $Others

# ------------------------------------------------------------
# Console output
# ------------------------------------------------------------

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Scan Results" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Folders scanned:          $($Folders.Count)"
Write-Host "Registered packages:      $($InstalledFamilyNames.Count)"
Write-Host "Orphaned package folders: $($Orphans.Count) ($OrphanMB MB)"
Write-Host "Other folders:            $($Others.Count) ($OtherMB MB)"
Write-Host ""

if ($Orphans.Count -eq 0) {
    Write-Host "No orphaned package folders were found." -ForegroundColor Green
}
else {
    Write-Host "Orphaned package folders:" -ForegroundColor Yellow
    Write-ResultTable $Orphans
}

if ($Others.Count -gt 0) {
    Write-Host "Other folders (not package-named, review manually):" -ForegroundColor Gray
    Write-ResultTable $Others
}

# ------------------------------------------------------------
# Generate report
# ------------------------------------------------------------

$Report = New-Object System.Collections.Generic.List[string]

$Report.Add("============================================================")
$Report.Add(" AppData\Local\Packages - Orphaned Package Report")
$Report.Add("============================================================")
$Report.Add("")
$Report.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$Report.Add("Version:   $ScriptVersion")
$Report.Add("User:      $env:USERNAME")
$Report.Add("Computer:  $env:COMPUTERNAME")
$Report.Add("")
$Report.Add("Packages directory:")
$Report.Add($PackagesPath)
$Report.Add("")
$Report.Add("Folders scanned:          $($Folders.Count)")
$Report.Add("Registered packages:      $($InstalledFamilyNames.Count)")
$Report.Add("Orphaned package folders: $($Orphans.Count) ($OrphanMB MB)")
$Report.Add("Other folders:            $($Others.Count) ($OtherMB MB)")
$Report.Add("")
$Report.Add("IMPORTANT:")
$Report.Add("This is an identification report only.")
$Report.Add("Nothing was deleted or modified.")
$Report.Add("")
$Report.Add("Orphaned package folders are named like an app package but")
$Report.Add("are not registered for this Windows user. Other folders are")
$Report.Add("not named like a package and are often used by Windows.")
$Report.Add("Verify each folder before deleting it.")
$Report.Add("")

Add-ReportSection -Report $Report -Title "Orphaned Package Folders" -Items $Orphans `
    -EmptyText "No orphaned package folders were detected."
Add-ReportSection -Report $Report -Title "Other Folders (not package-named)" -Items $Others `
    -EmptyText "No other folders were detected."

$Report.Add("============================================================")
$Report.Add(" End of Report")
$Report.Add("============================================================")

try {
    $ReportDir = Split-Path -Path $ReportPath -Parent
    if ($ReportDir -and -not (Test-Path -LiteralPath $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    }
    $Report | Out-File -LiteralPath $ReportPath -Encoding UTF8 -Force -ErrorAction Stop

    Write-Host ""
    Write-Host "Report created:" -ForegroundColor Green
    Write-Host $ReportPath -ForegroundColor White

    if ($Csv) {
        @($Orphans) + @($Others) |
            Select-Object Category, FolderName, SizeMB, LastModified, FullPath, Status |
            Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8 -Force -ErrorAction Stop
        Write-Host "CSV created:" -ForegroundColor Green
        Write-Host $CsvPath -ForegroundColor White
    }
}
catch {
    Write-Host ""
    Write-Host "ERROR: Could not write output file." -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "Nothing was deleted or modified." -ForegroundColor Green
    Exit-Script 1
}

Write-Host ""
Write-Host "Nothing was deleted or modified." -ForegroundColor Green

Exit-Script 0
