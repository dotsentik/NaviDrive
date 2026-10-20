import Foundation

/// Планировщик параллельных загрузок.
///
/// Слоты работают как асинхронный семафор: пока активных потоков меньше лимита AIMD,
/// из SQLite атомарно забирается следующая задача и запускается независимый поток.
/// Каждый поток по завершении освобождает слот и снова вызывает `schedule()`.
///
/// Умная очередь:
/// - 1–2 слота держатся под мелкие файлы (< 10 МБ) и 1 слот под крупные, чтобы тысячи мелких
///   файлов не ждали за файлом на 50 ГБ и наоборот. Если файлов какого-то класса в очереди нет,
///   его зарезервированный слот временно отдаётся другим, чтобы канал не простаивал;
/// - экспорт Google Docs/Sheets/Slides — не более 2 одновременно;
/// - задачи на отключённом внешнем диске сразу переводятся в `waiting_for_volume` и слот не занимают;
/// - задачи, которым не хватает места на целевом диске, переводятся в `waiting_for_space`
///   и возвращаются в очередь, когда место освободится.
actor DownloadScheduler {
    static let exportLimit = 2

    private enum StopReason {
        case pauseTask, pauseAll, network, cancel, requeue
        /// Лимит облака (свой счётчик за 24 часа или ответ облака): задача ждёт, прогресс сохранён.
        case dailyLimit
    }

    private struct Running {
        let task: DownloadTask
        let sizeClass: TaskSizeClass
        let handle: Task<Void, Never>
    }

    private let db: DatabaseManager
    private let providers: CloudProviders
    private let progress: ProgressStore

    private var running: [String: Running] = [:]
    /// Пути `.gdrive.part`, в которые сейчас идёт запись: два потока никогда не пишут в один файл.
    private var activePartPaths: Set<String> = []
    private var stopReasons: [String: StopReason] = [:]
    private var liveProgress: [String: Int64] = [:]
    private var meter = ThroughputMeter()
    /// Скорость каждого файла — для подсказки у индикатора в браузере облака.
    private var taskMeters: [String: ThroughputMeter] = [:]
    private var balancer: AdaptiveConcurrency

    private var started = false
    /// Перед перезапуском приложения новые задачи не запускаются.
    private var isHalted = false
    private var isOnline = true
    /// Начало общей паузы: после короткой паузы (< 60 с) AIMD-разгон не сбрасывается.
    private var pausedAllAt: TimeInterval?
    static let shortPause: TimeInterval = 60
    /// Идущие задачи, по которым уже пришли байты (остальные показываются как «Подключение…»).
    private var receivedBytes: Set<String> = []
    private var stateVersion = 0
    /// Облака с действующим входом: задачи остальных ждут в очереди.
    private var authorized: Set<CloudProviderKind> = []

    private var scanningFolders = 0
    private var scannedFiles = 0
    private var scanErrors: [String] = []
    private var timers: [Task<Void, Never>] = []

    /// Проверка хеша идёт вне слотов загрузки, не более 2 файлов одновременно.
    static let maxConcurrentVerifications = 2
    private var verificationQueue: [DownloadTask] = []
    /// id → сколько байт уже прочитано при проверке.
    private var verifying: [String: Int64] = [:]

    /// Свободное место по томам (ключ `PathResolver.volumeKey`), кэш на несколько секунд:
    /// при тысячах мелких файлов том не опрашивается на каждый запуск.
    private var freeSpaceCache: [String: (bytes: Int64, at: TimeInterval)] = [:]
    private static let freeSpaceCacheSeconds: TimeInterval = 5
    /// Запас, который очередь не занимает: диск не заполняется до последнего байта.
    static let spaceMargin: Int64 = 2_000_000_000

    /// Лимит скачивания Google Drive: свой бюджет за скользящие 24 часа и остановка по ответу Google.
    /// У Dropbox своих лимитов скачивания нет (только пауза и повтор при 429).
    private var googleLimit: TransferLimiter

    /// Паузы перед повтором, которые будятся досрочно (пробуждение Mac, возврат сети).
    private let retryWaiter = RetryWaiter()

    /// Статистика текущей «сессии» очереди — от первой постановки до опустошения очереди.
    private struct Session {
        var active = false
        var projects: [String] = []
        var files = 0
        var bytes: Int64 = 0
        var verified = 0
        var failed = 0
        /// Общая папка скачанных файлов — для сообщения «Готово: … скачано в …».
        var directory: String?

        mutating func addDirectory(_ path: String) {
            guard let current = directory else { directory = path; return }
            let a = current.split(separator: "/"), b = path.split(separator: "/")
            let common = zip(a, b).prefix { $0 == $1 }.map(\.0)
            directory = "/" + common.joined(separator: "/")
        }
    }
    private var session = Session()
    private var sessionCounter = 0
    private var lastSession: QueueSessionSummary?

    init(db: DatabaseManager, providers: CloudProviders) {
        self.db = db
        self.providers = providers
        self.progress = ProgressStore(db: db)
        self.balancer = AdaptiveConcurrency(userLimit: AppSettings.maxConcurrentDownloads)
        self.googleLimit = TransferLimiter(provider: .googleDrive, direction: .download, db: db)
    }

    // MARK: - Lifecycle

    /// Подхватывает незавершённые задачи после перезапуска приложения.
    func start(authorized: Set<CloudProviderKind>) {
        guard !started else { return }
        started = true
        self.authorized = authorized
        db.moveStatuses([.downloading, .waitingForNetwork], to: .queued)
        // Незавершённые задачи после перезапуска — тоже сессия (уведомление в конце без имени проекта).
        if db.totals().pendingCount > 0 { session.active = true }
        // Проверки, прерванные выходом из приложения, продолжаются: .gdrive.part уже полностью на диске.
        verificationQueue = db.tasks(statuses: [.verifying], limit: 1_000_000)
        startVerifications()

        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AdaptiveConcurrency.evaluationInterval)
                await self?.rebalance()
            }
        })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.recheckVolumes()
                await self?.recheckSpace()
                await self?.checkLimits()
            }
        })
        schedule()
    }

    func setAuthorized(_ provider: CloudProviderKind, _ isAuthorized: Bool) {
        if isAuthorized {
            authorized.insert(provider)
            schedule()
        } else {
            authorized.remove(provider)
            stopAll(.requeue, provider: provider)
        }
    }

    func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        if online {
            balancer.reset(reason: String(localized: "Network restored"))
            meter.reset()
            db.moveStatuses([.waitingForNetwork], to: .queued)
            Task { await retryWaiter.wakeAll() }
            schedule()
        } else {
            // Идущие задачи сразу показываются в ожидании сети, а не в «Скачивается».
            for (id, _) in running where stopReasons[id] == nil {
                stop(id, .network)
                db.updateStatus(id: id, status: .waitingForNetwork, error: String(localized: "Waiting for network…"))
            }
        }
    }

    /// Перед перезапуском приложения: новые задачи не запускаются, идущие останавливаются и возвращаются
    /// в очередь (прогресс — в `.gdrive.part`), функция ждёт, пока потоки закроют файлы.
    /// После запуска очередь продолжается автоматически.
    func stopForRelaunch() async {
        isHalted = true
        googleLimit.flush(db: db)
        let handles = running.values.map(\.handle)
        stopAll(.requeue)
        for handle in handles { await handle.value }
    }

    /// Общая пауза: идущие и ожидающие задачи → `pausedAll` одной операцией. Идущие потоки
    /// останавливаются и дописывают .part, но в списке и счётчиках уже считаются приостановленными.
    func pauseAll() {
        for (id, _) in running where stopReasons[id] == nil { stop(id, .pauseAll) }
        db.pauseAll()
        if pausedAllAt == nil { pausedAllAt = Date().timeIntervalSinceReferenceDate }
    }

    /// Снять общую паузу (кнопка тулбара и трей): `pausedAll` → очередь. Вручную приостановленные остаются.
    func resumePausedAll() {
        db.resumePausedAll()
        resumeStopping(reasons: [.pauseAll])
        afterResume()
    }

    /// После паузы короче минуты AIMD продолжает с достигнутого лимита.
    private func afterResume() {
        let now = Date().timeIntervalSinceReferenceDate
        if let pausedAt = pausedAllAt, now - pausedAt >= Self.shortPause {
            balancer.reset(reason: String(localized: "Resumed"))
        }
        pausedAllAt = nil
        schedule()
    }

    /// Задачу возобновили, пока её поток ещё останавливается: по завершении она вернётся в очередь,
    /// а не в паузу.
    private func resumeStopping(reasons: Set<StopReason>, id: String? = nil) {
        for (taskId, reason) in stopReasons where reasons.contains(reason) && (id == nil || id == taskId) {
            stopReasons[taskId] = .requeue
        }
    }

    /// Новый предел из настроек. Применяется на лету: при уменьшении идущие загрузки не обрываются,
    /// лишние потоки просто не получают новых задач.
    func setUserLimit(_ value: Int) {
        balancer.setUserLimit(AppSettings.clampConcurrency(value))
        schedule()
    }

    // MARK: - Task control

    /// Ставит объекты в очередь и возвращает итог, когда завершится обход всех выбранных папок.
    /// Файлы начинают скачиваться сразу, не дожидаясь конца обхода.
    /// - Parameter ancestorIds: папки облака над объектами (ID цели) — для общего прогресса у строк папок.
    func enqueue(_ items: [CloudItem], destinationDir: String, projectName: String,
                 ancestorIds: [String] = []) async -> EnqueueReport {
        session.active = true
        if !projectName.isEmpty, !session.projects.contains(projectName) { session.projects.append(projectName) }
        var report = EnqueueReport()
        var files: [DownloadTask] = []
        var scans: [Task<EnqueueReport, Never>] = []

        for listed in items {
            var item = listed
            if item.isAlias {
                do {
                    item = try await providers.provider(for: item.provider).resolveAlias(item)
                } catch {
                    let message = String(localized: "Shortcut “\(listed.name)”: \(error.localizedDescription)")
                    scanFailed(message)
                    report.errors.append(message)
                    continue
                }
            }
            if item.isFolder {
                guard let provider = providers[item.provider] else {
                    scanFailed(CloudProviders.unavailableMessage)
                    report.errors.append(CloudProviders.unavailableMessage)
                    continue
                }
                scans.append(startScan(item, provider: provider, destinationDir: destinationDir, ancestorIds: ancestorIds))
            } else if item.isDownloadable {
                let name = freeFileName(for: item, in: destinationDir)
                do {
                    try PathResolver.validate((destinationDir as NSString).appendingPathComponent(name), inside: destinationDir)
                } catch {
                    scanFailed(error.localizedDescription)
                    report.errors.append(error.localizedDescription)
                    continue
                }
                var task = DownloadTask.make(from: item, fileName: name, targetDir: destinationDir)
                task.folderIds = ancestorIds
                files.append(task)
            } else {
                report.unsupported += 1
            }
        }

        do {
            let result = try db.enqueue(files)
            report.added += result.added
            report.alreadyDownloaded += result.alreadyDownloaded
            report.forbidden += result.forbidden
        } catch {
            let message = String(localized: "Couldn’t save the queue: \(error.localizedDescription)")
            scanFailed(message)
            report.errors.append(message)
        }
        schedule()

        for scan in scans {
            report.merge(await scan.value)
        }
        return report
    }

    func pauseTask(_ id: String) {
        // Проверка хеша локальная и короткая — её не прерываем.
        if verifying[id] != nil || verificationQueue.contains(where: { $0.id == id }) { return }
        if running[id] != nil { stop(id, .pauseTask) }
        db.updateStatus(id: id, status: .paused)
    }

    /// «Возобновить» отдельный файл: в начало очереди, докачка с размера .gdrive.part через Range.
    func resumeTask(_ id: String) {
        resumeStopping(reasons: [.pauseTask, .pauseAll], id: id)
        db.resume(id: id)
        schedule()
    }

    /// «Возобновить все» в секции «На паузе»: и вручную приостановленные, и после общей паузы.
    func resumeAllPaused() {
        db.resumeAllPaused()
        resumeStopping(reasons: [.pauseTask, .pauseAll])
        afterResume()
    }

    func cancelTask(_ id: String) {
        if running[id] != nil {
            stop(id, .cancel)
            db.updateStatus(id: id, status: .cancelled)
        } else {
            db.updateStatus(id: id, status: .cancelled)
            removePartFile(id)
        }
    }

    func retryFailed() {
        db.retryFailed()
        schedule()
    }

    /// Незавершённые задачи, которые ждут своей очереди (не идут и не проверяются).
    private static let unfinishedStatuses: [TaskStatus] = [
        .queued, .waitingForVolume, .waitingForSpace, .waitingForNetwork, .waitingDailyLimit,
    ]

    /// Очередь предыдущего аккаунта после входа другим: всё незавершённое — на паузу (прогресс сохраняется).
    func pauseUnfinished(_ provider: CloudProviderKind) {
        db.moveStatuses(Self.unfinishedStatuses, to: .paused, provider: provider)
    }

    /// Очередь предыдущего аккаунта после входа другим: незавершённое удаляется из очереди вместе с частями файлов.
    func cancelUnfinished(_ provider: CloudProviderKind) {
        for task in db.tasks(statuses: Self.unfinishedStatuses + [.paused, .pausedAll, .failed], limit: 1_000_000, provider: provider)
        where running[task.id] == nil {
            db.updateStatus(id: task.id, status: .cancelled)
            try? FileManager.default.removeItem(atPath: task.partPath)
        }
    }

    /// Mac проснулся: задачи, ждущие повтора, пробуют сразу; диски и квоты перепроверяются.
    func wakeUp() {
        Task { await retryWaiter.wakeAll() }
        recheckVolumes()
        recheckSpace()
        checkLimits()
    }

    func recheckVolumes() {
        for root in db.volumesAwaitingMount() {
            if case .available = PathResolver.volumeState(for: root) {
                db.requeueWaitingForVolume(volumeRoot: root)
            }
        }
        schedule()
    }

    // MARK: - Free space

    /// Задачи, ждущие места, возвращаются в очередь, если на их диске освободилось достаточно места.
    func recheckSpace() {
        var requeued = 0
        for root in db.volumesAwaitingSpace() {
            freeSpaceCache[root] = nil
            guard case .available = PathResolver.volumeState(for: root),
                  let free = freeSpace(volumeKey: root) else { continue }
            let available = free - reservedBytes(volumeKey: root) - Self.spaceMargin
            if available > 0 { requeued += db.requeueWaitingForSpace(volumeRoot: root, availableBytes: available) }
        }
        if requeued > 0 { schedule() }
    }

    /// Ставит на паузу задачи тома и дожидается, пока идущие загрузки закроют файлы (перед извлечением диска).
    func pauseTasks(onVolume root: String) async {
        var handles: [Task<Void, Never>] = []
        for (id, entry) in running where PathResolver.volumeKey(for: entry.task.targetDirPath) == root {
            stop(id, .pauseTask)
            db.updateStatus(id: id, status: .paused)
            handles.append(entry.handle)
        }
        db.pauseTasks(volumeRoot: root)
        for handle in handles { await handle.value }
    }

    private func freeSpace(volumeKey: String) -> Int64? {
        let now = Date().timeIntervalSinceReferenceDate
        if let cached = freeSpaceCache[volumeKey], now - cached.at < Self.freeSpaceCacheSeconds { return cached.bytes }
        // Реально пустое место: очищаемое macOS освобождает не сразу, и запись может упереться в «диск полон».
        guard let bytes = PathResolver.freeCapacity(at: volumeKey) else { return nil }
        freeSpaceCache[volumeKey] = (bytes, now)
        return bytes
    }

    /// Сколько ещё допишут на том уже идущие загрузки.
    private func reservedBytes(volumeKey: String) -> Int64 {
        running.values.reduce(0) { sum, entry in
            guard entry.task.expectedSize > 0, PathResolver.volumeKey(for: entry.task.targetDirPath) == volumeKey else { return sum }
            return sum + max(0, entry.task.expectedSize - (liveProgress[entry.task.id] ?? entry.task.downloadedSize))
        }
    }

    /// Текст для менеджера загрузок, если остатку файла не хватает места на диске (с учётом идущих загрузок).
    private func spaceShortage(for task: DownloadTask) -> String? {
        let needed = task.expectedSize - task.downloadedSize
        guard task.expectedSize > 0, needed > 0 else { return nil }
        let key = PathResolver.volumeKey(for: task.targetDirPath)
        guard let free = freeSpace(volumeKey: key) else { return nil }
        let available = max(0, free - reservedBytes(volumeKey: key))
        guard needed + Self.spaceMargin > available else { return nil }
        let name = (try? URL(fileURLWithPath: key).resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? key
        return String(localized: "Not enough space on “\(name)”: \(Format.diskBytes(needed)) needed, \(Format.diskBytes(available)) free (a \(Format.diskBytes(Self.spaceMargin)) reserve is kept). Free up space and the download will continue automatically.")
    }

    /// Проверка свежим значением свободного места после ошибки потока.
    private func shortageAfterFailure(_ task: DownloadTask) -> String? {
        guard let current = db.task(id: task.id) else { return nil }
        freeSpaceCache[PathResolver.volumeKey(for: task.targetDirPath)] = nil
        return spaceShortage(for: current)
    }

    // MARK: - Reports from workers / scanners

    func report(id: String, delta: Int64, total: Int64) {
        guard running[id] != nil else { return }
        liveProgress[id] = total
        if delta > 0 {
            if running[id]?.task.provider == .googleDrive { countGoogleTraffic(delta, id: id) }
            receivedBytes.insert(id)
            let now = Date().timeIntervalSinceReferenceDate
            meter.add(delta, at: now)
            taskMeters[id, default: ThroughputMeter()].add(delta, at: now)
        }
    }

    /// Ответ 429 / 403 rateLimitExceeded от любого потока: лимит сразу делится пополам.
    func reportRateLimit() {
        balancer.rateLimitHit(now: Date().timeIntervalSinceReferenceDate)
    }

    func scanProgress(files: Int) {
        scannedFiles += files
        schedule()
    }

    func scanFailed(_ message: String) {
        scanErrors.append(message)
        if scanErrors.count > 50 { scanErrors.removeFirst(scanErrors.count - 50) }
    }

    func clearScanErrors() { scanErrors.removeAll() }

    /// Снимок планировщика, счётчики и строки секций — одним вызовом актора. Все смены статусов
    /// идут через этот актор, поэтому между чтениями ничего не меняется.
    func state(sections kinds: [TaskSectionKind]) -> DownloadState {
        let totals = db.totals()
        var snapshot = snapshot()
        snapshot.isPaused = !totals.hasPausable && totals.pausedAllCount > 0
        stateVersion += 1
        let stats = db.downloadLimitStats(provider: .googleDrive, limit: googleLimit.budget)
        let limits = [googleLimit.status(stats, reserved: reservedGoogleBytes())]
        return DownloadState(version: stateVersion, snapshot: snapshot, totals: totals,
                             sections: AppModel.loadSections(kinds, from: db), limits: limits)
    }

    func snapshot() -> EngineSnapshot {
        let counts = runningCounts()
        let active = running.keys.filter { stopReasons[$0] == nil }
        return EngineSnapshot(
            isPaused: false,
            isOnline: isOnline,
            isAuthorized: !authorized.isEmpty,
            // Нет идущих потоков — скорость сразу 0 (а не затухающее среднее за 3 с).
            bytesPerSecond: active.isEmpty ? 0 : meter.bytesPerSecond(window: 3, now: Date().timeIntervalSinceReferenceDate),
            liveProgress: liveProgress,
            // Останавливающиеся потоки уже не считаются: их задачи показаны в паузе / ожидании.
            runningCount: active.count,
            adaptiveLimit: balancer.limit,
            userLimit: balancer.userLimit,
            runningSmall: counts.small,
            runningLarge: counts.large,
            runningExports: counts.export,
            balancerStatus: balancer.status,
            verificationProgress: verifying,
            connecting: Set(active.filter { !receivedBytes.contains($0) }),
            speeds: taskMeters.mapValues { $0.bytesPerSecond(window: 3, now: Date().timeIntervalSinceReferenceDate) },
            lastSession: lastSession,
            scanningFolders: scanningFolders,
            scannedFiles: scannedFiles,
            scanErrors: scanErrors,
            runningTasks: running.values.filter { stopReasons[$0.task.id] == nil }.map {
                RunningTransfer(id: $0.task.id, name: $0.task.fileName, provider: $0.task.provider, size: $0.task.expectedSize)
            }
        )
    }

    // MARK: - Balancing

    private func rebalance() {
        // Без идущих загрузок (общая пауза, пустая очередь) скорость не о чем судить.
        guard started, !authorized.isEmpty, isOnline, !isHalted, !running.isEmpty else { return }
        let speed = meter.bytesPerSecond(window: AdaptiveConcurrency.evaluationWindowSeconds,
                                         now: Date().timeIntervalSinceReferenceDate)
        let saturated = running.count >= balancer.limit && !db.queueHeads(providers: authorized).isEmpty
        balancer.evaluate(speed: speed, saturated: saturated)
        schedule()
    }

    // MARK: - Scheduling

    private func runningCounts() -> (small: Int, large: Int, export: Int) {
        var small = 0, large = 0, export = 0
        for entry in running.values where stopReasons[entry.task.id] == nil {
            switch entry.sizeClass {
            case .small: small += 1
            case .large: large += 1
            case .export: export += 1
            }
        }
        return (small, large, export)
    }

    /// Выбор класса для следующего свободного слота.
    private func pickClass(heads: [TaskSizeClass: Int64]) -> TaskSizeClass? {
        let limit = balancer.limit
        let counts = runningCounts()
        let reserveSmall = limit >= 6 ? 2 : (limit >= 2 ? 1 : 0)
        let reserveLarge = limit >= 2 ? 1 : 0

        // 1. Сначала — незаполненные резервы классов, у которых есть задачи в очереди.
        var reserved: [TaskSizeClass] = []
        if heads[.small] != nil, counts.small < reserveSmall { reserved.append(.small) }
        if heads[.large] != nil, counts.large < reserveLarge { reserved.append(.large) }
        if let oldest = reserved.min(by: { heads[$0]! < heads[$1]! }) { return oldest }

        // 2. Остальные слоты — общий пул в порядке очереди (FIFO по rowid), экспорт не более 2.
        let candidates = heads.keys.filter { $0 != .export || counts.export < Self.exportLimit }
        return candidates.min(by: { heads[$0]! < heads[$1]! })
    }

    private func schedule() {
        guard started, !authorized.isEmpty, isOnline, !isHalted else { return }
        let googleAuthorized = authorized.contains(.googleDrive)
        if googleAuthorized, googleLimit.isServerBlocked {
            // Google ответил «лимит исчерпан»: новые задачи Google сразу ждут, раз в час — одна пробная.
            db.moveQueuedToDailyLimit(provider: .googleDrive, nextAttemptAt: googleLimit.nextProbe.map(Self.unix),
                                      error: googleLimit.serverMessage())
            launchGoogleProbeIfDue()
        }
        var claimedGoogle = false
        while running.count < balancer.limit {
            var claimable = authorized
            var budget: TransferBudget?
            if googleAuthorized {
                switch googleLimit.gate(reserved: reservedGoogleBytes()) {
                case .open: break
                case .budget(let value): budget = value
                case .closed: claimable.remove(.googleDrive)
                }
            }
            guard !claimable.isEmpty else { break }
            let task: DownloadTask
            let sizeClass: TaskSizeClass
            // Сначала — файлы, которые пользователь возобновил вручную.
            if let prioritized = db.claimNextPrioritized(allowExport: runningCounts().export < Self.exportLimit,
                                                         providers: claimable, budget: budget) {
                task = prioritized
                sizeClass = TaskSizeClass(prioritized)
            } else {
                let heads = db.queueHeads(providers: claimable, budget: budget)
                guard let picked = pickClass(heads: heads),
                      let claimed = db.claimNext(sizeClass: picked, providers: claimable, budget: budget) else { break }
                task = claimed
                sizeClass = picked
            }

            // Внешний диск отключён — задача (и вся очередь на этом томе) уходит в ожидание, слот свободен.
            if case .missing(let message) = PathResolver.volumeState(for: task.targetDirPath) {
                db.updateStatus(id: task.id, status: .waitingForVolume, error: message)
                if let root = PathResolver.volumeRoot(for: task.targetDirPath) {
                    db.markWaitingForVolume(volumeRoot: root, message: message)
                }
                continue
            }
            if running[task.id] != nil { continue }
            if let message = spaceShortage(for: task) {
                db.updateStatus(id: task.id, status: .waitingForSpace, error: message)
                continue
            }
            if activePartPaths.contains(task.partPath) {
                db.updateStatus(id: task.id, status: .failed,
                                error: String(localized: "Another download is already writing to “\(task.fileName)” (same name in the same folder)"))
                continue
            }
            if task.provider == .googleDrive { claimedGoogle = true }
            launch(task, sizeClass: sizeClass)
        }
        // Слоты свободны, а ни один файл Google не помещается в остаток своего лимита:
        // очередь Google ждёт (секция «Ожидают»), пока бюджет не освободится.
        if googleAuthorized, !claimedGoogle, !googleLimit.isServerBlocked, googleLimit.budget != nil,
           running.count < balancer.limit, !running.values.contains(where: { $0.task.provider == .googleDrive }),
           db.hasQueuedDownloads(provider: .googleDrive) {
            parkGoogleQueue()
        }
    }

    private static func unix(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970) }

    private func launch(_ task: DownloadTask, sizeClass: TaskSizeClass) {
        liveProgress[task.id] = task.downloadedSize
        receivedBytes.remove(task.id)
        activePartPaths.insert(task.partPath)
        let provider = providers[task.provider]
        let worker = provider.map { DownloadWorker(db: db, provider: $0, scheduler: self, progress: progress, retryWaiter: retryWaiter) }
        let handle = Task.detached(priority: .utility) {
            let outcome = await worker?.run(task) ?? .failed(CloudProviders.unavailableMessage)
            await self.finish(task, outcome: outcome)
        }
        running[task.id] = Running(task: task, sizeClass: sizeClass, handle: handle)
    }

    private func finish(_ task: DownloadTask, outcome: DownloadWorker.Outcome) {
        let wasProbe = googleLimit.probeTaskId == task.id
        if wasProbe { googleLimit.probeTaskId = nil }
        running[task.id] = nil
        // Последняя передача закончилась — сглаживание скорости обнуляется вместе с ней.
        if running.isEmpty { meter.reset() }
        activePartPaths.remove(task.partPath)
        liveProgress[task.id] = nil
        taskMeters[task.id] = nil
        receivedBytes.remove(task.id)
        let reason = stopReasons.removeValue(forKey: task.id)

        switch outcome {
        case .completed(let size):
            db.markCompleted(id: task.id, size: size)
        case .downloaded(let size):
            if reason == .cancel {
                db.updateStatus(id: task.id, status: .cancelled)
                removePartFile(task.id)
            } else {
                completeDownloaded(task, size: size)
            }
        case .failed(let message):
            if reason == .cancel {
                db.updateStatus(id: task.id, status: .cancelled)
                removePartFile(task.id)
            } else if reason == .dailyLimit {
                markLimitWaiting(task)
            } else if let shortage = shortageAfterFailure(task) {
                // Место кончилось во время скачивания: не ошибка, а ожидание места (часть файла сохранена).
                db.updateStatus(id: task.id, status: .waitingForSpace, error: shortage)
            } else {
                db.updateStatus(id: task.id, status: .failed, error: message)
                session.failed += 1
            }
        case .waitingForVolume(let message):
            db.updateStatus(id: task.id, status: .waitingForVolume, error: message)
            if let root = PathResolver.volumeRoot(for: task.targetDirPath) {
                db.markWaitingForVolume(volumeRoot: root, message: message)
            }
        case .limitReached:
            if reason == .cancel {
                db.updateStatus(id: task.id, status: .cancelled)
                removePartFile(task.id)
            } else {
                // Google ответил «лимит исчерпан»: стоят все скачивания Google, пробный запрос — через час.
                enterGoogleServerLimit()
                markLimitWaiting(task)
            }
        case .stopped:
            switch reason {
            case .pauseTask:
                db.updateStatus(id: task.id, status: .paused)
            case .pauseAll:
                db.updateStatus(id: task.id, status: .pausedAll)
            case .network:
                db.updateStatus(id: task.id, status: .waitingForNetwork, error: String(localized: "Waiting for network…"))
            case .dailyLimit:
                markLimitWaiting(task)
            case .cancel:
                db.updateStatus(id: task.id, status: .cancelled)
                removePartFile(task.id)
            case .requeue, nil:
                db.updateStatus(id: task.id, status: .queued)
            }
        case .signedOut:
            // Вход отозван: очередь стоит до нового входа, скачанная часть файла сохранена.
            if wasProbe, googleLimit.isServerBlocked { googleLimit.probeNow() }
            authorized.remove(task.provider)
            stopAll(.requeue, provider: task.provider)
            switch reason {
            case .pauseTask:
                db.updateStatus(id: task.id, status: .paused)
            case .cancel:
                db.updateStatus(id: task.id, status: .cancelled)
                removePartFile(task.id)
            default:
                db.updateStatus(id: task.id, status: .queued)
            }
        }
        // Проба закончилась без ответа о лимите и без полученных байт (файл уже был на диске, ошибка файла):
        // сразу пробуем следующую ждущую задачу.
        if wasProbe, googleLimit.isServerBlocked, !Self.isLimitOutcome(outcome) { googleLimit.probeNow() }
        schedule()
        checkIdle()
    }

    private static func isLimitOutcome(_ outcome: DownloadWorker.Outcome) -> Bool {
        if case .limitReached = outcome { return true }
        return false
    }

    // MARK: - Limits

    /// Раз в 30 секунд и после сна: старые минуты выходят из окна 24 часов — ждущие задачи Google
    /// продолжаются, когда бюджет освободился; после ответа Google о лимите — пробный запрос раз в час.
    func checkLimits() {
        googleLimit.prune(db: db)
        googleLimit.flush(db: db)
        // Во время общей паузы плановая проверка ничего не запускает (ручное «Попробовать сейчас» — да).
        guard pausedAllAt == nil else { return }
        if googleLimit.isServerBlocked {
            if googleLimit.probeDue { schedule() }
            return
        }
        releaseGoogleWaiting()
    }

    /// «Попробовать сейчас»: после ответа Google — пробный запрос сразу; при своём лимите — перепроверка
    /// (файлы, которые не помещаются в остаток, вернутся в ожидание).
    func retryLimitNow() {
        if googleLimit.isServerBlocked {
            googleLimit.probeNow()
        } else if db.requeueLimitWaiting(provider: .googleDrive) == 0 {
            return
        }
        schedule()
    }

    /// Лимит изменён в настройках: исчерпан — скачивания Google останавливаются; иначе ждущие продолжаются.
    func limitsChanged() {
        if googleLimit.isExhausted() {
            enterGoogleBudgetLimit()
        } else {
            releaseGoogleWaiting()
        }
        schedule()
    }

    /// Ждущие своего лимита задачи Google — в очередь, если остатка хватает хотя бы одной из них.
    private func releaseGoogleWaiting() {
        guard !googleLimit.isServerBlocked else { return }
        guard googleLimit.budget != nil else {
            // Лимит выключен: ждать нечего.
            if db.requeueLimitWaiting(provider: .googleDrive) > 0 { schedule() }
            return
        }
        guard case .budget(let budget) = googleLimit.gate(reserved: reservedGoogleBytes()) else { return }
        let stats = db.downloadLimitStats(provider: .googleDrive, limit: budget.limit)
        guard stats.count > 0, let needed = googleLimit.neededToResume(stats), budget.remaining >= needed else { return }
        if db.requeueLimitWaiting(provider: .googleDrive) > 0 { schedule() }
    }

    /// Сколько ещё допишут идущие скачивания Google (бюджет на них уже занят).
    private func reservedGoogleBytes() -> Int64 {
        running.values.reduce(0) { sum, entry in
            guard entry.task.provider == .googleDrive, stopReasons[entry.task.id] == nil, entry.task.expectedSize > 0 else { return sum }
            return sum + max(0, entry.task.expectedSize - (liveProgress[entry.task.id] ?? entry.task.downloadedSize))
        }
    }

    private func countGoogleTraffic(_ bytes: Int64, id: String) {
        googleLimit.count(bytes, db: db)
        if id == googleLimit.probeTaskId {
            // Пробный запрос получил данные: Google снова отдаёт файлы — очередь Google продолжается.
            googleLimit.unblock()
            db.requeueLimitWaiting(provider: .googleDrive)
            schedule()
        }
        if googleLimit.isExhausted(),
           running.contains(where: { $0.value.task.provider == .googleDrive && stopReasons[$0.key] == nil }) {
            enterGoogleBudgetLimit()
        }
    }

    /// Свой лимит исчерпан: идущие скачивания Google останавливаются (часть файла сохраняется
    /// и продолжится с того же байта), очередь Google ждёт, пока бюджет не освободится.
    private func enterGoogleBudgetLimit() {
        googleLimit.flush(db: db)
        for (id, entry) in running where entry.task.provider == .googleDrive && stopReasons[id] == nil {
            stop(id, .dailyLimit)
            markLimitWaiting(entry.task)
        }
        parkGoogleQueue()
    }

    /// Google ответил «лимит исчерпан»: новых запросов нет, пробный — через час.
    private func enterGoogleServerLimit() {
        googleLimit.block()
        googleLimit.flush(db: db)
        for (id, entry) in running where entry.task.provider == .googleDrive && stopReasons[id] == nil {
            stop(id, .dailyLimit)
            markLimitWaiting(entry.task)
        }
        db.moveQueuedToDailyLimit(provider: .googleDrive, nextAttemptAt: googleLimit.nextProbe.map(Self.unix),
                                  error: googleLimit.serverMessage())
    }

    /// Очередь Google → ожидание своего лимита, с оценкой, когда продолжим.
    private func parkGoogleQueue() {
        let stats = db.downloadLimitStats(provider: .googleDrive, limit: googleLimit.budget)
        var probe = stats
        // Оценка с учётом и тех задач, что сейчас уходят в ожидание: берём худший случай — порцию.
        probe.count = max(1, stats.count)
        if probe.smallestFitting == nil { probe.hasOversized = true }
        let resume = googleLimit.resumeEstimate(probe, reserved: reservedGoogleBytes())
        db.moveQueuedToDailyLimit(provider: .googleDrive, nextAttemptAt: resume.map(Self.unix),
                                  error: googleLimit.budgetMessage(resumeAt: resume))
    }

    private func markLimitWaiting(_ task: DownloadTask) {
        if googleLimit.isServerBlocked {
            db.markLimitWaiting(id: task.id, nextAttemptAt: googleLimit.nextProbe.map(Self.unix), error: googleLimit.serverMessage())
        } else {
            let resume = googleLimit.resumeEstimate(LimitWaitingStats(count: 1, hasOversized: true), reserved: 0)
            db.markLimitWaiting(id: task.id, nextAttemptAt: resume.map(Self.unix), error: googleLimit.budgetMessage(resumeAt: resume))
        }
    }

    /// Раз в час (или по «Попробовать сейчас») — одна пробная задача Google: та, что дольше всех ждёт.
    private func launchGoogleProbeIfDue() {
        guard googleLimit.probeDue, googleLimit.probeTaskId == nil, pausedAllAt == nil,
              running.count < balancer.limit, let task = db.claimDownloadProbe(provider: .googleDrive) else { return }
        googleLimit.beginProbe(task.id)
        if case .missing(let message) = PathResolver.volumeState(for: task.targetDirPath) {
            googleLimit.probeTaskId = nil
            googleLimit.probeNow()
            db.updateStatus(id: task.id, status: .waitingForVolume, error: message)
            return
        }
        launch(task, sizeClass: TaskSizeClass(task))
    }

    #if DEBUG
    /// Debug → Simulate: ответ Google «лимит исчерпан» (тот же путь, что и настоящий ответ).
    func debugSimulateServerLimit() {
        enterGoogleServerLimit()
        schedule()
    }

    /// Debug → Simulate: счётчик на `fraction` лимита (в базу не пишется); 0 — снять.
    func debugSimulateUsage(_ fraction: Double) {
        googleLimit.debugExtraUsed = 0
        guard fraction > 0, let budget = googleLimit.budget else { return }
        googleLimit.debugExtraUsed = max(0, Int64(Double(budget) * fraction) - googleLimit.used())
    }
    #endif

    // MARK: - Verification & finalization

    private func completeDownloaded(_ task: DownloadTask, size: Int64) {
        if task.needsChecksumVerification {
            db.updateStatus(id: task.id, status: .verifying)
            verificationQueue.append(task)
            startVerifications()
        } else {
            finalizeFile(task, verified: false)
        }
    }

    private func finalizeFile(_ task: DownloadTask, verified: Bool) {
        do {
            let size = try FileFinalizer.finalize(task)
            db.markCompleted(id: task.id, size: size, verified: verified)
            session.files += 1
            session.bytes += size
            session.addDirectory(task.targetDirPath)
            if verified { session.verified += 1 }
        } catch {
            session.failed += 1
            if case .missing(let message) = PathResolver.volumeState(for: task.targetDirPath) {
                db.updateStatus(id: task.id, status: .waitingForVolume, error: message)
            } else {
                db.updateStatus(id: task.id, status: .failed, error: String(localized: "Couldn’t save the file: \(error.localizedDescription)"))
            }
        }
    }

    private func startVerifications() {
        while verifying.count < Self.maxConcurrentVerifications, !verificationQueue.isEmpty {
            let task = verificationQueue.removeFirst()
            guard verifying[task.id] == nil else { continue }
            verifying[task.id] = 0
            Task.detached(priority: .utility) {
                let result = await FileFinalizer.verify(task) { bytes in
                    Task { await self.reportVerification(id: task.id, bytes: bytes) }
                }
                await self.verificationFinished(task, result: result)
            }
        }
    }

    private func reportVerification(id: String, bytes: Int64) {
        if verifying[id] != nil { verifying[id] = bytes }
    }

    private func verificationFinished(_ task: DownloadTask, result: FileFinalizer.VerificationResult) {
        verifying[task.id] = nil
        defer {
            startVerifications()
            schedule()
            checkIdle()
        }
        // Пока шла проверка, задачу могли отменить — результат не применяем.
        guard let current = db.task(id: task.id), current.status == .verifying else {
            if db.task(id: task.id)?.status == .cancelled { removePartFile(task.id) }
            return
        }

        switch result {
        case .verified:
            finalizeFile(current, verified: true)
        case .mismatch(let expected, let actual):
            try? FileManager.default.removeItem(atPath: current.partPath)
            let failures = current.checksumFailures + 1
            let giveUp = failures >= 2
            let message = giveUp
                ? String(localized: "Checksum mismatch")
                : String(localized: "Checksum mismatch (expected \(String(expected.prefix(8)))…, got \(String(actual.prefix(8)))…) — downloading the file again")
            db.markChecksumMismatch(id: current.id, failures: failures, error: message, giveUp: giveUp)
            if giveUp { session.failed += 1 }
        case .missingFile:
            db.markChecksumMismatch(id: current.id, failures: current.checksumFailures,
                                    error: String(localized: "The downloaded file disappeared from the disk — downloading again"), giveUp: false)
        case .failed(let message):
            if case .missing(let volumeMessage) = PathResolver.volumeState(for: current.targetDirPath) {
                db.updateStatus(id: current.id, status: .waitingForVolume, error: volumeMessage)
            } else {
                db.updateStatus(id: current.id, status: .failed, error: String(localized: "File verification failed: \(message)"))
                session.failed += 1
            }
        }
    }

    /// Очередь опустела — итог сессии для уведомления «Проект скачан».
    private func checkIdle() {
        guard session.active, running.isEmpty, verifying.isEmpty, verificationQueue.isEmpty,
              scanningFolders == 0, !isHalted else { return }
        let totals = db.totals()
        let counts = totals.countsByStatus
        // Общая пауза — очередь не закончилась, уведомление «скачано» не нужно.
        let stillWorking = [TaskStatus.queued, .downloading, .verifying, .waitingForNetwork, .pausedAll]
            .reduce(0) { $0 + (counts[$1] ?? 0) }
        guard stillWorking == 0 else { return }
        defer { session = Session() }
        guard session.files > 0 || session.failed > 0 else { return }
        sessionCounter += 1
        lastSession = QueueSessionSummary(
            id: sessionCounter, projects: session.projects, files: session.files, bytes: session.bytes,
            verified: session.verified, failed: session.failed,
            waitingLimit: counts[.waitingDailyLimit] ?? 0, waitingVolume: counts[.waitingForVolume] ?? 0,
            destination: session.directory)
    }

    private func stop(_ id: String, _ reason: StopReason) {
        guard let entry = running[id] else { return }
        stopReasons[id] = reason
        entry.handle.cancel()
    }

    /// - Parameter provider: только задачи этого облака (nil — все).
    private func stopAll(_ reason: StopReason, provider: CloudProviderKind? = nil) {
        for (id, entry) in running where provider == nil || entry.task.provider == provider { stop(id, reason) }
    }

    private func removePartFile(_ id: String) {
        guard let task = db.task(id: id) else { return }
        try? FileManager.default.removeItem(atPath: task.partPath)
    }

    /// Имя файла, не конфликтующее с другим объектом облака в той же локальной папке.
    private func freeFileName(for item: CloudItem, in dir: String) -> String {
        var name = item.localFileName
        var used: Set<String> = [name.lowercased()]
        while db.fileNameTaken(targetDir: dir, fileName: name, except: item.provider, fileId: item.id) {
            name = PathResolver.uniqueName(item.localFileName, used: &used)
        }
        return name
    }

    // MARK: - Folder scans

    private func startScan(_ folder: CloudItem, provider: any CloudProvider, destinationDir: String,
                           ancestorIds: [String]) -> Task<EnqueueReport, Never> {
        scanningFolders += 1
        let scanner = FolderScanner(db: db, provider: provider, scheduler: self)
        return Task.detached(priority: .utility) {
            let report = await scanner.scan(folder, into: destinationDir, ancestorIds: ancestorIds)
            await self.scanFinished()
            return report
        }
    }

    private func scanFinished() {
        scanningFolders = max(0, scanningFolders - 1)
        if scanningFolders == 0 { scannedFiles = 0 }
        schedule()
        checkIdle()
    }
}
