# Changelog

All notable changes to NaviDrive are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
`Scripts/release.sh` takes the release notes from the `## [X.Y.Z]` section of the version.

## [Unreleased]

## [1.1.3] - 2026-11-16

### Added
- Save Locations: a Clear All button removes all save locations of the selected cloud after a confirmation; the … menu removes only unavailable ones (disk not connected or folder missing). Files on disk are never deleted.
- Delete, ⌘⌫ and ⌦ remove the selected entries in Added by Link, Save Locations, Uploads and Download Manager; ⌘A selects all. In Uploads and Download Manager only completed and cancelled entries are removed — running, waiting and failed transfers are not touched.
- A transfer log (Help → Show Log in Finder) records resume offsets, server responses, interruptions, pauses, retries and why a partial file was truncated. Link keys and tokens are never written to it.
- A download that receives no data for 60 seconds shows the reason in its row; after 5 minutes the connection is restarted from the partial file, and after 3 restarts the download fails with the reason.
- Diagnostics… in the Download Manager row explains in plain words what is happening with a download and shows its recent events, with Copy Report.

### Changed
- Save Locations and its sidebar counter show only the cloud selected in the sidebar.
- A link of another cloud (for example a Dropbox link on the Google Drive tab) says which tab opens it.

### Fixed
- Opening an unsupported link no longer breaks the window layout.
- The window no longer jumps when switching to Save Locations.
- Holding ⌘Q to quit no longer also quits the next app in focus: NaviDrive now quits when the keys are released ("Release ⌘Q to Quit").

## [1.1.2] - 2026-10-31

### Security
- Downloaded files and folders are marked as coming from the internet, so macOS checks apps, disk images and scripts before they are opened for the first time.
- Partial downloads and upload sources are opened without following symbolic links.
- Sign-in credentials are no longer sent to another host when a request is redirected.
- The local sign-in server checks the Host header, compares the sign-in state in constant time and limits connections.
- Signing out of Dropbox revokes the token on Dropbox's side, also after a relaunch.
- A token refresh that finishes after the account was changed is discarded.
- "Add by Link" accepts only exact Google Drive and Dropbox addresses.
- The "Upload to NaviDrive" service accepts only existing absolute paths.
- The app data folder and database are accessible only to your user account.
- A download stops if the server sends more data than the declared file size.
- Update release tags with surrounding whitespace are rejected.

### Changed
- The PKCE challenge is computed with CryptoKit instead of a custom SHA-256 implementation.

### Fixed
- The Download Manager stats layout no longer shifts while transfers update.

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
