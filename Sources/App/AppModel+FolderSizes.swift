import Foundation

/// Папка, размер которой считается или ждёт очереди.
struct FolderSizeJob: Sendable, Equatable {
    /// Подсчёт идёт (иначе ждёт, пока закончится подсчёт другой папки этого облака).
    var token: UUID?
    /// Промежуточный итог идущего подсчёта.
    var progress: FolderSizeTally?

    var isRunning: Bool { token != nil }
}

/// Размер папки облака — только по запросу из контекстного меню, без фонового обновления.
/// Одновременно идёт один подсчёт на облако, чтобы не отнимать запросы у скачивания и отправки.
extension AppModel {
    /// Посчитанный размер «свежий» для проверки свободного места.
    static let freshFolderSizeAge: TimeInterval = 60 * 60

    func reloadFolderSizes() {
        Task {
            guard let rows = await inBackground({ $0.allFolderSizes() }) else { return }
            var map = Dictionary(rows, uniquingKeysWith: { first, _ in first })
            // Подсчёты, закончившиеся во время чтения, новее.
            for (key, size) in folderSizes { map[key] = size }
            if map != folderSizes { folderSizes = map }
        }
    }

    /// Размер считается у обычных папок (не у ярлыков и не у загружаемых строк-заглушек).
    static func canCalculateSize(_ item: CloudItem) -> Bool {
        item.isFolder && !item.isAlias && !isUploadPlaceholder(item.id)
    }

    func calculateFolderSizes(_ folders: [CloudItem]) {
        for folder in folders where Self.canCalculateSize(folder) && folderSizeJobs[folder.routeKey] == nil {
            folderSizeJobs[folder.routeKey] = FolderSizeJob()
            folderSizeQueue[folder.provider, default: []].append(folder)
        }
        for kind in CloudProviderKind.allCases { startNextFolderSize(kind) }
    }

    func stopCalculatingFolderSizes(_ folders: [CloudItem]) {
        for folder in folders {
            let key = folder.routeKey
            folderSizeQueue[folder.provider]?.removeAll { $0.routeKey == key }
            folderSizeTasks.removeValue(forKey: key)?.cancel()
            folderSizeJobs[key] = nil
        }
        for kind in CloudProviderKind.allCases { startNextFolderSize(kind) }
    }

    /// Посчитанный не больше часа назад размер (для проверки свободного места перед скачиванием).
    func freshFolderSize(_ item: CloudItem) -> FolderSize? {
        guard let size = folderSizes[item.routeKey], -size.computedAt.timeIntervalSinceNow < Self.freshFolderSizeAge else {
            return nil
        }
        return size
    }

    private func startNextFolderSize(_ kind: CloudProviderKind) {
        guard !folderSizeTasks.keys.contains(where: { $0.provider == kind }),
              var queue = folderSizeQueue[kind], !queue.isEmpty else { return }
        let folder = queue.removeFirst()
        folderSizeQueue[kind] = queue
        let key = folder.routeKey
        guard let provider = providers[kind] else {
            folderSizeJobs[key] = nil
            startNextFolderSize(kind)
            return
        }
        let token = UUID()
        folderSizeJobs[key] = FolderSizeJob(token: token)
        folderSizeTasks[key] = Task(priority: .utility) {
            let result: Result<FolderSizeTally, Error>
            do {
                result = .success(try await provider.folderSize(folder) { tally in
                    await self.updateFolderSizeProgress(tally, for: key, token: token)
                })
            } catch {
                result = .failure(error)
            }
            self.finishFolderSize(folder, token: token, result: result)
        }
    }

    private func updateFolderSizeProgress(_ tally: FolderSizeTally, for key: RouteKey, token: UUID) {
        guard folderSizeJobs[key]?.token == token else { return }
        folderSizeJobs[key]?.progress = tally
    }

    private func finishFolderSize(_ folder: CloudItem, token: UUID, result: Result<FolderSizeTally, Error>) {
        let key = folder.routeKey
        // Подсчёт остановлен (или папку уже считают заново) — итог не нужен.
        guard folderSizeJobs[key]?.token == token else { return }
        folderSizeTasks[key] = nil
        folderSizeJobs[key] = nil
        switch result {
        case .success(let tally):
            let size = FolderSize(tally: tally, computedAt: Date())
            folderSizes[key] = size
            Task {
                let failure = await inBackground { db -> String? in
                    do { try db.saveFolderSize(size, for: key); return nil } catch { return error.localizedDescription }
                }
                if let failure, let failure { errorMessage = failure }
            }
        case .failure(let error):
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled {
                errorMessage = String(localized: "Couldn’t calculate the size of “\(folder.name)”: \(error.localizedDescription)")
            }
        }
        startNextFolderSize(folder.provider)
    }

    // MARK: - Text

    /// «12 340 files · 1 280 folders · 15 Google Docs · counted 5 min ago».
    static func folderSizeHelp(_ size: FolderSize) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        let age = formatter.localizedString(for: size.computedAt, relativeTo: Date())
        return (countParts(size.tally) + [String(localized: "counted \(age)")]).joined(separator: " · ")
    }

    static func folderSizeProgressHelp(_ job: FolderSizeJob) -> String {
        guard job.isRunning else { return String(localized: "Waiting to calculate size…") }
        let parts = job.progress.map(countParts) ?? []
        return ([String(localized: "Calculating size…")] + parts).joined(separator: " · ")
    }

    private static func countParts(_ tally: FolderSizeTally) -> [String] {
        var parts = [counted(tally.fileCount) { String(localized: "\($0) files") },
                     counted(tally.folderCount) { String(localized: "\($0) folders") }]
        if tally.nativeDocCount > 0 {
            parts.append(counted(tally.nativeDocCount) { String(localized: "\($0) Google Docs") })
        }
        return parts
    }

    /// Строка с формой множественного числа, где число записано с разделителями разрядов («12 340»).
    private static func counted(_ count: Int, _ text: (Int) -> String) -> String {
        let result = text(count)
        guard let range = result.range(of: String(count)) else { return result }
        return result.replacingCharacters(in: range, with: count.formatted())
    }
}
