# Changelog

All notable changes to NaviDrive are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
`Scripts/release.sh` takes the release notes from the `## [X.Y.Z]` section of the version.

## [Unreleased]

## [1.1.1] - 2026-10-20

### Fixed
- The sign-in timeout message names the cloud being connected: Dropbox no longer reports "No response from Google".

## [1.1.0] - 2026-10-20

### Added
- Updates from GitHub Releases: Settings → General → Updates and NaviDrive → Check for Updates…
- Automatic check once a week (can be turned off), "Skip This Version".
- The update is verified before installing: SHA-256 checksum, the same code signing certificate, the version number.
- Downloads and uploads are paused with progress saved and continue after the update.
- README in English and Russian, signing documentation (`docs/SIGNING.md`), pinned signing certificate fingerprint.
- "READ ME FIRST.txt" with first-launch instructions inside the DMG.

## [1.0] - 2026-10-20

First version, not published as a GitHub release.

### Added
- Google Drive browser (My Drive, Shared with me) with downloads to a default folder, a custom folder or an external disk.
- Download manager: parallel chunked downloads, adaptive concurrency, pause and resume, checksum verification.
- Dropbox support alongside Google Drive; several clouds connected at once.
- SQLite storage for the download and upload queues, history, save locations and folder sizes.
- Uploads with resume and the "Upload to NaviDrive" Finder service.
- Adding files and folders by link; "Download All" for added links; download counts in the context menu.
- Status feed and alerts for limits, errors and disk events; Google Drive daily limit tracking.
- Hold ⌘Q to quit, "Quit When Done".
- Marks for cloud files that are already downloaded to this Mac.

### Changed
- Styled sign-in success page.

### Fixed
- Dropbox resume: 5-minute response timeout, visible retry reason, restart from the beginning when the server ignores the range request.
- Selecting nested items no longer downloads them twice.
