<#
.SYNOPSIS
    Turns the scheduled WinPkgScan scan on or off, or shows it.

.DESCRIPTION
    Adds a task to Windows Task Scheduler that scans for leftover app
    folders daily or weekly, for you only, while you are signed in. No
    administrator rights are needed.

    - The scan is read-only: it never removes anything.
    - When it finds orphaned folders that were not there at the last scan,
      it shows a Windows notification. Clicking it opens the HTML report.
    - The results go to %LOCALAPPDATA%\WinPkgScan\app, so the WinPkgScan
      app shows them the next time you open it.
    - If the computer is off at the scheduled time, the scan runs as soon
      as possible afterwards.

    The task runs the scanner in this script's folder. If you move or
    delete that folder, run this script again from the new place.

.PARAMETER Frequency
    Daily, Weekly, or Off to remove the scheduled scan.

.PARAMETER Day
    The day for weekly scans. Default: Sunday.

.PARAMETER Time
    The time of day, 24-hour HH:mm. Default: 19:00.

.PARAMETER Show
    Show the current schedule and change nothing. This is also what
    happens when -Frequency is not given. Returns an object with the
    details.

.PARAMETER TaskName
    The name of the task in Task Scheduler.

.PARAMETER NoPause
    Never pause at the end. The script only pauses when it opened its own
    window, not when run from an open PowerShell prompt.

.EXAMPLE
    .\Register-WinPkgScanSchedule.ps1 -Frequency Weekly -Day Sunday -Time 19:00

.EXAMPLE
    .\Register-WinPkgScanSchedule.ps1 -Frequency Off

.EXAMPLE
    .\Register-WinPkgScanSchedule.ps1 -Show

.NOTES
    Version: 1.9.0
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [ValidateSet('Daily', 'Weekly', 'Off')]
    [string]$Frequency,

    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
    [string]$Day = 'Sunday',

    [string]$Time = '19:00',

    [switch]$Show,

    [string]$TaskName = 'WinPkgScan scheduled scan',

    [switch]$NoPause
)

$ScriptVersion = "1.9.0"

# Pause at the end only when this script opened its own window.
$PauseAtEnd = $false
if (-not $NoPause.IsPresent) {
    try {
        $PauseAtEnd = (-not [Console]::IsInputRedirected) -and
            ([Environment]::CommandLine.IndexOf([System.IO.Path]::GetFileName($PSCommandPath), [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    catch {
        $PauseAtEnd = $false
    }
}

function Exit-Script {
    param([int]$Code = 0)
    if ($PauseAtEnd) {
        Write-Host ""
        Read-Host "Press Enter to exit" | Out-Null
    }
    exit $Code
}

function ConvertTo-ScheduleTime {
    # "7:05" or "19:00" -> a DateTime today at that time, or $null.
    param([string]$Text)
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact("$Text".Trim(), [string[]]@('H:mm', 'HH:mm'),
        [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
    if (-not $ok) { return $null }
    return (Get-Date).Date.Add($parsed.TimeOfDay)
}

function Get-ScheduleText {
    param([string]$Frequency, [string]$Day, [string]$Time)
    if ($Frequency -eq 'Weekly') { return "Weekly on $Day at $Time" }
    if ($Frequency -eq 'Daily') { return "Daily at $Time" }
    return 'Off'
}

function Get-ScheduleDescription {
    # Stored in the task, so -Show and the app can read the schedule back.
    param([string]$Frequency, [string]$Day, [string]$Time)
    return "WinPkgScan schedule: $Frequency $Day $Time. Scans for leftover app folders (read-only) and shows a notification when new ones are found."
}

function ConvertFrom-ScheduleDescription {
    param([string]$Description)
    $m = [regex]::Match("$Description", 'WinPkgScan schedule: (Daily|Weekly) (\w+) (\d{1,2}:\d{2})')
    if (-not $m.Success) { return $null }
    return [PSCustomObject]@{ Frequency = $m.Groups[1].Value; Day = $m.Groups[2].Value; Time = $m.Groups[3].Value }
}

function Get-ScheduledScanArgument {
    # powershell.exe arguments for the scheduled scan.
    param([string]$Scanner, [string]$ReportPath)
    return '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Scanner +
        '" -Csv -Html -NoPause -Notify -ReportPath "' + $ReportPath + '"'
}

function Get-CurrentUserName {
    try { return [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    catch { return "$env:USERDOMAIN\$env:USERNAME" }
}

function Get-ScheduleState {
    # The current schedule, from Task Scheduler.
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $task) {
        return [PSCustomObject]@{ Enabled = $false; Frequency = 'Off'; Day = ''; Time = ''; Text = 'Off'; NextRun = $null; LastRun = $null }
    }
    $parsed = ConvertFrom-ScheduleDescription -Description $task.Description
    $info = $null
    try { $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop } catch { $info = $null }
    $state = [PSCustomObject]@{
        Enabled   = ("$($task.State)" -ne 'Disabled')
        Frequency = if ($parsed) { $parsed.Frequency } else { 'Custom' }
        Day       = if ($parsed) { $parsed.Day } else { '' }
        Time      = if ($parsed) { $parsed.Time } else { '' }
        Text      = if ($parsed) { Get-ScheduleText -Frequency $parsed.Frequency -Day $parsed.Day -Time $parsed.Time } else { 'Custom (changed in Task Scheduler)' }
        NextRun   = if ($info) { $info.NextRunTime } else { $null }
        LastRun   = if ($info) { $info.LastRunTime } else { $null }
    }
    return $state
}

function Write-ScheduleState {
    param($State)
    Write-Host "Scheduled scan: $($State.Text)$(if ($State.Frequency -ne 'Off' -and -not $State.Enabled) { ' (disabled in Task Scheduler)' })"
    if ($State.NextRun) { Write-Host "Next scan:      $($State.NextRun)" }
    if ($State.LastRun -and $State.LastRun.Year -gt 2000) { Write-Host "Last scan:      $($State.LastRun)" }
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

Write-Host ""
Write-Host "WinPkgScan scheduled scan (v$ScriptVersion)" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Task Scheduler commands are not available. Scheduled scans need Windows." -ForegroundColor Red
    Exit-Script 1
}

try {
    if ($Show -or -not $Frequency) {
        $state = Get-ScheduleState
        Write-ScheduleState -State $state
        Write-Output $state
        Exit-Script 0
    }

    if ($Frequency -eq 'Off') {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            if ($PSCmdlet.ShouldProcess($TaskName, 'Remove the scheduled scan')) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
                Write-Host "The scheduled scan is turned off." -ForegroundColor Green
            }
        }
        else {
            Write-Host "There is no scheduled scan. Nothing to turn off."
        }
        Exit-Script 0
    }

    $at = ConvertTo-ScheduleTime -Text $Time
    if (-not $at) {
        Write-Host "ERROR: '$Time' is not a time. Use 24-hour HH:mm, for example 19:00." -ForegroundColor Red
        Exit-Script 1
    }
    $Time = $at.ToString('HH:mm')

    $scanner = Join-Path $PSScriptRoot 'Find-OrphanedAppxFolders.ps1'
    if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
        Write-Host "ERROR: Find-OrphanedAppxFolders.ps1 was not found next to this script." -ForegroundColor Red
        Exit-Script 1
    }
    $appDir = Join-Path (Join-Path $env:LOCALAPPDATA 'WinPkgScan') 'app'
    $report = Join-Path $appDir 'Orphaned-Appx-Packages.txt'
    $text   = Get-ScheduleText -Frequency $Frequency -Day $Day -Time $Time

    if (-not $PSCmdlet.ShouldProcess($TaskName, "Scan $text")) {
        Write-Host "Preview only: nothing was changed."
        Exit-Script 0
    }
    if (-not (Test-Path -LiteralPath $appDir)) { New-Item -ItemType Directory -Path $appDir -Force | Out-Null }

    $exe = 'powershell.exe'
    if ($env:SystemRoot) {
        $full = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $full) { $exe = $full }
    }
    $action = New-ScheduledTaskAction -Execute $exe -Argument (Get-ScheduledScanArgument -Scanner $scanner -ReportPath $report) `
        -WorkingDirectory $PSScriptRoot
    $trigger = if ($Frequency -eq 'Daily') {
        New-ScheduledTaskTrigger -Daily -At $at
    }
    else {
        New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $at
    }
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId (Get-CurrentUserName) -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description (Get-ScheduleDescription -Frequency $Frequency -Day $Day -Time $Time) -Force -ErrorAction Stop | Out-Null

    Write-Host "Scheduled scan: $text" -ForegroundColor Green
    Write-Host "Scanner:        $scanner"
    Write-Host "Results:        $appDir"
    Write-Host "You get a notification when new leftover app folders are found."
    Exit-Script 0
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Exit-Script 1
}
