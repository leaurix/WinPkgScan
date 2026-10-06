#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Pester tests for Remove-OrphanedAppxFolders.ps1

    - Unit tests: run anywhere. Get-AppxPackage is mocked, and a fake
      Packages folder is built in Pester's TestDrive. Deletion is tested
      for real with -Permanent, and with -WhatIf.
    - Integration tests (tag "Integration"): Windows only. Test the
      Recycle Bin and the full scan > mark > delete flow through the
      batch files.

    Run:  Invoke-Pester ./tests
#>

BeforeDiscovery {
    $script:OnWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
}

BeforeAll {
    $script:RepoRoot    = Split-Path -Parent $PSScriptRoot
    $script:RemovePath  = Join-Path $RepoRoot 'Remove-OrphanedAppxFolders.ps1'
    $script:ScanPath    = Join-Path $RepoRoot 'Find-OrphanedAppxFolders.ps1'
    $script:OnWindows   = [Environment]::OSVersion.Platform -eq 'Win32NT'
    $script:SavedLocalAppData = $env:LOCALAPPDATA

    # Get-AppxPackage only exists on Windows. Pester can only mock a
    # command that exists, so add a stub where it is missing.
    $script:CreatedStub = $false
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        function global:Get-AppxPackage { [CmdletBinding()] param() }
        $script:CreatedStub = $true
    }

    $script:OrphanA   = 'Contoso.Old_abc123def4567'
    $script:OrphanB   = 'Fabrikam.Gone_8wekyb3d8bbwe'
    $script:Installed = 'Microsoft.WindowsStore_8wekyb3d8bbwe'
    $script:Other     = 'windows_ie_ac_001'
    $script:OldDate   = [datetime]'2024-03-15'

    function New-PackageFolder {
        param(
            [string]$Name,
            [long]$Bytes = 1KB,
            [datetime]$Modified = $script:OldDate
        )
        $dir = Join-Path $script:PackagesDir $Name
        $sub = Join-Path $dir 'LocalState'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        $file = Join-Path $sub 'data.bin'
        [System.IO.File]::WriteAllBytes($file, (New-Object byte[] $Bytes))
        (Get-Item -LiteralPath $file).LastWriteTime = $Modified
        (Get-Item -LiteralPath $sub).LastWriteTime  = $Modified
        (Get-Item -LiteralPath $dir).LastWriteTime  = $Modified
        return $dir
    }

    # Writes a CSV in the scanner's format. Pass folder names to mark,
    # or full rows (hashtables) for custom cases.
    function New-TestCsv {
        param(
            [string[]]$Marked = @(),
            [object[]]$Rows,
            [string]$Delimiter = ',',
            [switch]$NoDeleteColumn
        )
        if (-not $Rows) {
            $Rows = foreach ($n in @($script:OrphanA, $script:OrphanB, $script:Other)) {
                @{ Name = $n; Delete = $(if ($Marked -contains $n) { 'Yes' } else { '' }) }
            }
        }
        $objects = foreach ($r in $Rows) {
            $full = if ($r.ContainsKey('FullPath')) { $r.FullPath } else { Join-Path $script:PackagesDir $r.Name }
            $o = [ordered]@{}
            if (-not $NoDeleteColumn) { $o.Delete = $r.Delete }
            $o.Category     = 'Orphaned package'
            $o.FolderName   = $r.Name
            $o.SizeMB       = '0'
            $o.LastModified = '2024-03-15'
            $o.FullPath     = $full
            $o.Status       = 'NOT CURRENTLY REGISTERED'
            [pscustomobject]$o
        }
        $objects | Export-Csv -LiteralPath $script:CsvPath -NoTypeInformation -Delimiter $Delimiter -Encoding UTF8
    }

    # Runs the remover quietly. Returns the exit code and the log rows.
    function Invoke-Remove {
        param([hashtable]$Params = @{})
        $Params['NoPause'] = $true
        if (-not $Params.ContainsKey('CsvPath')) { $Params['CsvPath'] = $script:CsvPath }
        if (-not $Params.ContainsKey('LogPath')) { $Params['LogPath'] = $script:LogPath }
        if (-not ($Params.ContainsKey('WhatIf') -or $Params.ContainsKey('Confirm') -or $Params.ContainsKey('Force'))) {
            $Params['Confirm'] = $false
        }
        & $script:RemovePath @Params 6>&1 | Out-Null
        $code = $LASTEXITCODE
        $log  = if (Test-Path -LiteralPath $script:LogPath) { @(Import-Csv -LiteralPath $script:LogPath) } else { @() }
        return [pscustomobject]@{ ExitCode = $code; Log = $log }
    }

    function Get-LogRow {
        param($Result, [string]$Name)
        return $Result.Log | Where-Object FolderName -eq $Name
    }
}

AfterAll {
    $env:LOCALAPPDATA = $script:SavedLocalAppData
}

Describe 'Remove script file' {

    It 'parses without syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($RemovePath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has comment-based help' {
        (Get-Help $RemovePath).Synopsis | Should -Match 'Deletes the orphaned AppX folders'
    }

    It 'supports -WhatIf and -Confirm' {
        $cmd = Get-Command $RemovePath
        $cmd.Parameters.Keys | Should -Contain 'WhatIf'
        $cmd.Parameters.Keys | Should -Contain 'Confirm'
    }

    It 'has the same version as the scanner' {
        $pattern = '\$ScriptVersion\s*=\s*"(\d+\.\d+\.\d+)"'
        $removeVer = [regex]::Match((Get-Content -LiteralPath $RemovePath -Raw), $pattern).Groups[1].Value
        $scanVer   = [regex]::Match((Get-Content -LiteralPath $ScanPath -Raw), $pattern).Groups[1].Value
        $helpVer   = [regex]::Match((Get-Content -LiteralPath $RemovePath -Raw), 'Version:\s*(\d+\.\d+\.\d+)').Groups[1].Value
        $removeVer | Should -Not -BeNullOrEmpty
        $removeVer | Should -Be $scanVer
        $helpVer   | Should -Be $scanVer
    }
}

Describe 'Removing (mocked AppX packages)' {

    BeforeEach {
        $env:LOCALAPPDATA   = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:PackagesDir = Join-Path $env:LOCALAPPDATA 'Packages'
        $script:WorkDir     = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:CsvPath     = Join-Path $WorkDir 'scan.csv'
        $script:LogPath     = Join-Path $WorkDir 'log.csv'
        New-Item -ItemType Directory -Path $PackagesDir, $WorkDir -Force | Out-Null

        Mock Import-Module { } -ParameterFilter { $Name -contains 'Appx' }
        Mock Get-AppxPackage {
            [pscustomobject]@{ PackageFamilyName = 'Microsoft.WindowsStore_8wekyb3d8bbwe' }
        }

        $script:DirA     = New-PackageFolder -Name $OrphanA -Bytes 3MB
        $script:DirB     = New-PackageFolder -Name $OrphanB -Bytes 1MB
        $script:DirOther = New-PackageFolder -Name $Other
        $script:DirInst  = New-PackageFolder -Name $Installed
    }

    Context 'deleting' {

        It 'deletes only the rows marked Yes' {
            New-TestCsv -Marked $OrphanA
            $r = Invoke-Remove @{ Permanent = $true }

            $r.ExitCode | Should -Be 0
            $DirA | Should -Not -Exist
            $DirB | Should -Exist
            $DirOther | Should -Exist
            (Get-LogRow $r $OrphanA).Action | Should -Be 'Deleted'
            (Get-LogRow $r $OrphanA).SizeMB | Should -Be '3'
            @($r.Log).Count | Should -Be 1
        }

        It 'accepts <Value> as a Delete mark' -TestCases @(
            @{ Value = 'yes' }, @{ Value = 'Y' }, @{ Value = 'TRUE' }, @{ Value = '1' }, @{ Value = 'x' }, @{ Value = ' Yes ' }
        ) {
            param($Value)
            New-TestCsv -Rows @(@{ Name = $OrphanA; Delete = $Value })
            (Invoke-Remove @{ Permanent = $true }).ExitCode | Should -Be 0
            $DirA | Should -Not -Exist
        }

        It 'ignores <Value> as a Delete mark' -TestCases @(
            @{ Value = 'No' }, @{ Value = '' }, @{ Value = 'maybe' }, @{ Value = '0' }
        ) {
            param($Value)
            New-TestCsv -Rows @(@{ Name = $OrphanA; Delete = $Value })
            (Invoke-Remove @{ Permanent = $true }).ExitCode | Should -Be 0
            $DirA | Should -Exist
        }

        It 'reads a CSV saved with ";" by Excel' {
            New-TestCsv -Marked $OrphanA -Delimiter ';'
            (Invoke-Remove @{ Permanent = $true }).ExitCode | Should -Be 0
            $DirA | Should -Not -Exist
        }

        It 'deletes nothing with -WhatIf, and logs what it would do' {
            New-TestCsv -Marked $OrphanA, $OrphanB
            $r = Invoke-Remove @{ Permanent = $true; WhatIf = $true }

            $r.ExitCode | Should -Be 0
            $DirA | Should -Exist
            $DirB | Should -Exist
            (Get-LogRow $r $OrphanA).Action | Should -Be 'WhatIf'
            (Get-LogRow $r $OrphanB).Action | Should -Be 'WhatIf'
        }

        It 'deletes without prompting when -Force is used' {
            New-TestCsv -Marked $OrphanA
            $r = Invoke-Remove @{ Permanent = $true; Force = $true }
            $r.ExitCode | Should -Be 0
            $DirA | Should -Not -Exist
        }

        It 'exits 0 with nothing to do when no rows are marked' {
            New-TestCsv
            (Invoke-Remove @{ Permanent = $true }).ExitCode | Should -Be 0
            $DirA | Should -Exist
        }
    }

    Context 'safety checks' {

        It 'skips a folder that is registered to an installed app' {
            New-TestCsv -Rows @(@{ Name = $Installed; Delete = 'Yes' })
            $r = Invoke-Remove @{ Permanent = $true }
            $DirInst | Should -Exist
            (Get-LogRow $r $Installed).Reason | Should -Match 'Registered'
        }

        It 'skips a folder that became registered after the scan' {
            New-TestCsv -Marked $OrphanA
            Mock Get-AppxPackage {
                [pscustomobject]@{ PackageFamilyName = 'Microsoft.WindowsStore_8wekyb3d8bbwe' }
                [pscustomobject]@{ PackageFamilyName = 'CONTOSO.OLD_abc123def4567' }
            }
            $r = Invoke-Remove @{ Permanent = $true }
            $DirA | Should -Exist
            (Get-LogRow $r $OrphanA).Action | Should -Be 'Skipped'
        }

        It 'skips other (non-package) folders by default' {
            New-TestCsv -Marked $Other
            $r = Invoke-Remove @{ Permanent = $true }
            $DirOther | Should -Exist
            (Get-LogRow $r $Other).Reason | Should -Match 'Not a package-named folder'
        }

        It 'deletes other folders with -IncludeOtherFolders' {
            New-TestCsv -Marked $Other
            (Invoke-Remove @{ Permanent = $true; IncludeOtherFolders = $true }).ExitCode | Should -Be 0
            $DirOther | Should -Not -Exist
        }

        It 'skips a folder modified within -MinAgeDays' {
            $recent = New-PackageFolder -Name 'Recent.App_abc123def4567' -Modified (Get-Date).AddDays(-5)
            New-TestCsv -Rows @(@{ Name = 'Recent.App_abc123def4567'; Delete = 'Yes' })
            $r = Invoke-Remove @{ Permanent = $true }
            $recent | Should -Exist
            (Get-LogRow $r 'Recent.App_abc123def4567').Reason | Should -Match 'within 30 days'
        }

        It 'deletes a recent folder when -MinAgeDays is 0' {
            $recent = New-PackageFolder -Name 'Recent.App_abc123def4567' -Modified (Get-Date)
            New-TestCsv -Rows @(@{ Name = 'Recent.App_abc123def4567'; Delete = 'Yes' })
            (Invoke-Remove @{ Permanent = $true; MinAgeDays = 0 }).ExitCode | Should -Be 0
            $recent | Should -Not -Exist
        }

        It 'checks the newest file inside the folder, not just the folder date' {
            $dir  = New-PackageFolder -Name 'Deep.App_abc123def4567'
            $file = Join-Path $dir 'LocalState/new.txt'
            Set-Content -LiteralPath $file -Value 'recent'
            (Get-Item -LiteralPath (Join-Path $dir 'LocalState')).LastWriteTime = $OldDate
            (Get-Item -LiteralPath $dir).LastWriteTime = $OldDate
            New-TestCsv -Rows @(@{ Name = 'Deep.App_abc123def4567'; Delete = 'Yes' })
            Invoke-Remove @{ Permanent = $true } | Out-Null
            $dir | Should -Exist
        }

        It 'skips a path outside the Packages folder' {
            $outside = Join-Path $TestDrive ('Victim_' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $outside | Out-Null
            $name = Split-Path $outside -Leaf
            New-TestCsv -Rows @(@{ Name = $name; Delete = 'Yes'; FullPath = $outside })
            $r = Invoke-Remove @{ Permanent = $true; IncludeOtherFolders = $true; MinAgeDays = 0 }
            $outside | Should -Exist
            (Get-LogRow $r $name).Reason | Should -Match 'Not directly inside'
        }

        It 'skips a path that uses ".." to leave the Packages folder' {
            $outside = Join-Path $env:LOCALAPPDATA 'Victim.App_abc123def4567'
            New-Item -ItemType Directory -Path $outside | Out-Null
            $sneaky = Join-Path $PackagesDir '../Victim.App_abc123def4567'
            New-TestCsv -Rows @(@{ Name = 'Victim.App_abc123def4567'; Delete = 'Yes'; FullPath = $sneaky })
            Invoke-Remove @{ Permanent = $true; MinAgeDays = 0 } | Out-Null
            $outside | Should -Exist
        }

        It 'skips a sub-folder deeper inside the Packages folder' {
            $deep = Join-Path $DirA 'LocalState'
            New-TestCsv -Rows @(@{ Name = 'LocalState'; Delete = 'Yes'; FullPath = $deep })
            Invoke-Remove @{ Permanent = $true; IncludeOtherFolders = $true; MinAgeDays = 0 } | Out-Null
            $deep | Should -Exist
        }

        It 'skips a row where FolderName and FullPath do not match' {
            New-TestCsv -Rows @(@{ Name = $OrphanB; Delete = 'Yes'; FullPath = $DirA })
            $r = Invoke-Remove @{ Permanent = $true }
            $DirA | Should -Exist
            $DirB | Should -Exist
            (Get-LogRow $r $OrphanB).Reason | Should -Match 'do not match'
        }

        It 'skips a folder that no longer exists' {
            New-TestCsv -Rows @(@{ Name = 'Gone.Already_abc123def4567'; Delete = 'Yes' })
            $r = Invoke-Remove @{ Permanent = $true }
            $r.ExitCode | Should -Be 0
            (Get-LogRow $r 'Gone.Already_abc123def4567').Reason | Should -Match 'not found'
        }

        It 'does not follow a link or junction' {
            $target = Join-Path $TestDrive ('LinkTarget_' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $target | Out-Null
            $keep = Join-Path $target 'keep.txt'
            Set-Content -LiteralPath $keep -Value 'must survive'

            $link = Join-Path $PackagesDir 'Linked.App_abc123def4567'
            $type = if ($OnWindows) { 'Junction' } else { 'SymbolicLink' }
            New-Item -ItemType $type -Path $link -Target $target | Out-Null

            New-TestCsv -Rows @(@{ Name = 'Linked.App_abc123def4567'; Delete = 'Yes' })
            $r = Invoke-Remove @{ Permanent = $true; MinAgeDays = 0 }
            $keep | Should -Exist
            $link | Should -Exist
            (Get-LogRow $r 'Linked.App_abc123def4567').Reason | Should -Match 'Link or junction'
        }
    }

    Context 'links inside a folder' {

        It 'skips a folder that contains a link or junction, and keeps the target' {
            $target = Join-Path $TestDrive ('InnerTarget_' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $target | Out-Null
            $keep = Join-Path $target 'keep.txt'
            Set-Content -LiteralPath $keep -Value 'must survive'

            $inner = Join-Path $DirA 'LocalState/link'
            $type  = if ($OnWindows) { 'Junction' } else { 'SymbolicLink' }
            New-Item -ItemType $type -Path $inner -Target $target | Out-Null

            New-TestCsv -Marked $OrphanA
            $r = Invoke-Remove @{ Permanent = $true; MinAgeDays = 0 }
            $keep | Should -Exist
            $DirA | Should -Exist
            (Get-LogRow $r $OrphanA).Reason | Should -Match 'Contains links or junctions'
        }
    }

    Context 'errors' {

        It 'deletes nothing and exits 1 when Get-AppxPackage fails' {
            New-TestCsv -Marked $OrphanA
            Mock Get-AppxPackage { throw 'Access denied (mock)' }
            (Invoke-Remove @{ Permanent = $true }).ExitCode | Should -Be 1
            $DirA | Should -Exist
        }

        It 'deletes nothing and exits 1 when no packages are returned' {
            New-TestCsv -Marked $OrphanA
            Mock Get-AppxPackage { }
            (Invoke-Remove @{ Permanent = $true }).ExitCode | Should -Be 1
            $DirA | Should -Exist
        }

        It 'exits 1 when the CSV is missing' {
            (Invoke-Remove @{ Permanent = $true; CsvPath = (Join-Path $WorkDir 'none.csv') }).ExitCode | Should -Be 1
        }

        It 'exits 1 when the CSV has no Delete column' {
            New-TestCsv -NoDeleteColumn
            (Invoke-Remove @{ Permanent = $true }).ExitCode | Should -Be 1
            $DirA | Should -Exist
        }
    }

    Context 'end to end with the scanner' {

        It 'scans, marks one row, and deletes only that folder' {
            $report = Join-Path $WorkDir 'Orphaned-Appx-Packages.txt'
            & $ScanPath -NoPause -Csv -ReportPath $report 6>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0

            $scanCsv = [System.IO.Path]::ChangeExtension($report, '.csv')
            $rows = @(Import-Csv -LiteralPath $scanCsv)
            $rows[0].PSObject.Properties.Name[0] | Should -Be 'Delete'
            ($rows | Where-Object FolderName -eq $OrphanA).Delete = 'Yes'
            $rows | Export-Csv -LiteralPath $scanCsv -NoTypeInformation -Encoding UTF8

            $r = Invoke-Remove @{ Permanent = $true; CsvPath = $scanCsv }
            $r.ExitCode | Should -Be 0
            $DirA | Should -Not -Exist
            $DirB | Should -Exist
            $DirOther | Should -Exist
            $DirInst | Should -Exist
        }
    }
}

Describe 'Recycle Bin and batch files on Windows' -Tag 'Integration' -Skip:(-not $OnWindows) {

    BeforeAll {
        # A global stub would take priority over the real cmdlet.
        if ($script:CreatedStub) {
            Remove-Item -Path Function:\global:Get-AppxPackage -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        $env:LOCALAPPDATA   = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:PackagesDir = Join-Path $env:LOCALAPPDATA 'Packages'
        $script:WorkDir     = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:CsvPath     = Join-Path $WorkDir 'scan.csv'
        $script:LogPath     = Join-Path $WorkDir 'log.csv'
        New-Item -ItemType Directory -Path $PackagesDir, $WorkDir -Force | Out-Null
        $script:DirA = New-PackageFolder -Name $OrphanA
        $script:DirB = New-PackageFolder -Name $OrphanB
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocalAppData
    }

    It 'moves a folder to the Recycle Bin' {
        New-TestCsv -Marked $OrphanA
        # The real Get-AppxPackage runs; the test folder names are not installed apps.
        $r = Invoke-Remove @{}
        $r.ExitCode | Should -Be 0
        (Get-LogRow $r $OrphanA).Action | Should -Be 'Recycled'
        $DirA | Should -Not -Exist
        $DirB | Should -Exist
    }

    It 'Run-Scan.bat saves a CSV by default' {
        $report = Join-Path $WorkDir 'bat-scan.txt'
        & (Join-Path $RepoRoot 'Run-Scan.bat') -NoPause -ReportPath $report | Out-Null
        $LASTEXITCODE | Should -Be 0
        [System.IO.Path]::ChangeExtension($report, '.csv') | Should -Exist
    }

    It 'Run-Scan.bat accepts -Csv without passing it twice' {
        $report = Join-Path $WorkDir 'bat-scan2.txt'
        & (Join-Path $RepoRoot 'Run-Scan.bat') -Csv -NoPause -ReportPath $report | Out-Null
        $LASTEXITCODE | Should -Be 0
        [System.IO.Path]::ChangeExtension($report, '.csv') | Should -Exist
    }

    It 'Run-Delete.bat deletes the marked folder' {
        New-TestCsv -Marked $OrphanB
        & (Join-Path $RepoRoot 'Run-Delete.bat') $CsvPath -Permanent -Force -NoPause -LogPath $LogPath | Out-Null
        $LASTEXITCODE | Should -Be 0
        $DirB | Should -Not -Exist
        $DirA | Should -Exist
    }
}
