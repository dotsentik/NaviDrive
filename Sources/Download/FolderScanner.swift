import Foundation

/// Рекурсивный обход папки Google Drive с пагинацией. Сразу создаёт локальные директории
/// и пакетно (одной транзакцией на страницу) добавляет файлы в очередь `download_tasks`.
///
/// Ярлыки разрешаются через `files.get`: ярлык на папку обходится как папка-цель,
/// ярлык на файл скачивается как файл-цель (под именем ярлыка). Множество посещённых
/// папок защищает от циклов (ярлык на папку-предка) и от повторного обхода одной папки.
struct FolderScanner: Sendable {
    let db: DatabaseManager
    let api: GoogleDriveAPIClient
    let scheduler: DownloadScheduler

    /// - Parameter folder: уже разрешённая папка (не ярлык).
    func scan(_ folder: DriveItem, into destinationDir: String) async -> EnqueueReport {
        var report = EnqueueReport()
        let rootDir = (destinationDir as NSString).appendingPathComponent(PathResolver.sanitize(folder.name))
        var stack: [(id: String, dir: String, driveId: String?)] = [(folder.id, rootDir, folder.driveId)]
        var visited: Set<String> = [folder.id]

        while let (folderId, dir, driveId) = stack.popLast() {
            if Task.isCancelled { break }
            // Папка обязана лежать внутри папки назначения и не проходить через символическую ссылку.
            do {
                try PathResolver.validate(dir, inside: destinationDir)
            } catch {
                await fail(error.localizedDescription, into: &report)
                continue
            }
            if case .available = PathResolver.volumeState(for: dir) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }

            var usedNames = Set<String>()
            var pageToken: String?
            repeat {
                let page: DriveFileList
                do {
                    page = try await api.listPage(.children(of: folderId, driveId: driveId), pageToken: pageToken,
                                                  orderBy: "folder,name,createdTime")
                } catch {
                    await fail(String(localized: "Couldn’t read folder “\(dir)”: \(error.localizedDescription)"), into: &report)
                    break
                }

                var batch: [DownloadTask] = []
                batch.reserveCapacity(page.files.count)
                for listed in page.files {
                    var item = listed
                    if item.isShortcut {
                        do {
                            item = try await api.resolveShortcut(item)
                        } catch {
                            await fail(String(localized: "Shortcut “\(listed.name)” in “\(dir)”: \(error.localizedDescription)"), into: &report)
                            continue
                        }
                    }

                    if item.isFolder {
                        // Цикл через ярлык или повторная ссылка на уже обойдённую папку — пропускаем.
                        guard visited.insert(item.id).inserted else { continue }
                        let name = PathResolver.uniqueName(PathResolver.sanitize(item.name), used: &usedNames)
                        // Ярлыки уже раскрыты через files.get: driveId — собственный диск цели (nil — не общий диск).
                        stack.append((item.id, (dir as NSString).appendingPathComponent(name), item.driveId))
                    } else if item.isDownloadable {
                        let name = PathResolver.uniqueName(item.localFileName, used: &usedNames)
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

                do {
                    let result = try db.enqueue(batch)
                    report.added += result.added
                    report.alreadyDownloaded += result.alreadyDownloaded
                    report.forbidden += result.forbidden
                } catch {
                    await fail(String(localized: "Couldn’t save the queue: \(error.localizedDescription)"), into: &report)
                }
                await scheduler.scanProgress(files: batch.count)
                pageToken = page.nextPageToken
            } while pageToken != nil
        }
        return report
    }

    private func fail(_ message: String, into report: inout EnqueueReport) async {
        report.errors.append(message)
        await scheduler.scanFailed(message)
    }
}
