import Foundation

/// Скачивание одного файла: потоково, чанками по 1 МБ в `<file_name>.gdrive.part`, с докачкой через HTTP Range.
/// Каждый поток независим: его ошибка, пауза или отмена не затрагивают остальные.
struct DownloadWorker: Sendable {
    let db: DatabaseManager
    let provider: any CloudProvider
    let scheduler: DownloadScheduler
    let progress: ProgressStore
    let retryWaiter: RetryWaiter

    static let chunkSize = 1_048_576
    static let syncInterval: Int64 = 16 * 1_048_576
    static let maxHTTPRetries = 5
    static let maxRateLimitRetries = 10
    static let rateLimitMaxDelay: Double = 64
    /// Переполнения буфера чаще, чем раз в 64 МБ, означают, что диск устойчиво медленнее сети.
    static let overflowWindow: Int64 = 64 * 1_048_576

    /// Экспоненциальная пауза со случайным разбросом ±50%, чтобы потоки не повторяли запросы синхронно.
    static func jitteredDelay(attempt: Int, cap: Double) -> Double {
        let base = min(cap, pow(2, Double(max(1, attempt))))
        return base * Double.random(in: 0.5...1.5)
    }

    enum Outcome: Sendable {
        /// Финальный файл уже был на диске с нужным размером.
        case completed(Int64)
        /// `.gdrive.part` полностью получен и совпал по размеру; дальше — проверка хеша и переименование.
        case downloaded(Int64)
        case failed(String)
        case waitingForVolume(String)
        /// Квота облака на скачивание файла — повтор через часы, без траты лимита повторов.
        case waitingForQuota(String)
        /// Вход отозван или истёк: задача возвращается в очередь до нового входа (прогресс сохранён).
        case signedOut
        case stopped
    }

    private enum AttemptError: Error {
        case transient(String)
        case rateLimited(String)
        case quota(String)
        case fatal(String)
        case volume(String)
        case unauthorized(String)
        case restart
        /// Поток остановлен из-за переполнения буфера — сразу продолжить через Range с размера `.part`.
        case continueFromDisk
    }

    func run(_ task: DownloadTask) async -> Outcome {
        var retries = task.retryCount
        var rateLimitRetries = 0
        var unauthorizedRefreshes = 0
        var restarts = 0
        var lastContinuationSize: Int64 = -1
        var continuationsWithoutProgress = 0
        // Диск устойчиво медленнее сети (переполнения буфера чаще, чем раз в 64 МБ) —
        // этот файл докачивается через AsyncBytes с системным обратным давлением.
        var frequentOverflows = 0
        var lastOverflowSize: Int64 = -1

        while true {
            if Task.isCancelled { return .stopped }
            do {
                return try await attempt(task, useAsyncBytes: frequentOverflows >= 2)
            } catch AttemptError.fatal(let message) {
                return .failed(message)
            } catch AttemptError.quota(let message) {
                return .waitingForQuota(message)
            } catch AttemptError.volume(let message) {
                return .waitingForVolume(message)
            } catch AttemptError.unauthorized(let token) {
                unauthorizedRefreshes += 1
                guard unauthorizedRefreshes <= 2 else { return .failed(String(localized: "HTTP 401: access denied")) }
                do {
                    try await provider.refreshAuthorization(after: token)
                } catch {
                    if Task.isCancelled { return .stopped }
                    if provider.isSignedOutError(error) { return .signedOut }
                    return .failed(error.localizedDescription)
                }
                continue
            } catch AttemptError.rateLimited(let message) {
                // Лимит запросов облака: регулятор сразу уменьшает число потоков вдвое,
                // а эта задача повторяется после паузы с разбросом.
                await scheduler.reportRateLimit()
                rateLimitRetries += 1
                guard rateLimitRetries <= Self.maxRateLimitRetries else { return .failed(message) }
                let delay = Self.jitteredDelay(attempt: rateLimitRetries, cap: Self.rateLimitMaxDelay)
                db.recordRetry(id: task.id, retryCount: retries + rateLimitRetries,
                               error: String(localized: "\(message) — retrying in \(Int(delay.rounded())) s"))
                do {
                    try await retryWaiter.sleep(seconds: delay)
                } catch {
                    return .stopped
                }
            } catch AttemptError.continueFromDisk {
                // Не ошибка: продолжаем с текущего байта. Защита от цикла без прогресса
                // (например, если сервер перестал поддерживать Range и каждый раз отдаёт файл с начала).
                let size = Self.fileSize(task.partPath) ?? 0
                if lastOverflowSize >= 0, size - lastOverflowSize < Self.overflowWindow { frequentOverflows += 1 }
                lastOverflowSize = size
                if size > lastContinuationSize {
                    continuationsWithoutProgress = 0
                } else {
                    continuationsWithoutProgress += 1
                    guard continuationsWithoutProgress <= 3 else { return .failed(String(localized: "Can’t continue the download: no progress")) }
                }
                lastContinuationSize = size
                continue
            } catch AttemptError.restart {
                restarts += 1
                guard restarts <= 3 else { return .failed(String(localized: "The server doesn’t support resuming (Range)")) }
                continue
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return .stopped
                }
                if case .missing(let message) = PathResolver.volumeState(for: task.targetDirPath) {
                    return .waitingForVolume(message)
                }
                if provider.isSignedOutError(error) { return .signedOut }
                if error is OAuthError { return .failed(error.localizedDescription) }

                let message: String
                let unlimited: Bool
                if case AttemptError.transient(let text) = error {
                    message = text
                    unlimited = false
                } else if CloudNetwork.isTransientError(error) {
                    // Обрывы сети повторяем бесконечно (с паузой до 32 с) — файл докачается с места обрыва.
                    message = error.localizedDescription
                    unlimited = true
                } else {
                    message = error.localizedDescription
                    unlimited = false
                }

                retries += 1
                db.recordRetry(id: task.id, retryCount: retries, error: message)
                if !unlimited && retries > Self.maxHTTPRetries { return .failed(message) }
                let delay = Self.jitteredDelay(attempt: retries, cap: 32)
                do {
                    // Досрочно прерывается после пробуждения Mac или возврата сети.
                    try await retryWaiter.sleep(seconds: delay)
                } catch {
                    return .stopped
                }
            }
        }
    }

    // MARK: - Single attempt

    private func attempt(_ task: DownloadTask, useAsyncBytes: Bool) async throws -> Outcome {
        let fm = FileManager.default
        let dir = task.targetDirPath
        let partPath = task.partPath
        let isExport = task.exportFormat != nil

        // 1. Целевой том доступен?
        if case .missing(let message) = PathResolver.volumeState(for: dir) { throw AttemptError.volume(message) }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw AttemptError.fatal(String(localized: "Couldn’t create folder \(dir): \(error.localizedDescription)"))
        }

        // Запись никогда не идёт по символической ссылке, подложенной вместо файла.
        for path in [partPath, task.finalPath] where PathResolver.isSymlink(path) {
            throw AttemptError.fatal(PathResolver.PathSafetyError.symlink(path).localizedDescription)
        }

        // Файл уже полностью скачан ранее (повторная постановка в очередь).
        if !isExport, !fm.fileExists(atPath: partPath), let existing = Self.fileSize(task.finalPath),
           existing == task.expectedSize {
            return .completed(existing)
        }

        // 2–3. Размер .gdrive.part на диске.
        var localBytes: Int64
        if let size = Self.fileSize(partPath) {
            localBytes = size
        } else {
            guard fm.createFile(atPath: partPath, contents: nil) else {
                throw AttemptError.fatal(String(localized: "No write access: \(dir)"))
            }
            localBytes = 0
        }
        if localBytes > 0, isExport || (task.expectedSize > 0 && localBytes > task.expectedSize) {
            try Self.truncate(partPath)
            localBytes = 0
        }

        if task.expectedSize > 0, let free = PathResolver.availableCapacity(at: dir), free < task.expectedSize - localBytes {
            throw AttemptError.fatal(String(localized: "Not enough disk space: \(Format.bytes(task.expectedSize - localBytes)) needed, \(Format.bytes(free)) available"))
        }
        await scheduler.report(id: task.id, delta: 0, total: localBytes)

        // 4–6. Подписанный провайдером запрос с Range.
        let authorized = try await provider.downloadRequest(for: task, offset: localBytes)
        let request = authorized.request
        let token = authorized.credential

        let stream: any ResponseBodyStream
        let http: HTTPURLResponse
        if useAsyncBytes {
            let (bytes, response) = try await provider.session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw AttemptError.transient(String(localized: "Invalid server response"))
            }
            (stream, http) = (AsyncBytesStream(bytes), httpResponse)
        } else {
            // Экспорт документов нельзя продолжить через Range — для него жёсткий предел буфера не нужен
            // (экспорт невелик: у Google он ограничен 10 МБ).
            (stream, http) = try await DataTaskStream.start(request, session: provider.session, chunkSize: Self.chunkSize,
                                                             hardLimitChunks: isExport ? nil : 8)
        }

        // 7. Разбор HTTP-ответа.
        let handle: FileHandle
        switch http.statusCode {
        case 206:
            guard let opened = FileHandle(forUpdatingAtPath: partPath) else { throw AttemptError.fatal(String(localized: "Couldn’t open \(partPath)")) }
            if let start = Self.contentRangeStart(http.value(forHTTPHeaderField: "Content-Range")), start != localBytes {
                try? opened.close()
                stream.cancel()
                try Self.truncate(partPath)
                throw AttemptError.restart
            }
            try opened.seekToEnd()
            handle = opened
        case 200:
            guard let opened = FileHandle(forUpdatingAtPath: partPath) else { throw AttemptError.fatal(String(localized: "Couldn’t open \(partPath)")) }
            if localBytes > 0 {
                try opened.truncate(atOffset: 0)
                localBytes = 0
                await scheduler.report(id: task.id, delta: 0, total: 0)
            }
            handle = opened
        case 416:
            stream.cancel()
            if task.expectedSize > 0, localBytes >= task.expectedSize {
                return try finalize(task)
            }
            try Self.truncate(partPath)
            throw AttemptError.restart
        default:
            let body = await Self.readBody(stream, limit: 16_384)
            switch provider.downloadFailure(status: http.statusCode, body: body, task: task, credential: token) {
            case .unauthorized(let credential): throw AttemptError.unauthorized(credential)
            case .rateLimited(let message): throw AttemptError.rateLimited(message)
            case .quotaExceeded(let message): throw AttemptError.quota(message)
            case .transient(let message): throw AttemptError.transient(message)
            case .fatal(let message): throw AttemptError.fatal(message)
            }
        }

        // 8. Потоковая запись блоками по 1 МБ (URLSessionDataDelegate с обратным давлением)
        //    и двойной буферизацией: пока один блок пишется на диск, следующий принимается из сети.
        let writer = ChunkWriter(handle: handle, label: task.driveFileId)
        var sinceSync: Int64 = 0
        let written: Int64
        do {
            written = try await ChunkPump.run(stream: stream, writer: writer, startingAt: localBytes,
                                              chunkSize: Self.chunkSize) { delta, total in
                await scheduler.report(id: task.id, delta: delta, total: total)
                sinceSync += delta
                if sinceSync >= Self.syncInterval {
                    try await writer.synchronize()
                    await progress.record(id: task.id, bytes: total)
                    sinceSync = 0
                }
            }
            await writer.close()
        } catch let interrupted as ChunkPump.Interrupted {
            await writer.close()
            await progress.commit(id: task.id, bytes: Self.fileSize(partPath) ?? interrupted.written)
            if case DataTaskStream.StreamError.bufferOverflow = interrupted.underlying {
                throw AttemptError.continueFromDisk
            }
            throw interrupted.underlying
        }
        await progress.commit(id: task.id, bytes: written)

        // 9. Финализация.
        return try finalize(task)
    }

    /// Проверка размера. Сверку хеша и переименование выполняет планировщик вне слота загрузки.
    private func finalize(_ task: DownloadTask) throws -> Outcome {
        let size = Self.fileSize(task.partPath) ?? 0
        if task.exportFormat == nil, task.expectedSize > 0, size != task.expectedSize {
            if size > task.expectedSize { try Self.truncate(task.partPath) }
            throw AttemptError.transient(String(localized: "Size mismatch: received \(size) of \(task.expectedSize) bytes"))
        }
        return .downloaded(size)
    }

    // MARK: - Helpers

    static func fileSize(_ path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) != .typeDirectory else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    private static func truncate(_ path: String) throws {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
    }

    /// `Content-Range: bytes 100-999/1000` → 100
    private static func contentRangeStart(_ header: String?) -> Int64? {
        guard let header, let range = header.split(separator: " ").last,
              let start = range.split(separator: "-").first else { return nil }
        return Int64(start)
    }

    private static func readBody(_ stream: any ResponseBodyStream, limit: Int) async -> Data {
        var data = Data()
        do {
            while data.count < limit, let chunk = try await stream.next(chunkSize: 16_384) {
                data.append(chunk)
            }
        } catch {}
        stream.cancel()
        return data
    }
}
