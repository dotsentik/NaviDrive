import Foundation

/// Что сейчас идёт — для подтверждения выхода («Сейчас идут: 3 скачивания, 1 отправка»).
struct QuitActivity: Equatable, Sendable {
    var downloads = 0
    var uploads = 0
    var trashMoves = 0
    var sizeCalculations = 0

    var isEmpty: Bool { downloads + uploads + trashMoves + sizeCalculations == 0 }

    /// Только то, что реально идёт, с формами множественного числа.
    var summary: String {
        var parts: [String] = []
        if downloads > 0 { parts.append(String(localized: "\(downloads) downloads")) }
        if uploads > 0 { parts.append(String(localized: "\(uploads) uploads")) }
        if trashMoves > 0 { parts.append(String(localized: "\(trashMoves) moves to the Trash")) }
        if sizeCalculations > 0 { parts.append(String(localized: "\(sizeCalculations) size calculations")) }
        return parts.joined(separator: ", ")
    }
}

extension AppModel {
    /// Идущие скачивания (и просмотр папок перед ними), отправки (и их подготовка), перемещение в корзину
    /// и подсчёты размера папок. Очередь, которая ещё не началась, выходу не мешает — она продолжится при запуске.
    var quitActivity: QuitActivity {
        QuitActivity(
            downloads: snapshot.isPaused ? 0 : snapshot.runningCount + snapshot.scanningFolders,
            uploads: uploadSnapshot.isPaused ? 0 : uploadSnapshot.runningCount + uploadSnapshot.preparing.count,
            trashMoves: trashOperation.map { $0.finishedAt == nil ? 1 : 0 } ?? 0,
            sizeCalculations: folderSizeJobs.count)
    }

    /// «Выйти после завершения» ждёт и очередь подключённых облаков: пока она не пуста, новые файлы
    /// встают на место законченных. На паузе, в ожидании сети, диска или лимита — уже не ждём.
    private var hasWorkBeforeQuit: Bool {
        guard quitActivity.isEmpty else { return true }
        let connected = Set(connectedClouds)
        let downloadsQueued = !snapshot.isPaused
            && totals.byProvider.contains { connected.contains($0.key) && $0.value.files > 0 }
        let uploadsQueued = !uploadSnapshot.isPaused
            && (!uploadSnapshot.verificationProgress.isEmpty
                || uploadTotals.byProvider.contains { connected.contains($0.key) && $0.value.files > 0 })
        return downloadsQueued || uploadsQueued || !snapshot.verificationProgress.isEmpty
    }

    /// Вызывается из `refresh` (2 раза в секунду): передачи закончились — выход без вопросов.
    func quitIfTransfersFinished() {
        guard quitWhenDone, !hasWorkBeforeQuit else { return }
        quitWhenDone = false
        QuitController.shared.terminateWithoutPrompt()
    }

    func cancelQuitWhenDone() {
        quitWhenDone = false
        rebuildStatusFeed()
    }

    /// Перед завершением: подсчёты размера отменяются, скачивания и отправки останавливаются и возвращаются
    /// в очередь (прогресс — в .part-файлах и offset сессий отправки); при следующем запуске продолжатся.
    func stopForQuit() async {
        for task in folderSizeTasks.values { task.cancel() }
        let downloads = Task { await scheduler?.stopForRelaunch() }
        let uploads = Task { await uploadScheduler?.stopForRelaunch() }
        await downloads.value
        await uploads.value
    }
}
