import Foundation

/// Отчёт окна «Диагностика» по одной загрузке: факты (статус, размер `.part` на диске, записанный
/// прогресс, состояние сторожа), вывод простыми словами и события этого файла из журнала.
struct DownloadDiagnosticsReport: Sendable {
    let fileName: String
    let status: TaskStatus
    let expectedSize: Int64
    /// Прогресс, записанный в базе.
    let recordedBytes: Int64
    /// Реальный размер `.part` на диске (nil — файла нет).
    let partBytes: Int64?
    let finalFileExists: Bool
    let retryCount: Int
    let lastError: String?
    let live: DownloadLiveDiagnostics?
    let verdict: [String]
    let events: [String]
    let createdAt: Date

    /// Текст для «Скопировать отчёт» (без ключей ссылок — журнал уже очищен от них).
    var plainText: String {
        var lines = [
            "NaviDrive — \(String(localized: "Diagnostics")): \(fileName)",
            "\(String(localized: "Status")): \(status.title)",
            "\(String(localized: "On disk")): \(partBytes.map(AppLog.bytes) ?? "—") / \(AppLog.bytes(expectedSize))",
            "\(String(localized: "Recorded progress")): \(AppLog.bytes(recordedBytes))",
        ]
        if let lastError { lines.append("\(String(localized: "Last error")): \(lastError)") }
        lines.append("")
        lines += verdict
        lines.append("")
        lines.append(String(localized: "Recent events:"))
        lines += events
        return lines.joined(separator: "\n")
    }
}

extension AppModel {
    /// Расхождение больше этого между записанным прогрессом и `.part` — данные на диске потеряны.
    nonisolated static let lostDataThreshold: Int64 = 64 * 1_048_576

    func downloadDiagnostics(for task: DownloadTask) async -> DownloadDiagnosticsReport {
        let current = await inBackground { $0.task(id: task.id) } ?? nil
        let fresh = current ?? task
        let live = await scheduler?.diagnostics(id: task.id)
        let needles = [task.id, "“\(task.fileName)”"]
        let (partBytes, finalExists, events) = await Task.detached(priority: .userInitiated) {
            // У готового файла `.part` уже переименован — на диске итоговый файл.
            (DownloadWorker.fileSize(fresh.partPath)
                ?? (fresh.status == .completed ? DownloadWorker.fileSize(fresh.finalPath) : nil),
             FileManager.default.fileExists(atPath: fresh.finalPath),
             AppLog.writer.recentLines(matching: needles, limit: 60))
        }.value
        return DownloadDiagnosticsReport(
            fileName: fresh.fileName, status: fresh.status, expectedSize: fresh.expectedSize,
            recordedBytes: live?.liveBytes ?? fresh.downloadedSize, partBytes: partBytes, finalFileExists: finalExists,
            retryCount: fresh.retryCount, lastError: fresh.lastError, live: live,
            verdict: Self.verdict(for: fresh, live: live, partBytes: partBytes, finalExists: finalExists),
            events: events, createdAt: Date())
    }

    /// Вывод простыми словами: что с загрузкой и почему.
    nonisolated static func verdict(for task: DownloadTask, live: DownloadLiveDiagnostics?, partBytes: Int64?,
                                    finalExists: Bool) -> [String] {
        var lines: [String] = []
        let onDisk = partBytes ?? 0
        let recorded = live?.liveBytes ?? task.downloadedSize
        let total = Format.bytes(task.expectedSize)

        if ![.completed, .cancelled, .verifying].contains(task.status), recorded - onDisk > lostDataThreshold {
            lines.append(String(localized: "Warning: only \(Format.bytes(onDisk)) is on disk, but \(Format.bytes(recorded)) was recorded as downloaded — part of the downloaded data was lost or the file was truncated. The events below show when it happened."))
        }

        switch task.status {
        case .downloading:
            if let live {
                let idle = Int(live.secondsWithoutData)
                if live.isWaitingOnPurpose {
                    lines.append(String(localized: "Waiting before the next attempt: \(live.lastEvent)"))
                } else if live.secondsWithoutData >= DownloadScheduler.stallWarningAfter {
                    lines.append(String(localized: "Stalled: no data for \(idle) s. Last event: \(live.lastEvent)"))
                    lines.append(String(localized: "After \(Int(DownloadScheduler.stallRestartAfter / 60)) min without data the connection is restarted automatically (reconnects so far: \(live.stallRestarts) of \(live.maxStallRestarts)); after that the download gets the Error status with the reason."))
                } else {
                    lines.append(String(localized: "Downloading normally: \(Format.bytes(onDisk)) of \(total). Last event: \(live.lastEvent)"))
                }
            } else {
                lines.append(String(localized: "Starting the download…"))
            }
        case .queued:
            lines.append(String(localized: "In the queue: the download will continue from \(Format.bytes(onDisk)) of \(total)."))
        case .paused, .pausedAll:
            lines.append(onDisk > 0
                ? String(localized: "Paused: \(Format.bytes(onDisk)) of \(total) is on disk. After Resume the download continues from this point.")
                : String(localized: "Paused: nothing is on disk yet — the download will start from the beginning."))
        case .failed:
            lines.append(String(localized: "The download failed: \(task.lastError ?? "—")"))
            if onDisk > 0 {
                lines.append(String(localized: "\(Format.bytes(onDisk)) is kept on disk — Retry continues from this point."))
            }
        case .completed:
            lines.append(finalExists
                ? String(localized: "Downloaded.")
                : String(localized: "Downloaded, but the file is no longer at its location (moved or deleted)."))
        case .verifying:
            lines.append(String(localized: "The file is downloaded, checking the checksum."))
        case .cancelled:
            lines.append(String(localized: "Cancelled."))
        case .waitingForNetwork, .waitingForVolume, .waitingForSpace, .waitingDailyLimit:
            lines.append(String(localized: "Waiting: \(task.lastError ?? task.status.title)"))
        }
        if task.retryCount > 0, ![.completed, .cancelled].contains(task.status) {
            lines.append(String(localized: "Failed attempts so far: \(task.retryCount)."))
        }
        return lines
    }
}
