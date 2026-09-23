# WinPkgScan

A read-only PowerShell script that finds leftover app folders in `%LOCALAPPDATA%\Packages` whose app is no longer installed for the current Windows user.

It lists each folder with its size and saves a report to your Desktop. **It never deletes, uninstalls or modifies anything.**

## Why

When a Microsoft Store (AppX/MSIX) app is removed, its data folder in `AppData\Local\Packages` is sometimes left behind. Over time these folders can take up significant disk space. WinPkgScan helps you identify them so you can decide what to clean up manually.

## How it works

1. Reads all AppX packages registered for the current user (`Get-AppxPackage`).
2. Lists every folder in `%LOCALAPPDATA%\Packages`.
3. Flags any folder whose name does not match a registered Package Family Name (case-insensitive), e.g. `Microsoft.WindowsStore_8wekyb3d8bbwe`.
4. Calculates the size of each flagged folder and sorts the results largest first.
5. Prints the results and writes a text report.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- No administrator rights needed

## Files

| File | Purpose |
|---|---|
| `Find-OrphanedAppxFolders.ps1` | The scanner script |
| `Run-Scan.bat` | Double-click launcher. Shows results and waits for Enter. |
| `Run-Scan-Unattended.bat` | For Task Scheduler or other scripts. No prompt, returns an exit code. |

Keep all three files in the same folder.

## Usage

**Easiest:** double-click `Run-Scan.bat`.

**From PowerShell:** open PowerShell in the script's folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Find-OrphanedAppxFolders.ps1
```

`-ExecutionPolicy Bypass` applies to this run only and does not change your system settings.

### Options

| Parameter | Description |
|---|---|
| `-NoPause` | Skip the "Press Enter to exit" prompt. Use for scheduled or unattended runs. |
| `-ReportPath <path>` | Save the report to a custom location instead of the Desktop. |

```powershell
.\Find-OrphanedAppxFolders.ps1 -NoPause -ReportPath "C:\Temp\appx-report.txt"
```

Both batch files pass options through, for example:

```bat
Run-Scan-Unattended.bat -ReportPath "C:\Temp\appx-report.txt"
```

The script exits with code `0` on success and `1` on error.

## Output

- **Console:** summary counts, total leftover size and a table of flagged folders (name, size, status).
- **Report file:** `Orphaned-Appx-Packages.txt` on your Desktop (OneDrive-redirected Desktops are detected), or the path given in `-ReportPath`

Example report entry:

```
Folder : Contoso.SampleApp_abc123xyz
Size   : 412.57 MB
Path   : C:\Users\You\AppData\Local\Packages\Contoso.SampleApp_abc123xyz
Status : NOT CURRENTLY REGISTERED
```

## Limitations

- Scans the current user only. Other user profiles are not checked.
- A flagged folder is a candidate, not a confirmed orphan. Some system or provisioned apps may appear in the list. Verify each folder before deleting it.
- Files the script cannot access are skipped, so reported sizes may be lower than actual.
- If the installed package list cannot be read, the scan stops instead of flagging every folder.

## Safety

This tool only reads and reports. Any cleanup is your decision and your responsibility. Back up or move a folder before deleting it if you are unsure.