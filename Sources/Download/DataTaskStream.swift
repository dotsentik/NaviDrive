import Foundation

/// Источник тела HTTP-ответа блоками.
protocol ResponseBodyStream: AnyObject, Sendable {
    /// Следующий блок ровно `chunkSize` байт (последний — меньше). nil — ответ закончился.
    func next(chunkSize: Int) async throws -> Data?
    /// Уже полученные, но не выданные байты (дописываются в `.gdrive.part` при обрыве).
    func drainBuffered() -> Data
    func cancel()
}

/// Запасной режим для медленных дисков: `URLSession.AsyncBytes` с надёжным обратным давлением
/// (системный механизм удерживает память на уровне десятков мегабайт), но побайтовое чтение
/// ограничено примерно 420 МБ/с на ядро — это всё равно выше скорости любого HDD.
final class AsyncBytesStream: ResponseBodyStream, @unchecked Sendable {
    private let bytes: URLSession.AsyncBytes
    /// Используется только из одной задачи-потребителя (ChunkPump).
    private var iterator: URLSession.AsyncBytes.AsyncIterator

    init(_ bytes: URLSession.AsyncBytes) {
        self.bytes = bytes
        self.iterator = bytes.makeAsyncIterator()
    }

    func next(chunkSize: Int) async throws -> Data? {
        var buffer = [UInt8]()
        buffer.reserveCapacity(chunkSize)
        var it = iterator
        defer { iterator = it }
        while buffer.count < chunkSize, let byte = try await it.next() {
            buffer.append(byte)
        }
        return buffer.isEmpty ? nil : Data(buffer)
    }

    func drainBuffered() -> Data { Data() }

    func cancel() { bytes.task.cancel() }
}

/// Тело HTTP-ответа блоками (URLSessionDataDelegate `didReceive data`) с обратным давлением.
///
/// Полученные данные копятся во внутреннем буфере. Когда в нём набирается `highWaterMark`
/// (2 чанка), задача URLSession приостанавливается (`suspend()`) и возобновляется, когда
/// потребитель забрал данные и в буфере осталось не больше `lowWaterMark` (1 чанк).
///
/// Страховка: на практике после первого цикла suspend/resume URLSession может продолжать
/// читать сокет, хотя задача числится приостановленной (замерено на macOS 27: гигабайты данных
/// при `state == .suspended`). Поэтому есть жёсткий предел `hardLimit`: при его превышении
/// задача отменяется с `StreamError.bufferOverflow`, всё полученное отдаётся потребителю,
/// а загрузчик сразу продолжает с этого байта через Range. Память ограничена в любом случае.
final class DataTaskStream: NSObject, URLSessionDataDelegate, ResponseBodyStream, @unchecked Sendable {
    enum StreamError: Error {
        /// Буфер превысил жёсткий предел — продолжить через Range с текущего байта.
        case bufferOverflow
    }

    private let lock = NSLock()
    private let highWaterMark: Int
    private let lowWaterMark: Int
    private let hardLimit: Int?

    // Всё ниже меняется только под lock.
    private var task: URLSessionDataTask?
    /// Полученные куски в порядке прихода (очередь без сдвига больших буферов) и их суммарный размер.
    private var pieces: [Data] = []
    private var bufferedCount = 0
    private var isSuspended = false
    private var isComplete = false
    private var isCancelled = false
    private var isOverflowed = false
    private var completionError: Error?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var dataContinuation: CheckedContinuation<Void, Never>?

    private init(chunkSize: Int, hardLimitChunks: Int?) {
        self.highWaterMark = 2 * chunkSize
        self.lowWaterMark = chunkSize
        self.hardLimit = hardLimitChunks.map { $0 * chunkSize }
    }

    /// Отправляет запрос и ждёт заголовков ответа.
    /// - Parameter hardLimitChunks: жёсткий предел буфера в чанках; nil — без предела
    ///   (для ответов, которые нельзя продолжить через Range, например экспорта Google Docs).
    static func start(_ request: URLRequest, session: URLSession, chunkSize: Int,
                      hardLimitChunks: Int? = 8) async throws -> (DataTaskStream, HTTPURLResponse) {
        let stream = DataTaskStream(chunkSize: chunkSize, hardLimitChunks: hardLimitChunks)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                let task = session.dataTask(with: request)
                task.delegate = stream
                let cancelled: Bool = stream.lock.withLock {
                    stream.responseContinuation = continuation
                    stream.task = task
                    return stream.isCancelled
                }
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: {
            stream.cancel()
        }
        return (stream, response)
    }

    /// Следующий блок ровно `chunkSize` байт (последний — меньше). nil — ответ закончился.
    func next(chunkSize: Int) async throws -> Data? {
        while true {
            enum Step { case chunk(Data), finished(Error?), wait }
            let step: Step = lock.withLock {
                if bufferedCount >= chunkSize || (isComplete && bufferedCount > 0) {
                    let chunk = takeLocked(min(chunkSize, bufferedCount))
                    resumeIfDrainedLocked()
                    return .chunk(chunk)
                }
                if isComplete { return .finished(completionError) }
                resumeIfDrainedLocked()
                return .wait
            }

            switch step {
            case .chunk(let data):
                return data
            case .finished(let error):
                if let error { throw error }
                return nil
            case .wait:
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let ready: Bool = lock.withLock {
                            if bufferedCount >= chunkSize || isComplete { return true }
                            dataContinuation = continuation
                            return false
                        }
                        if ready { continuation.resume() }
                    }
                } onCancel: {
                    self.cancel()
                }
                try Task.checkCancellation()
            }
        }
    }

    /// Уже полученные, но ещё не выданные байты — чтобы при обрыве дописать их в `.gdrive.part`.
    func drainBuffered() -> Data {
        lock.withLock { takeLocked(bufferedCount) }
    }

    func cancel() {
        let task: URLSessionDataTask? = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    /// Забрать из начала очереди ровно `count` байт одним непрерывным блоком (вызывается под lock).
    private func takeLocked(_ count: Int) -> Data {
        var chunk = Data(capacity: count)
        var needed = count
        var consumed = 0
        while needed > 0, consumed < pieces.count {
            let piece = pieces[consumed]
            if piece.count <= needed {
                chunk.append(piece)
                needed -= piece.count
                consumed += 1
            } else {
                let split = piece.startIndex + needed
                chunk.append(piece.subdata(in: piece.startIndex..<split))
                pieces[consumed] = piece.subdata(in: split..<piece.endIndex)
                needed = 0
            }
        }
        pieces.removeFirst(consumed)
        bufferedCount -= chunk.count
        return chunk
    }

    /// Возобновить приостановленную задачу, если буфер опустел до нижней границы.
    /// Вызывается под lock: флаг `isSuspended` и вызовы suspend()/resume() меняются строго вместе,
    /// иначе задача может остаться запущенной с флагом «приостановлена», и буфер будет расти без предела.
    private func resumeIfDrainedLocked() {
        guard isSuspended, bufferedCount <= lowWaterMark, !isComplete else { return }
        isSuspended = false
        task?.resume()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let continuation = lock.withLock {
            defer { responseContinuation = nil }
            return responseContinuation
        }
        if let http = response as? HTTPURLResponse {
            continuation?.resume(returning: http)
            completionHandler(.allow)
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            pieces.append(data)
            bufferedCount += data.count
            if bufferedCount >= highWaterMark, !isSuspended {
                isSuspended = true
                dataTask.suspend()
            }
            if let hardLimit, bufferedCount > hardLimit, !isOverflowed, !isComplete {
                isOverflowed = true
                dataTask.cancel()
            }
            defer { dataContinuation = nil }
            return dataContinuation
        }
        continuation?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (response, data) = lock.withLock {
            isComplete = true
            completionError = isOverflowed && !isCancelled ? StreamError.bufferOverflow : error
            defer {
                responseContinuation = nil
                dataContinuation = nil
            }
            return (responseContinuation, dataContinuation)
        }
        response?.resume(throwing: error ?? URLError(.badServerResponse))
        data?.resume()
    }
}

/// Перекачка тела ответа в файл: блоки по 1 МБ строго подряд, двойной буфер
/// (пока один блок пишется на диск, следующий принимается из сети) — не больше 2 чанков на поток.
enum ChunkPump {
    /// Перекачка прервана; `written` — байты, гарантированно записанные в файл подряд.
    struct Interrupted: Error {
        let written: Int64
        let underlying: Error
    }

    /// - Parameters:
    ///   - offset: сколько байт уже было в файле (докачка через Range).
    ///   - onWritten: вызывается после записи каждого блока (`delta`, `total`).
    /// - Returns: итоговый размер записанных данных.
    static func run(stream: any ResponseBodyStream, writer: ChunkWriter, startingAt offset: Int64, chunkSize: Int,
                    onWritten: (_ delta: Int64, _ total: Int64) async throws -> Void) async throws -> Int64 {
        var written = offset
        var pendingWrite: Task<Void, Error>?
        var pendingBytes: Int64 = 0
        /// Блок, уже полученный из сети, но ещё не отданный на запись.
        var heldChunk: Data?
        do {
            while true {
                // Двойной буфер: следующий блок читается из сети, пока предыдущий пишется на диск.
                let next = try await stream.next(chunkSize: chunkSize)
                heldChunk = next
                if let previous = pendingWrite {
                    try await previous.value
                    pendingWrite = nil
                    written += pendingBytes
                    try await onWritten(pendingBytes, written)
                }
                try Task.checkCancellation()
                guard let chunk = next else { break }
                heldChunk = nil
                pendingBytes = Int64(chunk.count)
                pendingWrite = Task { try await writer.write(chunk) }
            }
            try await writer.synchronize()
            return written
        } catch {
            // Сохраняем всё полученное: дожидаемся текущей записи, затем дописываем удержанный блок
            // и остаток буфера. Если запись на диск хоть раз не удалась, дописывать нельзя —
            // появится дыра или дубль, а .gdrive.part должен оставаться корректным для Range.
            var contiguous = true
            if let previous = pendingWrite {
                if (try? await previous.value) != nil { written += pendingBytes } else { contiguous = false }
            }
            stream.cancel()
            if contiguous, !writer.hasFailed {
                var rest = heldChunk ?? Data()
                rest.append(stream.drainBuffered())
                if !rest.isEmpty, (try? await writer.write(rest)) != nil {
                    written += Int64(rest.count)
                }
            }
            try? await writer.synchronize()
            throw Interrupted(written: written, underlying: error)
        }
    }
}
