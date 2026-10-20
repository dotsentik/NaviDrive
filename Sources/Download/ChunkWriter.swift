import Foundation

/// Запись чанков в `.gdrive.part` на отдельной последовательной очереди, чтобы блокирующий
/// дисковый ввод-вывод (особенно fsync на внешнем SSD) не занимал потоки пула Swift Concurrency.
/// Все операции с FileHandle выполняются строго по порядку на `queue`.
final class ChunkWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue: DispatchQueue
    /// Меняется только на `queue`.
    private var failed = false

    /// Была ли хотя бы одна неудачная операция (после неё запись прекращается).
    var hasFailed: Bool { queue.sync { failed } }

    init(handle: FileHandle, label: String) {
        self.handle = handle
        self.queue = DispatchQueue(label: "com.navidrive.writer.\(label)", qos: .utility)
    }

    func write(_ chunk: Data) async throws {
        try await perform { handle in try handle.write(contentsOf: chunk) }
    }

    func synchronize() async throws {
        try await perform { handle in try handle.synchronize() }
    }

    /// Закрывает файл всегда, даже после ошибки записи (чтобы не утекал дескриптор).
    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                try? self.handle.close()
                continuation.resume()
            }
        }
    }

    private func perform(_ operation: @escaping @Sendable (FileHandle) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.failed else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                    return
                }
                do {
                    try operation(self.handle)
                    continuation.resume()
                } catch {
                    self.failed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
