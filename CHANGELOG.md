# Changelog

All notable changes to this project are listed here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/).

## [1.6.0] - 2026-10-08

### Added
- **Mark folders in the HTML report:** tick orphaned folders and click **Save marked CSV**. No Excel needed. Includes "mark all shown", which respects the filter, and a running count and size.
- **`WinPkgScan.bat` menu:** scan, scan as administrator, open the report, preview, delete, restore, edit exclusions and help, in one place. Also runs `scan`, `preview`, `delete` and `restore` directly for scripts.
- **`Restore-OrphanedAppxFolders.ps1`:** puts recycled folders back from the Recycle Bin using the delete log. Supports `-WhatIf` and `-Name`. Skips a folder if something already exists at its path.
- **Administrator checks** (`-AdminChecks Auto|On|Off`, on both scanner and remover): when elevated, apps still registered to you in an unfinished state (staged or pending) are kept out of the results and never deleted. Folders get notes such as "Provisioned" or "Installed for 2 other users".
- New `Notes` column in the CSV, text report and HTML report.
- The remover finds the CSV itself: the newest of `Orphaned-Appx-Packages.csv` and `WinPkgScan-marked*.csv` on the Desktop and in Downloads (`-SearchFolder` to change).
- Screenshot of the HTML report in the README.
- Dependabot keeps the GitHub Actions versions up to date.

### Changed
- Package lookup now includes every package type (optional, resource, bundle), so fewer folders are wrongly flagged. Falls back if the filter is not supported.
- CSV files are read with their real encoding (UTF-8 with or without BOM, UTF-16, or Excel's ANSI code page), so folder paths with letters like n-tilde work.
- The release zip includes `WinPkgScan.bat` and `Restore-OrphanedAppxFolders.ps1`.

## [1.5.0] - 2026-10-07

### Added
- **HTML report** (`-Html`): a sortable, searchable report with summary tiles, in light and dark mode. `-Open` opens it in your browser.
- **Exclusions:** `-Exclude` (wildcards) and a `WinPkgScan.exclude.txt` file next to the scripts. Excluded folders are left out of the scan and are never deleted by the remover.
- **Windows component protection:** folders from the Windows publisher (`_cw5n1h2txyewy`) and `windows_ie_ac_*` are shown in their own "Windows components (keep)" group. The remover skips them unless `-IncludeWindowsComponents` is used.
- `-ExcludeFile` on both scripts to use a different exclude file.
- Tests for exclusions, Windows components and the HTML report.

### Changed
- `Run-Scan.bat` also saves the HTML report, and opens it when double-clicked.
- The scanner summary, report and CSV include the new Windows components group and the excluded count.
- The release zip includes `WinPkgScan.exclude.txt`.

## [1.4.0] - 2026-10-06

### Added
- `Remove-OrphanedAppxFolders.ps1`: deletes only the folders marked `Yes` in the Delete column of the scanner's CSV.
  - Moves folders to the Recycle Bin by default. `-Permanent` deletes them instead.
  - Asks before each folder. `-WhatIf` previews without changing anything. `-Force` skips the prompts for unattended runs.
  - Re-checks every folder before deleting: it must be directly inside the current user's Packages folder, match its CSV row, still exist, not be or contain a link or junction, not be registered to an installed app, be package-named (unless `-IncludeOtherFolders`), and not be modified in the last 30 days (`-MinAgeDays`).
  - Stops without deleting anything if the installed package list cannot be read.
  - Writes a log CSV of every action and reports the space freed.
  - Reads CSVs saved by Excel with `;` as the separator.
- `Run-Delete.bat`: double-click, or drag a CSV onto it.
- Pester tests for every delete safety check, plus Windows tests for the Recycle Bin and the batch files.

### Changed
- The scanner CSV has a new empty `Delete` column as its first column.
- `Run-Scan.bat` now always saves the CSV, so scan, review and delete work by double-click.
- The release zip includes `Remove-OrphanedAppxFolders.ps1` and `Run-Delete.bat`.

## [1.3.0] - 2026-10-06

### Added
- Pester test suite (`tests/`): unit tests with mocked AppX data, plus Windows-only integration tests that run the real `Get-AppxPackage` and `Run-Scan-Unattended.bat`.
- PSScriptAnalyzer lint with `PSScriptAnalyzerSettings.psd1`.
- `build.ps1` to run lint and tests locally or in CI.
- GitHub Actions workflow: lint on Ubuntu, tests on Windows with PowerShell 5.1 and 7.
- Release workflow: pushing a version tag runs CI, then publishes a GitHub Release with a ready-to-use zip and its SHA256 checksum.
- `build.ps1 -Task Package`: builds the release zip and checks the tag matches the script version, the CHANGELOG has a section for it, and the scripts have CRLF line endings.
- `.gitignore`.

### Fixed
- Lint findings: inaccessible folders are now logged with `-Verbose` instead of being silently ignored.

## [1.2.0] - 2026-10-05

### Added
- Unmatched folders are split into **Orphaned package folders** and **Other folders** (not package-named, e.g. `windows_ie_ac_001`), each with its own count and size.
- Last-modified date per folder (newest file inside it), shown in the console, report and CSV.
- `-Csv` switch: saves results as a CSV next to the text report.
- Comment-based help (`Get-Help .\Find-OrphanedAppxFolders.ps1`).
- Version number shown in the console and report.
- `.gitattributes` to keep CRLF line endings for `.bat` and `.ps1` files.
- `LICENSE` (MIT) and this changelog.

## [1.1.0] - 2026-10-05

### Added
- `Run-Scan.bat` (double-click) and `Run-Scan-Unattended.bat` (Task Scheduler) launchers.
- `-NoPause` switch for unattended runs.
- `-ReportPath` parameter for a custom report location.
- PowerShell 7+ support.
- Total leftover size, user, computer and timestamp in the report.
- Exit codes: `0` on success, `1` on error.

### Fixed
- Scan now aborts if `Get-AppxPackage` fails or returns no packages, instead of flagging every folder.
- Report is saved to the real Desktop, including OneDrive-redirected Desktops.
- Console results table no longer disappears when output is redirected.
- Registered package count no longer includes entries with a blank name.
- Script saved with a `.ps1` extension.

## [1.0.0]

### Added
- Initial release: read-only scan of `%LOCALAPPDATA%\Packages` with a text report.
