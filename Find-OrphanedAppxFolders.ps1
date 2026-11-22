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

    When run as administrator, it also asks Windows about every user's
    packages: folders of apps registered to you in an unfinished state
    (staged or pending) are kept out of the results, and each folder gets
    notes such as "Provisioned" or "Installed for 1 other user".

    SAFETY: read-only. Nothing is deleted, uninstalled or modified.

.PARAMETER NoPause
    Never pause at the end. The script only pauses when it opened its own
    window (a batch file or "Run with PowerShell"), not when run from an
    open PowerShell prompt.

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
    If not given, your own list is read: %LOCALAPPDATA%\WinPkgScan\exclude.txt
    (the app's Settings edit it), plus WinPkgScan.exclude.txt next to this
    script if you still have one from an older version.

.PARAMETER AdminChecks
    Auto (default): run the extra checks when running as administrator.
    On: always try them (a warning is shown if they fail). Off: never.

.PARAMETER ProgressLines
    Print a "PROGRESS n/total folder" line for each folder. Used by the app
    to show a progress bar.

.PARAMETER Notify
    Show a Windows notification when orphaned folders are found that were
    not there at the last scan. Clicking it opens the HTML report (with
    -Html). Used by the scheduled scan.

.PARAMETER NoHistory
    Do not read or update the scan history. The history is kept in
    %LOCALAPPDATA%\WinPkgScan\history.json and is used to show which
    folders are new since the last scan and how much space was freed.

.EXAMPLE
    .\Find-OrphanedAppxFolders.ps1

.EXAMPLE
    .\Find-OrphanedAppxFolders.ps1 -NoPause -Csv -ReportPath "C:\Temp\report.txt"

.EXAMPLE
    .\Find-OrphanedAppxFolders.ps1 -Csv -Html -Open -Exclude '*Teams*'

.NOTES
    Version: 1.9.0
#>

[CmdletBinding()]
param(
    [switch]$NoPause,
    [string]$ReportPath,
    [switch]$Csv,
    [switch]$Html,
    [switch]$Open,
    [string[]]$Exclude,
    [string]$ExcludeFile,
    [ValidateSet('Auto', 'On', 'Off')]
    [string]$AdminChecks = 'Auto',
    [switch]$NoHistory,
    [switch]$ProgressLines,
    [switch]$Notify
)

$ScriptVersion = "1.9.0"
# Pause at the end only when this script opened its own console window
# (a batch file or "Run with PowerShell"), so you can read the result before
# it closes. Never from an open PowerShell prompt, the module, the app, or
# with redirected input.
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

function Write-ResultTable {
    param([object[]]$Items)
    # Out-String with a fixed width keeps the table visible
    # even when output is redirected to a file or log.
    $Items |
        Format-Table FolderName,
            @{Name = "App"; Expression = { $_.DisplayName }},
            @{Name = "Size (MB)"; Expression = { $_.SizeMB }},
            @{Name = "Last Modified"; Expression = { $_.LastModified }},
            Advice, New, Notes -AutoSize |
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
        $Report.Add("App           : $($Item.DisplayName)$(if ($Item.Publisher) { " ($($Item.Publisher))" })")
        $Report.Add("Advice        : $($Item.Advice) - $($Item.AdviceReason)")
        $Report.Add("Size          : $($Item.SizeMB) MB")
        $Report.Add("Last Modified : $($Item.LastModified)")
        $Report.Add("Path          : $($Item.FullPath)")
        $Report.Add("Status        : $($Item.Status)")
        if ($Item.Notes) {
            $Report.Add("Notes         : $($Item.Notes)")
        }
        if ($Item.New -eq 'Yes') {
            $Report.Add("New           : yes, not found in the last scan")
        }
        $Report.Add("")
    }
}

function Get-ExcludePattern {
    # Patterns from -Exclude plus the exclude files (one per line, # = comment).
    param([string[]]$FromParameter, [string[]]$Files, [bool]$FileWasGiven)
    $patterns = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($FromParameter)) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { $patterns.Add($p.Trim()) }
    }
    foreach ($file in @($Files)) {
        if ($file -and (Test-Path -LiteralPath $file -PathType Leaf)) {
            foreach ($line in (Get-Content -LiteralPath $file)) {
                $t = $line.Trim()
                if ($t -and -not $t.StartsWith('#')) { $patterns.Add($t) }
            }
        }
        elseif ($FileWasGiven) {
            Write-Host "WARNING: Exclude file not found: $file" -ForegroundColor Yellow
        }
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

# Friendly names for common apps whose package name says little.
$KnownAppNames = @{
    'Microsoft.549981C3F5F10'                = 'Cortana'
    'Microsoft.ZuneMusic'                    = 'Media Player'
    'Microsoft.ZuneVideo'                    = 'Films & TV'
    'Microsoft.SkypeApp'                     = 'Skype'
    'Microsoft.YourPhone'                    = 'Phone Link'
    'Microsoft.BingWeather'                  = 'Weather'
    'Microsoft.BingNews'                     = 'News'
    'Microsoft.GetHelp'                      = 'Get Help'
    'Microsoft.Getstarted'                   = 'Tips'
    'Microsoft.MicrosoftSolitaireCollection' = 'Solitaire Collection'
    'Microsoft.MicrosoftStickyNotes'         = 'Sticky Notes'
    'Microsoft.MicrosoftOfficeHub'           = 'Microsoft 365 (Office)'
    'Microsoft.Office.OneNote'               = 'OneNote for Windows 10'
    'Microsoft.OutlookForWindows'            = 'Outlook (new)'
    'microsoft.windowscommunicationsapps'    = 'Mail and Calendar'
    'Microsoft.WindowsAlarms'                = 'Clock'
    'Microsoft.WindowsCamera'                = 'Camera'
    'Microsoft.WindowsCalculator'            = 'Calculator'
    'Microsoft.WindowsMaps'                  = 'Maps'
    'Microsoft.WindowsSoundRecorder'         = 'Sound Recorder'
    'Microsoft.WindowsFeedbackHub'           = 'Feedback Hub'
    'Microsoft.WindowsNotepad'               = 'Notepad'
    'Microsoft.WindowsTerminal'              = 'Terminal'
    'Microsoft.Windows.Photos'               = 'Photos'
    'Microsoft.ScreenSketch'                 = 'Snipping Tool'
    'Microsoft.Todos'                        = 'Microsoft To Do'
    'Microsoft.People'                       = 'People'
    'Microsoft.XboxApp'                      = 'Xbox Console Companion'
    'Microsoft.GamingApp'                    = 'Xbox'
    'Microsoft.Microsoft3DViewer'            = '3D Viewer'
    'Microsoft.MixedReality.Portal'          = 'Mixed Reality Portal'
    'Microsoft.PowerAutomateDesktop'         = 'Power Automate'
    'MicrosoftTeams'                         = 'Microsoft Teams (classic)'
    'MSTeams'                                = 'Microsoft Teams'
}

# Publishers by the 13-character publisher ID at the end of the folder name.
$KnownPublishers = @{
    '8wekyb3d8bbwe' = 'Microsoft'
    'cw5n1h2txyewy' = 'Microsoft Windows'
    'kzf8qxf38zg5c' = 'Microsoft (Skype)'
    'yxz26nhyzhsrt' = 'Clipchamp'
    'zpdnekdrzrea0' = 'Spotify'
    'cv1g1gvanyjgm' = 'WhatsApp'
}

function ConvertTo-SpacedName {
    # "WhatsAppDesktop" -> "WhatsApp Desktop", "Windows.Photos" -> "Windows Photos"
    param([string]$Text)
    $t = $Text -replace '[._-]+', ' '
    $t = [regex]::Replace($t, '(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])', ' ')
    # Names that are written as one word.
    foreach ($word in 'WhatsApp', 'YouTube', 'OneNote', 'OneDrive', 'PowerPoint', 'LinkedIn', 'TikTok', 'PlayStation', 'GitHub', 'iTunes', 'iCloud') {
        $split = [regex]::Replace($word, '(?<=[a-z0-9])(?=[A-Z])', ' ')
        $t = $t -replace [regex]::Escape($split), $word
    }
    return ($t -replace '\s+', ' ').Trim()
}

function Get-AppIdentity {
    # A friendly app name and publisher, worked out from the folder name.
    param([string]$FolderName)
    $name = $FolderName
    $id   = ''
    $m = [regex]::Match($FolderName, '^(.+)_([0-9a-hjkmnp-tv-z]{13})$', 'IgnoreCase')
    if ($m.Success) { $name = $m.Groups[1].Value; $id = $m.Groups[2].Value.ToLowerInvariant() }
    elseif ($FolderName -like 'windows_ie_ac_*') {
        return [PSCustomObject]@{ DisplayName = 'Internet Explorer app container'; Publisher = 'Microsoft Windows' }
    }
    else {
        return [PSCustomObject]@{ DisplayName = $FolderName; Publisher = '' }
    }

    $parts  = @($name -split '\.')
    $vendor = if ($parts.Count -gt 1) { $parts[0] } else { '' }
    $display = $null
    foreach ($key in $KnownAppNames.Keys) {
        if ([string]::Equals($key, $name, [StringComparison]::OrdinalIgnoreCase)) { $display = $KnownAppNames[$key]; break }
    }
    if (-not $display) {
        $rest = if ($parts.Count -gt 1) { ($parts[1..($parts.Count - 1)] -join '.') } else { $name }
        $display = ConvertTo-SpacedName $rest
        if (-not $display) { $display = $name }
    }

    $publisher = ''
    if ($KnownPublishers.ContainsKey($id)) { $publisher = $KnownPublishers[$id] }
    elseif ($vendor -and $vendor -notmatch '^[0-9A-F]{6,}$' -and $vendor -match '[A-Za-z]{3}') { $publisher = ConvertTo-SpacedName $vendor }
    else { $publisher = "Unknown ($id)" }
    return [PSCustomObject]@{ DisplayName = $display; Publisher = $publisher }
}

function Get-RemovalAdvice {
    # Likely safe, Check first or Keep, with the reason.
    param([string]$Category, [int]$AgeDays, [string]$Notes)
    if ($Category -eq 'Windows component') {
        return [PSCustomObject]@{ Advice = 'Keep'; Reason = 'Part of Windows' }
    }
    if ($Category -ne 'Orphaned package') {
        return [PSCustomObject]@{ Advice = 'Check first'; Reason = 'Not named like an app package. Often used by Windows' }
    }
    if ($AgeDays -lt 30) {
        return [PSCustomObject]@{ Advice = 'Check first'; Reason = "Changed $AgeDays day$(if ($AgeDays -ne 1) { 's' }) ago. The remover skips folders changed in the last 30 days" }
    }
    if ($Notes -match 'Provisioned') {
        return [PSCustomObject]@{ Advice = 'Check first'; Reason = 'Windows may reinstall this app' }
    }
    if ($AgeDays -lt 90) {
        return [PSCustomObject]@{ Advice = 'Check first'; Reason = "Changed $AgeDays days ago" }
    }
    return [PSCustomObject]@{ Advice = 'Likely safe'; Reason = "App not installed, nothing changed for $AgeDays days" }
}

function Show-ScanNotification {
    # A Windows notification. Clicking it opens $OpenPath, if given.
    param([string]$Title, [string]$Text, [string]$OpenPath)
    # WINPKGSCAN_NO_NOTIFY turns notifications off, for the tests.
    if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or $env:WINPKGSCAN_NO_NOTIFY) { return }
    $shown = $false
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        try {
            [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
            $launch = ''
            if ($OpenPath -and (Test-Path -LiteralPath $OpenPath)) {
                $launch = ' activationType="protocol" launch="' + [System.Security.SecurityElement]::Escape(([System.Uri]$OpenPath).AbsoluteUri) + '"'
            }
            $xmlText = '<toast' + $launch + '><visual><binding template="ToastGeneric"><text>' +
                [System.Security.SecurityElement]::Escape($Title) + '</text><text>' +
                [System.Security.SecurityElement]::Escape($Text) + '</text></binding></visual></toast>'
            $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
            $doc.LoadXml($xmlText)
            $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
            $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
            $shown = $true
        }
        catch {
            Write-Verbose "Toast notification failed: $($_.Exception.Message)"
        }
    }
    if (-not $shown) {
        try {
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            $tray = New-Object System.Windows.Forms.NotifyIcon
            # Looked up at run time: System.Drawing only loads on Windows.
            $icons = 'System.Drawing.SystemIcons' -as [type]
            $tray.Icon = $icons::Information
            $tray.BalloonTipTitle = $Title
            $tray.BalloonTipText  = $Text
            $tray.Visible = $true
            $tray.ShowBalloonTip(10000)
            Start-Sleep -Seconds 6
            $tray.Dispose()
        }
        catch {
            Write-Verbose "Notification failed: $($_.Exception.Message)"
        }
    }
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
        --accent:#2f6fde; --warn:#b26a00; --keep:#2e7d32; --head:#f0f0ee; --mark:#eaf1fd; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#161618; --card:#1f1f22; --text:#ececee; --muted:#9a9aa2; --line:#33333a;
          --accent:#6ea0ff; --warn:#f0a843; --keep:#7bc47f; --head:#26262a; --mark:#1d2a42; }
}
* { box-sizing:border-box; }
body { margin:0; padding:24px 16px 96px; background:var(--bg); color:var(--text);
       font:14px/1.5 "Segoe UI", system-ui, sans-serif; }
main { max-width:1100px; margin:0 auto; }
h1 { font-size:22px; margin:0 0 4px; }
.sub { color:var(--muted); margin:0 0 20px; }
.tiles { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:12px; margin-bottom:20px; }
.tile { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 14px; }
.tile b { display:block; font-size:22px; }
.tile span { color:var(--muted); font-size:12px; }
.new { display:inline-block; margin-left:6px; padding:0 6px; border-radius:6px; font-size:11px;
       background:var(--accent); color:#fff; vertical-align:1px; }
.note { background:var(--card); border:1px solid var(--line); border-left:4px solid var(--warn);
        border-radius:8px; padding:10px 14px; margin-bottom:20px; }
.note ol { margin:6px 0 0; padding-left:20px; }
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
th.sel, td.sel { width:36px; padding-right:0; cursor:default; }
th[data-dir="asc"]::after { content:" \25B2"; font-size:10px; }
th[data-dir="desc"]::after { content:" \25BC"; font-size:10px; }
td.num, th.num { text-align:right; }
td.path { color:var(--muted); font-size:12px; }
td.notes { color:var(--warn); font-size:12px; }
td.pub { color:var(--muted); }
.adv { display:inline-block; padding:0 8px; border-radius:6px; font-size:12px; border:1px solid currentColor; }
.adv-safe { color:var(--keep); } .adv-check { color:var(--warn); } .adv-keep { color:var(--muted); }
tr.marked td { background:var(--mark); }
tr:last-child td { border-bottom:none; }
input[type=checkbox] { width:16px; height:16px; cursor:pointer; }
.empty { padding:12px; color:var(--muted); }
.k-orphan h2 { color:var(--accent); } .k-windows h2 { color:var(--keep); } .k-other h2 { color:var(--warn); }
.bar { position:fixed; left:0; right:0; bottom:0; background:var(--card); border-top:1px solid var(--line);
       padding:10px 16px; box-shadow:0 -2px 8px rgba(0,0,0,.08); }
.bar .in { max-width:1100px; margin:0 auto; display:flex; gap:12px; align-items:center; flex-wrap:wrap; }
.bar b { white-space:nowrap; }
.bar span { color:var(--muted); font-size:12px; flex:1 1 260px; }
button { font:inherit; padding:8px 14px; border-radius:8px; border:1px solid var(--accent);
         background:var(--accent); color:#fff; cursor:pointer; }
button:disabled { opacity:.45; cursor:default; }
footer { color:var(--muted); font-size:12px; margin-top:32px; }
@media (max-width: 600px) { .bar span { display:none; } .bar .in { justify-content:space-between; } }
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
    [void]$sb.Append(@'
</div>
<div class="note">Nothing was deleted or modified. To remove folders:
<ol><li>Tick the orphaned folders to remove, then click <b>Save marked CSV</b>. It goes to your Downloads folder.</li>
<li>Choose <b>Delete</b> in <b>WinPkgScan.bat</b>, or drag the file onto it. It uses the newest marked file, re-checks every folder and moves it to the Recycle Bin.</li></ol>
<b>Likely safe</b> means the app is not installed and nothing in the folder changed for 90 days or more. Hover over the advice to see why.</div>
<input id="filter" type="search" placeholder="Filter by name or path" aria-label="Filter">
'@)

    foreach ($sec in $Sections) {
        $count    = @($sec.Items).Count
        $markable = $sec.Kind -eq 'orphan'
        [void]$sb.Append("<section class=`"k-$($sec.Kind)`">`n<h2>$(ConvertTo-HtmlText $sec.Title) <small>($count, $($sec.TotalMB) MB)</small></h2>`n<p>$(ConvertTo-HtmlText $sec.Note)</p>`n<div class=`"wrap`">`n")
        if ($count -eq 0) {
            [void]$sb.Append("<div class=`"empty`">None found.</div>`n")
        }
        else {
            [void]$sb.Append("<table class=`"sortable`"><thead><tr>")
            if ($markable) {
                [void]$sb.Append("<th class=`"sel`"><input type=`"checkbox`" class=`"all`" aria-label=`"Mark all shown`"></th>")
            }
            [void]$sb.Append("<th>Folder</th><th>App</th><th>Publisher</th><th>Advice</th><th class=`"num`" data-type=`"num`">Size (MB)</th><th>Last modified</th><th>Notes</th><th>Path</th></tr></thead><tbody>`n")
            foreach ($i in $sec.Items) {
                $size = ([double]$i.SizeMB).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
                $attr = ''
                if ($markable) {
                    $attr = " data-cat=`"$(ConvertTo-HtmlText $i.Category)`" data-name=`"$(ConvertTo-HtmlText $i.FolderName)`"" +
                            " data-size=`"$size`" data-date=`"$(ConvertTo-HtmlText $i.LastModified)`"" +
                            " data-path=`"$(ConvertTo-HtmlText $i.FullPath)`" data-status=`"$(ConvertTo-HtmlText $i.Status)`"" +
                            " data-notes=`"$(ConvertTo-HtmlText $i.Notes)`""
                }
                [void]$sb.Append("<tr$attr>")
                if ($markable) {
                    [void]$sb.Append("<td class=`"sel`"><input type=`"checkbox`" class=`"mark`" aria-label=`"Mark $(ConvertTo-HtmlText $i.FolderName)`"></td>")
                }
                $badge = if ($i.New -eq 'Yes') { ' <span class="new">New</span>' } else { '' }
                $advClass = switch ($i.Advice) { 'Likely safe' { 'adv-safe' } 'Keep' { 'adv-keep' } default { 'adv-check' } }
                [void]$sb.Append("<td>$(ConvertTo-HtmlText $i.FolderName)$badge</td><td>$(ConvertTo-HtmlText $i.DisplayName)</td><td class=`"pub`">$(ConvertTo-HtmlText $i.Publisher)</td>")
                [void]$sb.Append("<td><span class=`"adv $advClass`" title=`"$(ConvertTo-HtmlText $i.AdviceReason)`">$(ConvertTo-HtmlText $i.Advice)</span></td><td class=`"num`" data-v=`"$size`">$size</td><td>$(ConvertTo-HtmlText $i.LastModified)</td><td class=`"notes`">$(ConvertTo-HtmlText $i.Notes)</td><td class=`"path`">$(ConvertTo-HtmlText $i.FullPath)</td></tr>`n")
            }
            [void]$sb.Append("</tbody></table>`n")
        }
        [void]$sb.Append("</div>`n</section>`n")
    }

    [void]$sb.Append("<footer>WinPkgScan v$ScriptVersion</footer>`n</main>`n")
    [void]$sb.Append(@'
<div class="bar"><div class="in">
<b id="count">0 marked (0.00 MB)</b>
<span>Marked folders are checked again before anything is removed, and go to the Recycle Bin.</span>
<button id="save" type="button" disabled>Save marked CSV</button>
</div></div>
<script>
function sortable() {
  document.querySelectorAll('table.sortable th').forEach(function (th) {
    if (th.classList.contains('sel')) { return; }
    th.addEventListener('click', function () {
      var table = th.closest('table'), body = table.tBodies[0];
      var col = Array.prototype.indexOf.call(th.parentNode.children, th);
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
}
function markedRows() {
  return Array.prototype.slice.call(document.querySelectorAll('input.mark:checked')).map(function (c) { return c.closest('tr'); });
}
function update() {
  var rows = markedRows(), mb = 0;
  rows.forEach(function (r) { mb += parseFloat(r.getAttribute('data-size')) || 0; });
  document.querySelectorAll('input.mark').forEach(function (c) { c.closest('tr').classList.toggle('marked', c.checked); });
  document.getElementById('count').textContent = rows.length + ' marked (' + mb.toFixed(2) + ' MB)';
  document.getElementById('save').disabled = rows.length === 0;
}
function csvField(v) { return '"' + String(v === null || v === undefined ? '' : v).replace(/"/g, '""') + '"'; }
function saveCsv() {
  var head = ['Delete', 'Category', 'FolderName', 'SizeMB', 'LastModified', 'FullPath', 'Status', 'Notes'];
  var lines = [head.map(csvField).join(',')];
  markedRows().forEach(function (r) {
    lines.push(['Yes', r.getAttribute('data-cat'), r.getAttribute('data-name'), r.getAttribute('data-size'),
      r.getAttribute('data-date'), r.getAttribute('data-path'), r.getAttribute('data-status'),
      r.getAttribute('data-notes')].map(csvField).join(','));
  });
  var blob = new Blob(['\ufeff' + lines.join('\r\n') + '\r\n'], { type: 'text/csv;charset=utf-8' });
  var a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'WinPkgScan-marked.csv';
  document.body.appendChild(a);
  a.click();
  setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}
sortable();
document.querySelectorAll('input.mark').forEach(function (c) { c.addEventListener('change', update); });
document.querySelectorAll('input.all').forEach(function (all) {
  all.addEventListener('change', function () {
    all.closest('table').querySelectorAll('tbody tr').forEach(function (r) {
      if (!r.hidden) { r.querySelector('input.mark').checked = all.checked; }
    });
    update();
  });
});
document.getElementById('save').addEventListener('click', saveCsv);
document.getElementById('filter').addEventListener('input', function (e) {
  var q = e.target.value.toLowerCase();
  document.querySelectorAll('tbody tr').forEach(function (row) {
    row.hidden = q !== '' && row.textContent.toLowerCase().indexOf(q) === -1;
  });
});
update();
</script>
</body>
</html>
'@)
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
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

# Exclude lists: the one next to the scripts, and your own one (the app's
# Settings edit it). -ExcludeFile uses only the file given.
if ([string]::IsNullOrWhiteSpace($ExcludeFile)) {
    $ExcludeFiles = @(
        (Join-Path $PSScriptRoot "WinPkgScan.exclude.txt")
        (Join-Path (Join-Path $env:LOCALAPPDATA 'WinPkgScan') 'exclude.txt')
    )
    $ExcludeFileGiven = $false
}
else {
    $ExcludeFiles = @($ExcludeFile)
    $ExcludeFileGiven = $true
}
$ExcludePatterns = Get-ExcludePattern -FromParameter $Exclude -Files $ExcludeFiles -FileWasGiven $ExcludeFileGiven

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
    $InstalledPackages = Get-RegisteredPackage
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

# Extra checks that need administrator rights.
$AdminInfo   = $null
$AdminStatus = "off (run as administrator for extra checks)"
$UseAdmin    = ($AdminChecks -eq 'On') -or ($AdminChecks -eq 'Auto' -and (Test-IsAdministrator))
if ($AdminChecks -eq 'Off') { $AdminStatus = "off" }
if ($UseAdmin) {
    Write-Host "Running administrator checks..." -ForegroundColor Yellow
    try {
        $AdminInfo   = Get-AdminPackageInfo -Sid (Get-CurrentUserSid)
        $AdminStatus = "on"
    }
    catch {
        $AdminStatus = "failed: $($_.Exception.Message)"
        Write-Host "WARNING: Administrator checks failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host "Administrator checks:     $AdminStatus"
Write-Host ""

# ------------------------------------------------------------
# Scan ONLY the Packages directory
# ------------------------------------------------------------

Write-Host "Scanning package folders..." -ForegroundColor Yellow
Write-Host ""

$Folders = @(
    Get-ChildItem -LiteralPath $PackagesPath -Directory -Force -ErrorAction SilentlyContinue
)

# Scan history: which folders were found last time.
$History   = $null
$PrevScan  = $null
$PrevNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if (-not $NoHistory) {
    $History  = Read-History -Path (Get-HistoryPath)
    $PrevScan = @($History.Scans) | Select-Object -Last 1
    if ($PrevScan) {
        foreach ($n in @($PrevScan.Folders)) { if ($n) { [void]$PrevNames.Add("$n") } }
    }
}

$Results  = New-Object System.Collections.Generic.List[object]
$Excluded = New-Object System.Collections.Generic.List[string]
$KeptByAdminCheck = 0

$FolderNumber = 0
foreach ($Folder in $Folders) {

    $FolderNumber++
    if ($ProgressLines) {
        Write-Host ("PROGRESS {0}/{1} {2}" -f $FolderNumber, $Folders.Count, $Folder.Name)
    }

    if ($InstalledFamilyNames.Contains($Folder.Name)) {
        continue
    }

    # Registered to this user in an unfinished state (staged, pending).
    if ($AdminInfo -and $AdminInfo.ForMe.Contains($Folder.Name)) {
        $KeptByAdminCheck++
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

    $NoteParts = @()
    if ($AdminInfo) {
        if ($AdminInfo.Provisioned.Contains($Folder.Name)) {
            $NoteParts += "Provisioned (Windows may reinstall it)"
        }
        if ($AdminInfo.OtherUsers.ContainsKey($Folder.Name)) {
            $n = $AdminInfo.OtherUsers[$Folder.Name]
            $NoteParts += "Installed for $n other user$(if ($n -ne 1) { 's' })"
        }
    }

    $Notes    = ($NoteParts -join '; ')
    $AgeDays  = [int][math]::Max(0, [math]::Floor(((Get-Date) - $Newest).TotalDays))
    $Identity = Get-AppIdentity -FolderName $Folder.Name
    $Advice   = Get-RemovalAdvice -Category $Category -AgeDays $AgeDays -Notes $Notes

    $Results.Add(
        [PSCustomObject]@{
            Category     = $Category
            FolderName   = $Folder.Name
            SizeMB       = [math]::Round(($SizeBytes / 1MB), 2)
            LastModified = $Newest.ToString("yyyy-MM-dd")
            FullPath     = $Folder.FullName
            Status       = $Status
            Notes        = $Notes
            New          = if ($PrevScan -and -not $PrevNames.Contains($Folder.Name)) { 'Yes' } else { '' }
            DisplayName  = $Identity.DisplayName
            Publisher    = $Identity.Publisher
            Advice       = $Advice.Advice
            AdviceReason = $Advice.Reason
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

$NewCount = @(@($Orphans) + @($Others) | Where-Object { $_.New -eq 'Yes' }).Count
$SafeItems = @($Orphans | Where-Object { $_.Advice -eq 'Likely safe' })
$SafeMB    = Get-TotalMB $SafeItems
if ($History) {
    $NewText   = if ($PrevScan) { "$NewCount (last scan $($PrevScan.Time))" } else { "first scan" }
    $FreedText = "$(Get-FreedMB $History) MB"
}

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
Write-Host "  Likely safe to remove:  $($SafeItems.Count) ($SafeMB MB)"
Write-Host "Windows components:       $($WinParts.Count) ($WinMB MB)"
Write-Host "Other folders:            $($Others.Count) ($OtherMB MB)"
Write-Host "Excluded:                 $($Excluded.Count)"
if ($AdminInfo) {
    Write-Host "Kept by admin checks:     $KeptByAdminCheck"
}
if ($History) {
    Write-Host "New since last scan:      $NewText"
    Write-Host "Freed with WinPkgScan:    $FreedText"
}
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
$Report.Add("  Likely safe to remove:  $($SafeItems.Count) ($SafeMB MB)")
$Report.Add("Windows components:       $($WinParts.Count) ($WinMB MB)")
$Report.Add("Other folders:            $($Others.Count) ($OtherMB MB)")
$Report.Add("Excluded:                 $($Excluded.Count)")
$Report.Add("Administrator checks:     $AdminStatus")
if ($AdminInfo) {
    $Report.Add("Kept by admin checks:     $KeptByAdminCheck")
}
if ($ExcludePatterns.Count -gt 0) {
    $Report.Add("Exclude patterns:         $($ExcludePatterns -join ', ')")
}
if ($History) {
    $Report.Add("New since last scan:      $NewText")
    $Report.Add("Freed with WinPkgScan:    $FreedText")
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
        $CsvRows = @(@($Orphans) + @($WinParts) + @($Others) |
            Select-Object @{ Name = 'Delete'; Expression = { '' } }, Category, FolderName, SizeMB, LastModified, FullPath, Status, Notes, New,
                DisplayName, Publisher, Advice)
        if ($CsvRows.Count -gt 0) {
            $CsvRows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8 -Force -ErrorAction Stop
        }
        else {
            # Nothing found: still write the header row, so the file is a valid CSV.
            '"Delete","Category","FolderName","SizeMB","LastModified","FullPath","Status","Notes","New","DisplayName","Publisher","Advice"' |
                Out-File -LiteralPath $CsvPath -Encoding UTF8 -Force -ErrorAction Stop
        }
        Write-Host "CSV created:" -ForegroundColor Green
        Write-Host $CsvPath -ForegroundColor White
    }

    if ($Html) {
        $tiles = @(
            [PSCustomObject]@{ Label = "Orphaned package folders"; Value = "$($Orphans.Count) ($OrphanMB MB)" }
            [PSCustomObject]@{ Label = "Likely safe to remove"; Value = "$($SafeItems.Count) ($SafeMB MB)" }
            [PSCustomObject]@{ Label = "Windows components (keep)"; Value = "$($WinParts.Count)" }
            [PSCustomObject]@{ Label = "Other folders"; Value = "$($Others.Count)" }
            [PSCustomObject]@{ Label = "Excluded"; Value = "$($Excluded.Count)" }
            [PSCustomObject]@{ Label = "Registered packages"; Value = "$($InstalledFamilyNames.Count)" }
        )
        if ($History) {
            $tiles += [PSCustomObject]@{ Label = "New since last scan"; Value = $(if ($PrevScan) { "$NewCount" } else { "First scan" }) }
            $tiles += [PSCustomObject]@{ Label = "Freed with WinPkgScan"; Value = $FreedText }
        }
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

# Remember this scan, for "new since last scan" next time.
if ($History) {
    try {
        $History.Scans = @(@($History.Scans) + [PSCustomObject]@{
            Time     = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            Version  = $ScriptVersion
            Orphans  = $Orphans.Count
            OrphanMB = $OrphanMB
            Windows  = $WinParts.Count
            Other    = $Others.Count
            Excluded = $Excluded.Count
            Folders  = @(@($Orphans) + @($WinParts) + @($Others) | ForEach-Object { $_.FolderName })
        })
        Save-History -History $History -Path (Get-HistoryPath)
    }
    catch {
        Write-Host "WARNING: Could not save the scan history: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Scheduled scans: tell the user about new orphaned folders.
if ($Notify) {
    # Wrapped in @() so one folder still counts as 1 in Windows PowerShell 5.1.
    $NotifyItems = @(if ($PrevScan) { $Orphans | Where-Object { $_.New -eq 'Yes' } } else { $Orphans })
    if ($NotifyItems.Count -gt 0) {
        $NotifyMB    = Get-TotalMB $NotifyItems
        $NotifyTitle = "WinPkgScan found $($NotifyItems.Count) $(if ($PrevScan) { 'new ' })leftover app folder$(if ($NotifyItems.Count -ne 1) { 's' })"
        $NotifyText  = "$NotifyMB MB could be freed. Open WinPkgScan to review them."
        Write-Host ""
        Write-Host "NOTIFY: $NotifyTitle | $NotifyText"
        Show-ScanNotification -Title $NotifyTitle -Text $NotifyText -OpenPath $(if ($Html) { $HtmlPath } else { '' })
    }
    else {
        Write-Host ""
        Write-Host "NOTIFY: none (no new orphaned folders)"
    }
}

Write-Host ""
Write-Host "Nothing was deleted or modified." -ForegroundColor Green

Exit-Script 0
