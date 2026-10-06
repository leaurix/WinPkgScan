<#
.SYNOPSIS
    Runs lint, tests and release packaging for WinPkgScan. Used locally and by CI.

.PARAMETER Task
    All (default: Lint + Test), Lint, Test or Package.

.PARAMETER Tag
    Package only. The release tag (e.g. v1.3.0). The build fails if it does
    not match the version in Find-OrphanedAppxFolders.ps1.

.EXAMPLE
    ./build.ps1

.EXAMPLE
    ./build.ps1 -Task Test

.EXAMPLE
    ./build.ps1 -Task Package -Tag v1.3.0

.NOTES
    Requires: PSScriptAnalyzer (Lint) and Pester 5.5+ (Test).
    Install-Module PSScriptAnalyzer, Pester -Scope CurrentUser -Force -SkipPublisherCheck
#>

[CmdletBinding()]
param(
    [ValidateSet('All', 'Lint', 'Test', 'Package')]
    [string]$Task = 'All',

    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$Root   = $PSScriptRoot
$OutDir = Join-Path $Root 'out'
$Failed = $false

# Files shipped to users in the release zip.
$ReleaseFiles = @(
    'Find-OrphanedAppxFolders.ps1'
    'Remove-OrphanedAppxFolders.ps1'
    'Run-Scan.bat'
    'Run-Scan-Unattended.bat'
    'Run-Delete.bat'
    'README.md'
    'LICENSE'
)

# Windows scripts must have CRLF line endings or cmd.exe can misread them.
$CrlfFiles = @(
    'Find-OrphanedAppxFolders.ps1'
    'Remove-OrphanedAppxFolders.ps1'
    'Run-Scan.bat'
    'Run-Scan-Unattended.bat'
    'Run-Delete.bat'
)

function Invoke-Lint {
    Write-Host ""
    Write-Host "== Lint (PSScriptAnalyzer)" -ForegroundColor Cyan
    Import-Module PSScriptAnalyzer -ErrorAction Stop

    $files = @(
        Join-Path $Root 'Find-OrphanedAppxFolders.ps1'
        Join-Path $Root 'Remove-OrphanedAppxFolders.ps1'
        Join-Path $Root 'build.ps1'
    )
    $settings = Join-Path $Root 'PSScriptAnalyzerSettings.psd1'
    $findings = @(foreach ($file in $files) {
        Invoke-ScriptAnalyzer -Path $file -Settings $settings
    })

    if ($findings.Count -gt 0) {
        $findings |
            Format-Table @{ Name = 'File'; Expression = { Split-Path $_.ScriptPath -Leaf } }, Line, Severity, RuleName, Message -AutoSize -Wrap |
            Out-String -Width 250 |
            Write-Host
        Write-Host "Lint failed: $($findings.Count) finding(s)." -ForegroundColor Red
        return $false
    }
    Write-Host "Lint passed: no findings." -ForegroundColor Green
    return $true
}

function Invoke-Test {
    Write-Host ""
    Write-Host "== Tests (Pester)" -ForegroundColor Cyan
    Import-Module Pester -MinimumVersion 5.5.0 -ErrorAction Stop

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

    $config = New-PesterConfiguration
    $config.Run.Path                = Join-Path $Root 'tests'
    $config.Run.PassThru            = $true
    $config.Output.Verbosity        = 'Detailed'
    $config.TestResult.Enabled      = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath   = Join-Path $OutDir 'testResults.xml'

    $result = Invoke-Pester -Configuration $config
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
        Write-Host "Tests failed." -ForegroundColor Red
        return $false
    }
    Write-Host "Tests passed." -ForegroundColor Green
    return $true
}

function Get-ScriptVersion {
    $text  = Get-Content -LiteralPath (Join-Path $Root 'Find-OrphanedAppxFolders.ps1') -Raw
    $match = [regex]::Match($text, '\$ScriptVersion\s*=\s*"(\d+\.\d+\.\d+)"')
    if (-not $match.Success) {
        throw 'Could not find $ScriptVersion in Find-OrphanedAppxFolders.ps1.'
    }
    return $match.Groups[1].Value
}

function Get-ReleaseNote {
    param([string]$Version)

    $lines   = @(Get-Content -LiteralPath (Join-Path $Root 'CHANGELOG.md'))
    $heading = '## [' + $Version + ']'
    $start   = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith($heading)) { $start = $i + 1; break }
    }
    if ($start -lt 0) {
        throw "CHANGELOG.md has no section for $Version. Add '## [$Version] - <date>' before releasing."
    }

    $end = $lines.Count
    for ($i = $start; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith('## [')) { $end = $i; break }
    }
    if ($end -le $start) {
        throw "The CHANGELOG.md section for $Version is empty."
    }

    $body = ($lines[$start..($end - 1)] -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw "The CHANGELOG.md section for $Version is empty."
    }
    return $body
}

function Test-CrlfLineEnding {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i - 1] -ne 13)) {
            return $false
        }
    }
    return $true
}

function Invoke-Package {
    param([string]$ReleaseTag)

    Write-Host ""
    Write-Host "== Package (release zip)" -ForegroundColor Cyan

    $version = Get-ScriptVersion
    Write-Host "Script version: $version"

    if (-not [string]::IsNullOrWhiteSpace($ReleaseTag) -and $ReleaseTag -ne "v$version") {
        Write-Host "Tag '$ReleaseTag' does not match the script version 'v$version'." -ForegroundColor Red
        Write-Host "Update `$ScriptVersion and the 'Version:' help line, or use the right tag." -ForegroundColor Red
        return $false
    }

    $notes = Get-ReleaseNote -Version $version

    foreach ($name in $ReleaseFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $name))) {
            Write-Host "Missing release file: $name" -ForegroundColor Red
            return $false
        }
    }
    foreach ($name in $CrlfFiles) {
        if (-not (Test-CrlfLineEnding -Path (Join-Path $Root $name))) {
            Write-Host "$name does not have CRLF line endings. Check .gitattributes." -ForegroundColor Red
            return $false
        }
    }

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $zipName  = "WinPkgScan-v$version.zip"
    $zipPath  = Join-Path $OutDir $zipName
    $hashPath = "$zipPath.sha256"
    $notePath = Join-Path $OutDir 'release-notes.md'
    Remove-Item -LiteralPath $zipPath, $hashPath, $notePath -ErrorAction SilentlyContinue

    $sources = $ReleaseFiles | ForEach-Object { Join-Path $Root $_ }
    Compress-Archive -Path $sources -DestinationPath $zipPath -CompressionLevel Optimal

    # Confirm the zip holds exactly the release files, at its root.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entries = @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object)
    }
    finally {
        $zip.Dispose()
    }
    $expected = @($ReleaseFiles | Sort-Object)
    if (($entries -join '|') -ne ($expected -join '|')) {
        Write-Host "Zip contents are wrong: $($entries -join ', ')" -ForegroundColor Red
        return $false
    }

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText($hashPath, "$hash  $zipName`n")

    $releaseNotes = @(
        $notes
        ''
        '### Download'
        "Download ``$zipName``, extract it, and double-click ``Run-Scan.bat``. See the README for options."
        ''
        "SHA256: ``$hash``"
    ) -join "`n"
    [System.IO.File]::WriteAllText($notePath, $releaseNotes + "`n")

    # Let GitHub Actions read the results.
    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "version=$version"
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "zip=out/$zipName"
    }

    Write-Host "Created: out/$zipName"
    Write-Host "Created: out/$zipName.sha256"
    Write-Host "Created: out/release-notes.md"
    Write-Host "Package passed." -ForegroundColor Green
    return $true
}

if ($Task -in 'All', 'Lint') {
    if (-not (Invoke-Lint)) { $Failed = $true }
}
if ($Task -in 'All', 'Test') {
    if (-not (Invoke-Test)) { $Failed = $true }
}
if ($Task -eq 'Package') {
    try {
        if (-not (Invoke-Package -ReleaseTag $Tag)) { $Failed = $true }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        $Failed = $true
    }
}

if ($Failed) { exit 1 }
exit 0
