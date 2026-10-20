import Foundation

/// Рекурсивный подсчёт числа файлов и общего размера папки (для карточки «Добавить по ссылке»).
/// Обход — `CloudProvider.traverse`: ярлыки на папки обходятся по цели, каждая папка — один раз.
struct FolderSizeCounter: Sendable {
    struct Stats: Sendable, Equatable {
        var files = 0
        var bytes: Int64 = 0
        /// Документы облака (размер до экспорта неизвестен) и ярлыки на файлы.
        var unsizedFiles = 0
        var folders = 0
        var forbidden = 0
    }

    let provider: any CloudProvider

    func count(_ folder: CloudItem, progress: @escaping @Sendable (Stats) async -> Void) async throws -> Stats {
        var stats = Stats()
        var lastReport = Date.distantPast

        for await event in provider.traverse(folder, resolvingAliases: false) {
            try Task.checkCancellation()
            switch event {
            case .folderFailed(_, let error), .itemFailed(_, _, let error):
                throw error
            case .page(_, let items):
                for item in items {
                    if item.isFolder {
                        stats.folders += 1
                    } else if item.isDownloadable {
                        stats.files += 1
                        if item.isAlias || item.exportFormat != nil {
                            stats.unsizedFiles += 1
                        } else {
                            stats.bytes += item.sizeValue
                        }
                        if !item.canDownload { stats.forbidden += 1 }
                    }
                }
            }
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                await progress(stats)
            }
        }
        try Task.checkCancellation()
        return stats
    }
}
