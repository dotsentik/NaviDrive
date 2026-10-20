import Foundation

/// Есть ли объект облака на этом Mac. Определяется только по задачам скачивания в базе и файлам на диске,
/// без запросов к облаку и без подсчёта хеша.
struct LocalPresence: Equatable, Sendable {
    enum State: Equatable, Sendable { case downloaded, partial, notDownloaded }

    var state: State
    var doneBytes: Int64 = 0
    /// 0 — размер неизвестен (документ на экспорт, ярлык).
    var totalBytes: Int64 = 0
    /// Файл качается сейчас: процент берётся из живого прогресса планировщика.
    var liveTaskId: String?
    /// Хеш уже был сверен при скачивании NaviDrive (новая проверка не запускается).
    var verified = false
    var isFolder = false
    /// Только у папок: сколько файлов внутри уже на диске.
    var doneFiles = 0
    var totalFiles = 0

    static let notDownloaded = LocalPresence(state: .notDownloaded)
}

/// Строки текущей папки браузера с путями, по которым они сохраняются (те же правила, что при скачивании).
struct LocalPresenceContext: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let id: String
        let isFolder: Bool
        /// ID объекта в задачах скачивания (`targetId`).
        let downloadId: String
        /// Размер в облаке; nil — неизвестен.
        let cloudSize: Int64?
        /// Куда файл сохранился бы сейчас: PathResolver с маршрутами.
        let localPath: String
        let routeKey: RouteKey
    }

    let provider: CloudProviderKind
    let rows: [Row]
}

/// Проверка файлов на диске вне главного потока с коротким кэшем размеров:
/// частые обновления (прогресс загрузок) не повторяют stat для каждой строки.
actor LocalPresenceChecker {
    private struct Entry {
        let size: Int64?
        let checkedAt: Date
    }

    /// Через столько секунд размер перечитывается: удалённый или перемещённый файл перестаёт считаться скачанным.
    static let maxAge: TimeInterval = 8
    private var cache: [String: Entry] = [:]

    func invalidate() { cache.removeAll() }

    func evaluate(_ context: LocalPresenceContext, db: DatabaseManager, live: [String: Int64],
                  folderTotals: [String: FolderSizeTally]) -> [String: LocalPresence] {
        let fileIds = context.rows.filter { !$0.isFolder }.map(\.downloadId)
        let folderIds = context.rows.filter(\.isFolder).map(\.downloadId)
        let fileTasks = Dictionary(grouping: db.downloadTasks(provider: context.provider, fileIds: fileIds), by: \.driveFileId)
        let folderTasks = db.downloadTasks(provider: context.provider, inFolders: folderIds)
        var result: [String: LocalPresence] = [:]
        for row in context.rows {
            if row.isFolder {
                result[row.id] = folder(tasks: folderTasks[row.downloadId] ?? [], known: folderTotals[row.id], live: live)
            } else {
                result[row.id] = file(row, provider: context.provider, tasks: fileTasks[row.downloadId] ?? [], live: live)
            }
        }
        if cache.count > 50_000 {
            let now = Date()
            cache = cache.filter { now.timeIntervalSince($0.value.checkedAt) < Self.maxAge }
        }
        return result
    }

    private func size(_ path: String) -> Int64? {
        let now = Date()
        if let entry = cache[path], now.timeIntervalSince(entry.checkedAt) < Self.maxAge { return entry.size }
        let size = DownloadWorker.fileSize(path)
        cache[path] = Entry(size: size, checkedAt: now)
        return size
    }

    /// Скачан: файл задачи или файл по текущему пути есть и размер совпал с облачным.
    /// Частично: есть .part / идёт загрузка, или локальный файл меньше облачного.
    private func file(_ row: LocalPresenceContext.Row, provider: CloudProviderKind, tasks: [DownloadTask],
                      live: [String: Int64]) -> LocalPresence {
        for task in tasks {
            guard let size = size(task.finalPath), task.expectedSize <= 0 || size == task.expectedSize else { continue }
            return LocalPresence(state: .downloaded, doneBytes: size, totalBytes: size,
                                 verified: task.verified && task.status == .completed)
        }
        let cloudSize = row.cloudSize ?? 0
        let localSize = size(row.localPath)
        if let localSize, cloudSize <= 0 || localSize == cloudSize {
            return LocalPresence(state: .downloaded, doneBytes: localSize, totalBytes: localSize)
        }
        for task in tasks where task.status != .completed {
            let done = live[task.id] ?? size(task.partPath) ?? 0
            if done > 0 || task.status == .downloading {
                return LocalPresence(state: .partial, doneBytes: done, totalBytes: max(task.expectedSize, cloudSize),
                                     liveTaskId: task.status == .downloading ? task.id : nil)
            }
        }
        if let part = size(row.localPath + provider.partialSuffix), part > 0 {
            return LocalPresence(state: .partial, doneBytes: part, totalBytes: cloudSize)
        }
        if let localSize, cloudSize > 0, localSize < cloudSize {
            return LocalPresence(state: .partial, doneBytes: localSize, totalBytes: cloudSize)
        }
        return .notDownloaded
    }

    /// Сводка по уже известным файлам папки (задачи в базе) и, если посчитан, по размеру папки в облаке.
    private func folder(tasks: [DownloadTask], known: FolderSizeTally?, live: [String: Int64]) -> LocalPresence {
        var files: [String: (done: Bool, bytes: Int64, total: Int64)] = [:]
        for task in tasks {
            var done = false
            var bytes: Int64 = 0
            if let size = size(task.finalPath), task.expectedSize <= 0 || size == task.expectedSize {
                done = true
                bytes = size
            } else if task.status != .completed {
                bytes = live[task.id] ?? size(task.partPath) ?? 0
                if task.expectedSize > 0 { bytes = min(bytes, task.expectedSize) }
            }
            // Один файл в разных папках назначения считается один раз — по лучшему состоянию.
            if let current = files[task.driveFileId], current.done || (!done && current.bytes >= bytes) { continue }
            files[task.driveFileId] = (done, bytes, max(task.expectedSize, bytes))
        }
        var presence = LocalPresence(state: .notDownloaded, isFolder: true)
        presence.doneFiles = files.values.filter(\.done).count
        presence.doneBytes = files.values.reduce(0) { $0 + $1.bytes }
        presence.totalFiles = max(files.count, known.map { $0.fileCount + $0.nativeDocCount } ?? 0)
        presence.totalBytes = max(files.values.reduce(0) { $0 + $1.total }, known?.totalSize ?? 0)
        if presence.totalFiles > 0, presence.doneFiles == presence.totalFiles {
            presence.state = .downloaded
        } else if presence.doneFiles > 0 || presence.doneBytes > 0 {
            presence.state = .partial
        }
        return presence
    }
}

extension AppModel {
    /// Пересчитать пометки «скачано на этот Mac» для текущей папки браузера.
    /// - Parameter invalidate: перечитать размеры с диска, не дожидаясь устаревания кэша (кнопка «Обновить»).
    func refreshBrowserPresence(invalidate: Bool = false) async {
        guard let context = browserPresenceContext, let db, selection?.isCloudBrowser == true else {
            if !browserPresence.isEmpty { browserPresence = [:] }
            return
        }
        let checker = presenceChecker
        if invalidate { await checker.invalidate() }
        let live = snapshot.liveProgress
        var folderTotals: [String: FolderSizeTally] = [:]
        for row in context.rows where row.isFolder {
            if let size = folderSizes[row.routeKey] { folderTotals[row.id] = size.tally }
        }
        let result = await checker.evaluate(context, db: db, live: live, folderTotals: folderTotals)
        // Пока шла проверка, пользователь мог уйти в другую папку.
        guard context == browserPresenceContext else { return }
        if result != browserPresence { browserPresence = result }
    }

    /// Процент для подсказки: у качающегося файла — по живому прогрессу.
    func presenceDoneBytes(_ presence: LocalPresence) -> Int64 {
        guard let id = presence.liveTaskId, let live = snapshot.liveProgress[id] else { return presence.doneBytes }
        return live
    }
}
