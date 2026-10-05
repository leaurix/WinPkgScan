# Changelog

All notable changes to this project are listed here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/).

## [1.3.0] - 2026-10-05

### Added
- Pester test suite (`tests/`): unit tests with mocked AppX data, plus Windows-only integration tests that run the real `Get-AppxPackage` and `Run-Scan-Unattended.bat`.
- PSScriptAnalyzer lint with `PSScriptAnalyzerSettings.psd1`.
- `build.ps1` to run lint and tests locally or in CI.
- GitHub Actions workflow: lint on Ubuntu, tests on Windows with PowerShell 5.1 and 7.
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
