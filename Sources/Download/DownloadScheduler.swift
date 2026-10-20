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
    private var balancer: AdaptiveConcurrency

    private var started = false
    private var isPaused = false
    private var isOnline = true
    private var isAuthorized = false

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
    }
    private var session = Session()
    private var sessionCounter = 0
    private var lastSession: QueueSessionSummary?

    init(db: DatabaseManager, providers: CloudProviders) {
        self.db = db
        self.providers = providers
        self.progress = ProgressStore(db: db)
        self.balancer = AdaptiveConcurrency(userLimit: AppSettings.maxConcurrentDownloads)
    }

    // MARK: - Lifecycle

    /// Подхватывает незавершённые задачи после перезапуска приложения.
    func start(authorized: Bool) {
        guard !started else { return }
        started = true
        isAuthorized = authorized
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
                await self?.requeueDueQuotaTasks()
            }
        })
        schedule()
    }

    func setAuthorized(_ authorized: Bool) {
        isAuthorized = authorized
        if authorized { schedule() } else { stopAll(.requeue) }
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
            stopAll(.network)
        }
    }

    /// Перед перезапуском приложения: новые задачи не запускаются, идущие останавливаются и возвращаются
    /// в очередь (прогресс — в `.gdrive.part`), функция ждёт, пока потоки закроют файлы.
    /// После запуска очередь продолжается автоматически.
    func stopForRelaunch() async {
        isPaused = true
        let handles = running.values.map(\.handle)
        stopAll(.requeue)
        for handle in handles { await handle.value }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            stopAll(.pauseAll)
        } else {
            // «Возобновить все» в трее и в шапке возобновляет и файлы, приостановленные вручную.
            // В остальных случаях (сеть, перезапуск, разгон потоков) задачи «На паузе» не трогаются.
            db.resumeAllPaused()
            balancer.reset(reason: String(localized: "Resumed"))
            meter.reset()
            schedule()
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
    func enqueue(_ items: [CloudItem], destinationDir: String, projectName: String) async -> EnqueueReport {
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
                scans.append(startScan(item, provider: provider, destinationDir: destinationDir))
            } else if item.isDownloadable {
                let name = freeFileName(for: item, in: destinationDir)
                do {
                    try PathResolver.validate((destinationDir as NSString).appendingPathComponent(name), inside: destinationDir)
                } catch {
                    scanFailed(error.localizedDescription)
                    report.errors.append(error.localizedDescription)
                    continue
                }
                files.append(.make(from: item, fileName: name, targetDir: destinationDir))
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
        if running[id] != nil { stop(id, .pauseTask) } else { db.updateStatus(id: id, status: .paused) }
    }

    /// «Возобновить» отдельный файл: в начало очереди, докачка с размера .gdrive.part через Range.
    func resumeTask(_ id: String) {
        guard running[id] == nil else { return }
        db.resume(id: id)
        schedule()
    }

    /// Возобновить все файлы, приостановленные вручную.
    func resumeAllPaused() {
        db.resumeAllPaused()
        schedule()
    }

    func cancelTask(_ id: String) {
        if running[id] != nil {
            stop(id, .cancel)
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
        .queued, .waitingForVolume, .waitingForSpace, .waitingForNetwork, .waitingForQuota,
    ]

    /// Очередь предыдущего аккаунта после входа другим: всё незавершённое — на паузу (прогресс сохраняется).
    func pauseUnfinished() {
        db.moveStatuses(Self.unfinishedStatuses, to: .paused)
    }

    /// Очередь предыдущего аккаунта после входа другим: незавершённое удаляется из очереди вместе с частями файлов.
    func cancelUnfinished() {
        for task in db.tasks(statuses: Self.unfinishedStatuses + [.paused, .failed], limit: 1_000_000)
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
        requeueDueQuotaTasks()
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
        if delta > 0 { meter.add(delta, at: Date().timeIntervalSinceReferenceDate) }
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

    func snapshot() -> EngineSnapshot {
        let counts = runningCounts()
        return EngineSnapshot(
            isPaused: isPaused,
            isOnline: isOnline,
            isAuthorized: isAuthorized,
            bytesPerSecond: meter.bytesPerSecond(window: 3, now: Date().timeIntervalSinceReferenceDate),
            liveProgress: liveProgress,
            runningCount: running.count,
            adaptiveLimit: balancer.limit,
            userLimit: balancer.userLimit,
            runningSmall: counts.small,
            runningLarge: counts.large,
            runningExports: counts.export,
            balancerStatus: balancer.status,
            verificationProgress: verifying,
            lastSession: lastSession,
            scanningFolders: scanningFolders,
            scannedFiles: scannedFiles,
            scanErrors: scanErrors
        )
    }

    // MARK: - Balancing

    private func rebalance() {
        guard started, isAuthorized, isOnline, !isPaused else { return }
        let speed = meter.bytesPerSecond(window: AdaptiveConcurrency.evaluationWindowSeconds,
                                         now: Date().timeIntervalSinceReferenceDate)
        let saturated = running.count >= balancer.limit && !db.queueHeads().isEmpty
        balancer.evaluate(speed: speed, saturated: saturated)
        schedule()
    }

    // MARK: - Scheduling

    private func runningCounts() -> (small: Int, large: Int, export: Int) {
        var small = 0, large = 0, export = 0
        for entry in running.values {
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
        guard started, isAuthorized, isOnline, !isPaused else { return }
        while running.count < balancer.limit {
            let task: DownloadTask
            let sizeClass: TaskSizeClass
            // Сначала — файлы, которые пользователь возобновил вручную.
            if let prioritized = db.claimNextPrioritized(allowExport: runningCounts().export < Self.exportLimit) {
                task = prioritized
                sizeClass = TaskSizeClass(prioritized)
            } else {
                let heads = db.queueHeads()
                guard let picked = pickClass(heads: heads), let claimed = db.claimNext(sizeClass: picked) else { return }
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
            launch(task, sizeClass: sizeClass)
        }
    }

    private func launch(_ task: DownloadTask, sizeClass: TaskSizeClass) {
        liveProgress[task.id] = task.downloadedSize
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
        running[task.id] = nil
        activePartPaths.remove(task.partPath)
        liveProgress[task.id] = nil
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
        case .waitingForQuota(let message):
            if reason == .cancel {
                db.updateStatus(id: task.id, status: .cancelled)
                removePartFile(task.id)
            } else {
                // 1 ч → 2 ч → 4 ч → … → 24 ч. Остальные файлы продолжают качаться.
                let attempts = task.quotaAttempts + 1
                let delay = Self.quotaDelay(attempt: attempts)
                let next = Date().addingTimeInterval(delay)
                let time = next.formatted(date: .omitted, time: .shortened)
                db.markWaitingForQuota(id: task.id, attempts: attempts, nextAttemptAt: Int64(next.timeIntervalSince1970),
                                       error: String(localized: "Google has temporarily limited downloads of this file (quota). Next attempt at \(time). \(message)"))
            }
        case .stopped:
            switch reason {
            case .pauseTask:
                db.updateStatus(id: task.id, status: .paused)
            case .network:
                db.updateStatus(id: task.id, status: .waitingForNetwork, error: String(localized: "Waiting for network…"))
            case .cancel:
                db.updateStatus(id: task.id, status: .cancelled)
                removePartFile(task.id)
            case .pauseAll, .requeue, nil:
                db.updateStatus(id: task.id, status: .queued)
            }
        case .signedOut:
            // Вход отозван: очередь стоит до нового входа, скачанная часть файла сохранена.
            isAuthorized = false
            stopAll(.requeue)
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
        schedule()
        checkIdle()
    }

    /// Пауза ожидания квоты: 1 ч, 2 ч, 4 ч, … не больше 24 ч.
    static func quotaDelay(attempt: Int) -> TimeInterval {
        min(24 * 3600, 3600 * pow(2, Double(max(0, attempt - 1))))
    }

    /// Вернуть в очередь задачи, у которых наступило время повтора после квоты.
    func requeueDueQuotaTasks(force: Bool = false) {
        if db.requeueDueQuotaTasks(force: force) > 0 { schedule() }
    }

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
              scanningFolders == 0, !isPaused else { return }
        let totals = db.totals()
        let counts = totals.countsByStatus
        let stillWorking = [TaskStatus.queued, .downloading, .verifying, .waitingForNetwork]
            .reduce(0) { $0 + (counts[$1] ?? 0) }
        guard stillWorking == 0 else { return }
        defer { session = Session() }
        guard session.files > 0 || session.failed > 0 else { return }
        sessionCounter += 1
        lastSession = QueueSessionSummary(
            id: sessionCounter, projects: session.projects, files: session.files, bytes: session.bytes,
            verified: session.verified, failed: session.failed,
            waitingQuota: counts[.waitingForQuota] ?? 0, waitingVolume: counts[.waitingForVolume] ?? 0)
    }

    private func stop(_ id: String, _ reason: StopReason) {
        guard let entry = running[id] else { return }
        stopReasons[id] = reason
        entry.handle.cancel()
    }

    private func stopAll(_ reason: StopReason) {
        for id in running.keys { stop(id, reason) }
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

    private func startScan(_ folder: CloudItem, provider: any CloudProvider, destinationDir: String) -> Task<EnqueueReport, Never> {
        scanningFolders += 1
        let scanner = FolderScanner(db: db, provider: provider, scheduler: self)
        return Task.detached(priority: .utility) {
            let report = await scanner.scan(folder, into: destinationDir)
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
