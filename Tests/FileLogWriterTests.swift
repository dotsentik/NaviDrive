import Foundation
import Testing

@Suite("File log: redaction, writing, rotation")
struct FileLogWriterTests {
    @Test func sharedLinkKeysAreRedacted() {
        let link = "https://www.dropbox.com/scl/fi/abc/a.MP4?rlkey=sgw4i4zjef&st=d7sls9cx&dl=0"
        let redacted = FileLogWriter.redact("open \(link)")
        #expect(!redacted.contains("sgw4i4zjef"))
        #expect(!redacted.contains("d7sls9cx"))
        #expect(redacted.contains("rlkey=…"))
        #expect(redacted.contains("dl=0"))
    }

    @Test func googleKeysAndTokensAreRedacted() {
        let text = "folders/1abc?resourcekey=0-XYZ secret access_token=ya29.AbC refresh_token=1//0g Bearer sl.AbCdEf-123"
        let redacted = FileLogWriter.redact(text)
        #expect(!redacted.contains("0-XYZ"))
        #expect(!redacted.contains("ya29.AbC"))
        #expect(!redacted.contains("1//0g"))
        #expect(!redacted.contains("sl.AbCdEf-123"))
        #expect(redacted.contains("Bearer …"))
        #expect(redacted.contains("folders/1abc"))
    }

    @Test func plainTextIsUnchanged() {
        let text = "“a.MP4” request Range bytes=7412334592- (part 7412334592 (6,9 GB)) Content-Range=bytes 1-2/3"
        #expect(FileLogWriter.redact(text) == text)
    }

    @Test func writesLinesWithCategory() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let writer = FileLogWriter(directory: URL(fileURLWithPath: folder.child("Logs")))
        writer.write("download", "first")
        writer.write("upload", "second rlkey=secret")
        writer.flush()
        let text = try String(contentsOf: writer.currentFileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("[download] first"))
        #expect(lines[1].hasSuffix("[upload] second rlkey=…"))
    }

    @Test func rotatesAndKeepsAtMostMaxFiles() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let writer = FileLogWriter(directory: URL(fileURLWithPath: folder.child("Logs")), maxFileSize: 200, maxFiles: 3)
        let line = String(repeating: "x", count: 150)
        for index in 0..<6 {
            writer.write("app", "\(index) \(line)")
            writer.flush()
        }
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: writer.fileURL(index: 0).path))
        #expect(fm.fileExists(atPath: writer.fileURL(index: 1).path))
        #expect(fm.fileExists(atPath: writer.fileURL(index: 2).path))
        #expect(!fm.fileExists(atPath: writer.fileURL(index: 3).path))
        // Самая свежая строка — в основном файле, предыдущая — в .1.
        #expect(try String(contentsOf: writer.fileURL(index: 0), encoding: .utf8).contains("[app] 5 "))
        #expect(try String(contentsOf: writer.fileURL(index: 1), encoding: .utf8).contains("[app] 4 "))
    }

    @Test func recentLinesFiltersByFileAcrossRotation() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let writer = FileLogWriter(directory: URL(fileURLWithPath: folder.child("Logs")), maxFileSize: 600, maxFiles: 3)
        for index in 0..<8 {
            writer.write("download", "“a.MP4” event \(index) " + String(repeating: "-", count: 60))
            writer.write("download", "“b.MP4” other \(index)")
            writer.flush()
        }
        #expect(FileManager.default.fileExists(atPath: writer.fileURL(index: 1).path))
        let lines = writer.recentLines(matching: ["“a.MP4”"], limit: 3)
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.contains("“a.MP4”") })
        // Старые — первыми, последняя строка — самое свежее событие.
        #expect(lines.last?.contains("event 7") == true)
    }
}
