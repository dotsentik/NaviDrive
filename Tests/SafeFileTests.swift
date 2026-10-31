import Foundation
import Testing

@Suite("Opening files without following symlinks (SEC-012, SEC-016)")
struct SafeFileTests {
    @Test func createsAndWritesRegularFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let part = folder.child("file.gdrive.part")
        let handle = try SafeFile.openForUpdate(part, create: true)
        try handle.write(contentsOf: Data("abc".utf8))
        try handle.close()
        #expect(FileManager.default.contents(atPath: part) == Data("abc".utf8))
    }

    @Test func refusesSymlinkInsteadOfPartFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let victim = folder.file("zshrc", contents: "original")
        let part = folder.child("file.gdrive.part")
        try FileManager.default.createSymbolicLink(atPath: part, withDestinationPath: victim)
        #expect(throws: POSIXError.self) { try SafeFile.openForUpdate(part, create: true) }
        #expect(throws: POSIXError.self) { try SafeFile.truncate(part) }
        #expect(FileManager.default.contents(atPath: victim) == Data("original".utf8))
    }

    @Test func refusesDanglingSymlinkOnCreate() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let part = folder.child("file.gdrive.part")
        let target = folder.child("created-through-link")
        try FileManager.default.createSymbolicLink(atPath: part, withDestinationPath: target)
        #expect(throws: POSIXError.self) { try SafeFile.openForUpdate(part, create: true) }
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func readingRefusesSymlinkToSecret() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let secret = folder.file("id_ed25519", contents: "PRIVATE KEY")
        let queued = folder.child("photo.jpg")
        try FileManager.default.createSymbolicLink(atPath: queued, withDestinationPath: secret)
        #expect(throws: POSIXError.self) { try SafeFile.openForReading(queued) }
    }

    @Test func refusesDirectory() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        #expect(throws: POSIXError.self) { try SafeFile.openForReading(folder.path) }
    }

    @Test func truncatesRegularFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let file = folder.file("part", contents: "0123456789")
        try SafeFile.truncate(file)
        #expect(FileManager.default.contents(atPath: file)?.isEmpty == true)
    }
}
