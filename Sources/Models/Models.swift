import Foundation

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
    /// Файл скачан, идёт сверка хеша с хешем из облака.
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
    /// ID файла в облаке `provider`.
    let driveFileId: String
    let fileName: String
    /// MIME-тип файла в облаке (по нему определяется экспорт документов).
    let mimeType: String?
    let expectedSize: Int64
    var downloadedSize: Int64
    /// Хеш содержимого от облака; алгоритм — `provider.hashKind`.
    let checksum: String?
    let targetDirPath: String
    var status: TaskStatus
    var retryCount: Int
    var lastError: String?
    var updatedAt: Int64
    /// Ключ доступа для объектов из ссылок (у Google — resourcekey).
    var resourceKey: String? = nil
    /// Дата изменения в облаке (Unix-время) — ставится как дата изменения файла.
    var driveModifiedAt: Int64? = nil
    /// Хеш файла совпал с хешем из облака.
    var verified = false
    /// Несовпадений контрольной суммы подряд.
    var checksumFailures = 0
    /// Сколько раз задача уже ждала квоту облака (пауза 1 ч → 2 ч → … → 24 ч).
    var quotaAttempts = 0
    /// Время следующей попытки (Unix) для задач в ожидании квоты.
    var nextAttemptAt: Int64? = nil
    var provider: CloudProviderKind = .googleDrive
    /// Путь в облаке; для объектов из общей ссылки — путь относительно корня ссылки (`resourceKey` — сама ссылка).
    var cloudPath: String? = nil

    var finalPath: String { (targetDirPath as NSString).appendingPathComponent(fileName) }
    var hashKind: CloudHashKind { provider.hashKind }
    /// Хеш сверяется для обычных файлов, у которых облако его отдало (не для экспорта документов).
    var needsChecksumVerification: Bool {
        exportFormat == nil && !(checksum ?? "").isEmpty
    }
    /// `.gdrive.part` у Google, `.dropbox.part` у Dropbox.
    var partPath: String { finalPath + provider.partialSuffix }
    var exportFormat: CloudExportFormat? { provider.exportFormat(forContentType: mimeType) }

    /// Финальный файл уже лежит на диске с ожидаемым размером и докачка не идёт.
    /// Для экспорта документов размер заранее неизвестен — такие файлы всегда скачиваются заново.
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

    /// ID задач Google Drive не меняются (совместимость с уже сохранёнными задачами),
    /// у остальных облаков в ID входит провайдер — ID остаются уникальными во всей таблице.
    static func makeId(provider: CloudProviderKind, fileId: String, targetDir: String) -> String {
        provider == .googleDrive ? "\(fileId)::\(targetDir)" : "\(provider.rawValue):\(fileId)::\(targetDir)"
    }

    static func make(from item: CloudItem, fileName: String, targetDir: String) -> DownloadTask {
        DownloadTask(
            id: makeId(provider: item.provider, fileId: item.targetId, targetDir: targetDir),
            driveFileId: item.targetId,
            fileName: fileName,
            mimeType: item.contentType,
            expectedSize: item.exportFormat == nil ? item.sizeValue : 0,
            downloadedSize: 0,
            checksum: item.hash.flatMap { $0.kind == item.provider.hashKind ? $0.value : nil },
            targetDirPath: targetDir,
            // Если автор запретил скачивание — сразу в ошибки, без попыток.
            status: item.canDownload ? .queued : .failed,
            retryCount: 0,
            lastError: item.canDownload ? nil : downloadForbiddenMessage,
            updatedAt: Int64(Date().timeIntervalSince1970),
            resourceKey: item.accessKey,
            driveModifiedAt: item.modifiedAt.map { Int64($0.timeIntervalSince1970) },
            provider: item.provider,
            cloudPath: item.path
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

/// Объект облака, добавленный по ссылке (раздел «Добавленные по ссылке»).
/// Поля заполняет и читает провайдер (`linkRecord(for:)` / `item(fromLinked:)`).
struct LinkedItem: Sendable, Identifiable, Hashable {
    let provider: CloudProviderKind
    let driveId: String
    let name: String
    let mimeType: String
    let resourceKey: String?
    let size: Int64?
    let sharedDriveId: String?
    let addedAt: Int64

    var id: RouteKey { RouteKey(provider: provider, id: driveId) }

    init(provider: CloudProviderKind, driveId: String, name: String, mimeType: String, resourceKey: String?, size: Int64?,
         sharedDriveId: String?, addedAt: Int64) {
        self.provider = provider
        self.driveId = driveId
        self.name = name
        self.mimeType = mimeType
        self.resourceKey = resourceKey
        self.size = size
        self.sharedDriveId = sharedDriveId
        self.addedAt = addedAt
    }
}

struct CustomRoute: Sendable, Identifiable, Hashable {
    var provider: CloudProviderKind = .googleDrive
    let driveId: String
    let driveName: String
    let localPath: String
    var id: RouteKey { RouteKey(provider: provider, id: driveId) }
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
