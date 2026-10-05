# WinPkgScan

![CI](https://github.com/OWNER/REPO/actions/workflows/ci.yml/badge.svg)

A read-only PowerShell script that finds leftover app folders in `%LOCALAPPDATA%\Packages` whose app is no longer installed for the current Windows user.

It lists each folder with its size and last-modified date, and saves a report to your Desktop. **It never deletes, uninstalls or modifies anything.**

## Why

When a Microsoft Store (AppX/MSIX) app is removed, its data folder in `AppData\Local\Packages` is sometimes left behind. Over time these folders can take up significant disk space. WinPkgScan helps you identify them so you can decide what to clean up manually.

## How it works

1. Reads all AppX packages registered for the current user (`Get-AppxPackage`).
2. Lists every folder in `%LOCALAPPDATA%\Packages`.
3. Skips any folder whose name matches a registered Package Family Name (case-insensitive), e.g. `Microsoft.WindowsStore_8wekyb3d8bbwe`.
4. Sorts the remaining folders into two groups:
   - **Orphaned package folders:** named like a package (`Name_` plus a 13-character publisher ID) but not registered. These are the main cleanup candidates.
   - **Other folders:** not named like a package, such as `windows_ie_ac_001`. These are often used by Windows itself and are listed separately for review.
5. Calculates each folder's size and last-modified date (newest file inside it), and sorts each group largest first.
6. Prints the results and writes a text report, plus an optional CSV.

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

Keep all three files in the same folder. The other files (`tests/`, `build.ps1`, `.github/`) are only for development.

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
| `-Csv` | Also save the results as a CSV file next to the report, for sorting in Excel. |

```powershell
.\Find-OrphanedAppxFolders.ps1 -NoPause -Csv -ReportPath "C:\Temp\appx-report.txt"
```

Both batch files pass options through, for example:

```bat
Run-Scan.bat -Csv
Run-Scan-Unattended.bat -Csv -ReportPath "C:\Temp\appx-report.txt"
```

Built-in help:

```powershell
Get-Help .\Find-OrphanedAppxFolders.ps1 -Full
```

The script exits with code `0` on success and `1` on error.

## Output

- **Console:** summary counts and sizes for each group, plus a table per group (name, size, last modified).
- **Report file:** `Orphaned-Appx-Packages.txt` on your Desktop (OneDrive-redirected Desktops are detected), or the path given in `-ReportPath`.
- **CSV file (with `-Csv`):** same name as the report with a `.csv` extension. Columns: `Category`, `FolderName`, `SizeMB`, `LastModified`, `FullPath`, `Status`.

Example report entry:

```
Folder        : Contoso.SampleApp_abc123def4567
Size          : 412.57 MB
Last Modified : 2024-03-15
Path          : C:\Users\You\AppData\Local\Packages\Contoso.SampleApp_abc123def4567
Status        : NOT CURRENTLY REGISTERED
```

## Limitations

- Scans the current user only. Other user profiles are not checked.
- A flagged folder is a candidate, not a confirmed orphan. Some system or provisioned apps may appear in the list. Verify each folder before deleting it.
- Files the script cannot access are skipped, so reported sizes may be lower than actual.
- If the installed package list cannot be read, the scan stops instead of flagging every folder.

## Safety

This tool only reads and reports. Any cleanup is your decision and your responsibility. Back up or move a folder before deleting it if you are unsure. An old last-modified date is a good sign a folder is unused, but it is not proof.

## Development

Install the tools once:

```powershell
Install-Module PSScriptAnalyzer, Pester -Scope CurrentUser -Force -SkipPublisherCheck
```

Run lint and tests:

```powershell
./build.ps1              # lint + tests
./build.ps1 -Task Lint   # PSScriptAnalyzer only
./build.ps1 -Task Test   # Pester only
```

- **Unit tests** mock `Get-AppxPackage` and use a fake Packages folder, so they run on any OS.
- **Integration tests** (tag `Integration`) run only on Windows. They scan the real user packages and run `Run-Scan-Unattended.bat`.
- **CI** (`.github/workflows/ci.yml`) runs on every push and pull request: lint on Ubuntu, tests on Windows with PowerShell 5.1 and 7. Test results are uploaded as a build artifact.

## License

MIT. See [LICENSE](LICENSE).
