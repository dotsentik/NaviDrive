import Foundation

/// Отправка одного файла через resumable upload Drive API.
///
/// - Файл читается с диска частями по 32 МБ через FileHandle — целиком в память не загружается.
/// - После каждой подтверждённой части `uploaded_bytes` сохраняется в SQLite.
/// - При возобновлении (обрыв сети, ошибка, перезапуск) смещение берётся у сервера:
///   PUT с пустым телом и `Content-Range: bytes */<размер>` → 308 + Range, а не локальный счётчик.
struct UploadWorker: Sendable {
    let db: DatabaseManager
    let api: GoogleDriveAPIClient
    let scheduler: UploadScheduler
    let retryWaiter: RetryWaiter

    /// 32 МБ — кратно 256 КБ, как требует Drive API для всех частей, кроме последней.
    static let chunkSize: Int64 = 32 * 1_048_576
    /// Google держит сессию около недели; старше 6 дней — новая сессия.
    static let sessionLifetime: TimeInterval = 6 * 24 * 3600
    static let maxRetries = 8
    static let maxRateLimitRetries = 10

    enum Outcome: Sendable {
        case uploaded(fileId: String, md5: String?, size: Int64)
        case failed(String, UploadErrorKind?)
        case waitingForVolume(String)
        /// Вход без права записи — задача остаётся в очереди до повторного входа.
        case needsReauth
        /// Вход отозван или истёк: задача возвращается в очередь до нового входа (сессия сохранена).
        case signedOut
        case stopped
    }

    private enum AttemptError: Error {
        case fatal(String, UploadErrorKind?)
        case volume(String)
        case transient(String)
        case rateLimited(String)
        case sessionExpired
        case unauthorized(String)
    }

    static var sourceChangedMessage: String { String(localized: "The file changed during upload") }

    func run(_ initial: UploadTask) async -> Outcome {
        var task = initial
        var retries = task.retryCount
        var rateLimitRetries = 0
        var unauthorizedRefreshes = 0
        var expiredSessions = 0

        while true {
            if Task.isCancelled { return .stopped }
            let confirmedBefore = task.uploadedBytes
            do {
                return try await attempt(&task)
            } catch AttemptError.fatal(let message, let kind) {
                return .failed(message, kind)
            } catch AttemptError.volume(let message) {
                return .waitingForVolume(message)
            } catch AttemptError.sessionExpired {
                // Сессия истекла (404/410): новая сессия с нуля. Защита от бесконечного цикла.
                expiredSessions += 1
                guard expiredSessions <= 3 else { return .failed(String(localized: "Google Drive doesn’t accept the upload session"), nil) }
                db.resetUploadSession(id: task.id)
                task.sessionURI = nil
                task.sessionCreatedAt = nil
                task.uploadedBytes = 0
                continue
            } catch AttemptError.unauthorized(let token) {
                unauthorizedRefreshes += 1
                guard unauthorizedRefreshes <= 2 else { return .failed(String(localized: "HTTP 401: access denied"), nil) }
                do {
                    _ = try await api.tokenManager.refreshAfterUnauthorized(failedToken: token)
                } catch {
                    if Task.isCancelled { return .stopped }
                    if (error as? OAuthError)?.meansSignedOut == true { return .signedOut }
                    return .failed(error.localizedDescription, nil)
                }
                continue
            } catch AttemptError.rateLimited(let message) {
                await scheduler.reportRateLimit()
                rateLimitRetries += 1
                guard rateLimitRetries <= Self.maxRateLimitRetries else { return .failed(message, nil) }
                let delay = DownloadWorker.jitteredDelay(attempt: rateLimitRetries, cap: 64)
                db.recordUploadRetry(id: task.id, retryCount: retries + rateLimitRetries,
                                     error: String(localized: "\(message) — retrying in \(Int(delay.rounded())) s"))
                do { try await retryWaiter.sleep(seconds: delay) } catch { return .stopped }
            } catch DriveAPIError.insufficientScope {
                return .needsReauth
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return .stopped
                }
                if case .missing(let message) = PathResolver.volumeState(for: task.localPath) {
                    return .waitingForVolume(message)
                }
                if let error = error as? OAuthError {
                    return error.meansSignedOut ? .signedOut : .failed(error.localizedDescription, nil)
                }

                // Часть подтверждена — счётчик повторов начинается заново.
                if task.uploadedBytes > confirmedBefore { retries = 0 }
                let networkDrop = GoogleDriveAPIClient.isTransientNetworkError(error)
                let message: String
                if case AttemptError.transient(let text) = error {
                    message = text
                } else if networkDrop || (error as? DriveAPIError)?.isTransient == true {
                    message = error.localizedDescription
                } else {
                    return .failed(error.localizedDescription, nil)
                }
                retries += 1
                // Обрывы сети повторяются без ограничения: файл продолжится с подтверждённого байта.
                guard networkDrop || retries <= Self.maxRetries else { return .failed(message, nil) }
                let delay = DownloadWorker.jitteredDelay(attempt: min(retries, 6), cap: 64)
                db.recordUploadRetry(id: task.id, retryCount: retries,
                                     error: String(localized: "\(message) — retrying in \(Int(delay.rounded())) s"))
                do { try await retryWaiter.sleep(seconds: delay) } catch { return .stopped }
            }
        }
    }

    // MARK: - One attempt

    private func attempt(_ task: inout UploadTask) async throws -> Outcome {
        try checkSource(task)

        // 1. Сессия: новая, если её нет или она старше 6 дней; иначе — спросить у сервера, сколько он принял.
        var offset: Int64 = 0
        let sessionAge = task.sessionCreatedAt.map { Date().timeIntervalSince1970 - TimeInterval($0) } ?? .infinity
        if let uri = task.sessionURI.flatMap(URL.init(string:)), sessionAge < Self.sessionLifetime {
            switch try await send(uri, range: "bytes */\(task.fileSize)", body: nil, task: task, base: 0) {
            case .incomplete(let next):
                offset = next
            case .complete(let fileId, let md5):
                return .uploaded(fileId: fileId, md5: md5, size: task.fileSize)
            case .expired:
                throw AttemptError.sessionExpired
            }
        } else {
            let uri = try await api.startUploadSession(name: task.fileName, parentId: task.parentDriveId,
                                                       size: task.fileSize, replaceFileId: task.replaceFileId)
            let created = Int64(Date().timeIntervalSince1970)
            db.saveUploadSession(id: task.id, uri: uri.absoluteString, createdAt: created)
            task.sessionURI = uri.absoluteString
            task.sessionCreatedAt = created
        }
        guard let uri = task.sessionURI.flatMap(URL.init(string:)) else { throw DriveAPIError.uploadSessionMissing }
        record(&task, confirmed: offset)

        // Пустой файл: один запрос без тела.
        if task.fileSize == 0 {
            if case .complete(let fileId, let md5) = try await send(uri, range: "bytes */0", body: nil, task: task, base: 0) {
                return .uploaded(fileId: fileId, md5: md5, size: 0)
            }
            throw AttemptError.transient(String(localized: "The server didn’t confirm the empty file upload"))
        }

        // 2. Части по 32 МБ, потоковое чтение через FileHandle.
        guard let handle = FileHandle(forReadingAtPath: task.localPath) else {
            if case .missing(let message) = PathResolver.volumeState(for: task.localPath) { throw AttemptError.volume(message) }
            throw AttemptError.fatal(String(localized: "Can’t open file “\(task.fileName)”"), nil)
        }
        defer { try? handle.close() }

        while offset < task.fileSize {
            try Task.checkCancellation()
            try checkSource(task)
            let length = min(Self.chunkSize, task.fileSize - offset)
            let data: Data
            do {
                try handle.seek(toOffset: UInt64(offset))
                data = try handle.read(upToCount: Int(length)) ?? Data()
            } catch {
                if case .missing(let message) = PathResolver.volumeState(for: task.localPath) { throw AttemptError.volume(message) }
                throw AttemptError.fatal(String(localized: "File read error: \(error.localizedDescription)"), nil)
            }
            guard Int64(data.count) == length else { throw AttemptError.fatal(Self.sourceChangedMessage, .sourceChanged) }

            let range = "bytes \(offset)-\(offset + length - 1)/\(task.fileSize)"
            switch try await send(uri, range: range, body: data, task: task, base: offset) {
            case .incomplete(let next):
                // Верим серверу: он мог принять меньше, чем мы отправили.
                offset = next
                record(&task, confirmed: offset)
            case .complete(let fileId, let md5):
                try checkSource(task)
                return .uploaded(fileId: fileId, md5: md5, size: task.fileSize)
            case .expired:
                throw AttemptError.sessionExpired
            }
        }
        // Все байты подтверждены, но финальный ответ не получен — спросим состояние.
        switch try await send(uri, range: "bytes */\(task.fileSize)", body: nil, task: task, base: offset) {
        case .complete(let fileId, let md5): return .uploaded(fileId: fileId, md5: md5, size: task.fileSize)
        case .expired: throw AttemptError.sessionExpired
        case .incomplete: throw AttemptError.transient(String(localized: "The server didn’t confirm the upload finished"))
        }
    }

    private func record(_ task: inout UploadTask, confirmed: Int64) {
        task.uploadedBytes = confirmed
        db.setUploadedBytes(id: task.id, bytes: confirmed)
        let id = task.id
        Task { await scheduler.report(id: id, bytes: confirmed, sentDelta: 0) }
    }

    /// Исходный файл на месте и не изменился (размер и дата изменения).
    private func checkSource(_ task: UploadTask) throws {
        if case .missing(let message) = PathResolver.volumeState(for: task.localPath) { throw AttemptError.volume(message) }
        guard let current = UploadTask.sourceAttributes(task.localPath) else {
            throw AttemptError.fatal(String(localized: "Source file not found: \(PathResolver.displayPath(task.localPath))"), nil)
        }
        guard current.size == task.fileSize, current.modifiedAt == task.localModifiedAt else {
            throw AttemptError.fatal(Self.sourceChangedMessage, .sourceChanged)
        }
    }

    /// Один запрос к session URI и разбор ответа.
    private func send(_ uri: URL, range: String, body: Data?, task: UploadTask, base: Int64) async throws
        -> GoogleDriveAPIClient.ResumableState {
        let delegate = UploadProgressDelegate(id: task.id, base: base, scheduler: scheduler)
        let (data, http, token) = try await api.sessionRequest(uri, contentRange: range, body: body,
                                                               delegate: body == nil ? nil : delegate)
        if let state = GoogleDriveAPIClient.resumableState(data, http) { return state }
        let message = GoogleDriveAPIClient.errorMessage(from: data)
        switch http.statusCode {
        case 401:
            throw AttemptError.unauthorized(token)
        case 403 where GoogleDriveAPIClient.isInsufficientScope(status: 403, data: data):
            throw DriveAPIError.insufficientScope
        case 403 where !Set(GoogleDriveAPIClient.errorReasons(from: data)).isDisjoint(with: DownloadWorker.rateLimitReasons):
            throw AttemptError.rateLimited(String(localized: "Google rate-limited requests (HTTP 403)"))
        case 429:
            throw AttemptError.rateLimited(String(localized: "Google rate-limited requests (HTTP 429)"))
        case 403 where GoogleDriveAPIClient.errorReasons(from: data).contains("storageQuotaExceeded"):
            throw AttemptError.fatal(String(localized: "Google Drive is out of storage"), nil)
        case 403:
            throw AttemptError.fatal(String(localized: "You don’t have permission to upload to this folder"), nil)
        case 500, 502, 503, 504:
            throw AttemptError.transient(String(localized: "Google Drive server is temporarily unavailable (HTTP \(http.statusCode))"))
        default:
            throw AttemptError.fatal("Google Drive API: HTTP \(http.statusCode) — \(message)", nil)
        }
    }
}

/// Живой прогресс отправки части: не чаще 4 раз в секунду, чтобы не заваливать актор сообщениями.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let id: String
    private let base: Int64
    private let scheduler: UploadScheduler
    private let lock = NSLock()
    private var reported: Int64 = 0
    private var lastTime: TimeInterval = 0

    init(id: String, base: Int64, scheduler: UploadScheduler) {
        self.id = id
        self.base = base
        self.scheduler = scheduler
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        let delta = totalBytesSent - reported
        let due = now - lastTime >= 0.25 || totalBytesSent == totalBytesExpectedToSend
        if due {
            reported = totalBytesSent
            lastTime = now
        }
        lock.unlock()
        guard due, delta > 0 else { return }
        let id = id, scheduler = scheduler, live = base + totalBytesSent
        Task { await scheduler.report(id: id, bytes: live, sentDelta: delta) }
    }
}
