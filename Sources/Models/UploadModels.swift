import Foundation

// MARK: - Upload tasks

enum UploadStatus: String, Sendable, CaseIterable, Codable {
    case queued
    case uploading
    case paused
    case waitingForNetwork = "waiting_for_network"
    case waitingForVolume = "waiting_for_volume"
    /// Файл передан, идёт сверка хеша локального файла с хешем из ответа облака.
    case verifying
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: String(localized: "Queued")
        case .uploading: String(localized: "Uploading")
        case .paused: String(localized: "Paused")
        case .waitingForNetwork: String(localized: "Waiting for network")
        case .waitingForVolume: String(localized: "Waiting for disk")
        case .verifying: String(localized: "Verifying…")
        case .completed: String(localized: "Uploaded")
        case .failed: String(localized: "Error")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .uploading: "arrow.up.circle"
        case .paused: "pause.circle"
        case .waitingForNetwork: "wifi.exclamationmark"
        case .waitingForVolume: "externaldrive.badge.exclamationmark"
        case .verifying: "checkmark.shield"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    /// Ещё не завершённая работа.
    static let pending: [UploadStatus] = [.queued, .uploading, .paused, .waitingForNetwork, .waitingForVolume, .verifying]
    /// Активные отправки — бейдж в боковой панели.
    static let active: [UploadStatus] = [.queued, .uploading, .verifying]
}

/// Ошибки, после которых файл нужно отправить заново с нуля (новая сессия).
enum UploadErrorKind: String, Sendable {
    /// Размер или дата изменения исходного файла поменялись во время загрузки.
    case sourceChanged = "source_changed"
    /// Хеш из ответа облака (MD5 Google, content_hash Dropbox) не совпал с локальным.
    case checksumMismatch = "checksum_mismatch"

    var restartTitle: String {
        switch self {
        case .sourceChanged: String(localized: "Start Over")
        case .checksumMismatch: String(localized: "Upload Again")
        }
    }
}

struct UploadTask: Sendable, Identifiable, Hashable {
    let id: String
    let localPath: String
    let fileName: String
    var fileSize: Int64
    /// Дата изменения исходного файла (мс с 1970), по ней и размеру ловится изменение во время загрузки.
    var localModifiedAt: Int64
    let parentDriveId: String
    /// Целевая папка для показа: «Проект / Рендеры».
    let parentName: String
    /// Общий диск, если папка на нём.
    let sharedDriveId: String?
    /// Новая версия существующего файла (files.update) вместо создания нового.
    let replaceFileId: String?
    var sessionURI: String?
    var sessionCreatedAt: Int64?
    /// Сколько байт подтвердил сервер (обновляется после каждой части).
    var uploadedBytes: Int64
    var status: UploadStatus
    var retryCount: Int
    var lastError: String?
    var errorKind: UploadErrorKind?
    var driveFileId: String?
    /// Хеш от облака после загрузки; алгоритм — `provider.hashKind`.
    var checksum: String?
    var updatedAt: Int64
    var provider: CloudProviderKind = .googleDrive
    /// Правило для занятого имени, выбранное при постановке в очередь (облако применяет его при фиксации файла).
    var conflictPolicy: UploadConflictPolicy = .keepBoth
    /// Папки облака (ID цели загрузки), внутри которых окажется файл: сохраняются в `transfer_folders`
    /// для общего прогресса у строки папки в браузере. Из базы не читается.
    var folderIds: [String] = []

    var fraction: Double? {
        guard fileSize > 0 else { return status == .completed ? 1 : nil }
        return min(1, Double(uploadedBytes) / Double(fileSize))
    }

    static func modificationMillis(_ date: Date?) -> Int64 {
        Int64(((date ?? .distantPast).timeIntervalSince1970 * 1000).rounded())
    }

    /// Размер и дата изменения файла на диске (nil — файла нет).
    static func sourceAttributes(_ path: String) -> (size: Int64, modifiedAt: Int64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
        return (size, modificationMillis(attributes[.modificationDate] as? Date))
    }
}

/// Секции экрана «Отправка».
enum UploadSectionKind: String, CaseIterable, Identifiable, Sendable {
    case uploading, paused, queued, waiting, failed, completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uploading: String(localized: "Uploading")
        case .paused: String(localized: "Paused")
        case .queued: String(localized: "Queued")
        case .waiting: String(localized: "Waiting")
        case .failed: String(localized: "Errors")
        case .completed: String(localized: "Completed")
        }
    }

    var statuses: [UploadStatus] {
        switch self {
        case .uploading: [.uploading, .verifying]
        case .paused: [.paused]
        case .queued: [.queued]
        case .waiting: [.waitingForNetwork, .waitingForVolume]
        case .failed: [.failed]
        case .completed: [.completed, .cancelled]
        }
    }

    var newestFirst: Bool { self == .failed || self == .completed }

    var limit: Int {
        switch self {
        case .uploading: 100
        case .waiting, .completed: 500
        case .paused, .queued, .failed: 1_000
        }
    }
}

extension DownloadFilter {
    /// Тот же сегментированный фильтр — для экрана «Отправка».
    var uploadSections: [UploadSectionKind] {
        switch self {
        case .all: UploadSectionKind.allCases
        case .active: [.uploading, .queued, .waiting]
        case .paused: [.paused]
        case .errors: [.failed]
        case .completed: [.completed]
        }
    }
}

struct UploadTotals: Sendable, Equatable {
    var countsByStatus: [UploadStatus: Int] = [:]
    var totalBytes: Int64 = 0
    var uploadedBytes: Int64 = 0
    var pendingCount = 0

    var activeCount: Int { UploadStatus.active.reduce(0) { $0 + (countsByStatus[$1] ?? 0) } }

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(uploadedBytes) / Double(totalBytes))
    }
}

struct UploadSnapshot: Sendable, Equatable {
    var isOnline = true
    var isPaused = false
    var runningCount = 0
    /// Текущий лимит (уменьшается при ограничении запросов от Google).
    var limit = 3
    var userLimit = 3
    var bytesPerSecond: Double = 0
    /// id → подтверждено + отправлено в текущей части.
    var liveProgress: [String: Int64] = [:]
    /// id → скорость отправки файла, байт/с.
    var speeds: [String: Double] = [:]
    /// id → прочитано байт при проверке MD5.
    var verificationProgress: [String: Int64] = [:]
    /// Растёт, когда нужен повторный вход с правом записи.
    var reauthRequests = 0
    var preparing: [String] = []
}

// MARK: - Planning

/// Папка в облаке, в которую отправляются файлы и создаются папки.
struct UploadTarget: Sendable, Hashable {
    let provider: CloudProviderKind
    let id: String
    let name: String
    /// Пространство (общий диск), в котором лежит папка.
    let spaceId: String?
}

/// Что делать с файлами, имя которых уже занято в целевой папке.
enum UploadConflictPolicy: String, Sendable {
    case skip
    /// Новая версия того же файла.
    case replace
    /// Добавить « (1)» к имени.
    case keepBoth = "keep_both"
}

struct UploadEnqueueReport: Sendable, Equatable {
    var title = ""
    var added = 0
    var bytes: Int64 = 0
    var foldersCreated = 0
    var skipped = 0
    var alreadyQueued = 0
    var unreadable: [String] = []

    var message: String {
        var parts: [String] = []
        if added > 0 {
            parts.append(String(localized: "Queued for upload: \(QueueSessionSummary.filesCount(added)), \(Format.bytes(bytes))"))
        } else {
            parts.append(String(localized: "No new files to upload"))
        }
        if foldersCreated > 0 { parts.append(String(localized: "folders created: \(foldersCreated)")) }
        if skipped > 0 { parts.append(String(localized: "existing skipped: \(skipped)")) }
        if alreadyQueued > 0 { parts.append(String(localized: "already queued: \(alreadyQueued)")) }
        if !unreadable.isEmpty { parts.append(String(localized: "unreadable: \(unreadable.count)")) }
        let body = parts.joined(separator: ", ")
        return title.isEmpty ? body : String(localized: "“\(title)”: \(body)")
    }
}
