import Foundation

/// Временная папка теста в /tmp/navidrive-audit-<UUID>; удаляется в `cleanUp()`.
struct TemporaryFolder {
    let path: String

    init() throws {
        path = "/tmp/navidrive-audit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func file(_ name: String, contents: String = "data") -> String {
        let file = (path as NSString).appendingPathComponent(name)
        FileManager.default.createFile(atPath: file, contents: Data(contents.utf8))
        return file
    }

    func child(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

    func cleanUp() { try? FileManager.default.removeItem(atPath: path) }
}
