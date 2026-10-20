import Foundation

/// Рекурсивный обход папки облака (`CloudProvider.traverse`, по страницам). Сразу создаёт локальные
/// директории и пакетно (одной транзакцией на страницу) добавляет файлы в очередь `download_tasks`.
///
/// Ярлыки раскрываются провайдером: ярлык на папку обходится как папка-цель, ярлык на файл
/// скачивается как файл-цель (под именем ярлыка). Каждая папка обходится один раз — это защищает
/// от циклов (ярлык на папку-предка) и от повторного обхода одной папки.
struct FolderScanner: Sendable {
    let db: DatabaseManager
    let provider: any CloudProvider
    let scheduler: DownloadScheduler

    /// - Parameter folder: уже разрешённая папка (не ярлык).
    func scan(_ folder: CloudItem, into destinationDir: String) async -> EnqueueReport {
        var report = EnqueueReport()
        let rootDir = (destinationDir as NSString).appendingPathComponent(PathResolver.sanitize(folder.name))
        /// Локальная папка для каждой папки облака; нет записи — папка (и её поддерево) пропускается.
        var dirs: [String: String] = [folder.targetId: rootDir]
        /// Папки, которые уже проверены и созданы на диске.
        var prepared: Set<String> = []
        /// Занятые имена в каждой папке (страниц у папки может быть несколько).
        var usedNames: [String: Set<String>] = [:]

        for await event in provider.traverse(folder, resolvingAliases: true) {
            if Task.isCancelled { break }
            switch event {
            case .itemFailed(let folderId, let name, let error):
                let dir = dirs[folderId] ?? rootDir
                await fail(String(localized: "Shortcut “\(name)” in “\(dir)”: \(error.localizedDescription)"), into: &report)
            case .folderFailed(let folderId, let error):
                guard let dir = await prepare(folderId, dirs: &dirs, prepared: &prepared, root: destinationDir, report: &report) else { continue }
                await fail(String(localized: "Couldn’t read folder “\(dir)”: \(error.localizedDescription)"), into: &report)
            case .page(let folderId, let items):
                guard let dir = await prepare(folderId, dirs: &dirs, prepared: &prepared, root: destinationDir, report: &report) else { continue }
                var used = usedNames[folderId] ?? []
                var batch: [DownloadTask] = []
                batch.reserveCapacity(items.count)
                for item in items {
                    if item.isFolder {
                        let name = PathResolver.uniqueName(PathResolver.sanitize(item.name), used: &used)
                        dirs[item.targetId] = (dir as NSString).appendingPathComponent(name)
                    } else if item.isDownloadable {
                        let name = PathResolver.uniqueName(item.localFileName, used: &used)
                        do {
                            try PathResolver.validate((dir as NSString).appendingPathComponent(name), inside: destinationDir)
                        } catch {
                            await fail(error.localizedDescription, into: &report)
                            continue
                        }
                        batch.append(.make(from: item, fileName: name, targetDir: dir))
                    } else {
                        report.unsupported += 1
                    }
                }
                usedNames[folderId] = used

                do {
                    let result = try db.enqueue(batch)
                    report.added += result.added
                    report.alreadyDownloaded += result.alreadyDownloaded
                    report.forbidden += result.forbidden
                } catch {
                    await fail(String(localized: "Couldn’t save the queue: \(error.localizedDescription)"), into: &report)
                }
                await scheduler.scanProgress(files: batch.count)
            }
        }
        return report
    }

    /// Локальная папка для папки облака: при первом обращении проверяется (внутри папки назначения,
    /// без символических ссылок) и создаётся. nil — папку пропустить вместе с поддеревом.
    private func prepare(_ folderId: String, dirs: inout [String: String], prepared: inout Set<String>,
                         root destinationDir: String, report: inout EnqueueReport) async -> String? {
        guard let dir = dirs[folderId] else { return nil }
        guard prepared.insert(folderId).inserted else { return dir }
        do {
            try PathResolver.validate(dir, inside: destinationDir)
        } catch {
            dirs[folderId] = nil
            await fail(error.localizedDescription, into: &report)
            return nil
        }
        if case .available = PathResolver.volumeState(for: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func fail(_ message: String, into report: inout EnqueueReport) async {
        report.errors.append(message)
        await scheduler.scanFailed(message)
    }
}
