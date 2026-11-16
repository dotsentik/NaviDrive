import Foundation

/// Журнал событий в текстовый файл (`navidrive.log`) с ротацией: при превышении `maxFileSize`
/// файл становится `navidrive.1.log`, старые сдвигаются, самый старый удаляется — на диске не больше
/// `maxFiles` файлов.
///
/// Нагрузка минимальна: вызов `write` только кладёт строку в очередь (без ожидания), строки копятся
/// в буфере и пишутся на диск одним вызовом раз в секунду или при 32 КБ. Пишутся события (старт, обрыв,
/// пауза, ответ сервера), а не каждый блок данных — это десятки строк в час на файл.
///
/// Секреты вырезаются до записи (`redact`): токены, ключи общих ссылок и коды авторизации.
final class FileLogWriter: @unchecked Sendable {
    let directory: URL
    let baseName: String
    let maxFileSize: Int
    let maxFiles: Int

    /// Всё изменяемое состояние — только на этой очереди.
    private let queue = DispatchQueue(label: "com.navidrive.filelog", qos: .utility)
    private var buffer = Data()
    private var handle: FileHandle?
    private var currentSize = 0
    private var flushScheduled = false
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static let flushThreshold = 32 * 1024
    static let flushDelay: TimeInterval = 1

    init(directory: URL, baseName: String = "navidrive", maxFileSize: Int = 5 * 1_048_576, maxFiles: Int = 5) {
        self.directory = directory
        self.baseName = baseName
        self.maxFileSize = maxFileSize
        self.maxFiles = max(1, maxFiles)
    }

    var currentFileURL: URL { fileURL(index: 0) }

    func fileURL(index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "\(baseName).log" : "\(baseName).\(index).log")
    }

    /// Не блокирует вызывающего: форматирование и запись — на очереди журнала.
    func write(_ category: String, _ message: String, date: Date = Date()) {
        queue.async { [self] in
            let line = "\(formatter.string(from: date)) [\(category)] \(Self.redact(message))\n"
            buffer.append(Data(line.utf8))
            if buffer.count >= Self.flushThreshold {
                flushNow()
            } else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + Self.flushDelay) { [self] in
                    flushScheduled = false
                    flushNow()
                }
            }
        }
    }

    /// Дописать буфер на диск и дождаться этого (выход из приложения, тесты, «Показать журнал»).
    func flush() {
        queue.sync { flushNow() }
    }

    private func flushNow() {
        guard !buffer.isEmpty else { return }
        if handle == nil { open() }
        if currentSize > 0, currentSize + buffer.count > maxFileSize {
            rotate()
            open()
        }
        guard let handle else {
            // Журнал недоступен (нет прав, нет места) — строки отбрасываются, приложение работает дальше.
            buffer.removeAll(keepingCapacity: true)
            return
        }
        do {
            try handle.write(contentsOf: buffer)
            currentSize += buffer.count
        } catch {
            try? handle.close()
            self.handle = nil
        }
        buffer.removeAll(keepingCapacity: true)
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let path = currentFileURL.path
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let opened = FileHandle(forWritingAtPath: path) else { return }
        currentSize = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        currentSize = 0
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL(index: maxFiles - 1))
        if maxFiles > 1 {
            for index in stride(from: maxFiles - 2, through: 0, by: -1) {
                let source = fileURL(index: index)
                guard fm.fileExists(atPath: source.path) else { continue }
                try? fm.moveItem(at: source, to: fileURL(index: index + 1))
            }
        }
    }

    /// Последние `limit` строк, содержащих любую из `needles`, из двух свежих файлов журнала (старые — первыми).
    /// Читается после `flush`, вне главного потока (файл до 5 МБ).
    func recentLines(matching needles: [String], limit: Int) -> [String] {
        flush()
        let needles = needles.filter { !$0.isEmpty }
        guard !needles.isEmpty, limit > 0 else { return [] }
        var result: [String] = []
        for index in stride(from: min(1, maxFiles - 1), through: 0, by: -1) {
            guard let data = try? Data(contentsOf: fileURL(index: index)) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") where needles.contains(where: { line.contains($0) }) {
                result.append(String(line))
            }
        }
        return Array(result.suffix(limit))
    }

    // MARK: - Секреты

    /// Параметры ссылок и запросов, значения которых в журнал не попадают.
    static let secretParameters = [
        "rlkey", "resourcekey", "key", "token", "access_token", "refresh_token", "id_token",
        "code", "code_verifier", "client_secret", "st", "sig", "signature", "password",
    ]

    private static let parameterPattern: NSRegularExpression = {
        let names = secretParameters.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // try! — шаблон постоянный и проверен тестом.
        return try! NSRegularExpression(pattern: "(?i)\\b(\(names))=[^&\\s\"']+")
    }()

    private static let bearerPattern = try! NSRegularExpression(pattern: "(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+")

    /// `…?rlkey=abc&dl=0` → `…?rlkey=…&dl=0`, `Bearer abc` → `Bearer …`.
    static func redact(_ text: String) -> String {
        guard text.contains("=") || text.localizedCaseInsensitiveContains("bearer") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = parameterPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1=…")
        let bearerRange = NSRange(result.startIndex..., in: result)
        result = bearerPattern.stringByReplacingMatches(in: result, range: bearerRange, withTemplate: "Bearer …")
        return result
    }
}
