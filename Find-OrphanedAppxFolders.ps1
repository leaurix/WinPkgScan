<#
.SYNOPSIS
    Finds leftover folders in %LOCALAPPDATA%\Packages whose app is no
    longer installed for the current Windows user.

.DESCRIPTION
    Compares every folder in %LOCALAPPDATA%\Packages against the Package
    Family Names registered for the current user (Get-AppxPackage).

    Unmatched folders are split into three groups:
      - Orphaned package folders: named like a package
        (Name_publisherid) but not currently registered.
      - Windows components: from the Windows publisher (_cw5n1h2txyewy)
        or windows_ie_ac_*. Listed so you can see them, but keep them.
      - Other folders: not named like a package at all.
        Listed separately for review.

    Folders matching an exclude pattern are left out of the results.

    SAFETY: read-only. Nothing is deleted, uninstalled or modified.

.PARAMETER NoPause
    Skip the "Press Enter to exit" prompt. For scheduled/unattended runs.

.PARAMETER ReportPath
    Custom location for the text report. Defaults to the user's Desktop
    (OneDrive-redirected Desktops are detected).

.PARAMETER Csv
    Also save the results as a CSV file next to the text report.
    The CSV has an empty Delete column: type Yes on the rows to remove,
    then run Remove-OrphanedAppxFolders.ps1.

.PARAMETER Html
    Also save a sortable HTML report next to the text report.

.PARAMETER Open
    Open the HTML report in your browser when the scan finishes.

.PARAMETER Exclude
    Folder names to leave out of the results. Wildcards allowed,
    e.g. -Exclude 'Contoso.*','*Teams*'

.PARAMETER ExcludeFile
    A text file with one exclude pattern per line (# starts a comment).
    Defaults to WinPkgScan.exclude.txt next to this script.

.EXAMPLE
    .\Find-OrphanedAppxFolders.ps1

.EXAMPLE
    .\Find-OrphanedAppxFolders.ps1 -NoPause -Csv -ReportPath "C:\Temp\report.txt"

.EXAMPLE
    .\Find-OrphanedAppxFolders.ps1 -Csv -Html -Open -Exclude '*Teams*'

.NOTES
    Version: 1.5.0
#>

[CmdletBinding()]
param(
    [switch]$NoPause,
    [string]$ReportPath,
    [switch]$Csv,
    [switch]$Html,
    [switch]$Open,
    [string[]]$Exclude,
    [string]$ExcludeFile
)

$ScriptVersion = "1.5.0"
$PauseAtEnd    = -not $NoPause.IsPresent

function Exit-Script {
    param([int]$Code = 0)
    if ($PauseAtEnd) {
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
    # Windows inbox components: publisher ID cw5n1h2txyewy, or the
    # Internet Explorer app containers (windows_ie_ac_*).
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    return $n.EndsWith('_cw5n1h2txyewy') -or $n -like 'windows_ie_ac_*'
}

function ConvertTo-HtmlText {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Write-HtmlReport {
    param(
        [string]$Path,
        [object[]]$Sections,
        [object[]]$Tiles,
        [string]$Subtitle
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WinPkgScan report</title>
<style>
:root { --bg:#f7f7f5; --card:#ffffff; --text:#1d1d1f; --muted:#6b6b70; --line:#e2e2e0;
        --accent:#2f6fde; --warn:#b26a00; --keep:#2e7d32; --head:#f0f0ee; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#161618; --card:#1f1f22; --text:#ececee; --muted:#9a9aa2; --line:#33333a;
          --accent:#6ea0ff; --warn:#f0a843; --keep:#7bc47f; --head:#26262a; }
}
* { box-sizing:border-box; }
body { margin:0; padding:24px 16px 48px; background:var(--bg); color:var(--text);
       font:14px/1.5 "Segoe UI", system-ui, sans-serif; }
main { max-width:1100px; margin:0 auto; }
h1 { font-size:22px; margin:0 0 4px; }
.sub { color:var(--muted); margin:0 0 20px; }
.tiles { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:12px; margin-bottom:20px; }
.tile { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 14px; }
.tile b { display:block; font-size:22px; }
.tile span { color:var(--muted); font-size:12px; }
.note { background:var(--card); border:1px solid var(--line); border-left:4px solid var(--warn);
        border-radius:8px; padding:10px 14px; margin-bottom:20px; }
input#filter { width:100%; max-width:360px; padding:8px 10px; border:1px solid var(--line);
               border-radius:8px; background:var(--card); color:var(--text); margin-bottom:16px; }
section { margin-bottom:28px; }
h2 { font-size:16px; margin:0 0 4px; }
h2 small { color:var(--muted); font-weight:normal; }
section p { color:var(--muted); margin:0 0 8px; }
.wrap { overflow-x:auto; background:var(--card); border:1px solid var(--line); border-radius:10px; }
table { border-collapse:collapse; width:100%; }
th, td { text-align:left; padding:8px 12px; border-bottom:1px solid var(--line); white-space:nowrap; }
th { background:var(--head); cursor:pointer; user-select:none; font-weight:600; }
th[data-dir="asc"]::after { content:" \25B2"; font-size:10px; }
th[data-dir="desc"]::after { content:" \25BC"; font-size:10px; }
td.num, th.num { text-align:right; }
td.path { color:var(--muted); font-size:12px; }
tr:last-child td { border-bottom:none; }
.empty { padding:12px; color:var(--muted); }
.k-orphan h2 { color:var(--accent); } .k-windows h2 { color:var(--keep); } .k-other h2 { color:var(--warn); }
footer { color:var(--muted); font-size:12px; margin-top:32px; }
</style>
</head>
<body>
<main>
<h1>WinPkgScan report</h1>
'@)
    [void]$sb.Append("<p class=`"sub`">$(ConvertTo-HtmlText $Subtitle)</p>`n<div class=`"tiles`">`n")
    foreach ($t in $Tiles) {
        [void]$sb.Append("<div class=`"tile`"><b>$(ConvertTo-HtmlText $t.Value)</b><span>$(ConvertTo-HtmlText $t.Label)</span></div>`n")
    }
    [void]$sb.Append("</div>`n<div class=`"note`">Read-only report: nothing was deleted or modified. To remove folders, type <b>Yes</b> in the Delete column of the CSV and run <b>Run-Delete.bat</b>.</div>`n")
    [void]$sb.Append("<input id=`"filter`" type=`"search`" placeholder=`"Filter by name or path`" aria-label=`"Filter`">`n")

    foreach ($sec in $Sections) {
        $count = @($sec.Items).Count
        [void]$sb.Append("<section class=`"k-$($sec.Kind)`">`n<h2>$(ConvertTo-HtmlText $sec.Title) <small>($count, $($sec.TotalMB) MB)</small></h2>`n<p>$(ConvertTo-HtmlText $sec.Note)</p>`n<div class=`"wrap`">`n")
        if ($count -eq 0) {
            [void]$sb.Append("<div class=`"empty`">None found.</div>`n")
        }
        else {
            [void]$sb.Append("<table class=`"sortable`"><thead><tr><th>Folder</th><th class=`"num`" data-type=`"num`">Size (MB)</th><th>Last modified</th><th>Path</th></tr></thead><tbody>`n")
            foreach ($i in $sec.Items) {
                $size = ([double]$i.SizeMB).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
                [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $i.FolderName)</td><td class=`"num`" data-v=`"$size`">$size</td><td>$(ConvertTo-HtmlText $i.LastModified)</td><td class=`"path`">$(ConvertTo-HtmlText $i.FullPath)</td></tr>`n")
            }
            [void]$sb.Append("</tbody></table>`n")
        }
        [void]$sb.Append("</div>`n</section>`n")
    }

    [void]$sb.Append("<footer>WinPkgScan v$ScriptVersion</footer>`n</main>`n")
    [void]$sb.Append(@'
<script>
document.querySelectorAll('table.sortable th').forEach(function (th, col) {
  th.addEventListener('click', function () {
    var table = th.closest('table'), body = table.tBodies[0];
    var asc = th.getAttribute('data-dir') !== 'asc';
    table.querySelectorAll('th').forEach(function (h) { h.removeAttribute('data-dir'); });
    th.setAttribute('data-dir', asc ? 'asc' : 'desc');
    var num = th.getAttribute('data-type') === 'num';
    Array.prototype.slice.call(body.rows).sort(function (a, b) {
      var x = a.cells[col].getAttribute('data-v') || a.cells[col].textContent;
      var y = b.cells[col].getAttribute('data-v') || b.cells[col].textContent;
      var r = num ? parseFloat(x) - parseFloat(y) : x.localeCompare(y);
      return asc ? r : -r;
    }).forEach(function (row) { body.appendChild(row); });
  });
});
document.getElementById('filter').addEventListener('input', function (e) {
  var q = e.target.value.toLowerCase();
  document.querySelectorAll('tbody tr').forEach(function (row) {
    row.hidden = q !== '' && row.textContent.toLowerCase().indexOf(q) === -1;
  });
});
</script>
</body>
</html>
'@)
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
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
$CsvPath  = [System.IO.Path]::ChangeExtension($ReportPath, ".csv")
$HtmlPath = [System.IO.Path]::ChangeExtension($ReportPath, ".html")

if ([string]::IsNullOrWhiteSpace($ExcludeFile)) {
    $ExcludeFile = Join-Path $PSScriptRoot "WinPkgScan.exclude.txt"
    $ExcludeFileGiven = $false
}
else {
    $ExcludeFileGiven = $true
}
$ExcludePatterns = Get-ExcludePattern -FromParameter $Exclude -File $ExcludeFile -FileWasGiven $ExcludeFileGiven

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

$Results  = New-Object System.Collections.Generic.List[object]
$Excluded = New-Object System.Collections.Generic.List[string]

foreach ($Folder in $Folders) {

    if ($InstalledFamilyNames.Contains($Folder.Name)) {
        continue
    }

    if (Get-MatchingPattern -Name $Folder.Name -Patterns $ExcludePatterns) {
        $Excluded.Add($Folder.Name)
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
    catch {
        Write-Verbose "Could not fully read $($Folder.FullName): $($_.Exception.Message)"
    }

    $IsPackageNamed = $Folder.Name -cmatch $PackageNamePattern -or
                      $Folder.Name.ToLowerInvariant() -cmatch $PackageNamePattern

    if (Test-WindowsComponent $Folder.Name) {
        $Category = "Windows component"; $Status = "WINDOWS COMPONENT (KEEP)"
    }
    elseif ($IsPackageNamed) {
        $Category = "Orphaned package";  $Status = "NOT CURRENTLY REGISTERED"
    }
    else {
        $Category = "Other folder";      $Status = "NOT A PACKAGE-NAMED FOLDER"
    }

    $Results.Add(
        [PSCustomObject]@{
            Category     = $Category
            FolderName   = $Folder.Name
            SizeMB       = [math]::Round(($SizeBytes / 1MB), 2)
            LastModified = $Newest.ToString("yyyy-MM-dd")
            FullPath     = $Folder.FullName
            Status       = $Status
        }
    )
}

$Orphans  = @($Results | Where-Object { $_.Category -eq "Orphaned package" }  | Sort-Object SizeMB -Descending)
$WinParts = @($Results | Where-Object { $_.Category -eq "Windows component" } | Sort-Object SizeMB -Descending)
$Others   = @($Results | Where-Object { $_.Category -eq "Other folder" }      | Sort-Object SizeMB -Descending)

function Get-TotalMB {
    param([object[]]$Items)
    if ($Items.Count -eq 0) { return 0 }
    return [math]::Round((($Items | Measure-Object -Property SizeMB -Sum).Sum), 2)
}
$OrphanMB = Get-TotalMB $Orphans
$WinMB    = Get-TotalMB $WinParts
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
Write-Host "Windows components:       $($WinParts.Count) ($WinMB MB)"
Write-Host "Other folders:            $($Others.Count) ($OtherMB MB)"
Write-Host "Excluded:                 $($Excluded.Count)"
Write-Host ""

if ($Orphans.Count -eq 0) {
    Write-Host "No orphaned package folders were found." -ForegroundColor Green
}
else {
    Write-Host "Orphaned package folders:" -ForegroundColor Yellow
    Write-ResultTable $Orphans
}

if ($WinParts.Count -gt 0) {
    Write-Host "Windows components (keep these):" -ForegroundColor Green
    Write-ResultTable $WinParts
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
$Report.Add("Windows components:       $($WinParts.Count) ($WinMB MB)")
$Report.Add("Other folders:            $($Others.Count) ($OtherMB MB)")
$Report.Add("Excluded:                 $($Excluded.Count)")
if ($ExcludePatterns.Count -gt 0) {
    $Report.Add("Exclude patterns:         $($ExcludePatterns -join ', ')")
}
$Report.Add("")
$Report.Add("IMPORTANT:")
$Report.Add("This is an identification report only.")
$Report.Add("Nothing was deleted or modified.")
$Report.Add("")
$Report.Add("Orphaned package folders are named like an app package but")
$Report.Add("are not registered for this Windows user. Windows components")
$Report.Add("belong to Windows itself: keep them. Other folders are not")
$Report.Add("named like a package and are often used by Windows.")
$Report.Add("Verify each folder before deleting it.")
$Report.Add("")

Add-ReportSection -Report $Report -Title "Orphaned Package Folders" -Items $Orphans `
    -EmptyText "No orphaned package folders were detected."
Add-ReportSection -Report $Report -Title "Windows Components (keep)" -Items $WinParts `
    -EmptyText "No Windows component folders were detected."
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
        @($Orphans) + @($WinParts) + @($Others) |
            Select-Object @{ Name = 'Delete'; Expression = { '' } }, Category, FolderName, SizeMB, LastModified, FullPath, Status |
            Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8 -Force -ErrorAction Stop
        Write-Host "CSV created:" -ForegroundColor Green
        Write-Host $CsvPath -ForegroundColor White
    }

    if ($Html) {
        $tiles = @(
            [PSCustomObject]@{ Label = "Orphaned package folders"; Value = "$($Orphans.Count) ($OrphanMB MB)" }
            [PSCustomObject]@{ Label = "Windows components (keep)"; Value = "$($WinParts.Count)" }
            [PSCustomObject]@{ Label = "Other folders"; Value = "$($Others.Count)" }
            [PSCustomObject]@{ Label = "Excluded"; Value = "$($Excluded.Count)" }
            [PSCustomObject]@{ Label = "Registered packages"; Value = "$($InstalledFamilyNames.Count)" }
        )
        $sections = @(
            [PSCustomObject]@{ Kind = 'orphan'; Title = 'Orphaned package folders'; Items = $Orphans; TotalMB = $OrphanMB
                               Note = 'Named like an app package but not registered for this user. Main cleanup candidates: check each one first.' }
            [PSCustomObject]@{ Kind = 'windows'; Title = 'Windows components'; Items = $WinParts; TotalMB = $WinMB
                               Note = 'Belong to Windows itself. Keep these. The remover will not delete them.' }
            [PSCustomObject]@{ Kind = 'other'; Title = 'Other folders'; Items = $Others; TotalMB = $OtherMB
                               Note = 'Not named like a package. Often used by Windows. Review manually.' }
        )
        $who = @($env:USERNAME, $env:COMPUTERNAME) | Where-Object { $_ }
        $subtitle = (@(($who -join ' on '), (Get-Date -Format 'yyyy-MM-dd HH:mm'), $PackagesPath) | Where-Object { $_ }) -join ', '
        Write-HtmlReport -Path $HtmlPath -Sections $sections -Tiles $tiles -Subtitle $subtitle
        Write-Host "HTML report created:" -ForegroundColor Green
        Write-Host $HtmlPath -ForegroundColor White

        if ($Open) {
            try {
                Invoke-Item -LiteralPath $HtmlPath -ErrorAction Stop
            }
            catch {
                Write-Host "Could not open the HTML report: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
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
