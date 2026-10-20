import Foundation

/// Рекурсивный подсчёт числа файлов и общего размера папки (для карточки «Добавить по ссылке»).
/// Ярлыки на папки обходятся по targetId, множество посещённых папок защищает от циклов.
struct FolderSizeCounter: Sendable {
    struct Stats: Sendable, Equatable {
        var files = 0
        var bytes: Int64 = 0
        /// Документы Google (размер до экспорта неизвестен) и ярлыки на файлы.
        var unsizedFiles = 0
        var folders = 0
        var forbidden = 0
    }

    let api: GoogleDriveAPIClient

    func count(_ folder: DriveItem, progress: @escaping @Sendable (Stats) async -> Void) async throws -> Stats {
        var stats = Stats()
        var stack: [(id: String, driveId: String?)] = [(folder.targetId, folder.targetDriveId)]
        var visited: Set<String> = [folder.targetId]
        var lastReport = Date.distantPast

        while let (folderId, driveId) = stack.popLast() {
            var pageToken: String?
            repeat {
                try Task.checkCancellation()
                let page = try await api.listPage(.children(of: folderId, driveId: driveId), pageToken: pageToken)
                for item in page.files {
                    if item.isFolder {
                        if visited.insert(item.targetId).inserted {
                            stats.folders += 1
                            stack.append((item.targetId, item.targetDriveId))
                        }
                    } else if item.isDownloadable {
                        stats.files += 1
                        if item.isShortcut || item.exportFormat != nil {
                            stats.unsizedFiles += 1
                        } else {
                            stats.bytes += item.sizeValue
                        }
                        if !item.canDownload { stats.forbidden += 1 }
                    }
                }
                pageToken = page.nextPageToken
                if Date().timeIntervalSince(lastReport) > 0.25 {
                    lastReport = Date()
                    await progress(stats)
                }
            } while pageToken != nil
        }
        return stats
    }
}
