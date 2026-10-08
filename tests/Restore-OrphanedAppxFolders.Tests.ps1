#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Pester tests for Restore-OrphanedAppxFolders.ps1 and WinPkgScan.bat

    - Unit tests: run anywhere. Finding and reading the delete log.
    - Integration tests (tag "Integration"): Windows only. A real round trip
      through the Recycle Bin, and the WinPkgScan.bat direct commands.

    Run:  Invoke-Pester ./tests
#>

BeforeDiscovery {
    $script:OnWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
}

BeforeAll {
    $script:RepoRoot    = Split-Path -Parent $PSScriptRoot
    $script:RestorePath = Join-Path $RepoRoot 'Restore-OrphanedAppxFolders.ps1'
    $script:RemovePath  = Join-Path $RepoRoot 'Remove-OrphanedAppxFolders.ps1'
    $script:MenuPath    = Join-Path $RepoRoot 'WinPkgScan.bat'
    $script:SavedLocalAppData = $env:LOCALAPPDATA

    $script:EmptyExclude = Join-Path $TestDrive 'empty.exclude.txt'
    Set-Content -LiteralPath $script:EmptyExclude -Value ''

    function New-PackageFolder {
        param([string]$Name)
        $dir = Join-Path $script:PackagesDir $Name
        $sub = Join-Path $dir 'LocalState'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sub 'settings.dat') -Value 'keep me'
        foreach ($p in (Join-Path $sub 'settings.dat'), $sub, $dir) {
            (Get-Item -LiteralPath $p).LastWriteTime = [datetime]'2024-03-15'
        }
        return $dir
    }

    function New-DeleteLog {
        param([string]$Folder, [object[]]$Rows, [string]$Stamp = '20261008-100000')
        $path = Join-Path $Folder "WinPkgScan-DeleteLog-$Stamp.csv"
        $Rows | ForEach-Object {
            [pscustomobject]@{
                Time = '2026-10-08 10:00:00'; Action = $_.Action; FolderName = $_.Name
                SizeMB = '0'; FullPath = (Join-Path $script:PackagesDir $_.Name); Reason = ''
            }
        } | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
        return $path
    }

    function Invoke-Restore {
        param([hashtable]$Params = @{})
        $Params['NoPause'] = $true
        $out  = & $script:RestorePath @Params 6>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
}

AfterAll {
    $env:LOCALAPPDATA = $script:SavedLocalAppData
}

Describe 'Restore script file' {

    It 'parses without syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($RestorePath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has comment-based help' {
        (Get-Help $RestorePath).Synopsis | Should -Match 'Recycle Bin'
    }

    It 'supports -WhatIf' {
        (Get-Command $RestorePath).Parameters.Keys | Should -Contain 'WhatIf'
    }
}

Describe 'Restore: finding and reading the log' {

    BeforeEach {
        $env:LOCALAPPDATA   = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:PackagesDir = Join-Path $env:LOCALAPPDATA 'Packages'
        $script:LogDir      = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $PackagesDir, $LogDir -Force | Out-Null
    }

    It 'exits 1 when no delete log is found' {
        $r = Invoke-Restore @{ SearchFolder = @($LogDir) }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'No delete log was found'
    }

    It 'uses the newest delete log' {
        $old = New-DeleteLog -Folder $LogDir -Stamp '20261001-100000' -Rows @(@{ Action = 'Recycled'; Name = 'Old.App_abc123def4567' })
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-2)
        $new = New-DeleteLog -Folder $LogDir -Stamp '20261008-100000' -Rows @(@{ Action = 'Deleted'; Name = 'New.App_abc123def4567' })
        $r = Invoke-Restore @{ SearchFolder = @($LogDir) }
        $r.Output | Should -Match ([regex]::Escape($new))
    }

    It 'has nothing to restore when every folder was deleted permanently' {
        New-DeleteLog -Folder $LogDir -Rows @(@{ Action = 'Deleted'; Name = 'Gone.App_abc123def4567' }) | Out-Null
        $r = Invoke-Restore @{ SearchFolder = @($LogDir) }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'cannot be restored\): 1'
        $r.Output | Should -Match 'Nothing to restore'
    }

    It 'ignores skipped, failed and WhatIf rows' {
        New-DeleteLog -Folder $LogDir -Rows @(
            @{ Action = 'Skipped'; Name = 'A.App_abc123def4567' },
            @{ Action = 'WhatIf';  Name = 'B.App_abc123def4567' },
            @{ Action = 'Failed';  Name = 'C.App_abc123def4567' }) | Out-Null
        (Invoke-Restore @{ SearchFolder = @($LogDir) }).Output | Should -Match 'Nothing to restore'
    }

    It 'only restores names matching -Name' {
        New-DeleteLog -Folder $LogDir -Rows @(@{ Action = 'Recycled'; Name = 'Contoso.App_abc123def4567' }) | Out-Null
        $r = Invoke-Restore @{ SearchFolder = @($LogDir); Name = @('Fabrikam.*') }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Nothing to restore'
    }

    It 'exits 1 for a CSV that is not a delete log' {
        $path = Join-Path $LogDir 'WinPkgScan-DeleteLog-20261008-100000.csv'
        Set-Content -LiteralPath $path -Value @('"Delete","FolderName","FullPath"', '"Yes","x","y"')
        $r = Invoke-Restore @{ LogPath = $path }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'not a WinPkgScan delete log'
    }
}

Describe 'Restore on Windows: Recycle Bin round trip' -Tag 'Integration' -Skip:(-not $OnWindows) {

    BeforeEach {
        $env:LOCALAPPDATA   = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:PackagesDir = Join-Path $env:LOCALAPPDATA 'Packages'
        $script:WorkDir     = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $PackagesDir, $WorkDir -Force | Out-Null

        # Recycle a test folder with the real remover.
        $script:Name = 'RoundTrip.App_abc123def4567'
        $script:Dir  = New-PackageFolder -Name $Name
        $csv = Join-Path $WorkDir 'scan.csv'
        [pscustomobject]@{ Delete = 'Yes'; FolderName = $Name; FullPath = $Dir } |
            Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
        $script:Log = Join-Path $WorkDir 'WinPkgScan-DeleteLog-20261008-100000.csv'
        & $RemovePath -CsvPath $csv -LogPath $Log -Force -NoPause -ExcludeFile $EmptyExclude -AdminChecks Off 6>&1 | Out-Null
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocalAppData
    }

    It 'recycles the folder first' {
        $Dir | Should -Not -Exist
        (Import-Csv -LiteralPath $Log).Action | Should -Be 'Recycled'
    }

    It 'restores nothing with -WhatIf' {
        $r = Invoke-Restore @{ LogPath = $Log; WhatIf = $true }
        $r.ExitCode | Should -Be 0
        $Dir | Should -Not -Exist
        Invoke-Restore @{ LogPath = $Log } | Out-Null
    }

    It 'puts the folder and its files back' {
        $r = Invoke-Restore @{ LogPath = $Log }
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Restored: 1'
        Join-Path $Dir 'LocalState\settings.dat' | Should -Exist
    }

    It 'skips a folder when something already exists at the path' {
        New-Item -ItemType Directory -Path $Dir | Out-Null
        $r = Invoke-Restore @{ LogPath = $Log }
        $r.Output | Should -Match 'already exists'
        Remove-Item -LiteralPath $Dir -Recurse -Force
        Invoke-Restore @{ LogPath = $Log } | Out-Null
    }
}

Describe 'WinPkgScan.bat direct commands on Windows' -Tag 'Integration' -Skip:(-not $OnWindows) {

    It 'rejects an unknown command with exit code 2' {
        & $MenuPath bogus | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It 'scans with "scan"' {
        $report = Join-Path $TestDrive 'menu-scan.txt'
        & $MenuPath scan -ReportPath $report | Out-Null
        $LASTEXITCODE | Should -Be 0
        [System.IO.Path]::ChangeExtension($report, '.csv') | Should -Exist
        [System.IO.Path]::ChangeExtension($report, '.html') | Should -Exist
    }

    It 'previews with "preview" without deleting anything' {
        $report = Join-Path $TestDrive 'menu-prev.txt'
        & $MenuPath scan -ReportPath $report | Out-Null
        $csv = [System.IO.Path]::ChangeExtension($report, '.csv')
        & $MenuPath preview -CsvPath $csv -LogPath (Join-Path $TestDrive 'menu-log.csv') | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}
