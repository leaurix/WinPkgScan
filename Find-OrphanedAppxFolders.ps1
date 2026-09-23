# ============================================================
# Find-OrphanedAppxFolders.ps1
#
# Scans ONLY:
#   %LOCALAPPDATA%\Packages
#
# Finds folders whose Package Family Name is no longer
# registered/installed for the current Windows user.
#
# SAFETY:
#   - Does NOT delete anything
#   - Does NOT uninstall anything
#   - Does NOT modify Windows
#
# USAGE:
#   .\Find-OrphanedAppxFolders.ps1
#   .\Find-OrphanedAppxFolders.ps1 -NoPause
#   .\Find-OrphanedAppxFolders.ps1 -ReportPath "C:\Temp\report.txt"
# ============================================================

[CmdletBinding()]
param(
    # Skip the "Press Enter to exit" prompt (for scheduled/unattended runs).
    [switch]$NoPause,

    # Custom report location. Defaults to the user's real Desktop.
    [string]$ReportPath
)

function Exit-Script {
    param([int]$Code = 0)
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "Press Enter to exit" | Out-Null
    }
    exit $Code
}

$PackagesPath = Join-Path $env:LOCALAPPDATA "Packages"

# Resolve the actual Desktop, including OneDrive-redirected Desktops.
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $DesktopPath = [Environment]::GetFolderPath("Desktop")
    if ([string]::IsNullOrWhiteSpace($DesktopPath)) {
        $DesktopPath = Join-Path $env:USERPROFILE "Desktop"
    }
    $ReportPath = Join-Path $DesktopPath "Orphaned-Appx-Packages.txt"
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " AppData\Local\Packages Orphan Scanner" -ForegroundColor Cyan
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

# A normal Windows install always has registered packages.
# Zero results means the query failed silently.
if ($InstalledPackages.Count -eq 0) {
    Write-Host "ERROR: No registered AppX packages were returned." -ForegroundColor Red
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

$PotentialOrphans = New-Object System.Collections.Generic.List[object]

foreach ($Folder in $Folders) {

    # Normal AppX folder names match the Package Family Name,
    # e.g. Microsoft.WindowsStore_8wekyb3d8bbwe
    if ($InstalledFamilyNames.Contains($Folder.Name)) {
        continue
    }

    # Inaccessible files are skipped, so size may be understated.
    $SizeBytes = 0
    try {
        $SizeBytes = (
            Get-ChildItem -LiteralPath $Folder.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum
        ).Sum
    }
    catch { }

    if ($null -eq $SizeBytes) { $SizeBytes = 0 }

    $PotentialOrphans.Add(
        [PSCustomObject]@{
            FolderName = $Folder.Name
            SizeMB     = [math]::Round(($SizeBytes / 1MB), 2)
            FullPath   = $Folder.FullName
            Status     = "NOT CURRENTLY REGISTERED"
        }
    )
}

$PotentialOrphans = @($PotentialOrphans | Sort-Object -Property SizeMB -Descending)
$TotalMB = [math]::Round((($PotentialOrphans | Measure-Object -Property SizeMB -Sum).Sum), 2)
if ($null -eq $TotalMB) { $TotalMB = 0 }

# ------------------------------------------------------------
# Console output
# ------------------------------------------------------------

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Scan Results" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Folders scanned:       $($Folders.Count)"
Write-Host "Registered packages:   $($InstalledFamilyNames.Count)"
Write-Host "Potential leftovers:   $($PotentialOrphans.Count)"
Write-Host "Total leftover size:   $TotalMB MB"
Write-Host ""

if ($PotentialOrphans.Count -eq 0) {
    Write-Host "No potential orphaned folders were found." -ForegroundColor Green
}
else {
    $PotentialOrphans |
        Format-Table FolderName, @{Name = "Size (MB)"; Expression = { $_.SizeMB }}, Status -AutoSize |
        Out-String -Width 250 |
        Write-Host
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
$Report.Add("User:      $env:USERNAME")
$Report.Add("Computer:  $env:COMPUTERNAME")
$Report.Add("")
$Report.Add("Packages directory:")
$Report.Add($PackagesPath)
$Report.Add("")
$Report.Add("Folders scanned:     $($Folders.Count)")
$Report.Add("Registered packages: $($InstalledFamilyNames.Count)")
$Report.Add("Potential leftovers: $($PotentialOrphans.Count)")
$Report.Add("Total leftover size: $TotalMB MB")
$Report.Add("")
$Report.Add("IMPORTANT:")
$Report.Add("This is an identification report only.")
$Report.Add("Nothing was deleted or modified.")
$Report.Add("")
$Report.Add("A folder appearing below means its folder name does not")
$Report.Add("match a Package Family Name currently registered for")
$Report.Add("this Windows user. Verify each one before deleting it.")
$Report.Add("")
$Report.Add("============================================================")
$Report.Add(" Potential Orphaned Folders")
$Report.Add("============================================================")
$Report.Add("")

if ($PotentialOrphans.Count -eq 0) {
    $Report.Add("No potential orphaned folders were detected.")
}
else {
    foreach ($Item in $PotentialOrphans) {
        $Report.Add("Folder : $($Item.FolderName)")
        $Report.Add("Size   : $($Item.SizeMB) MB")
        $Report.Add("Path   : $($Item.FullPath)")
        $Report.Add("Status : $($Item.Status)")
        $Report.Add("")
    }
}

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
}
catch {
    Write-Host ""
    Write-Host "ERROR: Could not write report to:" -ForegroundColor Red
    Write-Host $ReportPath
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "Nothing was deleted or modified." -ForegroundColor Green
    Exit-Script 1
}

Write-Host ""
Write-Host "Nothing was deleted or modified." -ForegroundColor Green

Exit-Script 0