import CoreServices
import Foundation

/// Карантин (`com.apple.quarantine`) для всего, что NaviDrive скачивает из облака: Gatekeeper и XProtect
/// проверяют такие файлы при открытии, как файлы из браузера. Чистая логика без UI и сети —
/// компилируется и в приложение, и в юнит-тесты.
enum Quarantine {
    static let attributeName = "com.apple.quarantine"
    static let agentName = "NaviDrive"

    /// Помечает файл или папку как загруженные из интернета. Ссылки не помечаются (и по ним не переходим).
    /// Ошибка не прерывает скачивание: false — пометить не удалось (например, ФС без расширенных атрибутов).
    @discardableResult
    static func mark(_ path: String) -> Bool {
        guard !isSymlink(path) else { return false }
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: agentName,
        ]
        do {
            try url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    /// У файла есть атрибут карантина (без перехода по ссылке).
    static func isMarked(_ path: String) -> Bool {
        getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW) > 0
    }

    /// Создаёт недостающие папки пути (как `withIntermediateDirectories`) и помечает карантином
    /// только созданные сейчас: уже существующие папки пользователя не трогаются.
    static func createDirectories(atPath path: String) throws {
        let fm = FileManager.default
        var missing: [String] = []
        var current = (path as NSString).standardizingPath
        while !current.isEmpty, current != "/", (try? fm.attributesOfItem(atPath: current)) == nil {
            missing.insert(current, at: 0)
            current = (current as NSString).deletingLastPathComponent
        }
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        for directory in missing { mark(directory) }
    }

    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
