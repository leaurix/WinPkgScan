#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Pester tests for Install.ps1

    - Unit tests: run anywhere. Install into a test folder without shortcuts,
      update, uninstall, and the safety guards.
    - Integration tests (tag "Integration"): Windows only. Real shortcuts and
      a Settings > Apps entry, in test locations.

    Run:  Invoke-Pester ./tests
#>

BeforeDiscovery {
    $script:OnWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
}

BeforeAll {
    $script:RepoRoot      = Split-Path -Parent $PSScriptRoot
    $script:InstallerPath = Join-Path $RepoRoot 'Install.ps1'
    $script:SavedLocalAppData = $env:LOCALAPPDATA

    function Invoke-Installer {
        param([hashtable]$Params = @{})
        $Params['NoPause'] = $true
        foreach ($k in 'NoShortcuts', 'NoUninstallEntry') {
            if (-not $Params.ContainsKey($k)) { $Params[$k] = $true }
        }
        # Join the lines ourselves: Out-String in Windows PowerShell 5.1 wraps long lines.
        $out = (& $script:InstallerPath @Params 6>&1 | ForEach-Object { "$_" }) -join "`n"
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }

    function Get-ListFromScript {
        # Reads a list like $ReleaseFiles = @( 'a' 'b' ) from a script.
        param([string]$Path, [string]$Name)
        $text = Get-Content -LiteralPath $Path -Raw
        $body = [regex]::Match($text, '(?s)\$' + $Name + ' = @\((.*?)\)').Groups[1].Value
        return @([regex]::Matches($body, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    }
}

AfterAll {
    $env:LOCALAPPDATA = $script:SavedLocalAppData
}

Describe 'Install script file' {

    It 'parses without syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($InstallerPath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has comment-based help' {
        (Get-Help $InstallerPath).Synopsis | Should -Match 'Installs WinPkgScan'
    }

    It 'supports -WhatIf' {
        (Get-Command $InstallerPath).Parameters.Keys | Should -Contain 'WhatIf'
    }

    It 'has the same version as the scanner' {
        $pattern = '\$ScriptVersion\s*=\s*"(\d+\.\d+\.\d+)"'
        $mine = [regex]::Match((Get-Content -LiteralPath $InstallerPath -Raw), $pattern).Groups[1].Value
        $help = [regex]::Match((Get-Content -LiteralPath $InstallerPath -Raw), 'Version:\s*(\d+\.\d+\.\d+)').Groups[1].Value
        $scan = [regex]::Match((Get-Content -LiteralPath (Join-Path $RepoRoot 'Find-OrphanedAppxFolders.ps1') -Raw), $pattern).Groups[1].Value
        $mine | Should -Be $scan
        $help | Should -Be $scan
    }

    It 'installs every file that ships in the release zip' {
        $installed = @(Get-ListFromScript -Path $InstallerPath -Name 'RequiredFiles') + @(Get-ListFromScript -Path $InstallerPath -Name 'OptionalFiles')
        $released  = @(Get-ListFromScript -Path (Join-Path $RepoRoot 'build.ps1') -Name 'ReleaseFiles')
        $released.Count | Should -BeGreaterThan 10
        foreach ($name in $released) { $installed | Should -Contain $name }
    }
}

Describe 'Installing and uninstalling (no shortcuts)' {

    BeforeEach {
        $env:LOCALAPPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Target    = Join-Path $env:LOCALAPPDATA 'Programs-WinPkgScan'
        $script:DataDir   = Join-Path $env:LOCALAPPDATA 'WinPkgScan'
        New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocalAppData
    }

    It 'copies the files and marks the folder as an install' {
        $r = Invoke-Installer @{ InstallPath = $Target }
        $r.ExitCode | Should -Be 0
        foreach ($name in 'Find-OrphanedAppxFolders.ps1', 'WinPkgScan-App.ps1', 'Install.ps1', 'WinPkgScan.ico', 'WinPkgScan.install') {
            Join-Path $Target $name | Should -Exist
        }
        $r.Output | Should -Match 'is installed'
    }

    It 'changes nothing with -WhatIf' {
        $r = Invoke-Installer @{ InstallPath = $Target; WhatIf = $true }
        $r.ExitCode | Should -Be 0
        $Target | Should -Not -Exist
        $r.Output | Should -Match 'Preview only'
    }

    It 'keeps your exclude list when updating' {
        Invoke-Installer @{ InstallPath = $Target } | Out-Null
        $list = Join-Path $Target 'WinPkgScan.exclude.txt'
        Set-Content -LiteralPath $list -Value 'Mine.*'
        $r = Invoke-Installer @{ InstallPath = $Target }
        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $list) | Should -Be 'Mine.*'
        $r.Output | Should -Match 'Kept your exclude list'
    }

    It 'refuses a folder that already has other files in it' {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Target 'other.txt') -Value 'x'
        $r = Invoke-Installer @{ InstallPath = $Target }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'already has other files'
        Join-Path $Target 'WinPkgScan-App.ps1' | Should -Not -Exist
    }

    It 'uninstalls the files and the folder, and keeps your history and settings' {
        Invoke-Installer @{ InstallPath = $Target } | Out-Null
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $DataDir 'history.json') -Value '{}'
        $r = Invoke-Installer @{ InstallPath = $Target; Uninstall = $true }
        $r.ExitCode | Should -Be 0
        $Target | Should -Not -Exist
        Join-Path $DataDir 'history.json' | Should -Exist
        $r.Output | Should -Match 'Kept your history and settings'
    }

    It 'leaves your own files in the folder when uninstalling' {
        Invoke-Installer @{ InstallPath = $Target } | Out-Null
        Set-Content -LiteralPath (Join-Path $Target 'notes.txt') -Value 'mine'
        $r = Invoke-Installer @{ InstallPath = $Target; Uninstall = $true }
        $r.ExitCode | Should -Be 0
        Join-Path $Target 'notes.txt' | Should -Exist
        Join-Path $Target 'Find-OrphanedAppxFolders.ps1' | Should -Not -Exist
        Join-Path $Target 'WinPkgScan.install' | Should -Not -Exist
    }

    It 'removes your history and settings with -RemoveData' {
        Invoke-Installer @{ InstallPath = $Target } | Out-Null
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $DataDir 'settings.json') -Value '{}'
        (Invoke-Installer @{ InstallPath = $Target; Uninstall = $true; RemoveData = $true }).ExitCode | Should -Be 0
        $DataDir | Should -Not -Exist
    }

    It 'refuses to uninstall from a folder it did not install' {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Target 'Find-OrphanedAppxFolders.ps1') -Value '# not ours'
        $r = Invoke-Installer @{ InstallPath = $Target; Uninstall = $true }
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'not a WinPkgScan install folder'
        Join-Path $Target 'Find-OrphanedAppxFolders.ps1' | Should -Exist
    }

    It 'removes nothing with -Uninstall -WhatIf' {
        Invoke-Installer @{ InstallPath = $Target } | Out-Null
        (Invoke-Installer @{ InstallPath = $Target; Uninstall = $true; WhatIf = $true }).ExitCode | Should -Be 0
        Join-Path $Target 'WinPkgScan-App.ps1' | Should -Exist
    }
}

Describe 'Installing on Windows: shortcuts and the Settings entry' -Tag 'Integration' -Skip:(-not $OnWindows) {

    BeforeAll {
        $env:LOCALAPPDATA   = Join-Path $TestDrive 'winlocal'
        $script:Target      = Join-Path $env:LOCALAPPDATA 'Programs\WinPkgScan'
        $script:StartMenu   = Join-Path $TestDrive 'StartMenu'
        $script:Desktop     = Join-Path $TestDrive 'Desktop'
        $script:Key         = "HKCU:\Software\WinPkgScanTests\$([guid]::NewGuid().ToString('N'))"
        $script:Common      = @{
            InstallPath = $Target; StartMenuPath = $StartMenu; DesktopPath = $Desktop
            UninstallKey = $Key; NoShortcuts = $false; NoUninstallEntry = $false
        }
        $script:Result = Invoke-Installer $Common.Clone()
        $script:Shell  = New-Object -ComObject WScript.Shell
    }

    AfterAll {
        Remove-Item -LiteralPath 'HKCU:\Software\WinPkgScanTests' -Recurse -Force -ErrorAction SilentlyContinue
        $env:LOCALAPPDATA = $script:SavedLocalAppData
    }

    It 'installs' {
        $Result.ExitCode | Should -Be 0 -Because $Result.Output
    }

    It 'adds Start menu and desktop shortcuts that start the app' {
        foreach ($link in (Join-Path $StartMenu 'WinPkgScan.lnk'), (Join-Path $Desktop 'WinPkgScan.lnk')) {
            $link | Should -Exist
            $s = $Shell.CreateShortcut($link)
            $s.TargetPath | Should -BeLike '*powershell.exe'
            $s.Arguments  | Should -Match '-STA'
            $s.Arguments  | Should -Match ([regex]::Escape((Join-Path $Target 'WinPkgScan-App.ps1')))
            $s.IconLocation | Should -BeLike '*WinPkgScan.ico*'
        }
    }

    It 'adds an entry to Settings > Apps' {
        $entry = Get-ItemProperty -LiteralPath $Key
        $entry.DisplayName    | Should -Be 'WinPkgScan'
        $entry.DisplayVersion | Should -Match '^\d+\.\d+\.\d+$'
        $entry.UninstallString | Should -Match 'Install\.ps1" -Uninstall$'
        $entry.InstallLocation | Should -Be $Target
    }

    It 'adds only the Start menu shortcut with -NoDesktopShortcut' {
        Remove-Item -LiteralPath (Join-Path $Desktop 'WinPkgScan.lnk') -Force
        $p = $Common.Clone(); $p['NoDesktopShortcut'] = $true
        (Invoke-Installer $p).ExitCode | Should -Be 0
        Join-Path $Desktop 'WinPkgScan.lnk' | Should -Not -Exist
        Join-Path $StartMenu 'WinPkgScan.lnk' | Should -Exist
    }

    It 'removes the files, shortcuts and entry when uninstalling' {
        $p = $Common.Clone(); $p['Uninstall'] = $true
        $r = Invoke-Installer $p
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Join-Path $StartMenu 'WinPkgScan.lnk' | Should -Not -Exist
        Test-Path -LiteralPath $Key | Should -BeFalse
        $Target | Should -Not -Exist
    }
}
