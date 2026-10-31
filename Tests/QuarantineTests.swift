import Foundation
import Testing

@Suite("Quarantine of downloaded items (SEC-011)")
struct QuarantineTests {
    @Test func marksFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let file = folder.file("installer.dmg.gdrive.part")
        #expect(!Quarantine.isMarked(file))
        #expect(Quarantine.mark(file))
        #expect(Quarantine.isMarked(file))
    }

    @Test func attributeNamesNaviDriveAsAgent() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let file = folder.file("script.command")
        Quarantine.mark(file)
        let length = getxattr(file, Quarantine.attributeName, nil, 0, 0, XATTR_NOFOLLOW)
        #expect(length > 0)
        var buffer = [UInt8](repeating: 0, count: max(length, 0))
        _ = getxattr(file, Quarantine.attributeName, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        #expect(String(decoding: buffer, as: UTF8.self).contains(Quarantine.agentName))
    }

    @Test func markSurvivesRename() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let part = folder.file("Evil.app.zip.gdrive.part")
        Quarantine.mark(part)
        let final = folder.child("Evil.app.zip")
        #expect(rename(part, final) == 0)
        #expect(Quarantine.isMarked(final))
    }

    @Test func doesNotMarkThroughSymlink() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let target = folder.file("target")
        let link = folder.child("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(!Quarantine.mark(link))
        #expect(!Quarantine.isMarked(target))
    }

    @Test func createDirectoriesMarksOnlyNewOnes() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let existing = folder.child("Existing")
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: false)
        let deep = (existing as NSString).appendingPathComponent("Shared/Tool.app/Contents")
        try Quarantine.createDirectories(atPath: deep)
        #expect(!Quarantine.isMarked(folder.path))
        #expect(!Quarantine.isMarked(existing))
        #expect(Quarantine.isMarked((existing as NSString).appendingPathComponent("Shared")))
        #expect(Quarantine.isMarked((existing as NSString).appendingPathComponent("Shared/Tool.app")))
        #expect(Quarantine.isMarked(deep))
    }

    @Test func createDirectoriesOnExistingPathIsNoOp() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        try Quarantine.createDirectories(atPath: folder.path)
        #expect(!Quarantine.isMarked(folder.path))
    }
}
