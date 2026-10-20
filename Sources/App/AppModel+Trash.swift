import Foundation
import SwiftUI

/// Объект, который не удалось переместить в корзину, и причина.
struct TrashFailure: Equatable, Sendable {
    let name: String
    let reason: String
}

/// Перемещение в корзину для карточки статуса: идёт (не меньше 1,5 с, чтобы было видно) →
/// «В корзину перемещено …» (~3 с, у Google — «Отменить») → обычный вид.
struct TrashOperation: Equatable, Sendable {
    let id: Int
    let provider: CloudProviderKind
    /// Папка, из которой удаляем (nil — корень).
    let location: String?
    let total: Int
    let firstName: String
    let startedAt: Date
    var processed = 0
    var trashed: [CloudItem] = []
    var failures: [TrashFailure] = []
    var finishedAt: Date?
    var undone = false

    static let minimumVisible: TimeInterval = 1.5
    static let doneVisible: TimeInterval = 3

    /// До какого момента показывается «идёт перемещение»: не раньше 1,5 с от начала.
    var runningUntil: Date? { finishedAt.map { max($0, startedAt.addingTimeInterval(Self.minimumVisible)) } }

    func isRunning(at now: Date) -> Bool { runningUntil.map { now < $0 } ?? true }

    func showsDone(at now: Date) -> Bool {
        guard let end = runningUntil, !trashed.isEmpty, !undone else { return false }
        return now >= end && now < end.addingTimeInterval(Self.doneVisible)
    }

    /// Всё показано — пора к обычному виду.
    func isOver(at now: Date) -> Bool {
        guard let end = runningUntil else { return false }
        return trashed.isEmpty || undone ? now >= end : now >= end.addingTimeInterval(Self.doneVisible)
    }
}

extension AppModel {
    /// В корзину (окончательное удаление не используется): Google — files.update trashed=true,
    /// Dropbox — delete_v2 (удалённое восстанавливается на сайте Dropbox). Ход и итог — в карточке статуса.
    /// Возвращает id перемещённых в корзину.
    func trash(_ items: [CloudItem], location: String? = nil) async -> Set<String> {
        guard let first = items.first else { return [] }
        guard await ensureWriteAccess(first.provider) else { return [] }
        trashCounter += 1
        let id = trashCounter
        trashOperation = TrashOperation(id: id, provider: first.provider, location: location, total: items.count,
                                        firstName: first.name, startedAt: Date())
        trashFailures = nil
        withAnimation(.easeInOut(duration: 0.4)) { trashPulseActive = true }
        rebuildStatusFeed()

        var trashed = Set<String>()
        for (index, item) in items.enumerated() {
            do {
                try await providers.provider(for: item.provider).trash(item)
                trashed.insert(item.id)
                updateTrash(id) { $0.trashed.append(item) }
            } catch is CancellationError {
                break
            } catch {
                let reason = Self.trashFailureReason(error)
                if case CloudAPIError.insufficientScope = error {
                    // Без права записи не пройдут и остальные: окно повторного входа, остаток — с той же причиной.
                    showReauthPrompt = true
                    let cloud = item.provider
                    Task { await uploadScheduler?.requireReauth(cloud) }
                    updateTrash(id) { operation in
                        operation.failures += items[index...].map { TrashFailure(name: $0.name, reason: reason) }
                        operation.processed = operation.total
                    }
                    break
                }
                updateTrash(id) { $0.failures.append(TrashFailure(name: item.name, reason: reason)) }
            }
            updateTrash(id) { $0.processed += 1 }
        }
        updateTrash(id) { $0.finishedAt = Date() }
        if let operation = trashOperation, operation.id == id, !operation.failures.isEmpty { trashFailures = operation }
        rebuildStatusFeed()
        return trashed
    }

    private func updateTrash(_ id: Int, _ change: (inout TrashOperation) -> Void) {
        guard var operation = trashOperation, operation.id == id else { return }
        change(&operation)
        trashOperation = operation
    }

    static func trashFailureReason(_ error: Error) -> String {
        switch error {
        case CloudAPIError.http(403, _, _):
            String(localized: "No permission")
        case CloudAPIError.http(404, _, _):
            String(localized: "Already deleted or not found")
        case CloudAPIError.insufficientScope:
            String(localized: "Sign in again to allow changes")
        case let urlError as URLError where CloudNetwork.isTransientError(urlError):
            String(localized: "No connection")
        default:
            error.localizedDescription
        }
    }

    /// «Отменить» в сообщении «В корзину перемещено …» (Google): files.update trashed=false для всех перемещённых.
    func undoTrash() {
        guard let operation = trashOperation, !operation.undone, !operation.trashed.isEmpty,
              let provider = providers[operation.provider], provider.canUntrash else { return }
        updateTrash(operation.id) { $0.undone = true }
        rebuildStatusFeed()
        let items = operation.trashed
        Task {
            var failures: [TrashFailure] = []
            for item in items {
                do {
                    try await provider.untrash(item)
                } catch {
                    failures.append(TrashFailure(name: item.name, reason: Self.trashFailureReason(error)))
                }
            }
            browserListingStaleToken += 1
            if !failures.isEmpty {
                errorMessage = Self.failureList(String(localized: "Couldn’t restore \(failures.count) of \(items.count) from Trash:"),
                                                failures)
            }
        }
    }

    /// Клик по красному сообщению: список с причинами; сообщение после этого убирается.
    func showTrashFailures() {
        guard let operation = trashFailures else { return }
        trashFailures = nil
        errorMessage = Self.failureList(
            String(localized: "Couldn’t move \(operation.failures.count) of \(operation.total) to Trash:"), operation.failures)
        rebuildStatusFeed()
    }

    private static func failureList(_ header: String, _ failures: [TrashFailure]) -> String {
        let shown = failures.prefix(20).map { "• \($0.name) — \($0.reason)" }
        var lines = [header] + shown
        if failures.count > shown.count { lines.append(String(localized: "…and \(failures.count - shown.count) more")) }
        return lines.joined(separator: "\n")
    }

    /// Вызывается из `refresh`: true — показ перемещения закончился, пора одним переходом к обычному виду.
    func updateTrashActivity(now: Date = Date()) -> Bool {
        guard let operation = trashOperation, operation.isOver(at: now) else { return false }
        trashOperation = nil
        return trashPulseActive
    }

    /// Сообщения карточки о корзине: идёт перемещение или «В корзину перемещено …».
    func trashMessages(now: Date) -> [StatusMessage] {
        guard let operation = trashOperation else { return [] }
        let cloud = operation.provider
        let place = operation.location.map { String(localized: "\(cloud.displayName) · folder \($0)") } ?? cloud.displayName
        if operation.isRunning(at: now) {
            let title = operation.total == 1
                ? String(localized: "Moving to Trash: \(operation.firstName)")
                : String(localized: "Moving to Trash: \(operation.processed) of \(operation.total)")
            return [StatusMessage(id: "trash.\(operation.id)", cloud: cloud, symbol: "trash", title: title, subtitle: place,
                                  isTrash: true)]
        }
        if operation.showsDone(at: now) {
            let canUndo = providers[cloud]?.canUntrash == true
            return [StatusMessage(
                id: "trash.done.\(operation.id)", cloud: cloud, symbol: "trash",
                title: String(localized: "Moved \(operation.trashed.count) items to Trash"),
                subtitle: canUndo ? place : String(localized: "You can restore items on the Dropbox website"),
                action: canUndo ? .undoTrash : nil, isSuccess: true, isTrash: true)]
        }
        return []
    }

    /// Красное «Не удалось переместить 3 из 40» — до клика (список с причинами) или следующего перемещения.
    func trashFailureMessage() -> StatusMessage? {
        guard let operation = trashFailures else { return nil }
        return StatusMessage(
            id: "trash.failed.\(operation.id)", severity: .critical, cloud: operation.provider, symbol: "trash",
            title: String(localized: "Couldn’t move \(operation.failures.count) of \(operation.total) to Trash"),
            subtitle: String(localized: "Click to see the reasons"), target: .trashFailures)
    }
}
