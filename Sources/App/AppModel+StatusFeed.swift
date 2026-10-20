import Foundation
import SwiftUI
import UserNotifications

/// Сообщение карточки статуса внизу sidebar (и верхней строки меню трея).
struct StatusMessage: Identifiable, Equatable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case normal, warning, critical

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Экран, на который ведёт клик по сообщению.
    enum Target: Equatable, Sendable {
        case downloads(TaskSectionKind?)
        case uploads(UploadSectionKind?)
        /// Строка диска в разделе «Диски» (корень тома).
        case disk(String)
        /// Список объектов, которые не удалось переместить в корзину, с причинами.
        case trashFailures
        case none
    }

    /// Кнопка «Попробовать сейчас» (или «Войти») прямо в карточке.
    enum Action: Equatable, Sendable {
        case retryLimit(CloudProviderKind, TransferDirection)
        case retryFailedDownloads
        case retryFailedUploads
        case recheckSpace
        case signIn(CloudProviderKind)
        /// «Отменить» перемещение в корзину (Google).
        case undoTrash
    }

    /// Стабильный ключ: при обновлении цифр текст меняется на месте, ротация не сбрасывается.
    let id: String
    var severity: Severity = .normal
    var cloud: CloudProviderKind?
    var direction: TransferDirection?
    /// Значок, если сообщение не об облаке (сеть, диск, готово).
    var symbol: String?
    var title: String
    var subtitle: String?
    var target: Target = .none
    var action: Action?
    /// Разовое сообщение («Готово: …») — до этого времени.
    var expires: Date?
    /// Значок зелёный (галочка «Готово»), у сообщений о корзине — оранжевый.
    var isSuccess = false
    /// Перемещение в корзину: оранжевая пульсация и точка.
    var isTrash = false

    /// Без активности и проблем: одно статичное «Online» / «Offline».
    var isIdle: Bool { id == "idle" }
}

/// Активность передач для карточки статуса: идут → «Готово: …» около 3 секунд → покой.
enum TransferActivity: Equatable {
    case idle
    case active
    /// Последняя передача закончилась; до `until` — сообщение «Готово: …», затем покой.
    case finishing(until: Date)
}

/// Файлы, которые передавались с начала текущей активности.
struct TransferLog {
    var downloads: [String: RunningTransfer] = [:]
    var uploads: [String: RunningTransfer] = [:]

    var isEmpty: Bool { downloads.isEmpty && uploads.isEmpty }
}

#if DEBUG
/// Debug → Simulate…: проверка карточки и уведомлений без реального превышения.
enum DebugSimulation: String, CaseIterable, Sendable {
    case googleLimit, warning80, diskDisconnected, noNetwork

    var title: String {
        switch self {
        case .googleLimit: String(localized: "Google Drive Daily Limit")
        case .warning80: String(localized: "80% Limit Warning")
        case .diskDisconnected: String(localized: "Disk Disconnected")
        case .noNetwork: String(localized: "No Network")
        }
    }
}
#endif

extension AppModel {
    /// Самое важное текущее сообщение — верхняя строка меню трея: красное > жёлтое > корзина > остальные.
    var topStatusMessage: StatusMessage? {
        statusMessages.first { $0.severity == .critical } ?? statusMessages.first { $0.severity == .warning }
            ?? statusMessages.first { $0.isTrash } ?? statusMessages.first
    }

    /// Есть красное сообщение: карточка красная, у значка трея красная точка.
    var hasCriticalStatus: Bool { statusMessages.contains { $0.severity == .critical } }

    // MARK: - Сообщения

    /// Сообщения строятся из единого состояния планировщиков скачивания и отправки (вызывается из `refresh`,
    /// не чаще 2 раз в секунду). Присваивается, только если что-то изменилось.
    func rebuildStatusFeed() {
        var critical: [StatusMessage] = []
        var warnings: [StatusMessage] = []
        var normal: [StatusMessage] = []
        let connected = Set(connectedClouds)
        var online = snapshot.isOnline
        #if DEBUG
        if debugSimulations.contains(.noNetwork) { online = false }
        #endif

        // Лимиты: достигнут — красное; 80% / 95% своего счётчика — жёлтое.
        for status in limits where connected.contains(status.provider) {
            if status.isReached {
                critical.append(limitReachedMessage(status))
            } else if let percent = status.warningPercent, let limit = status.limit {
                let text = String(localized: "\(status.provider.shortName) in 24 h: \(Format.diskBytes(status.used)) of \(Format.diskBytes(limit)) (\(percent)%)")
                warnings.append(StatusMessage(
                    id: "limit.warning.\(status.id)", severity: .warning, cloud: status.provider, direction: status.direction,
                    title: text,
                    subtitle: status.direction == .download ? String(localized: "Download limit") : String(localized: "Upload limit"),
                    target: status.direction == .download ? .downloads(nil) : .uploads(nil)))
            }
        }

        // Диск: не хватает места на очередь, которая уже стоит, — красное; заканчивается место — жёлтое.
        for (root, count) in totals.volumesAwaitingSpace.sorted(by: { $0.key < $1.key }) {
            critical.append(StatusMessage(
                id: "disk.space.\(root)", severity: .critical, direction: .download, symbol: "externaldrive.badge.xmark",
                title: String(localized: "Not enough space on “\(Self.volumeName(root))”"),
                subtitle: String(localized: "\(QueueSessionSummary.filesCount(count)) waiting · free up space"),
                target: .disk(root), action: .recheckSpace))
        }
        for volume in volumes where volume.lacksSpace && totals.volumesAwaitingSpace[volume.id] == nil {
            warnings.append(StatusMessage(
                id: "disk.low.\(volume.id)", severity: .warning, symbol: "externaldrive.badge.exclamationmark",
                title: String(localized: "Low space on “\(volume.name)”"),
                subtitle: String(localized: "Queue needs \(Format.diskBytes(volume.usage.remainingBytes)), \(Format.diskBytes(volume.freeBytes)) free"),
                target: .disk(volume.id)))
        }

        // Нет входа, а очередь облака ждёт.
        for cloud in CloudProviderKind.allCases where !connected.contains(cloud) {
            let waiting = (totals.byProvider[cloud]?.files ?? 0) + (uploadTotals.byProvider[cloud]?.files ?? 0)
            guard waiting > 0 else { continue }
            critical.append(StatusMessage(
                id: "auth.\(cloud.rawValue)", severity: .critical, cloud: cloud,
                title: String(localized: "Sign in to \(cloud.displayName)"),
                subtitle: String(localized: "\(QueueSessionSummary.filesCount(waiting)) waiting for sign-in"),
                action: .signIn(cloud)))
        }

        // Общая строка: сеть и скорость в обе стороны.
        let downloadsRunning = snapshot.runningCount > 0 && !snapshot.isPaused
        let uploadsRunning = uploadSnapshot.runningCount > 0 && !uploadSnapshot.isPaused
        let pendingWork = totals.pendingCount + uploadTotals.pendingCount > 0
        if !online, pendingWork {
            normal.append(StatusMessage(id: "network", symbol: "wifi.slash",
                                        title: String(localized: "No network · waiting"),
                                        subtitle: String(localized: "Transfers continue when the connection is back")))
        } else if downloadsRunning || uploadsRunning {
            // Скорость — только пока есть идущие передачи; без них строки нет совсем.
            var parts = [networkWord(online)]
            if downloadsRunning { parts.append("↓ " + Format.speed(snapshot.bytesPerSecond)) }
            if uploadsRunning { parts.append("↑ " + Format.speed(uploadSnapshot.bytesPerSecond)) }
            let count = (downloadsRunning ? snapshot.runningCount : 0) + (uploadsRunning ? uploadSnapshot.runningCount : 0)
            normal.append(StatusMessage(id: "overview", symbol: "network", title: parts.joined(separator: " · "),
                                        subtitle: String(localized: "Active transfers: \(count)")))
        }

        // Передачи по облакам.
        if !snapshot.isPaused {
            for cloud in CloudProviderKind.allCases {
                if let progress = totals.byProvider[cloud], progress.files > 0, connected.contains(cloud) {
                    normal.append(transferMessage(cloud, .download, progress: progress))
                }
            }
        }
        if !uploadSnapshot.isPaused {
            for cloud in CloudProviderKind.allCases {
                if let progress = uploadTotals.byProvider[cloud], progress.files > 0, connected.contains(cloud) {
                    normal.append(transferMessage(cloud, .upload, progress: progress))
                }
            }
        }

        // Ожидание отключённого диска.
        var awaitingMount = totals.volumesAwaitingMount
        #if DEBUG
        if debugSimulations.contains(.diskDisconnected) { awaitingMount["/Volumes/T7A"] = 3 }
        #endif
        for (root, count) in awaitingMount.sorted(by: { $0.key < $1.key }) {
            normal.append(StatusMessage(
                id: "disk.mount.\(root)", direction: .download, symbol: "externaldrive.badge.exclamationmark",
                title: String(localized: "Waiting for disk \(Self.volumeName(root)) · \(QueueSessionSummary.filesCount(count))"),
                subtitle: String(localized: "Connect the disk and downloads continue automatically"),
                target: .downloads(.waiting)))
        }

        if snapshot.scanningFolders > 0 {
            normal.append(StatusMessage(id: "scan", direction: .download, symbol: "magnifyingglass",
                                        title: String(localized: "Scanning folders: \(snapshot.scannedFiles) files found"),
                                        target: .downloads(nil)))
        }
        if let failed = totals.countsByStatus[.failed], failed > 0 {
            normal.append(StatusMessage(id: "failed.download", direction: .download, symbol: "exclamationmark.triangle",
                                        title: String(localized: "Download errors: \(QueueSessionSummary.filesCount(failed))"),
                                        target: .downloads(.failed), action: .retryFailedDownloads))
        }
        if let failed = uploadTotals.countsByStatus[.failed], failed > 0 {
            normal.append(StatusMessage(id: "failed.upload", direction: .upload, symbol: "exclamationmark.triangle",
                                        title: String(localized: "Upload errors: \(QueueSessionSummary.filesCount(failed))"),
                                        target: .uploads(.failed), action: .retryFailedUploads))
        }

        if let failed = trashFailureMessage() { critical.append(failed) }
        var messages = critical + warnings + trashMessages(now: Date()) + (completionMessage.map { [$0] } ?? []) + normal
        if messages.isEmpty {
            messages = [StatusMessage(id: "idle", symbol: online ? "checkmark.circle" : "wifi.slash", title: networkWord(online),
                                      subtitle: String(localized: "No active transfers"))]
        }
        if messages != statusMessages { statusMessages = messages }
    }

    private func networkWord(_ online: Bool) -> String {
        online ? String(localized: "Online") : String(localized: "Offline")
    }

    private func limitReachedMessage(_ status: TransferLimitStatus) -> StatusMessage {
        let name = status.provider.displayName
        var title: String
        if status.provider == .dropbox {
            title = String(localized: "Dropbox data transport limit reached")
        } else if status.direction == .download {
            title = String(localized: "Daily \(name) download limit reached")
        } else {
            title = String(localized: "Daily \(name) upload limit reached")
        }
        if let resume = status.resumeAt {
            let time = TransferLimiter.time(resume)
            title += " · " + (status.serverBlocked ? String(localized: "next check ~\(time)") : String(localized: "resumes ~\(time)"))
        }
        let files = QueueSessionSummary.filesCount(status.waitingCount)
        let subtitle = status.serverBlocked
            ? String(localized: "\(name) stopped accepting requests · \(files) waiting")
            : String(localized: "Progress is saved · \(files) waiting")
        return StatusMessage(
            id: "limit.reached.\(status.id)", severity: .critical, cloud: status.provider, direction: status.direction,
            title: title, subtitle: subtitle,
            target: status.direction == .download ? .downloads(.waiting) : .uploads(.waiting),
            action: .retryLimit(status.provider, status.direction))
    }

    /// «Google Drive: 12 файлов · 4,2 ГБ из 18 ГБ · 23%» или «Dropbox: Project_final.mov · 61%».
    private func transferMessage(_ cloud: CloudProviderKind, _ direction: TransferDirection,
                                 progress: TransferProgress) -> StatusMessage {
        let running = direction == .download ? snapshot.runningTasks : uploadSnapshot.runningTasks
        let live = direction == .download ? snapshot.liveProgress : uploadSnapshot.liveProgress
        let speeds = direction == .download ? snapshot.speeds : uploadSnapshot.speeds
        let mine = running.filter { $0.provider == cloud }
        let percent = Format.percent(progress.fraction)
        let title: String
        if progress.files == 1, let only = mine.first {
            let fraction = only.size > 0 ? min(1, Double(live[only.id] ?? 0) / Double(only.size)) : progress.fraction
            title = "\(cloud.displayName): \(only.name) · \(Format.percent(fraction))"
        } else {
            title = String(localized: "\(cloud.displayName): \(QueueSessionSummary.filesCount(progress.files)) · \(Format.diskBytes(progress.doneBytes)) of \(Format.diskBytes(progress.totalBytes)) · \(percent)")
        }
        let speed = mine.reduce(0.0) { $0 + (speeds[$1.id] ?? 0) }
        var subtitle: String
        if mine.isEmpty {
            subtitle = direction == .download ? String(localized: "Queued for download") : String(localized: "Queued for upload")
        } else {
            subtitle = direction == .download ? String(localized: "Downloading") : String(localized: "Uploading")
            subtitle += " · " + Format.speed(speed)
        }
        return StatusMessage(id: "transfer.\(direction.rawValue).\(cloud.rawValue)", cloud: cloud, direction: direction,
                             title: title, subtitle: subtitle,
                             target: direction == .download ? .downloads(.downloading) : .uploads(.uploading))
    }

    static func volumeName(_ root: String) -> String {
        root == "/" ? String(localized: "Macintosh HD") : (root as NSString).lastPathComponent
    }

    /// Идёт ли передача данных и в какой фазе карточка: передачи → «Готово: …» (~3 с) → покой.
    ///
    /// - «Байты идут»: скорость за последние 3 с плюс 2 с запаса — потоки, которые дольше 5 с только
    ///   подключаются, передачей не считаются; пауза и ожидание сети, диска, лимита — нет идущих потоков.
    /// - Когда заканчивается последняя передача — сообщение «Готово: …» с зелёной галочкой; новая передача
    ///   в это время (в том числе в первые 1,5 с) возвращает активность без перехода в покой.
    /// - Возвращает true, когда пора переходить в покой: вызывающий код делает это одним `withAnimation`.
    func updateTransferActivity() async -> Bool {
        let now = Date()
        let downloading = !snapshot.isPaused && snapshot.runningCount > 0 && snapshot.bytesPerSecond > 0
        let uploading = !uploadSnapshot.isPaused && uploadSnapshot.runningCount > 0 && uploadSnapshot.bytesPerSecond > 0
        if downloading || uploading { lastBytesFlowAt = now }
        let running = (!snapshot.isPaused && snapshot.runningCount > 0) || (!uploadSnapshot.isPaused && uploadSnapshot.runningCount > 0)
        let flowing = running && lastBytesFlowAt.map { now.timeIntervalSince($0) < 2 } == true
        if flowing != isTransferring { isTransferring = flowing }

        // Работа ещё есть: идут, проверяются, ждут своей очереди, готовятся (не на паузе и не в ожидании).
        let downloadWork = !snapshot.isPaused && (hasActiveDownloads || totals.byProvider.values.contains { $0.files > 0 })
        let uploadWork = !uploadSnapshot.isPaused && (uploadSnapshot.runningCount > 0 || !uploadSnapshot.verificationProgress.isEmpty
            || !uploadSnapshot.preparing.isEmpty || uploadTotals.byProvider.values.contains { $0.files > 0 })
        let busy = downloadWork || uploadWork

        if running {
            if transferActivity == .idle { transferLog = TransferLog() }
            for task in snapshot.runningTasks { transferLog.downloads[task.id] = task }
            for task in uploadSnapshot.runningTasks { transferLog.uploads[task.id] = task }
        }

        switch transferActivity {
        case .idle, .finishing:
            if running {
                // Новая передача (в том числе во время «Готово: …») — без перехода в покой.
                transferActivity = .active
                completionMessage = nil
            }
        case .active:
            if !busy {
                let log = transferLog
                transferLog = TransferLog()
                completionMessage = await completionMessage(for: log, now: now)
                // Ничего не завершилось (ошибка, лимит) — сразу в покой; иначе «Готово: …» ~3 с.
                transferActivity = completionMessage == nil ? .idle : .finishing(until: now.addingTimeInterval(3))
                if completionMessage == nil { return true }
            }
        }

        if case .finishing(let until) = transferActivity, now >= until {
            transferActivity = .idle
            completionMessage = nil
            return true
        }
        // Пульсация включается плавно (0,4 с), пока байты идут; во время «Готово: …» держится
        // и гаснет только вместе с переходом в покой.
        if transferActivity == .active, flowing != pulseActive {
            withAnimation(.easeInOut(duration: 0.4)) { pulseActive = flowing }
        }
        return false
    }

    /// «Готово: Дневник 001.wav отправлен в Dropbox» / «Готово: скачано 248 файлов» — только по завершённым файлам.
    private func completionMessage(for log: TransferLog, now: Date) async -> StatusMessage? {
        let downloadIds = Array(log.downloads.keys), uploadIds = Array(log.uploads.keys)
        let completed = await inBackground { db in
            (db.completedTaskIds(downloadIds, uploads: false), db.completedTaskIds(uploadIds, uploads: true))
        }
        guard let completed else { return nil }
        let downloads = log.downloads.values.filter { completed.0.contains($0.id) }
        let uploads = log.uploads.values.filter { completed.1.contains($0.id) }
        let all = downloads + uploads
        guard !all.isEmpty else { return nil }
        let files = QueueSessionSummary.filesCount(all.count)
        let clouds = Set(all.map(\.provider))
        let title: String
        if all.count == 1, let only = all.first {
            title = uploads.isEmpty
                ? String(localized: "Done: \(only.name) downloaded from \(only.provider.displayName)")
                : String(localized: "Done: \(only.name) uploaded to \(only.provider.displayName)")
        } else if uploads.isEmpty {
            title = String(localized: "Done: \(files) downloaded")
        } else if downloads.isEmpty, clouds.count == 1, let cloud = clouds.first {
            title = String(localized: "Done: uploaded \(files) to \(cloud.displayName)")
        } else if downloads.isEmpty {
            title = String(localized: "Done: uploaded \(files)")
        } else {
            title = String(localized: "Done: transferred \(files)")
        }
        let bytes = all.reduce(Int64(0)) { $0 + max(0, $1.size) }
        return StatusMessage(id: "done.\(Int(now.timeIntervalSince1970))", cloud: clouds.count == 1 ? clouds.first : nil,
                             direction: uploads.isEmpty ? .download : (downloads.isEmpty ? .upload : nil),
                             symbol: "checkmark.circle.fill", title: title, subtitle: Format.bytes(bytes),
                             target: uploads.isEmpty ? .downloads(.completed) : .uploads(.completed), isSuccess: true)
    }

    // MARK: - Переходы и действия

    /// Клик по сообщению: нужный экран главного окна.
    func openStatusTarget(_ target: StatusMessage.Target) {
        guard target != .none else { return }
        WindowOpener.showMainWindow()
        switch target {
        case .downloads(let section):
            selection = .downloads
            if let section {
                if !downloadFilter.sections.contains(section) { setFilter(.all) }
                pendingDownloadSection = section
            }
        case .uploads(let section):
            selection = .uploads
            if let section {
                if !uploadFilter.uploadSections.contains(section) { setUploadFilter(.all) }
                pendingUploadSection = section
            }
        case .trashFailures:
            showTrashFailures()
        case .disk(let root):
            UserDefaults.standard.set(true, forKey: AppSettings.showSidebarKey)
            highlightedVolume = root
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                if self?.highlightedVolume == root { self?.highlightedVolume = nil }
            }
        case .none:
            break
        }
    }

    func performStatusAction(_ action: StatusMessage.Action) {
        switch action {
        case .retryLimit(let provider, let direction): retryLimit(provider, direction)
        case .retryFailedDownloads: retryFailed()
        case .retryFailedUploads: retryFailedUploads()
        case .recheckSpace: Task { await scheduler?.recheckSpace(); await refresh() }
        case .signIn(let cloud): signIn(cloud)
        case .undoTrash: undoTrash()
        }
    }

    // MARK: - Системные уведомления

    /// Один раз при остановке по лимиту и один раз при возобновлении (если уведомления разрешены).
    /// У самого лимита передача продолжается порциями по мере освобождения окна 24 часов —
    /// «возобновлено» приходит, только когда счётчик опустился ниже 90% (или облако сняло остановку).
    func notifyLimitChanges() {
        let connected = Set(connectedClouds)
        let relevant = limits.filter { connected.contains($0.provider) }
        let reached = Set(relevant.filter(\.isReached).map(\.id))
        guard var notified = notifiedLimits else {
            // Первый снимок после запуска: остановка, известная с прошлого запуска, не повторяется.
            notifiedLimits = reached
            return
        }
        for status in relevant where status.isReached && !notified.contains(status.id) {
            notified.insert(status.id)
            let name = status.provider.displayName
            let title = status.direction == .download
                ? String(localized: "\(name): downloads stopped by the limit")
                : String(localized: "\(name): uploads stopped by the limit")
            var body = String(localized: "Progress is saved.")
            if let resume = status.resumeAt {
                body += " " + String(localized: "NaviDrive will continue automatically around \(TransferLimiter.time(resume)).")
            }
            postNotification(id: "limit.stop.\(status.id)", title: title, body: body)
        }
        for id in notified {
            let status = relevant.first { $0.id == id }
            guard let status else {
                // Облако отключено — без уведомления.
                notified.remove(id)
                continue
            }
            guard !status.isReached, (status.fraction ?? 0) < 0.9 else { continue }
            notified.remove(id)
            let name = status.provider.displayName
            let title = status.direction == .download
                ? String(localized: "\(name): downloads resumed")
                : String(localized: "\(name): uploads resumed")
            postNotification(id: "limit.resume.\(id)", title: title, body: String(localized: "The limit has freed up; files continue from where they stopped."))
        }
        if notified != notifiedLimits { notifiedLimits = notified }
    }

    func postNotification(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "navidrive.\(id).\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Debug

    #if DEBUG
    func toggleDebugSimulation(_ simulation: DebugSimulation) {
        let enabled = !debugSimulations.contains(simulation)
        if enabled { debugSimulations.insert(simulation) } else { debugSimulations.remove(simulation) }
        Task {
            switch simulation {
            case .googleLimit:
                if enabled {
                    await scheduler?.debugSimulateServerLimit()
                } else {
                    await scheduler?.retryLimitNow()
                }
            case .warning80:
                await scheduler?.debugSimulateUsage(enabled ? 0.8 : 0)
                await uploadScheduler?.debugSimulateUsage(enabled ? 0.8 : 0)
            case .noNetwork:
                await scheduler?.setOnline(!enabled)
                await uploadScheduler?.setOnline(!enabled)
            case .diskDisconnected:
                break
            }
            await refresh()
        }
    }
    #endif
}
