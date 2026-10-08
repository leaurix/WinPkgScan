#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Pester tests for Find-OrphanedAppxFolders.ps1

    - Unit tests: run anywhere (Windows, Linux, macOS). Get-AppxPackage is
      mocked and a fake Packages folder is built in Pester's TestDrive.
    - Integration tests (tag "Integration"): Windows only. Run the script
      for real against the current user's packages, and run the batch file.

    Run:  Invoke-Pester ./tests
#>

BeforeDiscovery {
    $script:OnWindows    = [Environment]::OSVersion.Platform -eq 'Win32NT'
    $script:HasPackages  = $script:OnWindows -and
                           (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages'))
}

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $RepoRoot 'Find-OrphanedAppxFolders.ps1'

    # Get-AppxPackage only exists on Windows. Pester can only mock a command
    # that exists, so add a stub where it is missing.
    # The stub is removed again before the real Windows run.
    $script:CreatedStub = $false
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        function global:Get-AppxPackage { [CmdletBinding()] param([switch]$AllUsers, [string]$PackageTypeFilter) }
        $script:CreatedStub = $true
    }
    if (-not (Get-Command Get-AppxProvisionedPackage -ErrorAction SilentlyContinue)) {
        function global:Get-AppxProvisionedPackage { [CmdletBinding()] param([switch]$Online) }
    }

    # The current user's SID, as the scripts see it. There is none off Windows,
    # so the scripts read it from WINPKGSCAN_TEST_SID instead.
    $script:MySid = $null
    try { $script:MySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $script:MySid = $null }
    if (-not $script:MySid) {
        $script:MySid = 'S-1-5-21-1000-2000-3000-1001'
        $env:WINPKGSCAN_TEST_SID = $script:MySid
    }

    # An empty exclude file, so the repo's WinPkgScan.exclude.txt never
    # changes test results.
    $script:EmptyExclude = Join-Path $TestDrive 'empty.exclude.txt'
    Set-Content -LiteralPath $script:EmptyExclude -Value ''

    # Runs the scanner quietly and returns its exit code.
    function Invoke-Scan {
        param([hashtable]$Params = @{})
        $Params['NoPause'] = $true
        if (-not $Params.ContainsKey('ExcludeFile')) { $Params['ExcludeFile'] = $script:EmptyExclude }
        if (-not $Params.ContainsKey('AdminChecks')) { $Params['AdminChecks'] = 'Off' }
        & $script:ScriptPath @Params 6>&1 | Out-Null
        return $LASTEXITCODE
    }

    # Creates a folder in the fake Packages directory with one file.
    function New-PackageFolder {
        param(
            [string]$Name,
            [long]$Bytes = 0,
            [datetime]$Modified = (Get-Date)
        )
        $dir = Join-Path $script:PackagesDir $Name
        $sub = Join-Path $dir 'LocalState'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        if ($Bytes -gt 0) {
            $file = Join-Path $sub 'data.bin'
            [System.IO.File]::WriteAllBytes($file, (New-Object byte[] $Bytes))
            (Get-Item -LiteralPath $file).LastWriteTime = $Modified
        }
        (Get-Item -LiteralPath $sub).LastWriteTime = $Modified
        (Get-Item -LiteralPath $dir).LastWriteTime = $Modified
    }

    $script:SavedLocalAppData = $env:LOCALAPPDATA
}

AfterAll {
    $env:LOCALAPPDATA = $script:SavedLocalAppData
}

Describe 'Script file' {

    It 'parses without syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has comment-based help' {
        (Get-Help $ScriptPath).Synopsis | Should -Match 'leftover folders'
    }

    It 'has the same version in the help, the script and CHANGELOG.md' {
        $text       = Get-Content -LiteralPath $ScriptPath -Raw
        $helpVer    = [regex]::Match($text, 'Version:\s*(\d+\.\d+\.\d+)').Groups[1].Value
        $scriptVer  = [regex]::Match($text, '\$ScriptVersion\s*=\s*"(\d+\.\d+\.\d+)"').Groups[1].Value
        $changelog  = Get-Content -LiteralPath (Join-Path $RepoRoot 'CHANGELOG.md') -Raw
        $latestVer  = [regex]::Match($changelog, '## \[(\d+\.\d+\.\d+)\]').Groups[1].Value

        $helpVer   | Should -Not -BeNullOrEmpty
        $scriptVer | Should -Be $helpVer
        $latestVer | Should -Be $helpVer
    }
}

Describe 'Scanning (mocked AppX packages)' {

    BeforeEach {
        $env:LOCALAPPDATA    = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:PackagesDir  = Join-Path $env:LOCALAPPDATA 'Packages'
        $script:OutDir       = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:ReportPath   = Join-Path $OutDir 'report.txt'
        $script:CsvPath      = Join-Path $OutDir 'report.csv'
        New-Item -ItemType Directory -Path $PackagesDir -Force | Out-Null

        Mock Import-Module { } -ParameterFilter { $Name -contains 'Appx' }
        Mock Get-AppxPackage {
            [pscustomobject]@{ PackageFamilyName = 'Microsoft.WindowsStore_8wekyb3d8bbwe' }
            [pscustomobject]@{ PackageFamilyName = 'Microsoft.Photos_8wekyb3d8bbwe' }
            [pscustomobject]@{ PackageFamilyName = '' }
        }

        # Registered (one with different letter case)
        New-PackageFolder -Name 'Microsoft.WindowsStore_8wekyb3d8bbwe' -Bytes 1KB
        New-PackageFolder -Name 'MICROSOFT.PHOTOS_8wekyb3d8bbwe'       -Bytes 1KB
        # Orphaned package folders
        New-PackageFolder -Name 'Contoso.Old_abc123def4567'   -Bytes 3MB -Modified ([datetime]'2024-03-15')
        New-PackageFolder -Name 'Fabrikam.Gone_8wekyb3d8bbwe' -Bytes 1MB
        # Windows components
        New-PackageFolder -Name 'windows_ie_ac_001' -Bytes 2MB
        New-PackageFolder -Name 'Microsoft.Windows.OldPart_cw5n1h2txyewy'
        # Other folders (not package-named)
        New-PackageFolder -Name 'Bad.Name_ABCIL'
    }

    Context 'normal run' {

        BeforeEach {
            $script:ExitCode = Invoke-Scan @{ ReportPath = $ReportPath; Csv = $true }
            $script:Rows     = @(Import-Csv -LiteralPath $CsvPath)
        }

        It 'exits with code 0' {
            $ExitCode | Should -Be 0
        }

        It 'writes the text report and the CSV' {
            $ReportPath | Should -Exist
            $CsvPath    | Should -Exist
        }

        It 'puts an empty Delete column first in the CSV' {
            $Rows[0].PSObject.Properties.Name[0] | Should -Be 'Delete'
            @($Rows | Where-Object { $_.Delete -ne '' }).Count | Should -Be 0
        }

        It 'ignores registered folders, including different letter case' {
            $Rows.FolderName | Should -Not -Contain 'Microsoft.WindowsStore_8wekyb3d8bbwe'
            $Rows.FolderName | Should -Not -Contain 'MICROSOFT.PHOTOS_8wekyb3d8bbwe'
        }

        It 'classifies package-named folders as orphaned' {
            $orphans = @($Rows | Where-Object Category -eq 'Orphaned package')
            $orphans.FolderName | Should -Be @('Contoso.Old_abc123def4567', 'Fabrikam.Gone_8wekyb3d8bbwe')
            $orphans.Status | Should -Be @('NOT CURRENTLY REGISTERED', 'NOT CURRENTLY REGISTERED')
        }

        It 'classifies Windows components separately, and marks them keep' {
            $win = @($Rows | Where-Object Category -eq 'Windows component')
            $win.FolderName | Should -Be @('windows_ie_ac_001', 'Microsoft.Windows.OldPart_cw5n1h2txyewy')
            $win.Status | Should -Be @('WINDOWS COMPONENT (KEEP)', 'WINDOWS COMPONENT (KEEP)')
        }

        It 'classifies other folders separately' {
            $others = @($Rows | Where-Object Category -eq 'Other folder')
            $others.FolderName | Should -Be @('Bad.Name_ABCIL')
        }

        It 'reports sizes in MB, largest first' {
            ($Rows | Where-Object FolderName -eq 'Contoso.Old_abc123def4567').SizeMB | Should -Be '3'
            ($Rows | Where-Object FolderName -eq 'Fabrikam.Gone_8wekyb3d8bbwe').SizeMB | Should -Be '1'
        }

        It 'reports the last-modified date' {
            ($Rows | Where-Object FolderName -eq 'Contoso.Old_abc123def4567').LastModified | Should -Be '2024-03-15'
        }

        It 'puts totals and the safety notice in the report' {
            $report = Get-Content -LiteralPath $ReportPath -Raw
            $report | Should -Match 'Registered packages:\s+2'
            $report | Should -Match 'Orphaned package folders:\s+2 \(4 MB\)'
            $report | Should -Match 'Windows components:\s+2 \(2 MB\)'
            $report | Should -Match 'Other folders:\s+1 \(0 MB\)'
            $report | Should -Match 'Excluded:\s+0'
            $report | Should -Match 'Nothing was deleted or modified'
        }
    }

    It 'does not change anything in the Packages folder' {
        $before = Get-ChildItem -LiteralPath $PackagesDir -Recurse -Force |
            ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }

        Invoke-Scan @{ ReportPath = $ReportPath; Csv = $true } | Should -Be 0

        $after = Get-ChildItem -LiteralPath $PackagesDir -Recurse -Force |
            ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }
        $after | Should -Be $before
    }

    Context 'package lookup' {

        It 'asks for every package type' {
            Invoke-Scan @{ ReportPath = $ReportPath } | Should -Be 0
            Should -Invoke Get-AppxPackage -ParameterFilter { $PackageTypeFilter -eq 'All' } -Scope It
        }

        It 'falls back when the package type filter is not supported' {
            Mock Get-AppxPackage { throw 'unsupported' } -ParameterFilter { $PackageTypeFilter }
            Invoke-Scan @{ ReportPath = $ReportPath; Csv = $true } | Should -Be 0
            @(Import-Csv -LiteralPath $CsvPath).FolderName | Should -Not -Contain 'Microsoft.WindowsStore_8wekyb3d8bbwe'
        }

        It 'adds an empty Notes column when admin checks are off' {
            Invoke-Scan @{ ReportPath = $ReportPath; Csv = $true } | Should -Be 0
            $rows = @(Import-Csv -LiteralPath $CsvPath)
            $rows[0].PSObject.Properties.Name | Should -Contain 'Notes'
            @($rows | Where-Object { $_.Notes }).Count | Should -Be 0
        }
    }

    Context 'administrator checks' {

        BeforeEach {
            New-PackageFolder -Name 'Staged.App_abc123def4567'
            New-PackageFolder -Name 'Prov.App_8wekyb3d8bbwe'
            Mock Get-AppxPackage -ParameterFilter { $AllUsers } {
                $me = $env:WINPKGSCAN_TEST_SID
                try { $w = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; if ($w) { $me = $w } } catch { $me = $env:WINPKGSCAN_TEST_SID }
                [pscustomobject]@{ PackageFamilyName = 'Staged.App_abc123def4567'
                    PackageUserInformation = @([pscustomobject]@{
                        UserSecurityId = [pscustomobject]@{ Sid = $me; UserName = 'me' }; InstallState = 'Staged' }) }
                [pscustomobject]@{ PackageFamilyName = 'Contoso.Old_abc123def4567'
                    PackageUserInformation = @(
                        'S-1-5-21-9-9-9-2001 [bob]: Installed',
                        'S-1-5-21-9-9-9-2002 [amy]: Installed',
                        'S-1-5-21-9-9-9-2002 [amy]: Staged',
                        'S-1-5-18 [S-1-5-18]: Staged') }
            }
            Mock Get-AppxProvisionedPackage {
                [pscustomobject]@{ DisplayName = 'Prov.App'; PublisherId = '8wekyb3d8bbwe' }
            }
        }

        It 'keeps out folders of apps registered to you in an unfinished state' {
            Invoke-Scan @{ ReportPath = $ReportPath; Csv = $true; AdminChecks = 'On' } | Should -Be 0
            $rows = @(Import-Csv -LiteralPath $CsvPath)
            $rows.FolderName | Should -Not -Contain 'Staged.App_abc123def4567'
            (Get-Content -LiteralPath $ReportPath -Raw) | Should -Match 'Kept by admin checks:\s+1'
        }

        It 'notes how many other real user accounts have the app' {
            Invoke-Scan @{ ReportPath = $ReportPath; Csv = $true; AdminChecks = 'On' } | Should -Be 0
            $row = Import-Csv -LiteralPath $CsvPath | Where-Object FolderName -eq 'Contoso.Old_abc123def4567'
            $row.Notes | Should -Be 'Installed for 2 other users'
        }

        It 'notes provisioned apps' {
            Invoke-Scan @{ ReportPath = $ReportPath; Csv = $true; AdminChecks = 'On' } | Should -Be 0
            $row = Import-Csv -LiteralPath $CsvPath | Where-Object FolderName -eq 'Prov.App_8wekyb3d8bbwe'
            $row.Category | Should -Be 'Orphaned package'
            $row.Notes | Should -Match 'Provisioned'
        }

        It 'does not run them when set to Off' {
            Invoke-Scan @{ ReportPath = $ReportPath; Csv = $true; AdminChecks = 'Off' } | Should -Be 0
            Should -Invoke Get-AppxPackage -ParameterFilter { $AllUsers } -Times 0 -Scope It
            @(Import-Csv -LiteralPath $CsvPath).FolderName | Should -Contain 'Staged.App_abc123def4567'
        }

        It 'carries on with a warning when they fail' {
            Mock Get-AppxPackage -ParameterFilter { $AllUsers } { throw 'Access denied (mock)' }
            Invoke-Scan @{ ReportPath = $ReportPath; Csv = $true; AdminChecks = 'On' } | Should -Be 0
            (Get-Content -LiteralPath $ReportPath -Raw) | Should -Match 'Administrator checks:\s+failed'
            @(Import-Csv -LiteralPath $CsvPath).FolderName | Should -Contain 'Staged.App_abc123def4567'
        }
    }

    Context 'exclusions' {

        It 'leaves out folders matching -Exclude wildcards' {
            Invoke-Scan @{ ReportPath = $ReportPath; Csv = $true; Exclude = @('Contoso.*', '*_ABCIL') } | Should -Be 0
            $rows = @(Import-Csv -LiteralPath $CsvPath)
            $rows.FolderName | Should -Not -Contain 'Contoso.Old_abc123def4567'
            $rows.FolderName | Should -Not -Contain 'Bad.Name_ABCIL'
            $rows.FolderName | Should -Contain 'Fabrikam.Gone_8wekyb3d8bbwe'
            (Get-Content -LiteralPath $ReportPath -Raw) | Should -Match 'Excluded:\s+2'
        }

        It 'reads patterns from the exclude file, ignoring comments and blank lines' {
            $file = Join-Path $OutDir 'my.exclude.txt'
            New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
            Set-Content -LiteralPath $file -Value @('# a comment', '', '  fabrikam.*  ', '#Contoso.*')
            Invoke-Scan @{ ReportPath = $ReportPath; Csv = $true; ExcludeFile = $file } | Should -Be 0
            $rows = @(Import-Csv -LiteralPath $CsvPath)
            $rows.FolderName | Should -Not -Contain 'Fabrikam.Gone_8wekyb3d8bbwe'
            $rows.FolderName | Should -Contain 'Contoso.Old_abc123def4567'
        }

        It 'still runs when the given exclude file does not exist' {
            Invoke-Scan @{ ReportPath = $ReportPath; ExcludeFile = (Join-Path $OutDir 'missing.txt') } | Should -Be 0
        }

        It 'ships an exclude file that has no active patterns' {
            $shipped = Join-Path $RepoRoot 'WinPkgScan.exclude.txt'
            $shipped | Should -Exist
            @(Get-Content -LiteralPath $shipped | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count | Should -Be 0
        }
    }

    Context 'HTML report' {

        It 'writes an HTML report with every section when -Html is used' {
            New-PackageFolder -Name 'Amp&Co_abc123def4567'
            Invoke-Scan @{ ReportPath = $ReportPath; Html = $true } | Should -Be 0
            $htmlPath = [System.IO.Path]::ChangeExtension($ReportPath, '.html')
            $htmlPath | Should -Exist
            $html = Get-Content -LiteralPath $htmlPath -Raw
            $html | Should -Match '<!doctype html>'
            $html | Should -Match 'Contoso\.Old_abc123def4567'
            $html | Should -Match 'Orphaned package folders'
            $html | Should -Match 'Windows components'
            $html | Should -Match 'Other folders'
            $html | Should -Match 'Amp&amp;Co_abc123def4567'
            $html | Should -Not -Match 'Amp&Co_'
        }

        It 'lets you mark only orphaned folders, with the data needed for the CSV' {
            Invoke-Scan @{ ReportPath = $ReportPath; Html = $true } | Should -Be 0
            $html = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($ReportPath, '.html')) -Raw
            ([regex]::Matches($html, 'class="mark"')).Count | Should -Be 2
            $html | Should -Match 'data-name="Contoso\.Old_abc123def4567"'
            $html | Should -Match 'data-path="[^"]*Contoso\.Old_abc123def4567"'
            $html | Should -Not -Match 'data-name="windows_ie_ac_001"'
            $html | Should -Match 'id="save"'
            $html | Should -Match 'WinPkgScan-marked\.csv'
        }

        It 'writes balanced HTML' {
            Invoke-Scan @{ ReportPath = $ReportPath; Html = $true } | Should -Be 0
            $html = Get-Content -LiteralPath ([System.IO.Path]::ChangeExtension($ReportPath, '.html')) -Raw
            foreach ($tag in 'div', 'section', 'table', 'tr', 'main') {
                ([regex]::Matches($html, "<$tag[ >]")).Count | Should -Be ([regex]::Matches($html, "</$tag>")).Count -Because "<$tag> must be closed"
            }
        }

        It 'does not write an HTML report without -Html' {
            Invoke-Scan @{ ReportPath = $ReportPath } | Should -Be 0
            [System.IO.Path]::ChangeExtension($ReportPath, '.html') | Should -Not -Exist
        }
    }

    It 'does not write a CSV without -Csv' {
        Invoke-Scan @{ ReportPath = $ReportPath } | Should -Be 0
        $ReportPath | Should -Exist
        $CsvPath    | Should -Not -Exist
    }

    It 'creates a missing report folder' {
        $nested = Join-Path $OutDir 'a/b/report.txt'
        Invoke-Scan @{ ReportPath = $nested } | Should -Be 0
        $nested | Should -Exist
    }

    Context 'error handling' {

        It 'aborts with code 1 when Get-AppxPackage fails' {
            Mock Get-AppxPackage { throw 'Access denied (mock)' }
            Invoke-Scan @{ ReportPath = $ReportPath } | Should -Be 1
            $ReportPath | Should -Not -Exist
        }

        It 'aborts with code 1 when no packages are returned' {
            Mock Get-AppxPackage { }
            Invoke-Scan @{ ReportPath = $ReportPath } | Should -Be 1
            $ReportPath | Should -Not -Exist
        }

        It 'aborts with code 1 when only blank package names are returned' {
            Mock Get-AppxPackage { [pscustomobject]@{ PackageFamilyName = '' } }
            Invoke-Scan @{ ReportPath = $ReportPath } | Should -Be 1
        }

        It 'exits with code 1 when the Packages folder is missing' {
            Remove-Item -LiteralPath $PackagesDir -Recurse -Force
            Invoke-Scan @{ ReportPath = $ReportPath } | Should -Be 1
        }

        It 'exits with code 1 when the report cannot be written' {
            # A path under an existing file can never be created.
            $blocker = Join-Path $TestDrive 'blocker.txt'
            Set-Content -LiteralPath $blocker -Value 'x'
            Invoke-Scan @{ ReportPath = (Join-Path $blocker 'report.txt') } | Should -Be 1
        }
    }
}

Describe 'Real Windows run' -Tag 'Integration' -Skip:(-not $HasPackages) {

    BeforeAll {
        $env:LOCALAPPDATA = $script:SavedLocalAppData

        # A global stub function would take priority over the real
        # Get-AppxPackage cmdlet, so remove it before running for real.
        if ($script:CreatedStub) {
            Remove-Item -Path Function:\global:Get-AppxPackage -ErrorAction SilentlyContinue
        }
    }

    It 'scans the current user with the real Get-AppxPackage' {
        $report = Join-Path $TestDrive 'real.txt'
        Invoke-Scan @{ ReportPath = $report; Csv = $true } | Should -Be 0
        $report | Should -Exist
        [System.IO.Path]::ChangeExtension($report, '.csv') | Should -Exist

        $count = [int][regex]::Match((Get-Content -LiteralPath $report -Raw), 'Registered packages:\s+(\d+)').Groups[1].Value
        $count | Should -BeGreaterThan 0
    }

    It 'runs through Run-Scan-Unattended.bat' {
        $report = Join-Path $TestDrive 'bat.txt'
        $bat    = Join-Path $RepoRoot 'Run-Scan-Unattended.bat'
        # Call the .bat directly. PowerShell runs it through cmd.exe and
        # quotes the arguments correctly.
        & $bat -ReportPath $report | Out-Null
        $LASTEXITCODE | Should -Be 0
        $report | Should -Exist
    }
}
