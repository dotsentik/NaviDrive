import Foundation
import Testing

@Suite("Private permissions for app data (SEC-008)")
struct FilePermissionsTests {
    private func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o777
    }

    @Test func directoryBecomesOwnerOnly() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        chmod(folder.path, 0o755)
        FilePermissions.restrict(directory: folder.path)
        #expect(mode(folder.path) == 0o700)
    }

    @Test func databaseFilesBecomeOwnerOnly() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let files = ["state.sqlite", "state.sqlite-wal", "state.sqlite-shm"].map { folder.file($0) }
        for file in files { chmod(file, 0o644) }
        FilePermissions.restrict(files: files + [folder.child("missing")])
        for file in files { #expect(mode(file) == 0o600) }
    }

    @Test func symlinkTargetIsNotChanged() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let target = folder.file("shared.txt")
        chmod(target, 0o644)
        let link = folder.child("state.sqlite")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        FilePermissions.restrict(files: [link])
        #expect(mode(target) == 0o644)
    }
}
