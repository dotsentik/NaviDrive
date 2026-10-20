import Foundation

/// Единая точка записи прогресса в SQLite: обновления от всех потоков копятся в памяти
/// и сбрасываются одной транзакцией раз в 2 секунды.
actor ProgressStore {
    static let flushInterval: Duration = .seconds(2)

    private let db: DatabaseManager
    private var pending: [String: Int64] = [:]
    private var flushScheduled = false

    init(db: DatabaseManager) {
        self.db = db
    }

    /// Отложенная запись (каждые 16 МБ во время скачивания).
    func record(id: String, bytes: Int64) {
        pending[id] = bytes
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            await self?.flush()
        }
    }

    /// Немедленная запись при остановке/завершении потока.
    func commit(id: String, bytes: Int64) {
        pending[id] = nil
        db.updateProgressBatch([id: bytes])
    }

    func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        db.updateProgressBatch(batch)
    }
}
