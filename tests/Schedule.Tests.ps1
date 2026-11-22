#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Pester tests for Register-WinPkgScanSchedule.ps1 (the scheduled scan)

    - Unit tests: run anywhere. The Task Scheduler commands are mocked.
    - Integration test (tag "Integration"): Windows only. Adds a real task
      under a test name, reads it back and removes it.

    Run:  Invoke-Pester ./tests
#>

BeforeDiscovery {
    $script:OnWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
}

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent $PSScriptRoot
    $script:SchedulePath = Join-Path $RepoRoot 'Register-WinPkgScanSchedule.ps1'
    $script:SavedLocalAppData = $env:LOCALAPPDATA

    # The ScheduledTasks commands only exist on Windows. Pester can only mock
    # a command that exists, so add stubs where they are missing.
    $script:Stubs = @()
    $stubDefinitions = @{
        'Get-ScheduledTask'            = { [CmdletBinding()] param([string]$TaskName) }
        'Get-ScheduledTaskInfo'        = { [CmdletBinding()] param([string]$TaskName) }
        'Register-ScheduledTask'       = { [CmdletBinding()] param([string]$TaskName, $Action, $Trigger, $Settings, $Principal, [string]$Description, [switch]$Force) }
        'Unregister-ScheduledTask'     = { [CmdletBinding(SupportsShouldProcess = $true)] param([string]$TaskName) }
        'New-ScheduledTaskAction'      = { [CmdletBinding()] param([string]$Execute, [string]$Argument, [string]$WorkingDirectory) }
        'New-ScheduledTaskTrigger'     = { [CmdletBinding()] param([switch]$Daily, [switch]$Weekly, [string[]]$DaysOfWeek, [datetime]$At) }
        'New-ScheduledTaskSettingsSet' = { [CmdletBinding()] param([switch]$StartWhenAvailable, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [timespan]$ExecutionTimeLimit, [string]$MultipleInstances) }
        'New-ScheduledTaskPrincipal'   = { [CmdletBinding()] param([string]$UserId, [string]$LogonType, [string]$RunLevel) }
    }
    foreach ($name in $stubDefinitions.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "Function:\global:$name" -Value $stubDefinitions[$name]
            $script:Stubs += $name
        }
    }

    function Invoke-Schedule {
        param([hashtable]$Params = @{})
        $Params['NoPause'] = $true
        if (-not $Params.ContainsKey('TaskName')) { $Params['TaskName'] = 'WinPkgScan unit test' }
        $output = @(& $script:SchedulePath @Params 6>&1)
        $code = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $code
            Text     = (@($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] -or $_ -is [string] } |
                          ForEach-Object { "$_" }) -join "`n")
            State    = @($output | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Frequency'] }) | Select-Object -First 1
        }
    }
}

AfterAll {
    foreach ($name in $script:Stubs) { Remove-Item -Path "Function:\global:$name" -ErrorAction SilentlyContinue }
    $env:LOCALAPPDATA = $script:SavedLocalAppData
}

Describe 'Schedule script file' {

    It 'parses without syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($SchedulePath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has comment-based help' {
        (Get-Help $SchedulePath).Synopsis | Should -Match 'scheduled'
    }

    It 'has the same version as the scanner' {
        $pattern = '\$ScriptVersion\s*=\s*"(\d+\.\d+\.\d+)"'
        $mine = [regex]::Match((Get-Content -LiteralPath $SchedulePath -Raw), $pattern).Groups[1].Value
        $scan = [regex]::Match((Get-Content -LiteralPath (Join-Path $RepoRoot 'Find-OrphanedAppxFolders.ps1') -Raw), $pattern).Groups[1].Value
        $mine | Should -Be $scan
    }
}

Describe 'Scheduling (mocked Task Scheduler)' {

    BeforeEach {
        $env:LOCALAPPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Register-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock Get-ScheduledTask { }
        Mock Get-ScheduledTaskInfo { }
        Mock New-ScheduledTaskAction { [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
        Mock New-ScheduledTaskTrigger { [pscustomobject]@{ Daily = [bool]$Daily; Days = $DaysOfWeek; At = $At } }
        Mock New-ScheduledTaskSettingsSet { [pscustomobject]@{} }
        Mock New-ScheduledTaskPrincipal { [pscustomobject]@{ UserId = $UserId } }
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocalAppData
    }

    It 'adds a weekly scan that runs the scanner with notifications into the app folder' {
        $r = Invoke-Schedule @{ Frequency = 'Weekly'; Day = 'Friday'; Time = '7:30' }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        Should -Invoke New-ScheduledTaskAction -Times 1 -Exactly -ParameterFilter {
            $Argument -match 'Find-OrphanedAppxFolders\.ps1' -and $Argument -match '-Notify' -and $Argument -match '-NoPause' -and
            $Argument -match ([regex]::Escape((Join-Path (Join-Path $env:LOCALAPPDATA 'WinPkgScan') 'app')))
        }
        Should -Invoke New-ScheduledTaskTrigger -Times 1 -Exactly -ParameterFilter { $Weekly -and $DaysOfWeek -contains 'Friday' -and $At.ToString('HH:mm') -eq '07:30' }
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $Description -match 'Weekly Friday 07:30' }
        $r.Text | Should -Match 'Weekly on Friday at 07:30'
        Join-Path (Join-Path $env:LOCALAPPDATA 'WinPkgScan') 'app' | Should -Exist
    }

    It 'adds a daily scan' {
        (Invoke-Schedule @{ Frequency = 'Daily'; Time = '19:00' }).ExitCode | Should -Be 0
        Should -Invoke New-ScheduledTaskTrigger -Times 1 -Exactly -ParameterFilter { $Daily }
    }

    It 'refuses a time that is not HH:mm' {
        $r = Invoke-Schedule @{ Frequency = 'Daily'; Time = '7pm' }
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'not a time'
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }

    It 'changes nothing with -WhatIf' {
        (Invoke-Schedule @{ Frequency = 'Daily'; WhatIf = $true }).ExitCode | Should -Be 0
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }

    It 'removes the scheduled scan with -Frequency Off' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = $TaskName; Description = 'WinPkgScan schedule: Daily Sunday 19:00.' } }
        $r = Invoke-Schedule @{ Frequency = 'Off' }
        $r.ExitCode | Should -Be 0
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly
        $r.Text | Should -Match 'turned off'
    }

    It 'has nothing to remove when there is no scheduled scan' {
        $r = Invoke-Schedule @{ Frequency = 'Off' }
        $r.ExitCode | Should -Be 0
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
    }

    It 'shows the schedule, read back from the task' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = $TaskName; State = 'Ready'; Description = 'WinPkgScan schedule: Weekly Monday 08:15. Scans...' } }
        $r = Invoke-Schedule @{ Show = $true }
        $r.ExitCode | Should -Be 0
        $r.State.Frequency | Should -Be 'Weekly'
        $r.State.Day | Should -Be 'Monday'
        $r.State.Time | Should -Be '08:15'
        $r.State.Enabled | Should -BeTrue
        $r.Text | Should -Match 'Weekly on Monday at 08:15'
    }

    It 'shows Off when there is no scheduled scan' {
        $r = Invoke-Schedule @{}
        $r.State.Frequency | Should -Be 'Off'
        $r.Text | Should -Match 'Scheduled scan: Off'
    }
}

Describe 'Scheduling on Windows: a real task' -Tag 'Integration' -Skip:(-not $OnWindows) {

    BeforeAll {
        $env:LOCALAPPDATA = Join-Path $TestDrive 'local'
        $script:TaskName = "WinPkgScan test $([guid]::NewGuid().ToString('N').Substring(0, 8))"
    }

    AfterAll {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        $env:LOCALAPPDATA = $script:SavedLocalAppData
    }

    It 'adds, shows and removes a weekly scan' {
        $r = Invoke-Schedule @{ TaskName = $TaskName; Frequency = 'Weekly'; Day = 'Sunday'; Time = '19:00' }
        $r.ExitCode | Should -Be 0 -Because $r.Text
        $task = Get-ScheduledTask -TaskName $TaskName
        $task.Actions[0].Arguments | Should -Match '-Notify'
        (Invoke-Schedule @{ TaskName = $TaskName; Show = $true }).State.Frequency | Should -Be 'Weekly'
        (Invoke-Schedule @{ TaskName = $TaskName; Frequency = 'Off' }).ExitCode | Should -Be 0
        Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
