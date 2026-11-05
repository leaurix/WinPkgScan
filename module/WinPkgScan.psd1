@{
    RootModule           = 'WinPkgScan.psm1'
    ModuleVersion        = '1.8.0'
    GUID                 = 'b1db2dd6-a2ac-457c-accf-1bf3ebfc1b50'
    Author               = 'Louis Yvan Alcayde'
    CompanyName          = 'Louis Yvan Alcayde'
    Copyright            = '(c) 2026 Louis Yvan Alcayde. MIT License.'
    Description          = 'Finds leftover app data folders of removed Microsoft Store (AppX/MSIX) apps in %LOCALAPPDATA%\Packages, and safely removes the ones you choose: every folder is checked again, moved to the Recycle Bin, and can be restored. Includes a Windows app.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport    = @(
        'Find-OrphanedAppxFolders'
        'Remove-OrphanedAppxFolders'
        'Restore-OrphanedAppxFolders'
        'Install-WinPkgScan'
        'Start-WinPkgScanApp'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    # Files in the published module. build.ps1 copies these from the repo.
    FileList             = @(
        'WinPkgScan.psd1'
        'WinPkgScan.psm1'
        'Find-OrphanedAppxFolders.ps1'
        'Remove-OrphanedAppxFolders.ps1'
        'Restore-OrphanedAppxFolders.ps1'
        'WinPkgScan-App.ps1'
        'Install.ps1'
        'WinPkgScan.exclude.txt'
        'WinPkgScan.ico'
        'README.md'
        'LICENSE'
    )

    PrivateData          = @{
        PSData = @{
            Tags         = @('Windows', 'AppX', 'MSIX', 'Cleanup', 'DiskSpace', 'Packages', 'StoreApps', 'PSEdition_Desktop', 'PSEdition_Core')
            LicenseUri   = 'https://github.com/leaurix/WinPkgScan/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/leaurix/WinPkgScan'
            IconUri      = 'https://raw.githubusercontent.com/leaurix/WinPkgScan/main/docs/icon.png'
            ReleaseNotes = 'https://github.com/leaurix/WinPkgScan/blob/main/CHANGELOG.md'
        }
    }
}
