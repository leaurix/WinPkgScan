<#
.SYNOPSIS
    Runs lint and tests for WinPkgScan. Used locally and by CI.

.PARAMETER Task
    All (default), Lint or Test.

.EXAMPLE
    ./build.ps1

.EXAMPLE
    ./build.ps1 -Task Test

.NOTES
    Requires: PSScriptAnalyzer (Lint) and Pester 5.5+ (Test).
    Install-Module PSScriptAnalyzer, Pester -Scope CurrentUser -Force -SkipPublisherCheck
#>

[CmdletBinding()]
param(
    [ValidateSet('All', 'Lint', 'Test')]
    [string]$Task = 'All'
)

$ErrorActionPreference = 'Stop'
$Root   = $PSScriptRoot
$Failed = $false

function Invoke-Lint {
    Write-Host ""
    Write-Host "== Lint (PSScriptAnalyzer)" -ForegroundColor Cyan
    Import-Module PSScriptAnalyzer -ErrorAction Stop

    $files = @(
        Join-Path $Root 'Find-OrphanedAppxFolders.ps1'
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

    $outDir = Join-Path $Root 'out'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $config = New-PesterConfiguration
    $config.Run.Path               = Join-Path $Root 'tests'
    $config.Run.PassThru           = $true
    $config.Output.Verbosity       = 'Detailed'
    $config.TestResult.Enabled     = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath  = Join-Path $outDir 'testResults.xml'

    $result = Invoke-Pester -Configuration $config
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
        Write-Host "Tests failed." -ForegroundColor Red
        return $false
    }
    Write-Host "Tests passed." -ForegroundColor Green
    return $true
}

if ($Task -in 'All', 'Lint') {
    if (-not (Invoke-Lint)) { $Failed = $true }
}
if ($Task -in 'All', 'Test') {
    if (-not (Invoke-Test)) { $Failed = $true }
}

if ($Failed) { exit 1 }
exit 0
