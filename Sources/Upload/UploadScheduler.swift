import Foundation

/// Очередь отправки в облако. Работает независимо от `DownloadScheduler`:
/// свой лимит (по умолчанию 3, от 1 до 6), свои слоты, общая только сеть и токен.
///
/// - При ответе облака об ограничении частоты лимит сразу делится пополам и потом
///   восстанавливается по одному слоту в минуту.
/// - Потеря сети: идущие отправки останавливаются (`waiting_for_network`) и продолжаются
///   после восстановления с подтверждённого сервером байта.
/// - Исходный файл на отключённом внешнем диске — `waiting_for_volume` до подключения.
/// - Лимиты: свой бюджет Google Drive за скользящие 24 часа; ответ облака о лимите (Google — дневной
///   лимит отправки, Dropbox — лимит передачи данных бизнес-тарифа) останавливает отправку в это облако,
///   пробный запрос — раз в час. Остальные облака и скачивание продолжают работать.
actor UploadScheduler {
    static let maxConcurrentVerifications = 2

    private enum StopReason { case pause, pauseAll, network, cancel, requeue, dailyLimit }

    private struct Running {
        let task: UploadTask
        let handle: Task<Void, Never>
    }

    private let db: DatabaseManager
    private let providers: CloudProviders
    private let retryWaiter = RetryWaiter()

    private var running: [String: Running] = [:]
    private var stopReasons: [String: StopReason] = [:]
    private var liveProgress: [String: Int64] = [:]
    private var meter = ThroughputMeter()
    /// Скорость каждого файла — для строки в списке отправки.
    private var taskMeters: [String: ThroughputMeter] = [:]

    private var userLimit: Int
    private var limit: Int
    private var lastRateLimit: TimeInterval = 0

    private var started = false
    private var isOnline = true
    /// Облака с действующим входом.
    private var authorized: Set<CloudProviderKind> = []
    private var isPaused = false
    /// Вход без права записи: отправка стоит, пока пользователь не войдёт заново.
    private var writeBlocked: Set<CloudProviderKind> = []
    private var reauthRequests = 0
    private var preparing: [String] = []

    private var verificationQueue: [UploadTask] = []
    private var verifying: [String: Int64] = [:]
    private var timers: [Task<Void, Never>] = []

    /// Лимиты отправки по облакам: у Google — свой бюджет и ответ Google, у Dropbox — только ответ Dropbox.
    private var limiters: [CloudProviderKind: TransferLimiter]

    init(db: DatabaseManager, providers: CloudProviders) {
        self.db = db
        self.providers = providers
        let limit = AppSettings.maxConcurrentUploads
        self.userLimit = limit
        self.limit = limit
        self.limiters = Dictionary(uniqueKeysWithValues: CloudProviderKind.allCases.map {
            ($0, TransferLimiter(provider: $0, direction: .upload, db: db))
        })
    }

    // MARK: - Lifecycle

    /// После перезапуска: прерванные отправки снова в очереди (продолжатся с подтверждённого сервером байта),
    /// прерванные проверки хеша — снова в проверке.
    func start(authorized: Set<CloudProviderKind>) {
        guard !started else { return }
        started = true
        self.authorized = authorized
        db.moveUploadStatuses([.uploading, .waitingForNetwork], to: .queued)
        verificationQueue = db.uploads(statuses: [.verifying])
        startVerifications()
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.recheckVolumes()
                await self?.restoreLimit()
                await self?.checkLimits()
            }
        })
        schedule()
    }

    func setAuthorized(_ provider: CloudProviderKind, _ isAuthorized: Bool) {
        if isAuthorized {
            authorized.insert(provider)
            writeBlocked.remove(provider)
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
            meter.reset()
            db.moveUploadStatuses([.waitingForNetwork], to: .queued)
            Task { await retryWaiter.wakeAll() }
            schedule()
        } else {
            stopAll(.network)
        }
    }

    /// Перед перезапуском приложения: идущие отправки возвращаются в очередь (подтверждённые части
    /// уже в базе, сессии сохранены) и после запуска продолжаются автоматически.
    func stopForRelaunch() async {
        isPaused = true
        for provider in limiters.keys { limiters[provider]?.flush(db: db) }
        let handles = running.values.map(\.handle)
        stopAll(.requeue)
        for handle in handles { await handle.value }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            stopAll(.pauseAll)
        } else {
            db.resumeAllPausedUploads()
            meter.reset()
            schedule()
        }
    }

    func setUserLimit(_ value: Int) {
        userLimit = AppSettings.clampUploadConcurrency(value)
        limit = userLimit
        schedule()
    }

    func wakeUp() {
        Task { await retryWaiter.wakeAll() }
        recheckVolumes()
        checkLimits()
    }

    func recheckVolumes() {
        for root in db.uploadVolumesAwaitingMount() {
            if case .available = PathResolver.volumeState(for: root) {
                db.requeueUploadsWaitingForVolume(volumeRoot: root)
            }
        }
        // Проверки хеша, прерванные отключением диска.
        for task in db.uploads(statuses: [.verifying])
        where verifying[task.id] == nil && !verificationQueue.contains(where: { $0.id == task.id }) {
            if case .available = PathResolver.volumeState(for: task.localPath) { verificationQueue.append(task) }
        }
        startVerifications()
        schedule()
    }

    // MARK: - Queue

    func beginPreparing(_ title: String) { preparing.append(title) }

    func endPreparing(_ title: String) {
        if let index = preparing.firstIndex(of: title) { preparing.remove(at: index) }
    }

    func enqueue(_ tasks: [UploadTask]) throws -> (added: Int, alreadyQueued: Int) {
        let result = try db.insertUploads(tasks)
        schedule()
        return result
    }

    func pauseTask(_ id: String) {
        if running[id] != nil { stop(id, .pause) } else { db.updateUploadStatus(id: id, status: .paused) }
    }

    func resumeTask(_ id: String) {
        guard running[id] == nil else { return }
        db.resumeUpload(id: id)
        schedule()
    }

    /// «Начать заново» / «Загрузить заново»: новая сессия и отправка с нуля.
    func restartTask(_ id: String) {
        guard running[id] == nil, let task = db.uploadTask(id: id) else { return }
        guard let attributes = UploadTask.sourceAttributes(task.localPath) else {
            db.updateUploadStatus(id: id, status: .failed,
                                  error: String(localized: "Source file not found: \(PathResolver.displayPath(task.localPath))"))
            return
        }
        if let session = task.sessionURI, let provider = providers[task.provider] {
            Task { await provider.cancelUploadSession(session) }
        }
        db.restartUpload(id: id, size: attributes.size, modifiedAt: attributes.modifiedAt)
        schedule()
    }

    func cancelTask(_ id: String) {
        if running[id] != nil {
            stop(id, .cancel)
        } else {
            cancelSession(of: id)
            db.updateUploadStatus(id: id, status: .cancelled)
        }
    }

    func resumeAllPaused() {
        db.resumeAllPausedUploads()
        schedule()
    }

    func retryFailed() {
        db.retryFailedUploads()
        schedule()
    }

    private static let unfinishedStatuses: [UploadStatus] = [.queued, .waitingForNetwork, .waitingForVolume, .waitingDailyLimit]

    /// Очередь предыдущего аккаунта после входа другим: всё незавершённое — на паузу.
    func pauseUnfinished(_ provider: CloudProviderKind) {
        db.moveUploadStatuses(Self.unfinishedStatuses, to: .paused, provider: provider)
    }

    /// Очередь предыдущего аккаунта после входа другим: незавершённое удаляется из очереди.
    func cancelUnfinished(_ provider: CloudProviderKind) {
        for task in db.uploads(statuses: Self.unfinishedStatuses + [.paused, .failed], provider: provider) where running[task.id] == nil {
            cancelSession(of: task.id)
            db.updateUploadStatus(id: task.id, status: .cancelled)
        }
    }

    // MARK: - Reports

    func report(id: String, bytes: Int64, sentDelta: Int64) {
        guard let entry = running[id] else { return }
        // Пробная задача: облако приняло сессию и подтвердило смещение — отправка снова разрешена.
        if sentDelta == 0, limiters[entry.task.provider]?.probeTaskId == id { limitLifted(entry.task.provider) }
        liveProgress[id] = max(bytes, 0)
        if sentDelta > 0 {
            if let provider = running[id]?.task.provider { countTraffic(sentDelta, provider: provider) }
            let now = Date().timeIntervalSinceReferenceDate
            meter.add(sentDelta, at: now)
            taskMeters[id, default: ThroughputMeter()].add(sentDelta, at: now)
        }
    }

    /// 403 rateLimitExceeded / userRateLimitExceeded или 429: меньше параллельных отправок.
    func reportRateLimit() {
        lastRateLimit = Date().timeIntervalSinceReferenceDate
        limit = max(1, limit / 2)
    }

    /// Через 2 минуты без ограничений — по одному слоту обратно до предела из настроек.
    private func restoreLimit() {
        guard limit < userLimit, Date().timeIntervalSinceReferenceDate - lastRateLimit > 120 else { return }
        limit += 1
        schedule()
    }

    func snapshot() -> UploadSnapshot {
        let now = Date().timeIntervalSinceReferenceDate
        return UploadSnapshot(
            isOnline: isOnline, isPaused: isPaused, runningCount: running.count, limit: limit, userLimit: userLimit,
            // Нет идущих отправок — скорость сразу 0 (а не затухающее среднее за 3 с).
            bytesPerSecond: running.keys.allSatisfy({ stopReasons[$0] != nil }) ? 0
                : meter.bytesPerSecond(window: 3, now: Date().timeIntervalSinceReferenceDate),
            liveProgress: liveProgress, speeds: taskMeters.mapValues { $0.bytesPerSecond(window: 3, now: now) },
            verificationProgress: verifying, reauthRequests: reauthRequests,
            preparing: preparing,
            runningTasks: running.values.filter { stopReasons[$0.task.id] == nil }.map {
                RunningTransfer(id: $0.task.id, name: $0.task.fileName, provider: $0.task.provider, size: $0.task.fileSize)
            },
            limits: limitStatuses())
    }

    // MARK: - Scheduling

    private func schedule() {
        let providers = authorized.subtracting(writeBlocked)
        guard started, !providers.isEmpty, isOnline, !isPaused else { return }
        for provider in providers where limiters[provider]?.isServerBlocked == true {
            // Облако ответило «лимит исчерпан»: новые отправки сразу ждут, раз в час — одна пробная.
            db.moveQueuedUploadsToDailyLimit(provider: provider, error: limiters[provider]?.serverMessage() ?? "")
            launchProbeIfDue(provider)
        }
        var claimedBudgeted: Set<CloudProviderKind> = []
        while running.count < limit {
            var claimable = providers
            var budgets: [TransferBudget] = []
            for provider in providers {
                guard let limiter = limiters[provider] else { continue }
                switch limiter.gate(reserved: reservedBytes(provider)) {
                case .open: break
                case .budget(let budget): budgets.append(budget)
                case .closed: claimable.remove(provider)
                }
            }
            guard !claimable.isEmpty, let task = db.claimNextUpload(providers: claimable, budgets: budgets) else { break }
            if case .missing(let message) = PathResolver.volumeState(for: task.localPath) {
                db.updateUploadStatus(id: task.id, status: .waitingForVolume, error: message)
                if let root = PathResolver.volumeRoot(for: task.localPath) {
                    db.markUploadsWaitingForVolume(volumeRoot: root, message: message)
                }
                continue
            }
            claimedBudgeted.insert(task.provider)
            launch(task)
        }
        // Слоты свободны, а ни один файл облака не помещается в остаток своего лимита — очередь облака ждёт.
        guard running.count < limit else { return }
        for provider in providers where !claimedBudgeted.contains(provider) {
            guard let limiter = limiters[provider], !limiter.isServerBlocked, limiter.budget != nil,
                  !running.values.contains(where: { $0.task.provider == provider }) else { continue }
            parkQueue(provider)
        }
    }

    private func launch(_ task: UploadTask) {
        liveProgress[task.id] = task.uploadedBytes
        let provider = providers[task.provider]
        let worker = provider.map { UploadWorker(db: db, provider: $0, scheduler: self, retryWaiter: retryWaiter) }
        let handle = Task.detached(priority: .utility) {
            let outcome = await worker?.run(task) ?? .failed(CloudProviders.unavailableMessage, nil)
            await self.finish(task, outcome: outcome)
        }
        running[task.id] = Running(task: task, handle: handle)
    }

    private func finish(_ task: UploadTask, outcome: UploadWorker.Outcome) {
        let wasProbe = limiters[task.provider]?.probeTaskId == task.id
        if wasProbe { limiters[task.provider]?.probeTaskId = nil }
        running[task.id] = nil
        // Последняя отправка закончилась — сглаживание скорости обнуляется вместе с ней.
        if running.isEmpty { meter.reset() }
        liveProgress[task.id] = nil
        taskMeters[task.id] = nil
        let reason = stopReasons.removeValue(forKey: task.id)

        // Проба закончилась без ответа о лимите: облако снова принимает файлы (или файл был с ошибкой —
        // тогда сразу пробуем следующий).
        if wasProbe, limiters[task.provider]?.isServerBlocked == true {
            if case .uploaded = outcome {
                limitLifted(task.provider)
            } else if !Self.isLimitOutcome(outcome) {
                limiters[task.provider]?.probeNow()
            }
        }
        if reason == .cancel {
            cancelSession(of: task.id)
            db.updateUploadStatus(id: task.id, status: .cancelled)
            schedule()
            return
        }
        switch outcome {
        case .uploaded(let fileId, let hash, let size, let name):
            db.markUploadTransferred(id: task.id, driveFileId: fileId, checksum: hash, size: size, fileName: name)
            if let current = db.uploadTask(id: task.id) {
                verificationQueue.append(current)
                startVerifications()
            }
        case .skipped:
            db.updateUploadStatus(id: task.id, status: .cancelled,
                                  error: String(localized: "Skipped: “\(task.fileName)” already exists in the folder"))
        case .failed(let message, let kind):
            db.updateUploadStatus(id: task.id, status: .failed, error: message, kind: kind)
        case .waitingForVolume(let message):
            db.updateUploadStatus(id: task.id, status: .waitingForVolume, error: message)
            if let root = PathResolver.volumeRoot(for: task.localPath) {
                db.markUploadsWaitingForVolume(volumeRoot: root, message: message)
            }
        case .signedOut:
            // Вход отозван: очередь стоит до нового входа; сессия и подтверждённые части сохранены.
            db.updateUploadStatus(id: task.id, status: reason == .pause ? .paused : .queued)
            authorized.remove(task.provider)
            stopAll(.requeue, provider: task.provider)
        case .limitReached:
            // Облако ответило «лимит исчерпан»: вся отправка в это облако ждёт (подтверждённые части сохранены).
            enterServerLimit(task.provider)
            db.updateUploadStatus(id: task.id, status: .waitingDailyLimit, error: limiters[task.provider]?.serverMessage())
        case .needsReauth:
            // Отправка встаёт целиком; задачи ждут в очереди повторного входа. Скачивание не затрагивается.
            db.updateUploadStatus(id: task.id, status: .queued,
                                  error: String(localized: "Sign in to \(task.provider.displayName) again to upload"))
            if writeBlocked.insert(task.provider).inserted {
                reauthRequests += 1
                stopAll(.requeue, provider: task.provider)
            }
        case .stopped:
            switch reason {
            case .pause: db.updateUploadStatus(id: task.id, status: .paused)
            case .network: db.updateUploadStatus(id: task.id, status: .waitingForNetwork, error: String(localized: "Waiting for network…"))
            case .dailyLimit:
                db.updateUploadStatus(id: task.id, status: .waitingDailyLimit, error: limitMessage(task.provider))
            case .pauseAll, .requeue, .cancel, nil: db.updateUploadStatus(id: task.id, status: .queued)
            }
        }
        schedule()
    }

    private static func isLimitOutcome(_ outcome: UploadWorker.Outcome) -> Bool {
        if case .limitReached = outcome { return true }
        return false
    }

    // MARK: - Limits

    /// Раз в 30 секунд и после сна: ждущие своего лимита отправки продолжаются, когда бюджет освободился;
    /// после ответа облака о лимите — пробный запрос раз в час.
    func checkLimits() {
        for provider in CloudProviderKind.allCases {
            limiters[provider]?.prune(db: db)
            limiters[provider]?.flush(db: db)
        }
        guard !isPaused else { return }
        for provider in CloudProviderKind.allCases {
            guard let limiter = limiters[provider] else { continue }
            if limiter.isServerBlocked {
                if limiter.probeDue { schedule() }
            } else {
                releaseWaiting(provider)
            }
        }
    }

    /// «Попробовать сейчас»: после ответа облака — пробный запрос сразу; при своём лимите — перепроверка.
    func retryLimitNow(_ provider: CloudProviderKind) {
        guard let limiter = limiters[provider] else { return }
        if limiter.isServerBlocked {
            limiters[provider]?.probeNow()
        } else if db.moveUploadStatuses([.waitingDailyLimit], to: .queued, provider: provider) == 0 {
            return
        }
        schedule()
    }

    /// Лимит изменён в настройках.
    func limitsChanged() {
        for provider in CloudProviderKind.allCases {
            if limiters[provider]?.isExhausted() == true {
                enterBudgetLimit(provider)
            } else {
                releaseWaiting(provider)
            }
        }
        schedule()
    }

    private func limitStatuses() -> [TransferLimitStatus] {
        CloudProviderKind.allCases.compactMap { provider in
            guard let limiter = limiters[provider] else { return nil }
            let stats = db.uploadLimitStats(provider: provider, limit: limiter.budget)
            return limiter.status(stats, reserved: reservedBytes(provider))
        }
    }

    private func releaseWaiting(_ provider: CloudProviderKind) {
        guard let limiter = limiters[provider], !limiter.isServerBlocked else { return }
        guard limiter.budget != nil else {
            if db.moveUploadStatuses([.waitingDailyLimit], to: .queued, provider: provider) > 0 { schedule() }
            return
        }
        guard case .budget(let budget) = limiter.gate(reserved: reservedBytes(provider)) else { return }
        let stats = db.uploadLimitStats(provider: provider, limit: budget.limit)
        guard stats.count > 0, let needed = limiter.neededToResume(stats), budget.remaining >= needed else { return }
        if db.moveUploadStatuses([.waitingDailyLimit], to: .queued, provider: provider) > 0 { schedule() }
    }

    /// Сколько ещё отправят идущие задачи облака.
    private func reservedBytes(_ provider: CloudProviderKind) -> Int64 {
        running.values.reduce(0) { sum, entry in
            guard entry.task.provider == provider, stopReasons[entry.task.id] == nil else { return sum }
            return sum + max(0, entry.task.fileSize - (liveProgress[entry.task.id] ?? entry.task.uploadedBytes))
        }
    }

    private func countTraffic(_ bytes: Int64, provider: CloudProviderKind) {
        limiters[provider]?.count(bytes, db: db)
        if limiters[provider]?.isExhausted() == true,
           running.contains(where: { $0.value.task.provider == provider && stopReasons[$0.key] == nil }) {
            enterBudgetLimit(provider)
        }
    }

    /// Свой лимит исчерпан: идущие отправки облака останавливаются (подтверждённые части сохранены),
    /// очередь облака ждёт, пока бюджет не освободится.
    private func enterBudgetLimit(_ provider: CloudProviderKind) {
        limiters[provider]?.flush(db: db)
        stopAll(.dailyLimit, provider: provider)
        parkQueue(provider)
    }

    private func enterServerLimit(_ provider: CloudProviderKind) {
        limiters[provider]?.block()
        limiters[provider]?.flush(db: db)
        stopAll(.dailyLimit, provider: provider)
        db.moveQueuedUploadsToDailyLimit(provider: provider, error: limiters[provider]?.serverMessage() ?? "")
    }

    /// Пробная отправка прошла: очередь облака продолжается.
    private func limitLifted(_ provider: CloudProviderKind) {
        guard limiters[provider]?.isServerBlocked == true else { return }
        limiters[provider]?.unblock()
        db.moveUploadStatuses([.waitingDailyLimit], to: .queued, provider: provider)
        schedule()
    }

    private func parkQueue(_ provider: CloudProviderKind) {
        db.moveQueuedUploadsToDailyLimit(provider: provider, error: limitMessage(provider))
    }

    /// Текст ожидания для строки задачи.
    private func limitMessage(_ provider: CloudProviderKind) -> String {
        guard let limiter = limiters[provider] else { return "" }
        if limiter.isServerBlocked { return limiter.serverMessage() }
        let resume = limiter.resumeEstimate(LimitWaitingStats(count: 1, hasOversized: true), reserved: reservedBytes(provider))
        return limiter.budgetMessage(resumeAt: resume)
    }

    private func launchProbeIfDue(_ provider: CloudProviderKind) {
        guard let limiter = limiters[provider], limiter.probeDue, limiter.probeTaskId == nil, !isPaused,
              running.count < limit, let task = db.claimUploadProbe(provider: provider) else { return }
        limiters[provider]?.beginProbe(task.id)
        launch(task)
    }

    #if DEBUG
    /// Debug → Simulate: ответ облака «лимит отправки исчерпан».
    func debugSimulateServerLimit(_ provider: CloudProviderKind) {
        enterServerLimit(provider)
        schedule()
    }

    func debugSimulateUsage(_ fraction: Double) {
        limiters[.googleDrive]?.debugExtraUsed = 0
        guard fraction > 0, let limiter = limiters[.googleDrive], let budget = limiter.budget else { return }
        limiters[.googleDrive]?.debugExtraUsed = max(0, Int64(Double(budget) * fraction) - limiter.used())
    }
    #endif

    /// Нужен повторный вход (обнаружено при операции в браузере диска).
    func requireReauth(_ provider: CloudProviderKind) {
        guard writeBlocked.insert(provider).inserted else { return }
        reauthRequests += 1
        stopAll(.requeue, provider: provider)
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

    private func cancelSession(of id: String) {
        guard let task = db.uploadTask(id: id), let session = task.sessionURI,
              let provider = providers[task.provider] else { return }
        Task { await provider.cancelUploadSession(session) }
    }

    // MARK: - Integrity

    private func startVerifications() {
        while verifying.count < Self.maxConcurrentVerifications, !verificationQueue.isEmpty {
            let task = verificationQueue.removeFirst()
            guard verifying[task.id] == nil else { continue }
            verifying[task.id] = 0
            Task.detached(priority: .utility) {
                let result = await Self.verify(task) { bytes in
                    Task { await self.reportVerification(id: task.id, bytes: bytes) }
                }
                await self.verificationFinished(task, result: result)
            }
        }
    }

    private enum Verification: Sendable {
        case verified
        case unverifiable
        case mismatch(expected: String, actual: String)
        case failed(String)
    }

    /// Потоковый хеш локального файла алгоритмом облака (Google — MD5, Dropbox — content_hash) против хеша из ответа облака.
    private static func verify(_ task: UploadTask, progress: @escaping @Sendable (Int64) -> Void) async -> Verification {
        guard let expected = task.checksum?.lowercased(), !expected.isEmpty else { return .unverifiable }
        do {
            let actual = try await ContentHasher.hash(ofFileAt: task.localPath, kind: task.provider.hashKind, progress: progress)
            return actual == expected ? .verified : .mismatch(expected: expected, actual: actual)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func reportVerification(id: String, bytes: Int64) {
        if verifying[id] != nil { verifying[id] = bytes }
    }

    private func verificationFinished(_ task: UploadTask, result: Verification) {
        verifying[task.id] = nil
        defer { startVerifications() }
        guard db.uploadTask(id: task.id)?.status == .verifying else { return }
        switch result {
        case .verified, .unverifiable:
            db.markUploadCompleted(id: task.id)
        case .mismatch(let expected, let actual):
            db.updateUploadStatus(id: task.id, status: .failed,
                                  error: String(localized: "Checksum mismatch (\(task.provider.displayName): \(String(expected.prefix(8)))…, file: \(String(actual.prefix(8)))…)"),
                                  kind: .checksumMismatch)
        case .failed(let message):
            if case .missing(let volumeMessage) = PathResolver.volumeState(for: task.localPath) {
                // Файл уже в облаке; проверка продолжится после подключения диска (recheckVolumes).
                db.updateUploadStatus(id: task.id, status: .verifying, error: volumeMessage)
            } else {
                db.updateUploadStatus(id: task.id, status: .failed, error: String(localized: "Couldn’t verify the file: \(message)"),
                                      kind: .checksumMismatch)
            }
        }
    }
}
