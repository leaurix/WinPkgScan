# WinPkgScan

![CI](https://github.com/leaurix/WinPkgScan/actions/workflows/ci.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/leaurix/WinPkgScan)

Finds leftover app folders in `%LOCALAPPDATA%\Packages` whose app is no longer installed for the current Windows user, and lets you remove the ones you choose.

- **The scanner is read-only.** It lists each folder with its size and last-modified date, and saves a report and a CSV to your Desktop.
- **The remover deletes only the folders you mark** in that CSV. It moves them to the Recycle Bin by default and asks before each one.

## Download

1. Download `WinPkgScan-vX.Y.Z.zip` from the [latest release](https://github.com/leaurix/WinPkgScan/releases/latest).
2. Right-click the zip > **Properties** > tick **Unblock** > **OK**. This stops Windows from warning about files downloaded from the internet.
3. Extract it and double-click `Run-Scan.bat`.

Optional: check the download is intact. The hash must match the `.sha256` file on the release page.

```powershell
Get-FileHash .\WinPkgScan-v1.4.0.zip -Algorithm SHA256
```

## Why

When a Microsoft Store (AppX/MSIX) app is removed, its data folder in `AppData\Local\Packages` is sometimes left behind. Over time these folders can take up significant disk space. WinPkgScan finds them and lets you clean them up safely.

## Quick start

1. **Scan:** double-click `Run-Scan.bat`. It saves `Orphaned-Appx-Packages.txt` and `Orphaned-Appx-Packages.csv` to your Desktop.
2. **Review:** open the CSV in Excel. Type `Yes` in the **Delete** column for each folder to remove. Save it as CSV, then close Excel.
3. **Preview:** open PowerShell in the WinPkgScan folder and run `.\Run-Delete.bat -WhatIf`. Nothing is changed.
4. **Remove:** double-click `Run-Delete.bat`. Answer `Y` for each folder, or `A` for all.
5. **Undo if needed:** restore folders from the Recycle Bin. A log of what was done is saved next to the CSV.

## How the scanner works

1. Reads all AppX packages registered for the current user (`Get-AppxPackage`).
2. Lists every folder in `%LOCALAPPDATA%\Packages`.
3. Skips any folder whose name matches a registered Package Family Name (case-insensitive), e.g. `Microsoft.WindowsStore_8wekyb3d8bbwe`.
4. Sorts the remaining folders into two groups:
   - **Orphaned package folders:** named like a package (`Name_` plus a 13-character publisher ID) but not registered. These are the main cleanup candidates.
   - **Other folders:** not named like a package, such as `windows_ie_ac_001`. These are often used by Windows itself and are listed separately for review.
5. Calculates each folder's size and last-modified date (newest file inside it), and sorts each group largest first.
6. Prints the results and writes a text report, plus a CSV.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- No administrator rights needed

## Files

| File | Purpose |
|---|---|
| `Find-OrphanedAppxFolders.ps1` | The scanner (read-only) |
| `Remove-OrphanedAppxFolders.ps1` | The remover |
| `Run-Scan.bat` | Double-click to scan. Saves the report and the CSV, then waits for Enter. |
| `Run-Scan-Unattended.bat` | Scan for Task Scheduler or other scripts. No prompt, returns an exit code. |
| `Run-Delete.bat` | Double-click to remove the folders marked in the Desktop CSV, or drag a CSV onto it. |

Keep these files in the same folder. The other files (`tests/`, `build.ps1`, `.github/`) are only for development.

## Scanner usage

**Easiest:** double-click `Run-Scan.bat`.

**From PowerShell:** open PowerShell in the script's folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Find-OrphanedAppxFolders.ps1 -Csv
```

`-ExecutionPolicy Bypass` applies to this run only and does not change your system settings.

### Scanner options

| Parameter | Description |
|---|---|
| `-NoPause` | Skip the "Press Enter to exit" prompt. Use for scheduled or unattended runs. |
| `-ReportPath <path>` | Save the report to a custom location instead of the Desktop. |
| `-Csv` | Also save the results as a CSV next to the report. `Run-Scan.bat` always adds this. |

```powershell
.\Find-OrphanedAppxFolders.ps1 -NoPause -Csv -ReportPath "C:\Temp\appx-report.txt"
```

The batch files pass options through, for example:

```bat
Run-Scan.bat -ReportPath "C:\Temp\appx-report.txt"
Run-Scan-Unattended.bat -Csv -ReportPath "C:\Temp\appx-report.txt"
```

### Scanner output

- **Console:** summary counts and sizes for each group, plus a table per group (name, size, last modified).
- **Report file:** `Orphaned-Appx-Packages.txt` on your Desktop (OneDrive-redirected Desktops are detected), or the path given in `-ReportPath`.
- **CSV file:** same name as the report with a `.csv` extension. Columns: `Delete` (empty, for you to fill in), `Category`, `FolderName`, `SizeMB`, `LastModified`, `FullPath`, `Status`.

Example report entry:

```
Folder        : Contoso.SampleApp_abc123def4567
Size          : 412.57 MB
Last Modified : 2024-03-15
Path          : C:\Users\You\AppData\Local\Packages\Contoso.SampleApp_abc123def4567
Status        : NOT CURRENTLY REGISTERED
```

## Removing folders

Mark rows in the CSV by typing `Yes` in the **Delete** column (`Y`, `True`, `1` and `X` also work). Then run `Run-Delete.bat`, or:

```powershell
.\Remove-OrphanedAppxFolders.ps1 -WhatIf     # preview only
.\Remove-OrphanedAppxFolders.ps1             # Recycle Bin, asks before each folder
```

### Safety checks

Every marked folder is checked again just before it is removed. It is **skipped** if:

- it is not directly inside `%LOCALAPPDATA%\Packages` of the current user, or its `FolderName` and `FullPath` do not match
- it no longer exists, it is a link or junction, or it contains one (links are never followed)
- it is registered to an installed app right now
- it is not package-named (an "Other folder"), unless you use `-IncludeOtherFolders`
- anything inside it changed in the last 30 days (change with `-MinAgeDays`)

If the list of installed packages cannot be read, nothing is removed.

### Remover options

| Parameter | Description |
|---|---|
| `-CsvPath <path>` | The CSV to read. Defaults to `Orphaned-Appx-Packages.csv` on your Desktop. Can be given first without the name. |
| `-WhatIf` | Show what would be removed. Nothing is changed. |
| `-Permanent` | Delete permanently instead of moving to the Recycle Bin. |
| `-Force` | Do not ask before each folder. Needed for unattended runs. |
| `-MinAgeDays <n>` | Skip folders with anything changed in the last `n` days. Default `30`. `0` turns this off. |
| `-IncludeOtherFolders` | Also allow folders that are not package-named. |
| `-LogPath <path>` | Where to save the log. Defaults to `WinPkgScan-DeleteLog-<date-time>.csv` next to the input CSV. |
| `-NoPause` | Skip the "Press Enter to exit" prompt. |

```bat
Run-Delete.bat -WhatIf
Run-Delete.bat "C:\Temp\appx-report.csv"
Run-Delete.bat -Force -NoPause
```

### Remover output

- **Console:** one line per marked folder (`Recycled`, `Deleted`, `WhatIf`, `Skipped` or `Failed`, with the reason), then a summary with the space freed.
- **Log CSV:** columns `Time`, `Action`, `FolderName`, `SizeMB`, `FullPath`, `Reason`.
- **Exit code:** `0` if nothing failed (skipped folders are not failures), `1` on an error or a failed delete.

## Limitations

- Scans the current user only. Other user profiles are not checked.
- A flagged folder is a candidate, not a confirmed orphan. Some system or provisioned apps may appear in the list. Check each folder before marking it.
- Files the script cannot access are skipped, so reported sizes may be lower than actual.
- If the installed package list cannot be read, the scanner stops instead of flagging every folder, and the remover stops without deleting.
- Windows deletes a folder permanently, instead of recycling it, if it is too large for the Recycle Bin. The size limit is set per drive in the Recycle Bin's properties.
- Close the CSV in Excel before running the remover. Excel locks the file while it is open.

## Safety

The scanner only reads and reports. The remover deletes only what you mark, re-checks each folder first, and uses the Recycle Bin by default. Removing folders is still your decision: check before you mark a folder, and use `-WhatIf` first. An old last-modified date is a good sign a folder is unused, but it is not proof.

## Development

Install the tools once:

```powershell
Install-Module PSScriptAnalyzer, Pester -Scope CurrentUser -Force -SkipPublisherCheck
```

Run lint and tests:

```powershell
./build.ps1                                # lint + tests
./build.ps1 -Task Lint                     # PSScriptAnalyzer only
./build.ps1 -Task Test                     # Pester only
./build.ps1 -Task Package -Tag v1.4.0      # build the release zip into out/
```

- **Unit tests** mock `Get-AppxPackage` and use a fake Packages folder, so they run on any OS. Deletion is tested for real on the fake folders.
- **Integration tests** (tag `Integration`) run only on Windows. They scan the real user packages, test the Recycle Bin, and run the batch files.
- **CI** (`.github/workflows/ci.yml`) runs on every branch push and pull request: lint on Ubuntu, tests on Windows with PowerShell 5.1 and 7. Test results are uploaded as a build artifact.

### Releasing

1. Update the version in both scripts, in both places in each: the `Version:` help line and `$ScriptVersion`.
2. Add a `## [X.Y.Z] - YYYY-MM-DD` section at the top of `CHANGELOG.md`.
3. Merge to `main` through a pull request, with CI green.
4. Tag and push:

   ```powershell
   git checkout main
   git pull
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

The **Release** workflow (`.github/workflows/release.yml`) then runs the full CI. If CI passes, it builds the zip (both scripts, the three batch files, README and LICENSE) and a SHA256 checksum, and publishes a GitHub Release. The release notes come from the CHANGELOG. The release fails if the tag does not match the script version or the CHANGELOG has no section for it.

## License

MIT. See [LICENSE](LICENSE).
