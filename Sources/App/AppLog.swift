import AppKit
import Foundation

/// Подробный журнал приложения: `~/Library/Application Support/NaviDrive/Logs/navidrive.log`
/// (до 5 файлов по 5 МБ). Пишутся события передач — старт и докачка с какого байта, ответ сервера,
/// обрывы, паузы, повторы, обрезка и удаление `.part`, проверка хеша, итог — чтобы по журналу
/// сразу было видно, почему файл не докачался. Системный журнал (`Logger`) остаётся как был.
enum AppLog {
    enum Category: String {
        case app, download, upload
    }

    static let writer = FileLogWriter(directory: directory)

    static var directory: URL {
        AppSettings.supportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    static func log(_ category: Category, _ message: String) {
        writer.write(category.rawValue, message)
    }

    static func app(_ message: String) { log(.app, message) }
    static func download(_ message: String) { log(.download, message) }
    static func upload(_ message: String) { log(.upload, message) }

    static func flush() { writer.flush() }

    /// «Справка → Показать журнал»: файл журнала выделен в Finder.
    @MainActor
    static func reveal() {
        flush()
        let file = writer.currentFileURL
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            try? FileManager.default.createDirectory(at: writer.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(writer.directory)
        }
    }

    // MARK: - Форматирование

    /// Байты с точным числом и в читаемом виде: `7 412 334 592 (6,9 GB)`.
    static func bytes(_ value: Int64) -> String {
        "\(value) (\(ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)))"
    }

    /// Краткое описание задачи загрузки для журнала (без ключа ссылки).
    static func describe(_ task: DownloadTask) -> String {
        "\(task.provider.rawValue) “\(task.fileName)” id=\(task.id) expected=\(bytes(task.expectedSize))"
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue): \(urlError.localizedDescription)"
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(error.localizedDescription)"
    }
}
