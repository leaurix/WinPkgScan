# WinPkgScan module.
#
# Each command runs the WinPkgScan script of the same name that ships in
# this module folder, so it behaves exactly like the script in the release
# zip, with the same options and help:
#
#   Find-OrphanedAppxFolders      scan (read-only)
#   Remove-OrphanedAppxFolders    remove the folders marked in the CSV
#   Restore-OrphanedAppxFolders   put removed folders back from the Recycle Bin
#   Install-WinPkgScan            add Start menu and desktop shortcuts to the app
#   Start-WinPkgScanApp           open the app
#
# Get-Help <command> -Full shows every option.

$ModuleFolder = $PSScriptRoot

$ScriptCommands = [ordered]@{
    'Find-OrphanedAppxFolders'    = 'Find-OrphanedAppxFolders.ps1'
    'Remove-OrphanedAppxFolders'  = 'Remove-OrphanedAppxFolders.ps1'
    'Restore-OrphanedAppxFolders' = 'Restore-OrphanedAppxFolders.ps1'
    'Install-WinPkgScan'          = 'Install.ps1'
}

# Build a small function for each script, with the script's own help and
# parameters, that runs the script. Running it as a script (not as the
# function body) keeps "exit" inside the script, so it never closes your
# PowerShell window.
foreach ($commandName in $ScriptCommands.Keys) {
    $scriptPath = Join-Path $ModuleFolder $ScriptCommands[$commandName]
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw "WinPkgScan: $scriptPath could not be read: $($parseErrors[0].Message)" }
    $helpText  = @($tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text.StartsWith('<#') } | Select-Object -First 1)[0].Text
    $attribute = (@($ast.ParamBlock.Attributes) | ForEach-Object { $_.Extent.Text }) -join "`n"
    $definition = @(
        "function $commandName {"
        $helpText
        $attribute
        $ast.ParamBlock.Extent.Text
        "& '$($scriptPath.Replace("'", "''"))' @PSBoundParameters"
        '}'
    ) -join "`n"
    . ([scriptblock]::Create($definition))
}

function Start-WinPkgScanApp {
    <#
    .SYNOPSIS
        Opens the WinPkgScan app in its own window.

    .DESCRIPTION
        Starts WinPkgScan-App.ps1 in a new Windows PowerShell process, so this
        prompt stays free. Needs Windows.

    .EXAMPLE
        Start-WinPkgScanApp
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $app = Join-Path $ModuleFolder 'WinPkgScan-App.ps1'
    $exe = 'powershell.exe'
    if ($env:SystemRoot) {
        $full = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $full) { $exe = $full }
    }
    if ($PSCmdlet.ShouldProcess($app, 'Start the WinPkgScan app')) {
        Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList (
            '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $app + '"')
    }
}

Export-ModuleMember -Function @(@($ScriptCommands.Keys) + 'Start-WinPkgScanApp')
