<#
.SYNOPSIS
    WinPkgScan app: scan, mark, remove and restore leftover app folders in
    one window.

.DESCRIPTION
    A Windows window on top of the WinPkgScan scripts. It runs the scanner,
    shows the results with tick boxes, and runs the remover and restore
    scripts. Every safety check of the scripts still applies: marked folders
    are checked again before anything is removed, and they go to the
    Recycle Bin. Nothing is removed without your confirmation.

    - Settings: your exclude list, the "skip recently changed" rule, the
      administrator checks, and light, dark or system theme.
    - History: every scan, removal and restore, and the space freed over time.

    The app keeps its own scan results and logs in
    %LOCALAPPDATA%\WinPkgScan\app, so it does not touch the reports on your
    Desktop. Settings are in %LOCALAPPDATA%\WinPkgScan\settings.json.

.PARAMETER SelfTest
    Build the windows without showing them, check that every part loads, and
    exit with code 0 (OK) or 1 (problem). Used by the test suite.

.PARAMETER TestMode
    Load the app's functions only, without any window. Used by the test
    suite on systems without Windows.

.EXAMPLE
    .\WinPkgScan-App.ps1

.NOTES
    Version: 1.8.0
    Needs Windows (WPF). Start it with WinPkgScan-App.bat, or from the
    shortcuts that Install.bat adds.
#>

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$TestMode
)

$AppVersion = "1.8.0"

# ------------------------------------------------------------
# Row shown in the results list. A small class, so tick boxes update the
# marked total as soon as they are clicked.
# ------------------------------------------------------------

if (-not ('WinPkgScanApp.Row' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;

namespace WinPkgScanApp
{
    public class Row : INotifyPropertyChanged
    {
        private bool _marked;
        public event PropertyChangedEventHandler PropertyChanged;

        public bool Marked
        {
            get { return _marked; }
            set
            {
                if (_marked == value) { return; }
                _marked = value;
                PropertyChangedEventHandler handler = PropertyChanged;
                if (handler != null) { handler(this, new PropertyChangedEventArgs("Marked")); }
            }
        }

        public bool CanMark { get; set; }
        public string FolderName { get; set; }
        public double SizeMB { get; set; }
        public string LastModified { get; set; }
        public string Category { get; set; }
        public string Notes { get; set; }
        public bool IsNew { get; set; }
        public string NewText { get { return IsNew ? "New" : ""; } }
        public string FullPath { get; set; }
        public string Status { get; set; }
    }
}
'@
}
function Get-HistoryPath {
    return Join-Path (Join-Path $env:LOCALAPPDATA 'WinPkgScan') 'history.json'
}

function Read-History {
    # Scan history: past scans (with folder names), removals and restores.
    param([string]$Path)
    $history = [PSCustomObject]@{ Scans = @(); Removals = @(); Restores = @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $history }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ($text.Trim()) {
            $data = $text | ConvertFrom-Json -ErrorAction Stop
            if ($data.Scans)    { $history.Scans    = @($data.Scans) }
            if ($data.Removals) { $history.Removals = @($data.Removals) }
            if ($data.Restores) { $history.Restores = @($data.Restores) }
        }
    }
    catch {
        Write-Host "WARNING: The scan history could not be read, so it starts again: $($_.Exception.Message)" -ForegroundColor Yellow
        try {
            Copy-Item -LiteralPath $Path -Destination "$Path.bad" -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
        }
        catch {
            Write-Verbose "Could not keep a copy of the unreadable history: $($_.Exception.Message)"
        }
    }
    return $history
}

function Save-History {
    param($History, [string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false -Confirm:$false | Out-Null
    }
    $data = [ordered]@{
        Version  = 1
        Scans    = @(@($History.Scans)    | Select-Object -Last 50)
        Removals = @(@($History.Removals) | Select-Object -Last 1000)
        Restores = @(@($History.Restores) | Select-Object -Last 1000)
    }
    $json = ConvertTo-Json -InputObject $data -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-FreedMB {
    # Space freed with WinPkgScan: removals minus restores.
    param($History)
    $freed = 0.0
    foreach ($r in @($History.Removals)) { if ($r) { $freed += [double]$r.FreedMB } }
    foreach ($r in @($History.Restores)) { if ($r) { $freed -= [double]$r.SizeMB } }
    if ($freed -lt 0) { $freed = 0 }
    return [math]::Round($freed, 2)
}

# ------------------------------------------------------------
# Logic (no window). Tested by tests/WinPkgScan-App.Tests.ps1.
# ------------------------------------------------------------

function Get-AppPath {
    # Where the app keeps its files, and where the scripts are.
    param([string]$ScriptFolder = $PSScriptRoot)
    $data = Join-Path $env:LOCALAPPDATA 'WinPkgScan'
    $app  = Join-Path $data 'app'
    [PSCustomObject]@{
        DataDir    = $data
        AppDir     = $app
        Report     = Join-Path $app 'Orphaned-Appx-Packages.txt'
        Csv        = Join-Path $app 'Orphaned-Appx-Packages.csv'
        Html       = Join-Path $app 'Orphaned-Appx-Packages.html'
        Marked     = Join-Path $app 'WinPkgScan-marked-app.csv'
        PreviewLog = Join-Path $app 'preview-log.csv'
        Output     = Join-Path $app 'last-output.txt'
        History    = Join-Path $data 'history.json'
        Scanner    = Join-Path $ScriptFolder 'Find-OrphanedAppxFolders.ps1'
        Remover    = Join-Path $ScriptFolder 'Remove-OrphanedAppxFolders.ps1'
        Restorer   = Join-Path $ScriptFolder 'Restore-OrphanedAppxFolders.ps1'
        Settings   = Join-Path $data 'settings.json'
        Exclude    = Join-Path $data 'exclude.txt'
        Icon       = Join-Path $ScriptFolder 'WinPkgScan.ico'
    }
}

function ConvertTo-AppRow {
    param($Item)
    $size = 0.0
    [void][double]::TryParse("$($Item.SizeMB)", [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$size)
    $row = New-Object WinPkgScanApp.Row
    $row.FolderName   = "$($Item.FolderName)"
    $row.SizeMB       = $size
    $row.LastModified = "$($Item.LastModified)"
    $row.Category     = "$($Item.Category)"
    $row.Notes        = "$($Item.Notes)"
    $row.IsNew        = ("$($Item.New)" -eq 'Yes')
    $row.FullPath     = "$($Item.FullPath)"
    $row.Status       = "$($Item.Status)"
    # Only orphaned package folders can be marked. Windows components and
    # other folders are shown for information.
    $row.CanMark      = ($row.Category -eq 'Orphaned package')
    return $row
}

function Read-ScanResult {
    # Reads the scanner CSV into rows for the list.
    param([string]$CsvPath)
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) { return }
    foreach ($item in @(Import-Csv -LiteralPath $CsvPath)) {
        if ($item.FolderName) { $rows.Add((ConvertTo-AppRow $item)) }
    }
    return $rows.ToArray()
}

function Get-MarkedTotal {
    param([object[]]$Rows)
    $marked = @($Rows | Where-Object { $_.Marked -and $_.CanMark })
    $mb = 0.0
    foreach ($r in $marked) { $mb += $r.SizeMB }
    [PSCustomObject]@{ Count = $marked.Count; SizeMB = [math]::Round($mb, 2) }
}

function Test-RowVisible {
    # View: 0 = orphaned folders, 1 = new since last scan, 2 = all folders.
    param($Row, [int]$View, [string]$Filter)
    if ($View -eq 0 -and $Row.Category -ne 'Orphaned package') { return $false }
    if ($View -eq 1 -and -not $Row.IsNew) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $q = $Filter.Trim()
        $hit = ($Row.FolderName -and $Row.FolderName.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
               ($Row.Notes -and $Row.Notes.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not $hit) { return $false }
    }
    return $true
}

function Export-MarkedCsv {
    # Writes the marked rows in the remover's CSV format (UTF-8 with BOM).
    param([object[]]$Rows, [string]$Path)
    $marked = @($Rows | Where-Object { $_.Marked -and $_.CanMark } | ForEach-Object {
        [PSCustomObject]@{
            Delete       = 'Yes'
            Category     = $_.Category
            FolderName   = $_.FolderName
            SizeMB       = $_.SizeMB.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
            LastModified = $_.LastModified
            FullPath     = $_.FullPath
            Status       = $_.Status
            Notes        = $_.Notes
        }
    })
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lines = @($marked | ConvertTo-Csv -NoTypeInformation)
    [System.IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    return $marked.Count
}

function Get-LogSummary {
    # Reads a delete log and counts what happened to each folder.
    param([string]$Path)
    $rows = if (Test-Path -LiteralPath $Path -PathType Leaf) { @(Import-Csv -LiteralPath $Path) } else { @() }
    $count = { param($a) @($rows | Where-Object Action -eq $a).Count }
    $mb = 0.0
    foreach ($r in @($rows | Where-Object { $_.Action -in 'Recycled', 'Deleted', 'WhatIf' })) {
        $v = 0.0
        [void][double]::TryParse("$($r.SizeMB)", [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)
        $mb += $v
    }
    [PSCustomObject]@{
        Rows     = $rows
        Recycled = & $count 'Recycled'
        Deleted  = & $count 'Deleted'
        WhatIf   = & $count 'WhatIf'
        Skipped  = & $count 'Skipped'
        Failed   = & $count 'Failed'
        SizeMB   = [math]::Round($mb, 2)
    }
}

function Format-LogSummary {
    # The text shown after Preview or Move to Recycle Bin.
    param($Summary, [switch]$Preview)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Preview) {
        $lines.Add("Would move to the Recycle Bin: $($Summary.WhatIf) ($($Summary.SizeMB) MB)")
    }
    else {
        $lines.Add("Moved to the Recycle Bin: $($Summary.Recycled + $Summary.Deleted) ($($Summary.SizeMB) MB)")
    }
    $lines.Add("Skipped: $($Summary.Skipped)")
    if ($Summary.Failed -gt 0) { $lines.Add("Failed: $($Summary.Failed)") }
    $problems = @($Summary.Rows | Where-Object { $_.Action -in 'Skipped', 'Failed' } | Select-Object -First 12)
    if ($problems.Count -gt 0) {
        $lines.Add('')
        foreach ($p in $problems) { $lines.Add("$($p.Action): $($p.FolderName)  -  $($p.Reason)") }
        $more = @($Summary.Rows | Where-Object { $_.Action -in 'Skipped', 'Failed' }).Count - $problems.Count
        if ($more -gt 0) { $lines.Add("...and $more more. See the log for all of them.") }
    }
    if (-not $Preview -and ($Summary.Recycled -gt 0)) {
        $lines.Add('')
        $lines.Add('You can put them back with Restore last delete.')
    }
    return ($lines -join "`n")
}

function Get-NewestDeleteLog {
    param([string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return $null }
    return Get-ChildItem -LiteralPath $Folder -Filter 'WinPkgScan-DeleteLog-*.csv' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function ConvertTo-ArgumentText {
    # Joins arguments for a command line, quoting any with spaces.
    param([string[]]$Arguments)
    $parts = foreach ($a in $Arguments) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }
    return ($parts -join ' ')
}

function Get-ScriptCommandLine {
    # Arguments for powershell.exe to run one of the WinPkgScan scripts.
    param([string]$Script, [string[]]$Arguments = @())
    return (ConvertTo-ArgumentText (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments))
}

function Get-PowerShellPath {
    try { return (Get-Process -Id $PID).Path } catch { return 'powershell.exe' }
}

function Get-HistorySummary {
    param([string]$Path)
    $history  = Read-History -Path $Path
    $lastScan = @($history.Scans) | Select-Object -Last 1
    [PSCustomObject]@{
        LastScan = if ($lastScan) { "$($lastScan.Time)" } else { '' }
        Scans    = @($history.Scans).Count
        FreedMB  = Get-FreedMB $history
    }
}


# ------------------------------------------------------------
# Settings, theme, progress and history logic (no window).
# ------------------------------------------------------------

function Get-DefaultAppSetting {
    [PSCustomObject]@{ MinAgeDays = 30; AdminChecks = 'Auto'; Theme = 'System' }
}

function Read-AppSetting {
    # Reads settings.json. Missing or invalid values fall back to the defaults.
    param([string]$Path)
    $setting = Get-DefaultAppSetting
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $setting }
    try {
        $data = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
        $days = 0
        if ($null -ne $data.MinAgeDays -and [int]::TryParse("$($data.MinAgeDays)", [ref]$days) -and $days -ge 0 -and $days -le 36500) {
            $setting.MinAgeDays = $days
        }
        $admin = @('Auto', 'On', 'Off') | Where-Object { $_ -eq "$($data.AdminChecks)" } | Select-Object -First 1
        if ($admin) { $setting.AdminChecks = $admin }
        $theme = @('System', 'Light', 'Dark') | Where-Object { $_ -eq "$($data.Theme)" } | Select-Object -First 1
        if ($theme) { $setting.Theme = $theme }
    }
    catch {
        Write-Verbose "Settings could not be read, using defaults: $($_.Exception.Message)"
    }
    return $setting
}

function Save-AppSetting {
    param($Setting, [string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject ([ordered]@{
        MinAgeDays  = [int]$Setting.MinAgeDays
        AdminChecks = "$($Setting.AdminChecks)"
        Theme       = "$($Setting.Theme)"
    })
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Test-MinAgeDay {
    # True if the text is a whole number of days from 0 to 36500.
    param([string]$Text)
    $days = 0
    return ([int]::TryParse("$Text".Trim(), [ref]$days) -and $days -ge 0 -and $days -le 36500)
}

function Get-RuleText {
    # The safety note under the marked total.
    param([int]$Days)
    $text = 'Marked folders are checked again before anything is removed, and go to the Recycle Bin.'
    if ($Days -gt 0) { $text += " Folders changed in the last $Days day$(if ($Days -ne 1) { 's' }) are skipped." }
    return $text
}

function Get-SystemUsesLightTheme {
    # Windows "app mode" setting: $true light, $false dark, $null unknown.
    try {
        $value = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
            -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ([int]$value -ne 0)
    }
    catch {
        return $null
    }
}

function Resolve-ThemeName {
    # The theme to show: the setting, or Windows' app mode for "System".
    param([string]$Setting, $SystemUsesLight)
    if ($Setting -eq 'Light' -or $Setting -eq 'Dark') { return $Setting }
    if ($SystemUsesLight -eq $false) { return 'Dark' }
    return 'Light'
}

function Get-ThemePalette {
    param([string]$Name)
    if ($Name -eq 'Dark') {
        return [ordered]@{
            BgBrush = '#161618'; CardBrush = '#1F1F22'; TextBrush = '#ECECEE'; MutedBrush = '#9A9AA2'
            LineBrush = '#33333A'; AccentBrush = '#6EA0FF'; AccentTextBrush = '#0B1530'; HeadBrush = '#26262A'
            MarkBrush = '#1D2A42'; AltBrush = '#1C1C1F'; InputBrush = '#26262A'; HoverBrush = '#2C2C31'
        }
    }
    return [ordered]@{
        BgBrush = '#F7F7F5'; CardBrush = '#FFFFFF'; TextBrush = '#1D1D1F'; MutedBrush = '#6B6B70'
        LineBrush = '#E2E2E0'; AccentBrush = '#2F6FDE'; AccentTextBrush = '#FFFFFF'; HeadBrush = '#F0F0EE'
        MarkBrush = '#EAF1FD'; AltBrush = '#FAFAF8'; InputBrush = '#FFFFFF'; HoverBrush = '#F0F0EE'
    }
}

function Get-ProgressInfo {
    # Reads a "PROGRESS done/total name" line printed by the scanner.
    param([string]$Line)
    $m = [regex]::Match("$Line", '^PROGRESS (\d+)/(\d+)\s*(.*)$')
    if (-not $m.Success) { return $null }
    $done  = [int]$m.Groups[1].Value
    $total = [int]$m.Groups[2].Value
    [PSCustomObject]@{
        Done    = $done
        Total   = $total
        Name    = $m.Groups[3].Value.Trim()
        Percent = if ($total -gt 0) { [math]::Round(100.0 * [math]::Min($done, $total) / $total, 1) } else { 0 }
    }
}

function Get-OutputLastLine {
    # Last non-empty line of a file that another process may still be writing.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $take = [int][math]::Min($stream.Length, 8192)
            if ($take -le 0) { return '' }
            [void]$stream.Seek(-$take, [System.IO.SeekOrigin]::End)
            $buffer = New-Object byte[] $take
            $read = $stream.Read($buffer, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        }
        finally {
            $stream.Dispose()
        }
        $lines = @($text -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($lines.Count -eq 0) { return '' }
        return $lines[-1]
    }
    catch {
        return ''
    }
}

function Get-ScanArgument {
    param($Paths, $Setting)
    @('-Csv', '-Html', '-NoPause', '-ProgressLines', '-AdminChecks', "$($Setting.AdminChecks)", '-ReportPath', $Paths.Report)
}

function Get-RemoveArgument {
    param($Paths, $Setting, [string]$LogPath, [switch]$Preview)
    @('-CsvPath', $Paths.Marked, '-LogPath', $LogPath, '-NoPause',
      '-MinAgeDays', "$([int]$Setting.MinAgeDays)", '-AdminChecks', "$($Setting.AdminChecks)",
      $(if ($Preview) { '-WhatIf' } else { '-Force' }))
}

function Get-DefaultExcludeText {
    return (@(
        '# Your WinPkgScan exclude list'
        '#'
        '# Folders matching a line here are left out of scans and are never deleted.'
        '# One folder name or pattern per line. * matches anything, ? matches one character.'
        '# Lines starting with # are ignored. Example:'
        '# Contoso.*'
    ) -join "`r`n") + "`r`n"
}

function Read-ExcludeText {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return [System.IO.File]::ReadAllText($Path) }
    return Get-DefaultExcludeText
}

function Save-ExcludeText {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $normal = ("$Text" -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($Path, $normal + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
}

function Get-ExcludeCount {
    # Number of active patterns in an exclude list.
    param([string]$Text)
    return @("$Text" -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }).Count
}

function Get-HistoryActivity {
    # Scans, removals and restores from the history, newest first.
    param($History)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($History.Scans)) {
        if (-not $s) { continue }
        $rows.Add([PSCustomObject]@{ Time = "$($s.Time)"; Event = 'Scan'; Folders = [int]$s.Orphans
            SizeMB = [math]::Round([double]$s.OrphanMB, 2); Detail = "$([int]$s.Orphans) orphaned folders found" })
    }
    foreach ($r in @($History.Removals)) {
        if (-not $r) { continue }
        $eventName = if ($r.Mode -eq 'Deleted') { 'Deleted permanently' } else { 'Moved to Recycle Bin' }
        $rows.Add([PSCustomObject]@{ Time = "$($r.Time)"; Event = $eventName; Folders = [int]$r.Folders
            SizeMB = [math]::Round([double]$r.FreedMB, 2); Detail = "$([int]$r.Folders) folders removed" })
    }
    foreach ($r in @($History.Restores)) {
        if (-not $r) { continue }
        $rows.Add([PSCustomObject]@{ Time = "$($r.Time)"; Event = 'Restored'; Folders = [int]$r.Folders
            SizeMB = [math]::Round([double]$r.SizeMB, 2); Detail = "$([int]$r.Folders) folders put back" })
    }
    return @($rows | Sort-Object Time -Descending)
}

function Get-FreedSeries {
    # Running total of space freed after each removal or restore, oldest first.
    param($History)
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($History.Removals)) { if ($r) { $events.Add([PSCustomObject]@{ Time = "$($r.Time)"; Delta = [double]$r.FreedMB }) } }
    foreach ($r in @($History.Restores)) { if ($r) { $events.Add([PSCustomObject]@{ Time = "$($r.Time)"; Delta = -[double]$r.SizeMB }) } }
    $total = 0.0
    foreach ($e in @($events | Sort-Object Time)) {
        $total = [math]::Max(0.0, $total + $e.Delta)
        [PSCustomObject]@{ Time = $e.Time; TotalMB = [math]::Round($total, 2) }
    }
}

function Get-ChartPoint {
    # Scales a freed-space series into a Width x Height box (y grows downward).
    param([object[]]$Series, [double]$Width, [double]$Height)
    $count = @($Series).Count
    if ($count -eq 0) { return }
    $max = (@($Series) | Measure-Object -Property TotalMB -Maximum).Maximum
    if ($max -le 0) { $max = 1 }
    for ($i = 0; $i -lt $count; $i++) {
        $x = if ($count -eq 1) { $Width / 2 } else { $Width * $i / ($count - 1) }
        [PSCustomObject]@{
            X = [math]::Round($x, 2)
            Y = [math]::Round($Height - ($Height * $Series[$i].TotalMB / $max), 2)
        }
    }
}

function Format-Size {
    # 950 MB, 1.25 GB.
    param([double]$MB)
    if ($MB -ge 1024) { return ('{0:0.##} GB' -f ($MB / 1024)) }
    return ('{0:0.##} MB' -f $MB)
}

if ($TestMode) { return }

# ------------------------------------------------------------
# Windows (Windows only)
# ------------------------------------------------------------

# WPF needs a single-threaded apartment. Restart with -STA if needed.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $argLine = Get-ScriptCommandLine -Script $PSCommandPath -Arguments $(if ($SelfTest) { @('-SelfTest') } else { @() })
    $proc = Start-Process -FilePath (Get-PowerShellPath) -ArgumentList "-STA $argLine" -WindowStyle Hidden -PassThru -Wait:$SelfTest
    if ($SelfTest) { exit $proc.ExitCode }
    exit 0
}

# Colours and styles shared by both windows. Colours are swapped at run time
# for the light or dark theme.
$SharedResources = @'
    <SolidColorBrush x:Key="BgBrush" Color="#F7F7F5"/>
    <SolidColorBrush x:Key="CardBrush" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="TextBrush" Color="#1D1D1F"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#6B6B70"/>
    <SolidColorBrush x:Key="LineBrush" Color="#E2E2E0"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#2F6FDE"/>
    <SolidColorBrush x:Key="AccentTextBrush" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="HeadBrush" Color="#F0F0EE"/>
    <SolidColorBrush x:Key="MarkBrush" Color="#EAF1FD"/>
    <SolidColorBrush x:Key="AltBrush" Color="#FAFAF8"/>
    <SolidColorBrush x:Key="InputBrush" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="HoverBrush" Color="#F0F0EE"/>

    <Style TargetType="Button">
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Background" Value="{DynamicResource CardBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentTextBrush}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource CardBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="12,10"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
    </Style>
    <Style x:Key="CardValue" TargetType="TextBlock">
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Text" Value="-"/>
    </Style>
    <Style x:Key="CardLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource InputBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Padding" Value="4,3"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="{DynamicResource CardBrush}"/>
      <Setter Property="RowBackground" Value="{DynamicResource CardBrush}"/>
      <Setter Property="AlternatingRowBackground" Value="{DynamicResource AltBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="RowHeight" Value="30"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="{DynamicResource HeadBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="{DynamicResource MarkBrush}"/>
          <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="{DynamicResource InputBrush}" BorderBrush="{DynamicResource LineBrush}"
                            BorderThickness="1" CornerRadius="6">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0" Data="M 0 0 L 4 4 L 8 0"
                            Stroke="{DynamicResource MutedBrush}" StrokeThickness="1.5"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Margin="10,0,28,0" VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True"
                     Focusable="False" PopupAnimation="Fade">
                <Border Background="{DynamicResource CardBrush}" BorderBrush="{DynamicResource LineBrush}" BorderThickness="1"
                        CornerRadius="6" Margin="0,2,0,0" Padding="0,4"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                  <ScrollViewer MaxHeight="{TemplateBinding MaxDropDownHeight}">
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Padding="10,5" Background="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource MarkBrush}"/>
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource HoverBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="2,4,2,6" Margin="0,0,20,0" Background="Transparent">
              <ContentPresenter ContentSource="Header" TextElement.FontSize="14" TextElement.FontWeight="SemiBold"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinPkgScan" Width="1100" Height="760" MinWidth="840" MinHeight="560"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource BgBrush}" Foreground="{DynamicResource TextBrush}">
  <Window.Resources>
<!--SHARED-->
  </Window.Resources>

  <DockPanel Margin="18">

    <!-- Header -->
    <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
      <StackPanel>
        <TextBlock Text="WinPkgScan" FontSize="22" FontWeight="SemiBold"/>
        <TextBlock x:Name="SubTitle" Style="{StaticResource Muted}" Text="Find and safely remove leftover app folders"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <Button x:Name="SettingsButton" Content="Settings"/>
        <Button x:Name="ReportButton" Content="Open HTML report"/>
        <Button x:Name="AdminScanButton" Content="Scan as administrator"
                ToolTip="Extra checks: apps still registered to you in an unfinished state are kept out"/>
        <Button x:Name="ScanButton" Content="Scan" Style="{StaticResource Primary}"/>
      </StackPanel>
    </Grid>

    <!-- Status bar -->
    <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <TextBlock x:Name="StatusText" Style="{StaticResource Muted}" VerticalAlignment="Center" TextWrapping="NoWrap"
                 TextTrimming="CharacterEllipsis" Margin="0,0,180,0" Text="Click Scan to find leftover app folders."/>
      <ProgressBar x:Name="BusyBar" IsIndeterminate="True" Width="160" Height="6" Minimum="0" Maximum="100"
                   HorizontalAlignment="Right" Visibility="Collapsed"
                   Foreground="{DynamicResource AccentBrush}" Background="{DynamicResource LineBrush}" BorderThickness="0"/>
    </Grid>

    <TabControl x:Name="Tabs" Background="Transparent" BorderThickness="0" Padding="0,12,0,0">

      <!-- Results -->
      <TabItem x:Name="ResultsTab" Header="Results">
        <DockPanel>
          <UniformGrid DockPanel.Dock="Top" Columns="5" Margin="0,0,-10,12">
            <Border Style="{StaticResource Card}">
              <StackPanel><TextBlock x:Name="OrphanValue" Style="{StaticResource CardValue}"/>
                <TextBlock Style="{StaticResource CardLabel}" Text="Orphaned folders"/></StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel><TextBlock x:Name="NewValue" Style="{StaticResource CardValue}"/>
                <TextBlock Style="{StaticResource CardLabel}" Text="New since last scan"/></StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel><TextBlock x:Name="WindowsValue" Style="{StaticResource CardValue}"/>
                <TextBlock Style="{StaticResource CardLabel}" Text="Windows components (keep)"/></StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel><TextBlock x:Name="OtherValue" Style="{StaticResource CardValue}"/>
                <TextBlock Style="{StaticResource CardLabel}" Text="Other folders"/></StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel><TextBlock x:Name="FreedValue" Style="{StaticResource CardValue}"/>
                <TextBlock Style="{StaticResource CardLabel}" Text="Freed with WinPkgScan"/></StackPanel>
            </Border>
          </UniformGrid>

          <!-- Action bar -->
          <Border DockPanel.Dock="Bottom" Style="{StaticResource Card}" Margin="0,12,0,0">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="RestoreButton" Content="Restore last delete"/>
                <Button x:Name="PreviewButton" Content="Preview" IsEnabled="False"/>
                <Button x:Name="DeleteButton" Content="Move to Recycle Bin" Style="{StaticResource Primary}" IsEnabled="False"/>
              </StackPanel>
              <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="MarkedText" Text="0 marked (0.00 MB)" FontWeight="SemiBold"/>
                <TextBlock x:Name="RuleText" Style="{StaticResource Muted}" FontSize="12"
                           Text="Marked folders are checked again before anything is removed, and go to the Recycle Bin."/>
              </StackPanel>
            </DockPanel>
          </Border>

          <!-- View and filter -->
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8" LastChildFill="True">
            <TextBlock Text="Show" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="ViewBox" Width="200" SelectedIndex="0" VerticalContentAlignment="Center">
              <ComboBoxItem Content="Orphaned folders"/>
              <ComboBoxItem Content="New since last scan"/>
              <ComboBoxItem Content="All folders"/>
            </ComboBox>
            <CheckBox x:Name="MarkAllBox" Content="Mark all shown" VerticalAlignment="Center" Margin="16,0,0,0"/>
            <TextBlock Text="Filter" VerticalAlignment="Center" Margin="16,0,8,0"/>
            <TextBox x:Name="FilterBox" VerticalContentAlignment="Center" ToolTip="Type part of a folder name or note"/>
          </DockPanel>

          <!-- Results list -->
          <Grid>
            <DataGrid x:Name="ResultsGrid" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
                      SelectionMode="Extended">
              <DataGrid.RowStyle>
                <Style TargetType="DataGridRow">
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding CanMark}" Value="False">
                      <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
                    </DataTrigger>
                    <DataTrigger Binding="{Binding Marked}" Value="True">
                      <Setter Property="Background" Value="{DynamicResource MarkBrush}"/>
                    </DataTrigger>
                  </Style.Triggers>
                </Style>
              </DataGrid.RowStyle>
              <DataGrid.Columns>
                <DataGridTemplateColumn Width="40" CanUserSort="False">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <CheckBox IsChecked="{Binding Marked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                IsEnabled="{Binding CanMark}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
                <DataGridTextColumn Header="Folder" Binding="{Binding FolderName}" Width="2*" IsReadOnly="True"/>
                <DataGridTextColumn Header="New" Binding="{Binding NewText}" Width="50" IsReadOnly="True" FontWeight="SemiBold"/>
                <DataGridTextColumn Header="Size (MB)" Binding="{Binding SizeMB, StringFormat=N2}" Width="90" IsReadOnly="True">
                  <DataGridTextColumn.ElementStyle>
                    <Style TargetType="TextBlock"><Setter Property="HorizontalAlignment" Value="Right"/></Style>
                  </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="Last modified" Binding="{Binding LastModified}" Width="110" IsReadOnly="True"/>
                <DataGridTextColumn Header="Group" Binding="{Binding Category}" Width="140" IsReadOnly="True"/>
                <DataGridTextColumn Header="Notes" Binding="{Binding Notes}" Width="*" IsReadOnly="True"/>
              </DataGrid.Columns>
            </DataGrid>
            <TextBlock x:Name="EmptyText" HorizontalAlignment="Center" VerticalAlignment="Center"
                       Style="{StaticResource Muted}" FontSize="14" TextAlignment="Center" MaxWidth="420"
                       Text="No scan yet. Click Scan to find leftover app folders."/>
          </Grid>
        </DockPanel>
      </TabItem>

      <!-- History -->
      <TabItem x:Name="HistoryTab" Header="History">
        <DockPanel>
          <UniformGrid DockPanel.Dock="Top" Columns="3" Margin="0,0,-10,12">
            <Border Style="{StaticResource Card}">
              <StackPanel><TextBlock x:Name="HistScansValue" Style="{StaticResource CardValue}"/>
                <TextBlock Style="{StaticResource CardLabel}" Text="Scans"/></StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel><TextBlock x:Name="HistRemovedValue" Style="{StaticResource CardValue}"/>
                <TextBlock Style="{StaticResource CardLabel}" Text="Folders removed"/></StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel><TextBlock x:Name="HistFreedValue" Style="{StaticResource CardValue}"/>
                <TextBlock Style="{StaticResource CardLabel}" Text="Freed with WinPkgScan"/></StackPanel>
            </Border>
          </UniformGrid>

          <Border DockPanel.Dock="Top" Style="{StaticResource Card}" Margin="0,0,0,12">
            <DockPanel>
              <TextBlock DockPanel.Dock="Top" Text="Space freed over time" FontWeight="SemiBold" Margin="0,0,0,8"/>
              <Grid DockPanel.Dock="Bottom" Margin="0,4,0,0">
                <TextBlock x:Name="ChartStartText" Style="{StaticResource Muted}" FontSize="11" HorizontalAlignment="Left"/>
                <TextBlock x:Name="ChartEndText" Style="{StaticResource Muted}" FontSize="11" HorizontalAlignment="Right"/>
              </Grid>
              <Grid Height="150">
                <Canvas x:Name="FreedChart" ClipToBounds="True"/>
                <TextBlock x:Name="ChartMaxText" Style="{StaticResource Muted}" FontSize="11"
                           HorizontalAlignment="Left" VerticalAlignment="Top"/>
                <TextBlock x:Name="ChartEmptyText" Style="{StaticResource Muted}" HorizontalAlignment="Center"
                           VerticalAlignment="Center" Text="Remove some folders to see the space freed over time."/>
              </Grid>
            </DockPanel>
          </Border>

          <DataGrid x:Name="ActivityGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Time" Binding="{Binding Time}" Width="140"/>
              <DataGridTextColumn Header="Event" Binding="{Binding Event}" Width="170"/>
              <DataGridTextColumn Header="Folders" Binding="{Binding Folders}" Width="80"/>
              <DataGridTextColumn Header="Size (MB)" Binding="{Binding SizeMB, StringFormat=N2}" Width="100"/>
              <DataGridTextColumn Header="Details" Binding="{Binding Detail}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </DockPanel>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@

$SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinPkgScan settings" Width="560" Height="600" MinWidth="460" MinHeight="480"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource BgBrush}" Foreground="{DynamicResource TextBrush}">
  <Window.Resources>
<!--SHARED-->
  </Window.Resources>
  <DockPanel Margin="18">
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="CancelButton" Content="Cancel" IsCancel="True"/>
      <Button x:Name="SaveButton" Content="Save" Style="{StaticResource Primary}" IsDefault="True"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Top">
      <TextBlock Text="Settings" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,12"/>

      <TextBlock Text="Skip folders changed in the last" FontWeight="SemiBold"/>
      <StackPanel Orientation="Horizontal" Margin="0,4,0,2">
        <TextBox x:Name="MinAgeBox" Width="70" TextAlignment="Right"/>
        <TextBlock Text="days" VerticalAlignment="Center" Margin="8,0,0,0"/>
      </StackPanel>
      <TextBlock Style="{StaticResource Muted}" FontSize="12" Margin="0,0,0,12"
                 Text="A folder with anything changed more recently is never removed. 0 turns this off. Default 30."/>

      <TextBlock Text="Administrator checks" FontWeight="SemiBold"/>
      <ComboBox x:Name="AdminBox" Width="200" HorizontalAlignment="Left" Margin="0,4,0,2">
        <ComboBoxItem Content="Auto"/>
        <ComboBoxItem Content="On"/>
        <ComboBoxItem Content="Off"/>
      </ComboBox>
      <TextBlock Style="{StaticResource Muted}" FontSize="12" Margin="0,0,0,12"
                 Text="Auto runs them when the scan runs as administrator. On always tries them. Off never does."/>

      <TextBlock Text="Theme" FontWeight="SemiBold"/>
      <ComboBox x:Name="ThemeBox" Width="200" HorizontalAlignment="Left" Margin="0,4,0,12">
        <ComboBoxItem Content="System"/>
        <ComboBoxItem Content="Light"/>
        <ComboBoxItem Content="Dark"/>
      </ComboBox>

      <TextBlock Text="Exclude list" FontWeight="SemiBold"/>
      <TextBlock Style="{StaticResource Muted}" FontSize="12" Margin="0,2,0,4"
                 Text="Folders matching a line here are left out of scans and never removed. One name or pattern per line, e.g. Contoso.*"/>
    </StackPanel>
    <TextBlock x:Name="ExcludePathText" DockPanel.Dock="Bottom" Style="{StaticResource Muted}" FontSize="11" Margin="0,4,0,0"/>
    <TextBox x:Name="ExcludeBox" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             FontFamily="Consolas" TextWrapping="NoWrap" VerticalContentAlignment="Top"/>
  </DockPanel>
</Window>
'@

$ControlNames = @(
    'SubTitle', 'SettingsButton', 'ReportButton', 'AdminScanButton', 'ScanButton',
    'StatusText', 'BusyBar', 'Tabs', 'ResultsTab', 'HistoryTab',
    'OrphanValue', 'NewValue', 'WindowsValue', 'OtherValue', 'FreedValue',
    'RestoreButton', 'PreviewButton', 'DeleteButton', 'MarkedText', 'RuleText',
    'ViewBox', 'MarkAllBox', 'FilterBox', 'ResultsGrid', 'EmptyText',
    'HistScansValue', 'HistRemovedValue', 'HistFreedValue',
    'ChartStartText', 'ChartEndText', 'FreedChart', 'ChartMaxText', 'ChartEmptyText', 'ActivityGrid'
)

$SettingsControlNames = @('CancelButton', 'SaveButton', 'MinAgeBox', 'AdminBox', 'ThemeBox', 'ExcludeBox', 'ExcludePathText')

function Show-Message {
    param([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK')
    if ($script:MainWindow -and $script:MainWindow.IsVisible) {
        return [System.Windows.MessageBox]::Show($script:MainWindow, $Text, 'WinPkgScan', $Buttons, $Icon)
    }
    return [System.Windows.MessageBox]::Show($Text, 'WinPkgScan', $Buttons, $Icon)
}

function Get-OutputTail {
    # Last lines a script printed, for error messages.
    if (Test-Path -LiteralPath $Paths.Output) {
        return ((Get-Content -LiteralPath $Paths.Output -Tail 12) -join "`n")
    }
    return ''
}

function Get-WindowFromXaml {
    # Loads a window from XAML with the shared styles.
    param([string]$Text)
    $full = $Text.Replace('<!--SHARED-->', $SharedResources)
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$full)
    return [System.Windows.Markup.XamlReader]::Load($reader)
}

function Show-DarkTitleBar {
    # Dark or light title bar to match the theme (Windows 10 20H1 and later).
    param($Window, [bool]$Dark)
    try {
        if (-not ('WinPkgScanApp.Dwm' -as [type])) {
            Add-Type -Namespace WinPkgScanApp -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attribute, ref int value, int size);
'@
        }
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).EnsureHandle()
        $value = [int]$Dark
        if ([WinPkgScanApp.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$value, 4) -ne 0) {
            [void][WinPkgScanApp.Dwm]::DwmSetWindowAttribute($hwnd, 19, [ref]$value, 4)
        }
    }
    catch {
        Write-Verbose "Title bar theme not changed: $($_.Exception.Message)"
    }
}

function Show-Theme {
    # Puts the light or dark colours into a window.
    param($Window, [string]$Name)
    $converter = New-Object System.Windows.Media.BrushConverter
    $palette = Get-ThemePalette -Name $Name
    foreach ($key in $palette.Keys) {
        $brush = $converter.ConvertFromString($palette[$key])
        $brush.Freeze()
        $Window.Resources[$key] = $brush
    }
    Show-DarkTitleBar -Window $Window -Dark ($Name -eq 'Dark')
}

function Get-CurrentThemeName {
    return Resolve-ThemeName -Setting $script:Setting.Theme -SystemUsesLight (Get-SystemUsesLightTheme)
}

function Show-WindowIcon {
    param($Window)
    if (-not (Test-Path -LiteralPath $Paths.Icon -PathType Leaf)) { return }
    try { $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri $Paths.Icon)) }
    catch { Write-Verbose "Icon not loaded: $($_.Exception.Message)" }
}

function Show-BusyState {
    param([bool]$Busy, [string]$Text)
    $script:IsBusy = $Busy
    $ui.BusyBar.IsIndeterminate = $true
    $ui.BusyBar.Value = 0
    $ui.BusyBar.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    foreach ($b in 'ScanButton', 'AdminScanButton', 'RestoreButton', 'ReportButton', 'SettingsButton') { $ui[$b].IsEnabled = -not $Busy }
    if ($Text) { $ui.StatusText.Text = $Text }
    Show-MarkedTotal
}

function Show-Progress {
    # Moves the progress bar for a "PROGRESS done/total name" line.
    param($Info)
    if (-not $Info) { return }
    $ui.BusyBar.IsIndeterminate = $false
    $ui.BusyBar.Value = $Info.Percent
    $ui.StatusText.Text = "Scanning... $($Info.Done) of $($Info.Total) folders  $($Info.Name)"
}

function Show-MarkedTotal {
    $total = Get-MarkedTotal -Rows @($script:Rows)
    $ui.MarkedText.Text = "$($total.Count) marked ($(Format-Size $total.SizeMB))"
    $canAct = ($total.Count -gt 0) -and -not $script:IsBusy
    $ui.PreviewButton.IsEnabled = $canAct
    $ui.DeleteButton.IsEnabled  = $canAct
}

function Show-ResultView {
    if ($script:View) { $script:View.Refresh() }
    $shown = 0
    if ($script:View) { foreach ($r in $script:View) { $shown++ } }
    if (@($script:Rows).Count -eq 0) {
        $ui.EmptyText.Text = if (Test-Path -LiteralPath $Paths.Csv) { 'No leftover app folders were found.' } else { 'No scan yet. Click Scan to find leftover app folders.' }
        $ui.EmptyText.Visibility = 'Visible'
    }
    elseif ($shown -eq 0) {
        $ui.EmptyText.Text = 'Nothing to show here. Try another view or clear the filter.'
        $ui.EmptyText.Visibility = 'Visible'
    }
    else {
        $ui.EmptyText.Visibility = 'Collapsed'
    }
}

function Show-FreedChart {
    # Draws the space freed over time. Width and Height default to the canvas size.
    param($History, [double]$Width = 0, [double]$Height = 0)
    $canvas = $ui.FreedChart
    $canvas.Children.Clear()
    if ($Width -le 0)  { $Width  = $canvas.ActualWidth }
    if ($Height -le 0) { $Height = $canvas.ActualHeight }
    $series = @(Get-FreedSeries -History $History)
    if ($series.Count -eq 0) {
        $ui.ChartEmptyText.Visibility = 'Visible'
        $ui.ChartMaxText.Text = ''; $ui.ChartStartText.Text = ''; $ui.ChartEndText.Text = ''
        return
    }
    $ui.ChartEmptyText.Visibility = 'Collapsed'
    $max = ($series | Measure-Object -Property TotalMB -Maximum).Maximum
    $ui.ChartMaxText.Text   = Format-Size $max
    $ui.ChartStartText.Text = $series[0].Time
    $ui.ChartEndText.Text   = $series[-1].Time
    if ($Width -lt 20 -or $Height -lt 20) { return }

    # Start the line at zero, before the first removal.
    $line = @([PSCustomObject]@{ Time = $series[0].Time; TotalMB = 0.0 }) + $series
    $top = 18.0
    $points = @(Get-ChartPoint -Series $line -Width ($Width - 8) -Height ($Height - $top - 2))

    $base = New-Object System.Windows.Shapes.Line
    $base.X1 = 0; $base.X2 = $Width; $base.Y1 = $Height - 1; $base.Y2 = $Height - 1; $base.StrokeThickness = 1
    $base.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'LineBrush')
    [void]$canvas.Children.Add($base)

    $area = New-Object System.Windows.Shapes.Polygon
    $poly = New-Object System.Windows.Shapes.Polyline
    $area.Points.Add((New-Object System.Windows.Point(($points[0].X + 4), ($Height - 1))))
    foreach ($p in $points) {
        $pt = New-Object System.Windows.Point(($p.X + 4), ($p.Y + $top))
        $area.Points.Add($pt)
        $poly.Points.Add($pt)
    }
    $area.Points.Add((New-Object System.Windows.Point(($points[-1].X + 4), ($Height - 1))))
    $area.Opacity = 0.15
    $area.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'AccentBrush')
    $poly.StrokeThickness = 2
    $poly.StrokeLineJoin = 'Round'
    $poly.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'AccentBrush')
    [void]$canvas.Children.Add($area)
    [void]$canvas.Children.Add($poly)

    foreach ($p in $points | Select-Object -Skip 1) {
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 6; $dot.Height = 6
        $dot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'AccentBrush')
        [System.Windows.Controls.Canvas]::SetLeft($dot, $p.X + 1)
        [System.Windows.Controls.Canvas]::SetTop($dot, $p.Y + $top - 3)
        [void]$canvas.Children.Add($dot)
    }
}

function Show-HistoryView {
    param($History)
    if (-not $History) { $History = Read-History -Path $Paths.History }
    $script:History = $History
    $removed = 0
    foreach ($r in @($History.Removals)) { if ($r) { $removed += [int]$r.Folders } }
    $ui.HistScansValue.Text   = "$(@($History.Scans | Where-Object { $_ }).Count)"
    $ui.HistRemovedValue.Text = "$removed"
    $ui.HistFreedValue.Text   = Format-Size (Get-FreedMB $History)
    $ui.FreedValue.Text       = $ui.HistFreedValue.Text
    $ui.ActivityGrid.ItemsSource = @(Get-HistoryActivity -History $History)
    Show-FreedChart -History $History
}

function Import-ScanView {
    # Loads the app's last scan into the list and the summary cards.
    $rows = @(Read-ScanResult -CsvPath $Paths.Csv)
    $script:Rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($r in $rows) {
        $r.add_PropertyChanged({ Show-MarkedTotal })
        $script:Rows.Add($r)
    }
    $ui.ResultsGrid.ItemsSource = $script:Rows
    $script:View = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows)
    $script:View.Filter = [Predicate[object]] {
        param($item)
        Test-RowVisible -Row $item -View $ui.ViewBox.SelectedIndex -Filter $ui.FilterBox.Text
    }

    $orphans = @($rows | Where-Object Category -eq 'Orphaned package')
    $mb = 0.0; foreach ($o in $orphans) { $mb += $o.SizeMB }
    $history = Read-History -Path $Paths.History
    $ui.OrphanValue.Text  = "$($orphans.Count)  ($(Format-Size $mb))"
    $ui.NewValue.Text     = if (-not (Test-Path -LiteralPath $Paths.Csv)) { '-' }
                            elseif (@($history.Scans).Count -gt 1) { "$(@($rows | Where-Object { $_.IsNew }).Count)" }
                            else { 'First scan' }
    $ui.WindowsValue.Text = "$(@($rows | Where-Object Category -eq 'Windows component').Count)"
    $ui.OtherValue.Text   = "$(@($rows | Where-Object Category -eq 'Other folder').Count)"

    $ui.MarkAllBox.IsChecked = $false
    if (Test-Path -LiteralPath $Paths.Csv) {
        $when = (Get-Item -LiteralPath $Paths.Csv).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        $ui.StatusText.Text = "Scanned $when. Tick the orphaned folders to remove. Double-click a row to open its folder."
    }
    Show-HistoryView -History $history
    Show-ResultView
    Show-MarkedTotal
}

function Invoke-ScriptAsync {
    # Runs a WinPkgScan script in the background. $OnDone gets the exit code.
    param([string]$Script, [string[]]$Arguments, [string]$BusyText, [scriptblock]$OnDone, [switch]$Elevated, [switch]$ShowProgress)
    if (-not (Test-Path -LiteralPath $Paths.AppDir)) { New-Item -ItemType Directory -Path $Paths.AppDir -Force | Out-Null }
    Remove-Item -LiteralPath $Paths.Output -ErrorAction SilentlyContinue
    $exe  = Get-PowerShellPath
    $line = Get-ScriptCommandLine -Script $Script -Arguments $Arguments
    if ($Elevated) {
        $proc = Start-Process -FilePath $exe -ArgumentList $line -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
    }
    else {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $env:ComSpec
        $psi.Arguments       = '/d /s /c ""' + $exe + '" ' + $line + ' > "' + $Paths.Output + '" 2>&1"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    $script:Job = [PSCustomObject]@{ Process = $proc; OnDone = $OnDone; ShowProgress = ($ShowProgress -and -not $Elevated) }
    Show-BusyState -Busy $true -Text $BusyText
    $script:Timer.Start()
}

function Invoke-Scan {
    param([switch]$Elevated)
    if ($script:IsBusy) { return }
    $text = if ($Elevated) { 'Scanning as administrator... Windows may ask for permission.' } else { 'Scanning...' }
    $script:ScanStarted = Get-Date
    try {
        Invoke-ScriptAsync -Script $Paths.Scanner -Arguments (Get-ScanArgument -Paths $Paths -Setting $script:Setting) `
            -BusyText $text -Elevated:$Elevated -ShowProgress -OnDone {
                param($code)
                # An elevated scan may not report its exit code: then check the CSV is new.
                $fresh = (Test-Path -LiteralPath $Paths.Csv) -and
                         ((Get-Item -LiteralPath $Paths.Csv).LastWriteTime -ge $script:ScanStarted.AddSeconds(-2))
                if ($code -eq 0 -or ($null -eq $code -and $fresh)) { Import-ScanView }
                else {
                    $ui.StatusText.Text = 'The scan did not finish.'
                    Show-Message -Text "The scan did not finish (exit code $code).`n`n$(Get-OutputTail)" -Icon 'Warning' | Out-Null
                }
            }
    }
    catch {
        Show-BusyState -Busy $false -Text 'The scan was not started.'
        Show-Message -Text "The scan was not started: $($_.Exception.Message)" -Icon 'Warning' | Out-Null
    }
}

function Invoke-Remove {
    param([switch]$Preview)
    $total = Get-MarkedTotal -Rows @($script:Rows)
    if ($total.Count -eq 0 -or $script:IsBusy) { return }
    if (-not $Preview) {
        $answer = Show-Message -Icon 'Question' -Buttons 'YesNo' -Text (
            "Move $($total.Count) folder$(if ($total.Count -ne 1) { 's' }) ($(Format-Size $total.SizeMB)) to the Recycle Bin?`n`n" +
            "Each folder is checked again first, and skipped if any check fails. " +
            "You can put them back with Restore last delete.")
        if ("$answer" -ne 'Yes') { return }
    }
    Export-MarkedCsv -Rows @($script:Rows) -Path $Paths.Marked | Out-Null
    $log = if ($Preview) { $Paths.PreviewLog } else { Join-Path $Paths.AppDir ("WinPkgScan-DeleteLog-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    Remove-Item -LiteralPath $Paths.PreviewLog -ErrorAction SilentlyContinue
    $script:LastLog = $log
    $script:LastWasPreview = [bool]$Preview
    Invoke-ScriptAsync -Script $Paths.Remover -Arguments (Get-RemoveArgument -Paths $Paths -Setting $script:Setting -LogPath $log -Preview:$Preview) `
        -BusyText $(if ($Preview) { 'Checking the marked folders...' } else { 'Moving the marked folders to the Recycle Bin...' }) `
        -OnDone {
            param($code)
            $summary = Get-LogSummary -Path $script:LastLog
            if (@($summary.Rows).Count -eq 0) {
                Show-Message -Text "Nothing was done (exit code $code).`n`n$(Get-OutputTail)" -Icon 'Warning' | Out-Null
                return
            }
            if ($script:LastWasPreview) {
                $ui.StatusText.Text = 'Preview finished. Nothing was changed.'
                Show-Message -Text ("Preview: nothing was changed.`n`n" + (Format-LogSummary -Summary $summary -Preview)) | Out-Null
            }
            else {
                Show-Message -Text (Format-LogSummary -Summary $summary) -Icon $(if ($summary.Failed -gt 0) { 'Warning' } else { 'Information' }) | Out-Null
                Invoke-Scan
            }
        }
}

function Invoke-Restore {
    if ($script:IsBusy) { return }
    $log = Get-NewestDeleteLog -Folder $Paths.AppDir
    $summary = if ($log) { Get-LogSummary -Path $log.FullName } else { $null }
    if (-not $summary -or $summary.Recycled -eq 0) {
        Show-Message -Text 'There is nothing to restore: the app has not moved any folders to the Recycle Bin yet.' | Out-Null
        return
    }
    $answer = Show-Message -Icon 'Question' -Buttons 'YesNo' -Text (
        "Put back the $($summary.Recycled) folder$(if ($summary.Recycled -ne 1) { 's' }) from the last delete ($($log.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))?`n`n" +
        "A folder is skipped if something already exists at its place, or if it is no longer in the Recycle Bin.")
    if ("$answer" -ne 'Yes') { return }
    Invoke-ScriptAsync -Script $Paths.Restorer -Arguments @('-LogPath', $log.FullName, '-NoPause') `
        -BusyText 'Restoring folders from the Recycle Bin...' -OnDone {
            param($code)
            $result = (Get-OutputTail) -split "`n" | Where-Object { $_ -match '^Restored:' } | Select-Object -Last 1
            $icon = if ($code -eq 0) { 'Information' } else { 'Warning' }
            Show-Message -Text $(if ($result) { $result.Trim() } else { "Restore finished with exit code $code.`n`n$(Get-OutputTail)" }) -Icon $icon | Out-Null
            Invoke-Scan
        }
}

function Get-SettingsWindow {
    # Builds the Settings window, filled in with the current settings.
    $dialog = Get-WindowFromXaml -Text $SettingsXaml
    $sui = @{}
    foreach ($name in $SettingsControlNames) { $sui[$name] = $dialog.FindName($name) }
    $sui.MinAgeBox.Text = "$($script:Setting.MinAgeDays)"
    $sui.AdminBox.SelectedIndex = [array]::IndexOf(@('Auto', 'On', 'Off'), "$($script:Setting.AdminChecks)")
    $sui.ThemeBox.SelectedIndex = [array]::IndexOf(@('System', 'Light', 'Dark'), "$($script:Setting.Theme)")
    $sui.ExcludeBox.Text = Read-ExcludeText -Path $Paths.Exclude
    $sui.ExcludePathText.Text = "Saved in $($Paths.Exclude). WinPkgScan.exclude.txt next to the scripts is used too."
    Show-Theme -Window $dialog -Name (Get-CurrentThemeName)
    Show-WindowIcon -Window $dialog
    return [PSCustomObject]@{ Window = $dialog; Controls = $sui }
}

function Show-SettingsDialog {
    $built = Get-SettingsWindow
    $built.Window.Owner = $script:MainWindow
    $script:SettingsWindow = $built
    $script:SettingsResult = $null

    $built.Controls.SaveButton.Add_Click({
        $sui = $script:SettingsWindow.Controls
        if (-not (Test-MinAgeDay -Text $sui.MinAgeBox.Text)) {
            [System.Windows.MessageBox]::Show($script:SettingsWindow.Window, 'Enter a whole number of days from 0 to 36500.',
                'WinPkgScan', 'OK', 'Warning') | Out-Null
            $sui.MinAgeBox.Focus() | Out-Null
            return
        }
        $script:SettingsResult = [PSCustomObject]@{
            MinAgeDays  = [int]$sui.MinAgeBox.Text.Trim()
            AdminChecks = @('Auto', 'On', 'Off')[[math]::Max(0, $sui.AdminBox.SelectedIndex)]
            Theme       = @('System', 'Light', 'Dark')[[math]::Max(0, $sui.ThemeBox.SelectedIndex)]
            Exclude     = $sui.ExcludeBox.Text
        }
        $script:SettingsWindow.Window.DialogResult = $true
    })

    $saved = $built.Window.ShowDialog()
    $script:SettingsWindow = $null
    if (-not $saved -or -not $script:SettingsResult) { return }
    $new = $script:SettingsResult
    try {
        Save-AppSetting -Setting $new -Path $Paths.Settings
        if ($new.Exclude -ne (Read-ExcludeText -Path $Paths.Exclude)) { Save-ExcludeText -Path $Paths.Exclude -Text $new.Exclude }
    }
    catch {
        Show-Message -Text "The settings could not be saved: $($_.Exception.Message)" -Icon 'Warning' | Out-Null
        return
    }
    $script:Setting = Read-AppSetting -Path $Paths.Settings
    Show-Theme -Window $script:MainWindow -Name (Get-CurrentThemeName)
    $ui.RuleText.Text = Get-RuleText -Days $script:Setting.MinAgeDays
    $count = Get-ExcludeCount -Text (Read-ExcludeText -Path $Paths.Exclude)
    $ui.StatusText.Text = "Settings saved. Exclude list: $count pattern$(if ($count -ne 1) { 's' }). Changes apply from the next scan."
}

# ------------------------------------------------------------
# Build the window
# ------------------------------------------------------------

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $Paths   = Get-AppPath
    $window  = Get-WindowFromXaml -Text $Xaml
    $script:MainWindow = $window
    $ui = @{}
    foreach ($name in $ControlNames) { $ui[$name] = $window.FindName($name) }

    $script:Setting = Read-AppSetting -Path $Paths.Settings
    $script:Rows    = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $script:View    = $null
    $script:Job     = $null
    $script:IsBusy  = $false
    $script:History = $null
    $script:Timer   = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $window.Title = "WinPkgScan $AppVersion"
    $ui.RuleText.Text = Get-RuleText -Days $script:Setting.MinAgeDays
    Show-WindowIcon -Window $window
    Show-Theme -Window $window -Name (Get-CurrentThemeName)

    $script:Timer.Add_Tick({
        $job = $script:Job
        if (-not $job) { $script:Timer.Stop(); return }
        $finished = $true
        try { $finished = $job.Process.HasExited } catch { $finished = $true }
        if (-not $finished) {
            if ($job.ShowProgress) { Show-Progress -Info (Get-ProgressInfo -Line (Get-OutputLastLine -Path $Paths.Output)) }
            return
        }
        $script:Timer.Stop()
        $code = $null
        try { $code = $job.Process.ExitCode } catch { $code = $null }
        $script:Job = $null
        Show-BusyState -Busy $false -Text 'Done.'
        try { & $job.OnDone $code }
        catch { Show-Message -Text "Something went wrong: $($_.Exception.Message)" -Icon 'Error' | Out-Null }
    })

    $ui.ScanButton.Add_Click({ Invoke-Scan })
    $ui.AdminScanButton.Add_Click({ Invoke-Scan -Elevated })
    $ui.PreviewButton.Add_Click({ Invoke-Remove -Preview })
    $ui.DeleteButton.Add_Click({ Invoke-Remove })
    $ui.RestoreButton.Add_Click({ Invoke-Restore })
    $ui.SettingsButton.Add_Click({ Show-SettingsDialog })
    $ui.ReportButton.Add_Click({
        if (Test-Path -LiteralPath $Paths.Html) { Invoke-Item -LiteralPath $Paths.Html }
        else { Show-Message -Text 'There is no report yet. Click Scan first.' | Out-Null }
    })
    $ui.ViewBox.Add_SelectionChanged({ $ui.MarkAllBox.IsChecked = $false; Show-ResultView })
    $ui.FilterBox.Add_TextChanged({ Show-ResultView })
    $ui.MarkAllBox.Add_Click({
        $state = [bool]$ui.MarkAllBox.IsChecked
        if ($script:View) { foreach ($r in $script:View) { if ($r.CanMark) { $r.Marked = $state } } }
        Show-MarkedTotal
    })
    $ui.ResultsGrid.Add_MouseDoubleClick({
        $row = $ui.ResultsGrid.SelectedItem
        if ($row -and $row.FullPath -and (Test-Path -LiteralPath $row.FullPath)) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($row.FullPath)`""
        }
    })
    $ui.Tabs.Add_SelectionChanged({
        $e = $args[1]
        # Lists and boxes inside the tabs raise this event too: only react to the tabs.
        if ($e.OriginalSource -eq $ui.Tabs -and $ui.Tabs.SelectedItem -eq $ui.HistoryTab) { Show-HistoryView }
    })
    $ui.FreedChart.Add_SizeChanged({ if ($script:History) { Show-FreedChart -History $script:History } })
    $window.Add_KeyDown({
        $e = $args[1]
        if ($e.Key -eq 'F5' -and -not $script:IsBusy) { Invoke-Scan; $e.Handled = $true }
    })
    $window.Add_Closing({
        $e = $args[1]
        if ($script:IsBusy) {
            $answer = Show-Message -Icon 'Question' -Buttons 'YesNo' -Text 'A task is still running. Close the app anyway? The task keeps running in the background.'
            if ("$answer" -ne 'Yes') { $e.Cancel = $true }
        }
    })

    Import-ScanView

    if ($SelfTest) {
        # Build everything without showing it, and check each part works.
        $problems = New-Object System.Collections.Generic.List[string]
        $missing = @($ControlNames | Where-Object { -not $ui[$_] })
        if ($missing.Count -gt 0) { $problems.Add("main window is missing $($missing -join ', ')") }

        $sample = New-Object WinPkgScanApp.Row
        $sample.FolderName = 'Sample.App_abc123def4567'; $sample.CanMark = $true; $sample.Category = 'Orphaned package'
        $sample.add_PropertyChanged({ Show-MarkedTotal })
        $script:Rows.Add($sample)
        $sample.Marked = $true
        Show-ResultView
        if ($ui.MarkedText.Text -notmatch '^1 marked') { $problems.Add("marked text is '$($ui.MarkedText.Text)'") }

        $settings = Get-SettingsWindow
        $missing = @($SettingsControlNames | Where-Object { -not $settings.Controls[$_] })
        if ($missing.Count -gt 0) { $problems.Add("settings window is missing $($missing -join ', ')") }
        if ($settings.Controls.AdminBox.SelectedIndex -lt 0) { $problems.Add('settings: no administrator checks choice') }
        $settings.Window.Close()

        foreach ($theme in 'Dark', 'Light') {
            Show-Theme -Window $window -Name $theme
            $want = (Get-ThemePalette -Name $theme).BgBrush
            $got = $window.Resources['BgBrush'].Color.ToString()
            if ($got -ne ('#FF' + $want.TrimStart('#'))) { $problems.Add("$theme theme: background is $got") }
        }

        $fakeHistory = [PSCustomObject]@{
            Scans    = @([PSCustomObject]@{ Time = '2026-10-01 10:00'; Orphans = 3; OrphanMB = 120 })
            Removals = @([PSCustomObject]@{ Time = '2026-10-01 10:05'; Folders = 2; FreedMB = 100; Mode = 'Recycled' },
                         [PSCustomObject]@{ Time = '2026-10-09 09:00'; Folders = 1; FreedMB = 50; Mode = 'Recycled' })
            Restores = @([PSCustomObject]@{ Time = '2026-10-02 08:00'; Folders = 1; SizeMB = 20 })
        }
        Show-HistoryView -History $fakeHistory
        Show-FreedChart -History $fakeHistory -Width 600 -Height 150
        if ($ui.FreedChart.Children.Count -lt 4) { $problems.Add("chart has $($ui.FreedChart.Children.Count) shapes") }
        if ($ui.HistFreedValue.Text -ne '130 MB') { $problems.Add("freed is '$($ui.HistFreedValue.Text)'") }
        if (@($ui.ActivityGrid.ItemsSource).Count -ne 4) { $problems.Add("activity has $(@($ui.ActivityGrid.ItemsSource).Count) rows") }

        Show-BusyState -Busy $true -Text 'Testing'
        Show-Progress -Info (Get-ProgressInfo -Line 'PROGRESS 5/20 Contoso.App_abc123def4567')
        if ($ui.BusyBar.IsIndeterminate -or $ui.BusyBar.Value -ne 25) { $problems.Add("progress bar is at $($ui.BusyBar.Value)") }
        Show-BusyState -Busy $false -Text 'Done.'

        if ($problems.Count -gt 0) { Write-Host "SELFTEST FAILED: $($problems -join '; ')"; exit 1 }
        Write-Host "SELFTEST OK: windows built ($($ControlNames.Count) + $($SettingsControlNames.Count) controls), marking, settings, themes, history chart and progress work"
        exit 0
    }

    [void]$window.ShowDialog()
}
catch {
    $message = "WinPkgScan app could not start: $($_.Exception.Message)"
    if ($SelfTest) { Write-Host "SELFTEST FAILED: $message"; exit 1 }
    try { [System.Windows.MessageBox]::Show($message, 'WinPkgScan', 'OK', 'Error') | Out-Null }
    catch { Write-Host $message; Read-Host 'Press Enter to exit' | Out-Null }
    exit 1
}
