import Foundation

// MARK: - Google Drive

struct DriveCapabilities: Codable, Sendable, Hashable {
    var canDownload: Bool? = nil
    var canAddChildren: Bool? = nil
    var canRename: Bool? = nil
    var canTrash: Bool? = nil
    var canMoveItemWithinDrive: Bool? = nil
}

struct ShortcutDetails: Codable, Sendable, Hashable {
    let targetId: String?
    let targetMimeType: String?
}

struct DriveItem: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let md5Checksum: String?
    let modifiedTime: String?
    /// Заполнено только у ярлыков (`application/vnd.google-apps.shortcut`).
    var shortcutDetails: ShortcutDetails? = nil
    /// Ключ ресурса для старых ссылок «доступно всем, у кого есть ссылка».
    var resourceKey: String? = nil
    var capabilities: DriveCapabilities? = nil
    /// ID общего диска, если объект лежит на общем диске.
    var driveId: String? = nil

    /// Автор может запретить скачивание (`capabilities.canDownload == false`).
    var canDownload: Bool { capabilities?.canDownload ?? true }
    /// Права на изменение. Неизвестные права (объект из ссылки и т. п.) не блокируют действие —
    /// окончательно решает Drive API, и его отказ показывается понятным текстом.
    var canAddChildren: Bool { capabilities?.canAddChildren ?? true }
    var canRename: Bool { capabilities?.canRename ?? true }
    var canTrash: Bool { capabilities?.canTrash ?? true }
    var canMove: Bool { capabilities?.canMoveItemWithinDrive ?? true }

    /// Копия с новым именем — для мгновенного обновления списка после переименования.
    func renamed(_ newName: String) -> DriveItem {
        DriveItem(id: id, name: newName, mimeType: mimeType, size: size, md5Checksum: md5Checksum,
                  modifiedTime: modifiedTime, shortcutDetails: shortcutDetails, resourceKey: resourceKey,
                  capabilities: capabilities, driveId: driveId)
    }

    static let folderMimeType = "application/vnd.google-apps.folder"
    static let shortcutMimeType = "application/vnd.google-apps.shortcut"

    // MARK: Ярлыки: всё поведение определяется целью ярлыка, имя — как у самого ярлыка.

    var isShortcut: Bool { mimeType == Self.shortcutMimeType }
    /// ID объекта, с которым реально работаем (цель ярлыка или сам объект).
    var targetId: String { isShortcut ? (shortcutDetails?.targetId ?? id) : id }
    /// mimeType цели для ярлыка, иначе собственный.
    var effectiveMimeType: String { isShortcut ? (shortcutDetails?.targetMimeType ?? mimeType) : mimeType }

    var isFolder: Bool { effectiveMimeType == Self.folderMimeType }
    /// Общий диск цели. У ярлыка он неизвестен (цель может лежать где угодно) —
    /// тогда листинг идёт по родителю без corpora=drive.
    var targetDriveId: String? { isShortcut ? nil : driveId }
    var isGoogleWorkspaceDocument: Bool { !isFolder && effectiveMimeType.hasPrefix("application/vnd.google-apps.") }
    var sizeValue: Int64 { size.flatMap(Int64.init) ?? 0 }

    /// Формат экспорта для документов Google (nil — объект нельзя скачать).
    var exportFormat: GoogleExportFormat? { GoogleExportFormat(googleMimeType: effectiveMimeType) }

    /// Можно ли скачать объект как файл (обычный бинарный файл или экспортируемый документ).
    /// Для ярлыка на файл размер и md5 станут известны только после `files.get` цели.
    var isDownloadable: Bool {
        if isFolder { return false }
        if isShortcut && shortcutDetails?.targetId == nil { return false }
        if isGoogleWorkspaceDocument { return exportFormat != nil }
        return true
    }

    /// Имя локального файла (для документов Google добавляется расширение экспорта).
    var localFileName: String {
        let base = PathResolver.sanitize(name)
        if let format = exportFormat, !base.lowercased().hasSuffix("." + format.fileExtension) {
            return base + "." + format.fileExtension
        }
        return base
    }

    var modifiedDate: Date? {
        guard let modifiedTime else { return nil }
        return DriveDate.parse(modifiedTime)
    }
}

enum DriveDate {
    static func parse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

struct DriveFileList: Decodable, Sendable {
    let nextPageToken: String?
    let files: [DriveItem]
}

struct GoogleExportFormat: Sendable, Hashable {
    let mimeType: String
    let fileExtension: String

    init?(googleMimeType: String) {
        switch googleMimeType {
        case "application/vnd.google-apps.document":
            mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            fileExtension = "docx"
        case "application/vnd.google-apps.spreadsheet":
            mimeType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            fileExtension = "xlsx"
        case "application/vnd.google-apps.presentation":
            mimeType = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            fileExtension = "pptx"
        case "application/vnd.google-apps.drawing":
            mimeType = "application/pdf"
            fileExtension = "pdf"
        default:
            return nil
        }
    }
}

// MARK: - Download tasks

enum TaskStatus: String, Sendable, CaseIterable, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled
    case waitingForVolume = "waiting_for_volume"
    case waitingForNetwork = "waiting_for_network"
    /// Файл скачан, идёт сверка MD5 с md5Checksum из Drive.
    case verifying
    /// Google временно ограничил скачивание этого файла (downloadQuotaExceeded); повтор по расписанию.
    case waitingForQuota = "waiting_for_quota"
    /// На целевом диске не хватает места на оставшуюся часть файла; повтор, когда место освободится.
    case waitingForSpace = "waiting_for_space"

    var title: String {
        switch self {
        case .queued: String(localized: "Queued")
        case .downloading: String(localized: "Downloading")
        case .paused: String(localized: "Paused")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Error")
        case .cancelled: String(localized: "Cancelled")
        case .waitingForVolume: String(localized: "Waiting for disk")
        case .waitingForNetwork: String(localized: "Waiting for network")
        case .verifying: String(localized: "Verifying…")
        case .waitingForQuota: String(localized: "Waiting for Google quota")
        case .waitingForSpace: String(localized: "Not enough space")
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .downloading: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .waitingForVolume: "externaldrive.badge.exclamationmark"
        case .waitingForNetwork: "wifi.exclamationmark"
        case .verifying: "checkmark.shield"
        case .waitingForQuota: "hourglass"
        case .waitingForSpace: "externaldrive.badge.xmark"
        }
    }

    /// Статусы, которые считаются «живыми» (ещё не завершённая работа).
    static let pending: [TaskStatus] = [.queued, .downloading, .paused, .waitingForVolume, .waitingForNetwork, .verifying, .waitingForQuota, .waitingForSpace]
}

struct DownloadTask: Sendable, Identifiable, Hashable {
    let id: String
    let driveFileId: String
    let fileName: String
    let mimeType: String?
    let expectedSize: Int64
    var downloadedSize: Int64
    let md5Checksum: String?
    let targetDirPath: String
    var status: TaskStatus
    var retryCount: Int
    var lastError: String?
    var updatedAt: Int64
    /// Заголовок `X-Goog-Drive-Resource-Keys` для объектов из ссылок с resourcekey.
    var resourceKey: String? = nil
    /// modifiedTime из Drive (Unix-время) — ставится как дата изменения файла.
    var driveModifiedAt: Int64? = nil
    /// MD5 файла совпал с md5Checksum из Drive.
    var verified = false
    /// Несовпадений контрольной суммы подряд.
    var checksumFailures = 0
    /// Сколько раз задача уже ждала квоту Google (пауза 1 ч → 2 ч → … → 24 ч).
    var quotaAttempts = 0
    /// Время следующей попытки (Unix) для задач в ожидании квоты.
    var nextAttemptAt: Int64? = nil

    var finalPath: String { (targetDirPath as NSString).appendingPathComponent(fileName) }
    /// MD5 сверяется для обычных файлов, у которых Drive отдал md5Checksum (не для экспорта Google Docs).
    var needsChecksumVerification: Bool {
        exportFormat == nil && !(md5Checksum ?? "").isEmpty
    }
    var partPath: String { finalPath + ".gdrive.part" }
    var exportFormat: GoogleExportFormat? { mimeType.flatMap(GoogleExportFormat.init(googleMimeType:)) }

    /// Финальный файл уже лежит на диске с ожидаемым размером и докачка не идёт.
    /// Для экспорта Google Docs размер заранее неизвестен — такие файлы всегда скачиваются заново.
    var isAlreadyDownloaded: Bool {
        guard exportFormat == nil else { return false }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: partPath),
              let attributes = try? fm.attributesOfItem(atPath: finalPath),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return false }
        return size == expectedSize
    }

    static var downloadForbiddenMessage: String { String(localized: "The owner has disabled downloading this file") }

    static func makeId(driveFileId: String, targetDir: String) -> String {
        "\(driveFileId)::\(targetDir)"
    }

    static func make(from item: DriveItem, fileName: String, targetDir: String) -> DownloadTask {
        DownloadTask(
            id: makeId(driveFileId: item.targetId, targetDir: targetDir),
            driveFileId: item.targetId,
            fileName: fileName,
            mimeType: item.effectiveMimeType,
            expectedSize: item.exportFormat == nil ? item.sizeValue : 0,
            downloadedSize: 0,
            md5Checksum: item.md5Checksum,
            targetDirPath: targetDir,
            // Если автор запретил скачивание (capabilities.canDownload == false) — сразу в ошибки, без попыток.
            status: item.canDownload ? .queued : .failed,
            retryCount: 0,
            lastError: item.canDownload ? nil : downloadForbiddenMessage,
            updatedAt: Int64(Date().timeIntervalSince1970),
            resourceKey: item.resourceKey,
            driveModifiedAt: item.modifiedDate.map { Int64($0.timeIntervalSince1970) }
        )
    }
}

/// Класс задачи для умной очереди. Значения совпадают с генерируемой колонкой `size_class` в SQLite.
enum TaskSizeClass: Int, Sendable, CaseIterable {
    case small = 0
    case large = 1
    case export = 2

    static let smallFileThreshold: Int64 = 10 * 1_048_576

    init(_ task: DownloadTask) {
        if task.exportFormat != nil {
            self = .export
        } else {
            self = task.expectedSize < Self.smallFileThreshold ? .small : .large
        }
    }
}

/// Итог постановки в очередь (для баннера в «Менеджере загрузок»).
struct EnqueueReport: Sendable, Equatable {
    enum Tone: Sendable { case success, info, warning }

    var title: String = ""
    var added = 0
    var alreadyDownloaded = 0
    var unsupported = 0
    /// Файлы, скачивание которых запретил автор.
    var forbidden = 0
    var errors: [String] = []

    mutating func merge(_ other: EnqueueReport) {
        added += other.added
        alreadyDownloaded += other.alreadyDownloaded
        unsupported += other.unsupported
        forbidden += other.forbidden
        errors += other.errors
    }

    var tone: Tone {
        if added > 0 { return errors.isEmpty && forbidden == 0 ? .success : .warning }
        if alreadyDownloaded > 0 && errors.isEmpty && forbidden == 0 { return .info }
        return .warning
    }

    var message: String {
        let body: String
        if added == 0 && alreadyDownloaded == 0 {
            if let error = errors.first {
                body = errors.count > 1 ? String(localized: "\(error) (and \(errors.count - 1) more errors)") : error
            } else if forbidden > 0 {
                body = forbidden == 1 ? DownloadTask.downloadForbiddenMessage
                    : String(localized: "The owner has disabled downloading of \(forbidden) files")
            } else if unsupported > 0 {
                body = unsupported == 1
                    ? String(localized: "This item is not supported (Google Forms, Sites and similar items cannot be downloaded)")
                    : String(localized: "\(unsupported) items are not supported")
            } else {
                body = String(localized: "There are no files to download in this folder")
            }
        } else if added == 0 && forbidden == 0 {
            body = String(localized: "Everything is already downloaded (\(alreadyDownloaded))")
        } else {
            var parts = [String(localized: "Added \(added)")]
            if alreadyDownloaded > 0 { parts.append(String(localized: "already downloaded \(alreadyDownloaded)")) }
            if unsupported > 0 { parts.append(String(localized: "not supported \(unsupported)")) }
            if forbidden > 0 { parts.append(String(localized: "download disabled by owner \(forbidden)")) }
            if !errors.isEmpty { parts.append(String(localized: "errors \(errors.count)")) }
            body = parts.joined(separator: ", ")
        }
        return title.isEmpty ? body : String(localized: "“\(title)”: \(body)")
    }
}

/// Объект, добавленный по ссылке.
struct LinkedItem: Sendable, Identifiable, Hashable {
    let driveId: String
    let name: String
    let mimeType: String
    let resourceKey: String?
    let size: Int64?
    let sharedDriveId: String?
    let addedAt: Int64

    var id: String { driveId }

    init(driveId: String, name: String, mimeType: String, resourceKey: String?, size: Int64?,
         sharedDriveId: String?, addedAt: Int64) {
        self.driveId = driveId
        self.name = name
        self.mimeType = mimeType
        self.resourceKey = resourceKey
        self.size = size
        self.sharedDriveId = sharedDriveId
        self.addedAt = addedAt
    }

    init(_ item: DriveItem) {
        self.init(driveId: item.id, name: item.name, mimeType: item.mimeType, resourceKey: item.resourceKey,
                  size: item.size.flatMap(Int64.init), sharedDriveId: item.driveId,
                  addedAt: Int64(Date().timeIntervalSince1970))
    }

    var driveItem: DriveItem {
        DriveItem(id: driveId, name: name, mimeType: mimeType, size: size.map(String.init), md5Checksum: nil,
                  modifiedTime: nil, resourceKey: resourceKey, driveId: sharedDriveId)
    }
}

/// Разбор ссылок Google Drive: /drive/folders/<id>, /file/d/<id>/view, open?id=<id>,
/// docs.google.com/<тип>/d/<id>/edit, ?usp=sharing, resourcekey=<key>, а также «голый» ID.
struct DriveLink: Sendable, Equatable {
    let id: String
    let resourceKey: String?

    private static let idCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func isValidId(_ value: String) -> Bool {
        value.count >= 10 && value.unicodeScalars.allSatisfy { idCharacters.contains($0) }
    }

    static func parse(_ input: String) -> DriveLink? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'")))
        guard !text.isEmpty else { return nil }
        if isValidId(text) { return DriveLink(id: text, resourceKey: nil) }

        let urlString = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host.hasSuffix("google.com") || host.hasSuffix("googleusercontent.com") else { return nil }

        let query = components.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            query.first { $0.name.lowercased() == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let resourceKey = queryValue("resourcekey")

        // /folders/<id>, /file/d/<id>, /document/d/<id>, /d/<id>
        let parts = components.path.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() where index + 1 < parts.count {
            if part == "folders" || part == "d", isValidId(parts[index + 1]) {
                return DriveLink(id: parts[index + 1], resourceKey: resourceKey)
            }
        }
        // open?id=<id>, uc?id=<id>
        if let id = queryValue("id"), isValidId(id) {
            return DriveLink(id: id, resourceKey: resourceKey)
        }
        return nil
    }
}

/// Потокобезопасный реестр resourceKey: `id → key`. Пополняется из ссылок и ответов API,
/// используется для заголовка `X-Goog-Drive-Resource-Keys` в запросах к объекту и его потомкам.
final class ResourceKeyRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    static let headerName = "X-Goog-Drive-Resource-Keys"

    func register(id: String, key: String?) {
        guard let key, !key.isEmpty else { return }
        lock.lock(); keys[id] = key; lock.unlock()
    }

    func register(_ items: [DriveItem]) {
        lock.lock()
        for item in items {
            if let key = item.resourceKey, !key.isEmpty { keys[item.id] = key }
        }
        lock.unlock()
    }

    func key(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return keys[id]
    }

    /// Значение заголовка для набора ID (`id1/key1,id2/key2`) или nil, если ключей нет.
    func headerValue(for ids: [String]) -> String? {
        lock.lock(); defer { lock.unlock() }
        let pairs = ids.compactMap { id in keys[id].map { "\(id)/\($0)" } }
        return pairs.isEmpty ? nil : pairs.joined(separator: ",")
    }
}

struct CustomRoute: Sendable, Identifiable, Hashable {
    let driveId: String
    let driveName: String
    let localPath: String
    var id: String { driveId }
}

struct QueueTotals: Sendable, Equatable {
    var taskCount: Int = 0
    var pendingCount: Int = 0
    /// Ближайшая попытка (Unix) среди задач в ожидании квоты Google.
    var nextQuotaAttemptAt: Int64?
    var expectedBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var countsByStatus: [TaskStatus: Int] = [:]
    /// Сумма expected_size по статусам (общий размер очереди и т. п.).
    var bytesByStatus: [TaskStatus: Int64] = [:]

    var fraction: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(expectedBytes))
    }
}

/// Итог завершённой очереди — для системного уведомления.
struct QueueSessionSummary: Sendable, Equatable {
    let id: Int
    let projects: [String]
    let files: Int
    let bytes: Int64
    let verified: Int
    let failed: Int
    let waitingQuota: Int
    let waitingVolume: Int

    var notificationTitle: String {
        switch projects.count {
        case 0: return String(localized: "Downloads finished")
        case 1: return String(localized: "Project “\(projects[0])” downloaded")
        default:
            let names = projects.prefix(3).map { "“\($0)”" }.formatted(.list(type: .and)) + (projects.count > 3 ? "…" : "")
            return String(localized: "Projects \(names) downloaded")
        }
    }

    var notificationBody: String {
        var parts = [String(localized: "\(Self.filesCount(files)), \(Format.bytes(bytes))")]
        if files > 0 {
            parts.append(verified == files ? String(localized: "all verified") : String(localized: "verified \(verified) of \(files)"))
        }
        var text = parts.joined(separator: ", ")
        if failed > 0 { text += ". " + String(localized: "Errors: \(failed)") }
        if waitingQuota > 0 { text += ". " + String(localized: "Waiting for Google quota: \(waitingQuota)") }
        if waitingVolume > 0 { text += ". " + String(localized: "Waiting for disk: \(waitingVolume)") }
        return text
    }

    /// «5 файлов» / «5 files» — правила множественного числа из каталога строк.
    static func filesCount(_ n: Int) -> String {
        String(localized: "\(n) files")
    }
}

struct EngineSnapshot: Sendable, Equatable {
    var isPaused = false
    var isOnline = true
    var isAuthorized = false
    var bytesPerSecond: Double = 0
    var liveProgress: [String: Int64] = [:]
    var runningCount = 0
    /// Текущий лимит потоков, который выставил AIMD-регулятор.
    var adaptiveLimit = 4
    /// Верхний предел из настроек пользователя.
    var userLimit = 8
    var runningSmall = 0
    var runningLarge = 0
    var runningExports = 0
    var balancerStatus = ""
    /// id → прочитано байт при проверке MD5.
    var verificationProgress: [String: Int64] = [:]
    /// Последняя завершённая очередь (для уведомления «Проект скачан»).
    var lastSession: QueueSessionSummary?
    var scanningFolders = 0
    var scannedFiles = 0
    var scanErrors: [String] = []
}
