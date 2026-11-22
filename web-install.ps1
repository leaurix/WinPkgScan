# WinPkgScan web installer
#
# Downloads the latest WinPkgScan release from GitHub, checks its SHA256
# checksum, and runs Install.ps1 from it. The app is installed for you with
# Start menu and desktop shortcuts. No administrator rights are needed.
#
# In PowerShell:
#   irm https://raw.githubusercontent.com/leaurix/WinPkgScan/main/web-install.ps1 | iex
#
# Run it again to update. Nothing is installed if the checksum does not match.

function Install-WinPkgScanFromWeb {
    [CmdletBinding()]
    param(
        [string]$Repository = 'leaurix/WinPkgScan',

        # Options for Install.ps1, e.g. @{ NoDesktopShortcut = $true }.
        [hashtable]$InstallArguments = @{ Launch = $true },

        [string]$WorkFolder = (Join-Path ([System.IO.Path]::GetTempPath()) ('WinPkgScan-' + [guid]::NewGuid().ToString('N')))
    )

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Verbose "TLS setting not changed: $($_.Exception.Message)"
    }
    $headers = @{ 'User-Agent' = 'WinPkgScan-web-install' }

    Write-Host 'Finding the latest WinPkgScan release...'
    $release   = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers
    $zipAsset  = @($release.assets | Where-Object { $_.name -match '^WinPkgScan-v[\d.]+\.zip$' }) | Select-Object -First 1
    $hashAsset = if ($zipAsset) { @($release.assets | Where-Object { $_.name -eq "$($zipAsset.name).sha256" }) | Select-Object -First 1 }
    if (-not $zipAsset -or -not $hashAsset) {
        throw "Release $($release.tag_name) has no WinPkgScan zip with a checksum. Nothing was installed."
    }

    New-Item -ItemType Directory -Path $WorkFolder -Force | Out-Null
    try {
        $zip      = Join-Path $WorkFolder $zipAsset.name
        $hashFile = Join-Path $WorkFolder $hashAsset.name
        Write-Host "Downloading $($zipAsset.name)..."
        Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zip -Headers $headers -UseBasicParsing
        Invoke-WebRequest -Uri $hashAsset.browser_download_url -OutFile $hashFile -Headers $headers -UseBasicParsing

        $expected = (("$(Get-Content -LiteralPath $hashFile -Raw)").Trim() -split '\s+')[0].ToLowerInvariant()
        $actual   = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -ne $actual) {
            throw 'The download does not match its SHA256 checksum, so it may be damaged or changed. Nothing was installed.'
        }
        Write-Host 'Checksum OK.'

        $files = Join-Path $WorkFolder 'files'
        Expand-Archive -LiteralPath $zip -DestinationPath $files -Force
        $installer = Join-Path $files 'Install.ps1'
        if (-not (Test-Path -LiteralPath $installer)) { throw 'Install.ps1 is missing from the release. Nothing was installed.' }
        if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
            Get-ChildItem -LiteralPath $files -File | Unblock-File
        }

        # Run the installer in its own PowerShell, so it works whatever the
        # execution policy of this window is.
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-NoPause')
        foreach ($name in $InstallArguments.Keys) {
            $value = $InstallArguments[$name]
            if ($value -is [bool] -or $value -is [System.Management.Automation.SwitchParameter]) {
                if ($value) { $arguments += "-$name" }
            }
            else {
                $arguments += "-$name"
                $arguments += "$value"
            }
        }
        $exe = (Get-Process -Id $PID).Path
        & $exe @arguments
        if ($LASTEXITCODE -ne 0) { throw "Install.ps1 did not finish (exit code $LASTEXITCODE)." }
    }
    finally {
        Remove-Item -LiteralPath $WorkFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The tests load the function without running it.
if (-not $env:WINPKGSCAN_WEB_INSTALL_TEST) {
    try {
        Install-WinPkgScanFromWeb
    }
    catch {
        Write-Host "WinPkgScan was not installed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
