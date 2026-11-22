#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Pester tests for web-install.ps1 (irm ... | iex)

    The GitHub download is mocked with a release zip built from the repo, so
    these run anywhere. The real Install.ps1 installs into a test folder.

    Run:  Invoke-Pester ./tests
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:SavedLocalAppData = $env:LOCALAPPDATA

    # Load the function without running it.
    $env:WINPKGSCAN_WEB_INSTALL_TEST = '1'
    . (Join-Path $RepoRoot 'web-install.ps1')

    # A release zip and checksum, like the ones the Release workflow makes.
    $script:ReleaseDir = Join-Path $TestDrive 'release'
    New-Item -ItemType Directory -Path $ReleaseDir -Force | Out-Null
    $script:Zip = Join-Path $ReleaseDir 'WinPkgScan-v9.9.9.zip'
    $files = foreach ($name in 'Find-OrphanedAppxFolders.ps1', 'Remove-OrphanedAppxFolders.ps1', 'Restore-OrphanedAppxFolders.ps1',
                               'WinPkgScan-App.ps1', 'Install.ps1', 'Register-WinPkgScanSchedule.ps1') {
        Join-Path $RepoRoot $name
    }
    Compress-Archive -Path $files -DestinationPath $Zip
    $script:GoodHash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()

    function Set-ReleaseMock {
        param([string]$Hash)
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                tag_name = 'v9.9.9'
                assets   = @(
                    [pscustomobject]@{ name = 'WinPkgScan-v9.9.9.zip'; browser_download_url = 'https://example.invalid/WinPkgScan-v9.9.9.zip' }
                    [pscustomobject]@{ name = 'WinPkgScan-v9.9.9.zip.sha256'; browser_download_url = 'https://example.invalid/WinPkgScan-v9.9.9.zip.sha256' }
                )
            }
        }
        $script:MockHash = $Hash
        Mock Invoke-WebRequest {
            if ($Uri -like '*.sha256') { Set-Content -LiteralPath $OutFile -Value "$script:MockHash  WinPkgScan-v9.9.9.zip" }
            else { Copy-Item -LiteralPath $script:Zip -Destination $OutFile }
        }
    }
}

AfterAll {
    Remove-Item Env:\WINPKGSCAN_WEB_INSTALL_TEST -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $script:SavedLocalAppData
}

Describe 'Web installer' {

    BeforeEach {
        $env:LOCALAPPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
        $script:Target = Join-Path $env:LOCALAPPDATA 'Programs-WinPkgScan'
        $script:Work   = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:InstallArgs = @{ InstallPath = $Target; NoShortcuts = $true; NoUninstallEntry = $true }
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocalAppData
    }

    It 'parses without syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'web-install.ps1'), [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'never uses exit, which would close the window it runs in' {
        (Get-Content -LiteralPath (Join-Path $RepoRoot 'web-install.ps1') -Raw) | Should -Not -Match '(?m)^\s*exit\b'
    }

    It 'downloads the latest release, checks it and installs it' {
        Set-ReleaseMock -Hash $GoodHash
        Install-WinPkgScanFromWeb -InstallArguments $InstallArgs -WorkFolder $Work 6>&1 | Out-Null
        Join-Path $Target 'WinPkgScan-App.ps1' | Should -Exist
        Join-Path $Target 'WinPkgScan.install' | Should -Exist
        $Work | Should -Not -Exist
    }

    It 'installs nothing when the checksum does not match' {
        Set-ReleaseMock -Hash ('0' * 64)
        { Install-WinPkgScanFromWeb -InstallArguments $InstallArgs -WorkFolder $Work 6>&1 | Out-Null } | Should -Throw '*checksum*'
        $Target | Should -Not -Exist
        $Work | Should -Not -Exist
    }

    It 'installs nothing when the release has no checksum' {
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v9.9.9'; assets = @([pscustomobject]@{ name = 'WinPkgScan-v9.9.9.zip' }) } }
        { Install-WinPkgScanFromWeb -InstallArguments $InstallArgs -WorkFolder $Work 6>&1 | Out-Null } | Should -Throw '*checksum*'
        $Target | Should -Not -Exist
    }
}
