import Foundation

/// Пауза перед повтором, которую можно прервать досрочно: после пробуждения Mac или возврата сети
/// все ожидающие задачи сразу пробуют снова, а не досиживают паузу до 32–64 с.
actor RetryWaiter {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Ждёт `seconds` или до `wakeAll()`. При отмене задачи бросает CancellationError.
    func sleep(seconds: Double) async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[id] = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    await self?.resume(id)
                }
            }
        } onCancel: {
            Task { await self.resume(id) }
        }
        try Task.checkCancellation()
    }

    /// Разбудить всех ожидающих повтора.
    func wakeAll() {
        let all = waiters
        waiters.removeAll()
        for continuation in all.values { continuation.resume() }
    }

    private func resume(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
