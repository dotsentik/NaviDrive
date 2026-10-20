import Foundation

/// Отправка одного файла загрузкой с возобновлением через `CloudProvider`.
///
/// - Файл читается с диска частями (`provider.uploadChunkSize`) через FileHandle — целиком в память не загружается.
/// - После каждой подтверждённой части `uploaded_bytes` сохраняется в SQLite.
/// - При возобновлении (обрыв сети, ошибка, перезапуск) смещение берётся у сервера
///   (`provider.uploadState`), а не из локального счётчика.
struct UploadWorker: Sendable {
    let db: DatabaseManager
    let provider: any CloudProvider
    let scheduler: UploadScheduler
    let retryWaiter: RetryWaiter

    static let maxRetries = 8
    static let maxRateLimitRetries = 10

    enum Outcome: Sendable {
        case uploaded(fileId: String, hash: String?, size: Int64)
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
        case sessionExpired
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
            } catch CloudTransferError.unauthorized(let token) {
                unauthorizedRefreshes += 1
                guard unauthorizedRefreshes <= 2 else { return .failed(String(localized: "HTTP 401: access denied"), nil) }
                do {
                    try await provider.refreshAuthorization(after: token)
                } catch {
                    if Task.isCancelled { return .stopped }
                    if provider.isSignedOutError(error) { return .signedOut }
                    return .failed(error.localizedDescription, nil)
                }
                continue
            } catch CloudTransferError.rateLimited(let message) {
                await scheduler.reportRateLimit()
                rateLimitRetries += 1
                guard rateLimitRetries <= Self.maxRateLimitRetries else { return .failed(message, nil) }
                let delay = DownloadWorker.jitteredDelay(attempt: rateLimitRetries, cap: 64)
                db.recordUploadRetry(id: task.id, retryCount: retries + rateLimitRetries,
                                     error: String(localized: "\(message) — retrying in \(Int(delay.rounded())) s"))
                do { try await retryWaiter.sleep(seconds: delay) } catch { return .stopped }
            } catch CloudTransferError.fatal(let message), CloudTransferError.quotaExceeded(let message) {
                return .failed(message, nil)
            } catch CloudAPIError.insufficientScope {
                return .needsReauth
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return .stopped
                }
                if case .missing(let message) = PathResolver.volumeState(for: task.localPath) {
                    return .waitingForVolume(message)
                }
                if provider.isSignedOutError(error) { return .signedOut }
                if error is OAuthError { return .failed(error.localizedDescription, nil) }

                // Часть подтверждена — счётчик повторов начинается заново.
                if task.uploadedBytes > confirmedBefore { retries = 0 }
                let networkDrop = CloudNetwork.isTransientError(error)
                let message: String
                if case CloudTransferError.transient(let text) = error {
                    message = text
                } else if case AttemptError.transient(let text) = error {
                    message = text
                } else if networkDrop || (error as? CloudAPIError)?.isTransient == true {
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

        // 1. Сессия: новая, если её нет или она устарела; иначе — спросить у сервера, сколько он принял.
        var offset: Int64 = 0
        let sessionAge = task.sessionCreatedAt.map { Date().timeIntervalSince1970 - TimeInterval($0) } ?? .infinity
        if let session = task.sessionURI, sessionAge < provider.uploadSessionLifetime {
            switch try await provider.uploadState(session: session, task: task) {
            case .incomplete(let next):
                offset = next
            case .complete(let fileId, let hash):
                return .uploaded(fileId: fileId, hash: hash, size: task.fileSize)
            case .expired:
                throw AttemptError.sessionExpired
            }
        } else {
            let session = try await provider.startUploadSession(for: task)
            let created = Int64(Date().timeIntervalSince1970)
            db.saveUploadSession(id: task.id, uri: session, createdAt: created)
            task.sessionURI = session
            task.sessionCreatedAt = created
        }
        guard let session = task.sessionURI else { throw CloudAPIError.uploadSessionMissing }
        record(&task, confirmed: offset)

        // Пустой файл: один запрос без тела.
        if task.fileSize == 0 {
            if case .complete(let fileId, let hash) = try await provider.uploadState(session: session, task: task) {
                return .uploaded(fileId: fileId, hash: hash, size: 0)
            }
            throw AttemptError.transient(String(localized: "The server didn’t confirm the empty file upload"))
        }

        // 2. Части фиксированного размера, потоковое чтение через FileHandle.
        guard let handle = FileHandle(forReadingAtPath: task.localPath) else {
            if case .missing(let message) = PathResolver.volumeState(for: task.localPath) { throw AttemptError.volume(message) }
            throw AttemptError.fatal(String(localized: "Can’t open file “\(task.fileName)”"), nil)
        }
        defer { try? handle.close() }

        while offset < task.fileSize {
            try Task.checkCancellation()
            try checkSource(task)
            let length = min(provider.uploadChunkSize, task.fileSize - offset)
            let data: Data
            do {
                try handle.seek(toOffset: UInt64(offset))
                data = try handle.read(upToCount: Int(length)) ?? Data()
            } catch {
                if case .missing(let message) = PathResolver.volumeState(for: task.localPath) { throw AttemptError.volume(message) }
                throw AttemptError.fatal(String(localized: "File read error: \(error.localizedDescription)"), nil)
            }
            guard Int64(data.count) == length else { throw AttemptError.fatal(Self.sourceChangedMessage, .sourceChanged) }

            let delegate = UploadProgressDelegate(id: task.id, base: offset, scheduler: scheduler)
            switch try await provider.uploadChunk(data, at: offset, session: session, task: task, delegate: delegate) {
            case .incomplete(let next):
                // Верим серверу: он мог принять меньше, чем мы отправили.
                offset = next
                record(&task, confirmed: offset)
            case .complete(let fileId, let hash):
                try checkSource(task)
                return .uploaded(fileId: fileId, hash: hash, size: task.fileSize)
            case .expired:
                throw AttemptError.sessionExpired
            }
        }
        // Все байты подтверждены, но финальный ответ не получен — спросим состояние.
        switch try await provider.uploadState(session: session, task: task) {
        case .complete(let fileId, let hash): return .uploaded(fileId: fileId, hash: hash, size: task.fileSize)
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
