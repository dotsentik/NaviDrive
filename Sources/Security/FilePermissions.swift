import Foundation

/// Права доступа к данным NaviDrive (папка Application Support/NaviDrive, база состояния):
/// только владелец. Ссылки не меняются и по ним не переходим.
enum FilePermissions {
    static let privateDirectory: mode_t = 0o700
    static let privateFile: mode_t = 0o600

    /// Папка — 0700 (если это настоящая папка, не ссылка).
    static func restrict(directory path: String) {
        restrict(path, to: privateDirectory, expecting: S_IFDIR)
    }

    /// Существующие обычные файлы — 0600; отсутствующие пропускаются.
    static func restrict(files paths: [String]) {
        for path in paths { restrict(path, to: privateFile, expecting: S_IFREG) }
    }

    private static func restrict(_ path: String, to mode: mode_t, expecting type: mode_t) {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == type, (info.st_mode & 0o777) != mode else { return }
        _ = fchmodat(AT_FDCWD, path, mode, AT_SYMLINK_NOFOLLOW)
    }
}
