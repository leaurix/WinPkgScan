#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Pester tests for WinPkgScan-App.ps1 (the app)

    - Unit tests: run anywhere. The app is loaded with -TestMode, which
      defines its functions without opening a window.
    - Integration test (tag "Integration"): Windows only. Runs -SelfTest,
      which builds the real windows without showing them, and checks the
      settings window, both themes, the history chart and the progress bar.

    Run:  Invoke-Pester ./tests
#>

BeforeDiscovery {
    $script:OnWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
}

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:AppPath    = Join-Path $RepoRoot 'WinPkgScan-App.ps1'
    $script:RemovePath = Join-Path $RepoRoot 'Remove-OrphanedAppxFolders.ps1'
    $script:SavedLocalAppData = $env:LOCALAPPDATA

    . $script:AppPath -TestMode

    function New-Row {
        param([string]$Name, [string]$Category = 'Orphaned package', [double]$Size = 1, [bool]$New = $false, [string]$Notes = '')
        ConvertTo-AppRow ([pscustomobject]@{
            FolderName = $Name; Category = $Category; SizeMB = $Size.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            LastModified = '2024-03-15'; FullPath = "C:\x\$Name"; Status = 'NOT CURRENTLY REGISTERED'
            Notes = $Notes; New = $(if ($New) { 'Yes' } else { '' })
        })
    }
}

AfterAll {
    $env:LOCALAPPDATA = $script:SavedLocalAppData
}

Describe 'App script file' {

    It 'parses without syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($AppPath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has comment-based help' {
        (Get-Help $AppPath).Synopsis | Should -Match 'WinPkgScan app'
    }

    It 'has the same version as the scanner' {
        $pattern = 'Version:\s*(\d+\.\d+\.\d+)'
        $appVer  = [regex]::Match((Get-Content -LiteralPath $AppPath -Raw), $pattern).Groups[1].Value
        $varVer  = [regex]::Match((Get-Content -LiteralPath $AppPath -Raw), '\$AppVersion\s*=\s*"(\d+\.\d+\.\d+)"').Groups[1].Value
        $scanVer = [regex]::Match((Get-Content -LiteralPath (Join-Path $RepoRoot 'Find-OrphanedAppxFolders.ps1') -Raw), $pattern).Groups[1].Value
        $appVer | Should -Be $scanVer
        $varVer | Should -Be $scanVer
    }

    Context 'window layout (XAML)' {

        BeforeAll {
            $text = Get-Content -LiteralPath $AppPath -Raw
            $start = $text.IndexOf("`$Xaml = @'")
            $start = $text.IndexOf("`n", $start) + 1
            $end   = $text.IndexOf("'@", $start)
            $script:XamlText = $text.Substring($start, $end - $start)
            $script:Doc = [xml]$XamlText
            $ns = New-Object System.Xml.XmlNamespaceManager($Doc.NameTable)
            $ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
            $script:XamlNames = @($Doc.SelectNodes('//@x:Name', $ns) | ForEach-Object { $_.Value })

            $listText = [regex]::Match($text, '(?s)\$ControlNames = @\((.*?)\)').Groups[1].Value
            $script:Listed = @([regex]::Matches($listText, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value })
            $script:Used = @([regex]::Matches($text, '\$ui\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        }

        It 'is well-formed XML' {
            $Doc.DocumentElement.LocalName | Should -Be 'Window'
        }

        It 'names every control the code looks up' {
            $Listed.Count | Should -BeGreaterThan 10
            foreach ($name in $Listed) { $XamlNames | Should -Contain $name }
        }

        It 'only uses controls it looks up' {
            foreach ($name in $Used) { $Listed | Should -Contain $name }
        }

        It 'has no duplicate names' {
            @($XamlNames | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
        }
    }

    Context 'settings window and shared styles (XAML)' {

        BeforeAll {
            $text = Get-Content -LiteralPath $AppPath -Raw
            function Get-HereString([string]$Name) {
                $s = $text.IndexOf("`$$Name = @'")
                $s = $text.IndexOf("`n", $s) + 1
                $e = $text.IndexOf("'@", $s)
                return $text.Substring($s, $e - $s)
            }
            $script:Shared   = Get-HereString 'SharedResources'
            $script:Settings = Get-HereString 'SettingsXaml'
            $script:MainXaml = Get-HereString 'Xaml'
            $ns = New-Object System.Xml.XmlNamespaceManager((New-Object System.Xml.NameTable))
            $ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
            $script:SettingsDoc = [xml]$Settings.Replace('<!--SHARED-->', $Shared)
            $script:MainDoc     = [xml]$MainXaml.Replace('<!--SHARED-->', $Shared)
            $nsm = New-Object System.Xml.XmlNamespaceManager($SettingsDoc.NameTable)
            $nsm.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
            $script:SettingsNames = @($SettingsDoc.SelectNodes('//@x:Name', $nsm) | ForEach-Object { $_.Value })
            $listText = [regex]::Match($text, '(?s)\$SettingsControlNames = @\((.*?)\)').Groups[1].Value
            $script:SettingsListed = @([regex]::Matches($listText, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value })
            $script:AllXaml = $Shared + $Settings + $MainXaml
        }

        It 'loads both windows with the shared styles as well-formed XML' {
            $MainDoc.DocumentElement.LocalName | Should -Be 'Window'
            $SettingsDoc.DocumentElement.LocalName | Should -Be 'Window'
        }

        It 'names every settings control the code looks up' {
            $SettingsListed.Count | Should -Be 7
            foreach ($name in $SettingsListed) { $SettingsNames | Should -Contain $name }
        }

        It 'defines a brush for every colour the theme sets, and the theme sets every brush used' {
            $defined = @([regex]::Matches($Shared, '<SolidColorBrush x:Key="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
            $used    = @([regex]::Matches($AllXaml, '\{DynamicResource (\w+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $palette = @((Get-ThemePalette -Name 'Light').Keys)
            ($defined | Sort-Object) -join ',' | Should -Be (($palette | Sort-Object) -join ',')
            foreach ($key in $used) { $palette | Should -Contain $key }
        }

        It 'has light colours that match the theme defaults in the XAML' {
            $light = Get-ThemePalette -Name 'Light'
            foreach ($m in [regex]::Matches($Shared, '<SolidColorBrush x:Key="(\w+)" Color="(#[0-9A-Fa-f]{6})"/>')) {
                $light[$m.Groups[1].Value] | Should -Be $m.Groups[2].Value
            }
        }
    }
}

Describe 'App logic' {

    It 'compiles the row type, and marking raises a change event' {
        $row = New-Row -Name 'A.App_abc123def4567'
        $script:changed = 0
        $row.add_PropertyChanged({ $script:changed++ })
        $row.Marked = $true
        $row.Marked = $true
        $script:changed | Should -Be 1
    }

    Context 'reading scan results' {

        BeforeAll {
            $script:Csv = Join-Path $TestDrive 'scan.csv'
            @(
                [pscustomobject]@{ Delete = ''; Category = 'Orphaned package'; FolderName = 'A.App_abc123def4567'; SizeMB = '12.5'; LastModified = '2024-03-15'; FullPath = 'C:\p\A'; Status = 'NOT CURRENTLY REGISTERED'; Notes = 'Provisioned'; New = 'Yes' }
                [pscustomobject]@{ Delete = ''; Category = 'Windows component'; FolderName = 'windows_ie_ac_001'; SizeMB = '2'; LastModified = '2024-03-15'; FullPath = 'C:\p\W'; Status = 'WINDOWS COMPONENT (KEEP)'; Notes = ''; New = '' }
                [pscustomobject]@{ Delete = ''; Category = 'Other folder'; FolderName = 'SomeTool_Cache'; SizeMB = '1'; LastModified = '2024-03-15'; FullPath = 'C:\p\O'; Status = 'NOT A PACKAGE-NAMED FOLDER'; Notes = ''; New = '' }
            ) | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
            $script:Rows = Read-ScanResult -CsvPath $Csv
        }

        It 'reads every row' {
            $Rows.Count | Should -Be 3
        }

        It 'lets you mark only orphaned folders' {
            ($Rows | Where-Object CanMark).FolderName | Should -Be 'A.App_abc123def4567'
        }

        It 'reads size, notes and the New flag' {
            $Rows[0].SizeMB | Should -Be 12.5
            $Rows[0].Notes  | Should -Be 'Provisioned'
            $Rows[0].IsNew  | Should -BeTrue
            $Rows[0].NewText | Should -Be 'New'
            $Rows[1].IsNew  | Should -BeFalse
        }

        It 'returns nothing when there is no scan yet' {
            @(Read-ScanResult -CsvPath (Join-Path $TestDrive 'none.csv')).Count | Should -Be 0
        }
    }

    Context 'marking, views and filter' {

        BeforeEach {
            $script:A = New-Row -Name 'Contoso.Old_abc123def4567' -Size 10 -New $true
            $script:B = New-Row -Name 'Fabrikam.Gone_8wekyb3d8bbwe' -Size 2.5 -Notes 'Provisioned'
            $script:W = New-Row -Name 'windows_ie_ac_001' -Category 'Windows component'
            $script:O = New-Row -Name 'SomeTool_Cache' -Category 'Other folder' -New $true
        }

        It 'totals the marked folders' {
            $A.Marked = $true; $B.Marked = $true
            $t = Get-MarkedTotal -Rows @($A, $B, $W, $O)
            $t.Count | Should -Be 2
            $t.SizeMB | Should -Be 12.5
        }

        It 'never counts a folder that cannot be marked' {
            $W.Marked = $true
            (Get-MarkedTotal -Rows @($W)).Count | Should -Be 0
        }

        It 'shows only orphaned folders in the first view' {
            @(@($A, $B, $W, $O) | Where-Object { Test-RowVisible -Row $_ -View 0 -Filter '' }).Count | Should -Be 2
        }

        It 'shows only new folders in the second view' {
            @(@($A, $B, $W, $O) | Where-Object { Test-RowVisible -Row $_ -View 1 -Filter '' }).FolderName |
                Should -Be @('Contoso.Old_abc123def4567', 'SomeTool_Cache')
        }

        It 'shows everything in the third view' {
            @(@($A, $B, $W, $O) | Where-Object { Test-RowVisible -Row $_ -View 2 -Filter '' }).Count | Should -Be 4
        }

        It 'filters by name or notes, ignoring case' {
            (@($A, $B, $W, $O) | Where-Object { Test-RowVisible -Row $_ -View 2 -Filter 'CONTOSO' }).FolderName | Should -Be 'Contoso.Old_abc123def4567'
            (@($A, $B, $W, $O) | Where-Object { Test-RowVisible -Row $_ -View 2 -Filter 'provisioned' }).FolderName | Should -Be 'Fabrikam.Gone_8wekyb3d8bbwe'
        }
    }

    Context 'command lines for the scripts' {

        It 'quotes arguments with spaces' {
            ConvertTo-ArgumentText @('-CsvPath', 'C:\My Files\a.csv', '-NoPause') | Should -Be '-CsvPath "C:\My Files\a.csv" -NoPause'
        }

        It 'runs scripts with -File and Bypass' {
            Get-ScriptCommandLine -Script 'C:\x y\s.ps1' -Arguments @('-Csv') |
                Should -Be '-NoProfile -ExecutionPolicy Bypass -File "C:\x y\s.ps1" -Csv'
        }

        It 'keeps the app files in %LOCALAPPDATA%\WinPkgScan\app' {
            $env:LOCALAPPDATA = Join-Path $TestDrive 'L'
            $p = Get-AppPath -ScriptFolder $RepoRoot
            $p.AppDir | Should -Be (Join-Path (Join-Path $env:LOCALAPPDATA 'WinPkgScan') 'app')
            $p.Scanner | Should -Exist
            $p.Remover | Should -Exist
            $p.Restorer | Should -Exist
            $env:LOCALAPPDATA = $script:SavedLocalAppData
        }
    }

    Context 'logs and history' {

        It 'summarises a delete log' {
            $log = Join-Path $TestDrive 'WinPkgScan-DeleteLog-20261014-100000.csv'
            @(
                [pscustomobject]@{ Time = 't'; Action = 'Recycled'; FolderName = 'A'; SizeMB = '3.5'; FullPath = 'x'; Reason = '' }
                [pscustomobject]@{ Time = 't'; Action = 'Skipped';  FolderName = 'B'; SizeMB = '1'; FullPath = 'y'; Reason = 'Registered to an installed app' }
            ) | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
            $s = Get-LogSummary -Path $log
            $s.Recycled | Should -Be 1
            $s.Skipped  | Should -Be 1
            $s.SizeMB   | Should -Be 3.5
            $text = Format-LogSummary -Summary $s
            $text | Should -Match 'Moved to the Recycle Bin: 1 \(3\.5 MB\)'
            $text | Should -Match 'Skipped: B  -  Registered to an installed app'
            $text | Should -Match 'Restore last delete'
        }

        It 'describes a preview' {
            $log = Join-Path $TestDrive 'preview.csv'
            [pscustomobject]@{ Time = 't'; Action = 'WhatIf'; FolderName = 'A'; SizeMB = '2'; FullPath = 'x'; Reason = '' } |
                Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
            Format-LogSummary -Summary (Get-LogSummary -Path $log) -Preview | Should -Match 'Would move to the Recycle Bin: 1 \(2 MB\)'
        }

        It 'finds the newest delete log' {
            $dir = Join-Path $TestDrive 'logs'
            New-Item -ItemType Directory -Path $dir | Out-Null
            $old = Join-Path $dir 'WinPkgScan-DeleteLog-20261001-100000.csv'; Set-Content $old 'x'
            (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-1)
            $new = Join-Path $dir 'WinPkgScan-DeleteLog-20261014-100000.csv'; Set-Content $new 'x'
            (Get-NewestDeleteLog -Folder $dir).Name | Should -Be 'WinPkgScan-DeleteLog-20261014-100000.csv'
            Get-NewestDeleteLog -Folder (Join-Path $TestDrive 'missing') | Should -BeNullOrEmpty
        }

        It 'reads the space freed from the history' {
            $h = Join-Path $TestDrive 'history.json'
            '{"Version":1,"Scans":[{"Time":"2026-10-14 10:00"},{"Time":"2026-10-14 11:00"}],"Removals":[{"FreedMB":10.5},{"FreedMB":4}],"Restores":[{"SizeMB":2.5}]}' |
                Set-Content -LiteralPath $h
            $s = Get-HistorySummary -Path $h
            $s.FreedMB  | Should -Be 12
            $s.Scans    | Should -Be 2
            $s.LastScan | Should -Be '2026-10-14 11:00'
        }
    }

    Context 'settings' {

        BeforeEach {
            $script:SettingsPath = Join-Path $TestDrive ("settings-{0}.json" -f [guid]::NewGuid().ToString('N'))
        }

        It 'uses the defaults when there is no settings file' {
            $s = Read-AppSetting -Path $SettingsPath
            $s.MinAgeDays  | Should -Be 30
            $s.AdminChecks | Should -Be 'Auto'
            $s.Theme       | Should -Be 'System'
        }

        It 'saves and reads back the settings' {
            Save-AppSetting -Path $SettingsPath -Setting ([pscustomobject]@{ MinAgeDays = 7; AdminChecks = 'On'; Theme = 'Dark' })
            $s = Read-AppSetting -Path $SettingsPath
            $s.MinAgeDays  | Should -Be 7
            $s.AdminChecks | Should -Be 'On'
            $s.Theme       | Should -Be 'Dark'
        }

        It 'falls back to the default for each value that is not valid' {
            '{"MinAgeDays":-5,"AdminChecks":"Maybe","Theme":"Dark"}' | Set-Content -LiteralPath $SettingsPath
            $s = Read-AppSetting -Path $SettingsPath
            $s.MinAgeDays  | Should -Be 30
            $s.AdminChecks | Should -Be 'Auto'
            $s.Theme       | Should -Be 'Dark'
        }

        It 'uses the defaults when the settings file is damaged' {
            '{ not json' | Set-Content -LiteralPath $SettingsPath
            (Read-AppSetting -Path $SettingsPath).MinAgeDays | Should -Be 30
        }

        It 'accepts only whole days from 0 to 36500' {
            foreach ($ok in '0', '30', ' 7 ', '36500') { Test-MinAgeDay -Text $ok | Should -BeTrue -Because "'$ok'" }
            foreach ($bad in '', '-1', 'abc', '1.5', '36501') { Test-MinAgeDay -Text $bad | Should -BeFalse -Because "'$bad'" }
        }

        It 'explains the recent-change rule under the marked total' {
            Get-RuleText -Days 30 | Should -Match 'last 30 days are skipped'
            Get-RuleText -Days 1  | Should -Match 'last 1 day are skipped'
            Get-RuleText -Days 0  | Should -Not -Match 'skipped'
        }

        It 'keeps the settings and exclude list in %LOCALAPPDATA%\WinPkgScan, where the scripts read the list' {
            $env:LOCALAPPDATA = Join-Path $TestDrive 'L'
            $p = Get-AppPath -ScriptFolder $RepoRoot
            $p.Settings | Should -Be (Join-Path (Join-Path $env:LOCALAPPDATA 'WinPkgScan') 'settings.json')
            $p.Exclude  | Should -Be (Join-Path (Join-Path $env:LOCALAPPDATA 'WinPkgScan') 'exclude.txt')
            $p.Icon     | Should -Be (Join-Path $RepoRoot 'WinPkgScan.ico')
            $p.Icon     | Should -Exist
            $env:LOCALAPPDATA = $script:SavedLocalAppData
        }
    }

    Context 'theme' {

        It 'follows the setting, or Windows for System' {
            Resolve-ThemeName -Setting 'Light' -SystemUsesLight $false | Should -Be 'Light'
            Resolve-ThemeName -Setting 'Dark'  -SystemUsesLight $true  | Should -Be 'Dark'
            Resolve-ThemeName -Setting 'System' -SystemUsesLight $false | Should -Be 'Dark'
            Resolve-ThemeName -Setting 'System' -SystemUsesLight $true  | Should -Be 'Light'
            Resolve-ThemeName -Setting 'System' -SystemUsesLight $null  | Should -Be 'Light'
        }

        It 'has the same colours named in both themes, all valid' {
            $light = Get-ThemePalette -Name 'Light'
            $dark  = Get-ThemePalette -Name 'Dark'
            (@($light.Keys) -join ',') | Should -Be (@($dark.Keys) -join ',')
            foreach ($v in @($light.Values) + @($dark.Values)) { $v | Should -Match '^#[0-9A-F]{6}$' }
            $dark.BgBrush | Should -Not -Be $light.BgBrush
        }
    }

    Context 'scan progress' {

        It 'reads a progress line' {
            $p = Get-ProgressInfo -Line 'PROGRESS 5/20 Contoso.App_abc123def4567'
            $p.Done | Should -Be 5
            $p.Total | Should -Be 20
            $p.Percent | Should -Be 25
            $p.Name | Should -Be 'Contoso.App_abc123def4567'
        }

        It 'ignores other lines, and never goes over 100 percent' {
            Get-ProgressInfo -Line 'Orphaned package folders: 3' | Should -BeNullOrEmpty
            Get-ProgressInfo -Line '' | Should -BeNullOrEmpty
            (Get-ProgressInfo -Line 'PROGRESS 9/4 x').Percent | Should -Be 100
            (Get-ProgressInfo -Line 'PROGRESS 0/0').Percent | Should -Be 0
        }

        It 'reads the last line of output that a script is still writing' {
            $file = Join-Path $TestDrive 'output.txt'
            $writer = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("Scanning`r`nPROGRESS 1/3 A`r`nPROGRESS 2/3 B`r`n")
                $writer.Write($bytes, 0, $bytes.Length); $writer.Flush()
                Get-OutputLastLine -Path $file | Should -Be 'PROGRESS 2/3 B'
            }
            finally {
                $writer.Dispose()
            }
            Get-OutputLastLine -Path (Join-Path $TestDrive 'none.txt') | Should -Be ''
        }
    }

    Context 'arguments passed to the scripts' {

        BeforeAll {
            $script:P = [pscustomobject]@{ Report = 'C:\A B\r.txt'; Marked = 'C:\A B\m.csv' }
            $script:S = [pscustomobject]@{ MinAgeDays = 14; AdminChecks = 'On'; Theme = 'Dark' }
        }

        It 'scans with progress lines and the administrator checks setting' {
            $a = @(Get-ScanArgument -Paths $P -Setting $S)
            $a | Should -Contain '-ProgressLines'
            $a | Should -Contain '-NoPause'
            $a[[array]::IndexOf($a, '-AdminChecks') + 1] | Should -Be 'On'
            $a[[array]::IndexOf($a, '-ReportPath') + 1] | Should -Be 'C:\A B\r.txt'
        }

        It 'previews with -WhatIf and removes with -Force, with the days setting' {
            $preview = @(Get-RemoveArgument -Paths $P -Setting $S -LogPath 'l.csv' -Preview)
            $preview | Should -Contain '-WhatIf'
            $preview | Should -Not -Contain '-Force'
            $remove = @(Get-RemoveArgument -Paths $P -Setting $S -LogPath 'l.csv')
            $remove | Should -Contain '-Force'
            $remove | Should -Not -Contain '-WhatIf'
            $remove[[array]::IndexOf($remove, '-MinAgeDays') + 1] | Should -Be '14'
        }

        It 'only passes options the scripts have' {
            $scanParams   = (Get-Command (Join-Path $RepoRoot 'Find-OrphanedAppxFolders.ps1')).Parameters.Keys
            $removeParams = (Get-Command $RemovePath).Parameters.Keys
            foreach ($a in @(Get-ScanArgument -Paths $P -Setting $S) | Where-Object { $_ -like '-*' }) { $scanParams | Should -Contain $a.TrimStart('-') }
            foreach ($a in @(Get-RemoveArgument -Paths $P -Setting $S -LogPath 'l') | Where-Object { $_ -like '-*' }) { $removeParams | Should -Contain $a.TrimStart('-') }
        }
    }

    Context 'exclude list' {

        It 'starts with a list that only has comments' {
            $text = Read-ExcludeText -Path (Join-Path $TestDrive 'no-list.txt')
            $text | Should -Match 'Contoso'
            Get-ExcludeCount -Text $text | Should -Be 0
        }

        It 'saves the list with Windows line endings, and counts the patterns' {
            $file = Join-Path (Join-Path $TestDrive 'data') 'exclude.txt'
            Save-ExcludeText -Path $file -Text "# mine`nContoso.*`n`nFabrikam.Tool_*"
            $raw = [System.IO.File]::ReadAllText($file)
            $raw | Should -Match "Contoso\.\*`r`n`r`nFabrikam"
            $raw.EndsWith("`r`n") | Should -BeTrue
            Get-ExcludeCount -Text (Read-ExcludeText -Path $file) | Should -Be 2
        }
    }

    Context 'history tab' {

        BeforeAll {
            $script:H = [pscustomobject]@{
                Scans    = @([pscustomobject]@{ Time = '2026-10-01 10:00'; Orphans = 3; OrphanMB = 120 })
                Removals = @([pscustomobject]@{ Time = '2026-10-01 10:05'; Folders = 2; FreedMB = 100; Mode = 'Recycled' },
                             [pscustomobject]@{ Time = '2026-10-09 09:00'; Folders = 1; FreedMB = 50; Mode = 'Deleted' })
                Restores = @([pscustomobject]@{ Time = '2026-10-02 08:00'; Folders = 1; SizeMB = 120 })
            }
        }

        It 'lists scans, removals and restores, newest first' {
            $rows = @(Get-HistoryActivity -History $H)
            $rows.Count | Should -Be 4
            $rows[0].Event | Should -Be 'Deleted permanently'
            $rows[-1].Event | Should -Be 'Scan'
            ($rows | Where-Object Event -eq 'Restored').Folders | Should -Be 1
        }

        It 'totals the space freed over time, never below zero' {
            $series = @(Get-FreedSeries -History $H)
            $series.TotalMB | Should -Be @(100, 0, 50)
        }

        It 'has nothing to chart or list for an empty history' {
            $empty = [pscustomobject]@{ Scans = @(); Removals = @(); Restores = @() }
            @(Get-FreedSeries -History $empty).Count | Should -Be 0
            @(Get-HistoryActivity -History $empty).Count | Should -Be 0
            @(Get-ChartPoint -Series @() -Width 100 -Height 50).Count | Should -Be 0
        }

        It 'scales the chart into its box' {
            $pts = @(Get-ChartPoint -Width 200 -Height 100 -Series @(
                [pscustomobject]@{ TotalMB = 0 }, [pscustomobject]@{ TotalMB = 50 }, [pscustomobject]@{ TotalMB = 100 }))
            $pts.X | Should -Be @(0, 100, 200)
            $pts.Y | Should -Be @(100, 50, 0)
        }

        It 'shows sizes in MB or GB' {
            Format-Size 950 | Should -Be '950 MB'
            Format-Size 1536 | Should -Match '^1[.,]5 GB$'
        }
    }

    Context 'marked CSV works with the remover' {

        It 'removes exactly the folders marked in the app' {
            $env:LOCALAPPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $pk = Join-Path $env:LOCALAPPDATA 'Packages'
            $dirs = foreach ($n in 'Contoso.Old_abc123def4567', 'Fabrikam.Gone_8wekyb3d8bbwe') {
                $d = Join-Path $pk $n
                New-Item -ItemType Directory -Path $d -Force | Out-Null
                (Get-Item -LiteralPath $d).LastWriteTime = [datetime]'2024-03-15'
                $d
            }
            $rows = foreach ($d in $dirs) {
                ConvertTo-AppRow ([pscustomobject]@{ FolderName = (Split-Path $d -Leaf); Category = 'Orphaned package'; SizeMB = '0'; FullPath = $d; New = '' })
            }
            $rows[0].Marked = $true
            $csv = Join-Path $TestDrive 'marked-app.csv'
            Export-MarkedCsv -Rows $rows -Path $csv | Should -Be 1

            if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
                function global:Get-AppxPackage { [CmdletBinding()] param([switch]$AllUsers, [string]$PackageTypeFilter) }
            }
            Mock Import-Module { } -ParameterFilter { $Name -contains 'Appx' }
            Mock Get-AppxPackage { [pscustomobject]@{ PackageFamilyName = 'Microsoft.WindowsStore_8wekyb3d8bbwe' } }
            $empty = Join-Path $TestDrive 'empty.txt'; Set-Content $empty ''
            & $RemovePath -CsvPath $csv -LogPath (Join-Path $TestDrive 'app-log.csv') -Permanent -Force -NoPause `
                -ExcludeFile $empty -AdminChecks Off -NoHistory 6>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $dirs[0] | Should -Not -Exist
            $dirs[1] | Should -Exist
            $env:LOCALAPPDATA = $script:SavedLocalAppData
        }
    }
}

Describe 'App window on Windows' -Tag 'Integration' -Skip:(-not $OnWindows) {

    It 'builds the window and passes its self-test' {
        $exe = (Get-Process -Id $PID).Path
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -STA -File $AppPath -SelfTest 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $out
        $out | Should -Match 'SELFTEST OK'
    }
}
