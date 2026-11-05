#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Pester tests for the PowerShell Gallery module (module/WinPkgScan.psd1
    and module/WinPkgScan.psm1).

    The module is assembled in TestDrive the same way build.ps1 does it:
    the two module files, plus the FileList in the manifest copied from the
    repo root. Runs anywhere.

    Run:  Invoke-Pester ./tests
#>

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent $PSScriptRoot
    $script:ModuleSource = Join-Path $RepoRoot 'module'
    $script:Manifest     = Import-PowerShellDataFile -LiteralPath (Join-Path $ModuleSource 'WinPkgScan.psd1')

    $script:ModuleDir = Join-Path $TestDrive 'WinPkgScan'
    New-Item -ItemType Directory -Path $ModuleDir -Force | Out-Null
    foreach ($name in $Manifest.FileList) {
        $from = Join-Path $ModuleSource $name
        if (-not (Test-Path -LiteralPath $from)) { $from = Join-Path $RepoRoot $name }
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $ModuleDir $name) }
    }
    $script:ManifestPath = Join-Path $ModuleDir 'WinPkgScan.psd1'
}

AfterAll {
    Remove-Module WinPkgScan -Force -ErrorAction SilentlyContinue
}

Describe 'PowerShell Gallery module' {

    It 'has the same version as the scripts' {
        $scan = [regex]::Match((Get-Content -LiteralPath (Join-Path $RepoRoot 'Find-OrphanedAppxFolders.ps1') -Raw),
            '\$ScriptVersion\s*=\s*"(\d+\.\d+\.\d+)"').Groups[1].Value
        $Manifest.ModuleVersion | Should -Be $scan
    }

    It 'only lists files that exist in the repo' {
        foreach ($name in $Manifest.FileList) { Join-Path $ModuleDir $name | Should -Exist }
    }

    It 'has a valid manifest' {
        $m = Test-ModuleManifest -Path $ManifestPath -ErrorAction Stop
        "$($m.Version)" | Should -Be $Manifest.ModuleVersion
        $Manifest.PrivateData.PSData.ProjectUri | Should -Match '^https://github\.com/'
        $Manifest.Description.Length | Should -BeGreaterThan 40
    }

    Context 'imported' {

        BeforeAll {
            $script:Mod = Import-Module $ManifestPath -Force -PassThru
        }

        AfterAll {
            Remove-Module WinPkgScan -Force -ErrorAction SilentlyContinue
        }

        It 'exports exactly the commands the manifest lists' {
            foreach ($name in 'Find-OrphanedAppxFolders', 'Remove-OrphanedAppxFolders', 'Restore-OrphanedAppxFolders',
                              'Install-WinPkgScan', 'Start-WinPkgScanApp') {
                $Mod.ExportedFunctions.Keys | Should -Contain $name
            }
            (@($Mod.ExportedFunctions.Keys | Sort-Object) -join ',') | Should -Be (@($Manifest.FunctionsToExport | Sort-Object) -join ',')
            $Mod.ExportedAliases.Count | Should -Be 0
        }

        It 'has the help and options of each script' {
            (Get-Help Find-OrphanedAppxFolders).Synopsis | Should -Match 'leftover folders'
            (Get-Help Remove-OrphanedAppxFolders -Parameter MinAgeDays).Name | Should -Be 'MinAgeDays'
            (Get-Help Install-WinPkgScan).Synopsis | Should -Match 'Installs WinPkgScan'
            (Get-Command Remove-OrphanedAppxFolders).Parameters.Keys | Should -Contain 'WhatIf'
            (Get-Command Restore-OrphanedAppxFolders).Parameters.Keys | Should -Contain 'LogPath'
            (Get-Command Find-OrphanedAppxFolders).Parameters.Keys | Should -Contain 'ProgressLines'
        }

        It 'runs the script from the module folder, and its exit code does not end the session' {
            $env:SavedLocal = $env:LOCALAPPDATA
            try {
                $env:LOCALAPPDATA = Join-Path $TestDrive 'local'
                $target = Join-Path $TestDrive 'installed'
                Install-WinPkgScan -InstallPath $target -NoShortcuts -NoUninstallEntry -NoPause 6>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0
                Join-Path $target 'WinPkgScan-App.ps1' | Should -Exist
                Install-WinPkgScan -InstallPath (Join-Path $TestDrive 'not-installed') -Uninstall -NoShortcuts -NoUninstallEntry -NoPause 6>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0
                $foreign = Join-Path $TestDrive 'foreign'
                New-Item -ItemType Directory -Path $foreign -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $foreign 'a.txt') -Value 'x'
                Install-WinPkgScan -InstallPath $foreign -Uninstall -NoShortcuts -NoUninstallEntry -NoPause 6>&1 | Out-Null
                $LASTEXITCODE | Should -Be 1
                Join-Path $foreign 'a.txt' | Should -Exist
            }
            finally {
                $env:LOCALAPPDATA = $env:SavedLocal
                Remove-Item Env:\SavedLocal -ErrorAction SilentlyContinue
            }
        }

        It 'starts the app in its own process, only when not -WhatIf' {
            Mock Start-Process { } -ModuleName WinPkgScan
            Start-WinPkgScanApp -WhatIf
            Should -Invoke Start-Process -ModuleName WinPkgScan -Times 0 -Exactly
            Start-WinPkgScanApp
            Should -Invoke Start-Process -ModuleName WinPkgScan -Times 1 -Exactly -ParameterFilter {
                "$ArgumentList" -match '-STA' -and "$ArgumentList" -match 'WinPkgScan-App\.ps1'
            }
        }
    }
}
