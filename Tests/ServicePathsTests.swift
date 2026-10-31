import Foundation
import Testing

@Suite("Finder Services pasteboard paths (SEC-015)")
struct ServicePathsTests {
    @Test func keepsExistingAbsolutePaths() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let file = folder.file("report.pdf")
        #expect(ServicePaths.sanitize([file, folder.path]) == [file, folder.path])
    }

    @Test func dropsRelativeMissingAndRoot() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        #expect(ServicePaths.sanitize(["report.pdf", "~/.ssh", "../etc", "", "/", folder.child("missing")]).isEmpty)
    }

    @Test func standardizesAndDeduplicates() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let file = folder.file("a.txt")
        let dotted = folder.path + "/./sub/../a.txt"
        #expect(ServicePaths.sanitize([file, dotted, file]) == [file])
    }

    @Test func dropsPathsWithNUL() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let file = folder.file("a.txt")
        #expect(ServicePaths.sanitize([file + "\u{0}/../../etc/passwd"]).isEmpty)
    }
}
