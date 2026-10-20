import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Строки текущей папки браузера, для которых нужны индикаторы передач.
/// Публикует открытый `DriveBrowserView`; модель по нему читает очереди не чаще тика обновления.
struct BrowserTransferContext: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let id: String
        let name: String
        let isFolder: Bool
        /// ID объекта для очереди скачивания (`targetId`).
        let downloadId: String
        /// ID папки как цели загрузки (у Dropbox — путь); nil у файлов.
        let uploadFolderId: String?
    }

    let provider: CloudProviderKind
    /// Текущая папка как цель загрузки: в неё попадают отправляемые файлы (nil — сюда загружать нельзя).
    let uploadParentId: String?
    let caseInsensitiveNames: Bool
    let rows: [Row]
}

/// Что именно показывает индикатор и к чему применяются действия контекстного меню.
enum TransferSubject: Hashable, Sendable {
    case uploadTask(String)
    case downloadTask(String)
    case uploadFolder(String)
    case downloadFolder(String)

    var isUpload: Bool {
        switch self {
        case .uploadTask, .uploadFolder: true
        case .downloadTask, .downloadFolder: false
        }
    }
}

/// Маленький круговой индикатор передачи у строки браузера.
struct TransferIndicator: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case queued, active, paused, waiting, failed }

    let subject: TransferSubject
    let phase: Phase
    /// 0…1; nil — размер неизвестен.
    let fraction: Double?
    let help: String

    var isUpload: Bool { subject.isUpload }
    var canPause: Bool { phase == .queued || phase == .active || phase == .waiting }
    var canResume: Bool { phase == .paused || phase == .failed }
}

/// Индикаторы и строки-заглушки загружаемых файлов для текущей папки браузера.
struct BrowserTransfers: Equatable {
    /// ID строки → индикатор.
    var indicators: [String: TransferIndicator] = [:]
    /// Файлы, которые ещё отправляются (или только что отправлены) и которых пока нет в списке папки.
    var placeholders: [CloudItem] = []

    var isEmpty: Bool { indicators.isEmpty && placeholders.isEmpty }
}

extension AppModel {
    static let uploadPlaceholderPrefix = "upload:"

    /// Строка-заглушка загружаемого файла (такого файла в облаке ещё нет).
    static func isUploadPlaceholder(_ id: String) -> Bool { id.hasPrefix(uploadPlaceholderPrefix) }

    /// Пересчитать индикаторы текущей папки браузера. Вызывается из `refresh` (не чаще 2 раз в секунду).
    func refreshBrowserTransfers() async {
        guard let context = browserTransferContext, let db, selection?.isCloudBrowser == true else {
            if !browserTransfers.isEmpty { browserTransfers = BrowserTransfers() }
            return
        }
        // Ни одной незавершённой передачи и нечего гасить — база не читается.
        let downloadsPending = totals.pendingCount + (totals.countsByStatus[.failed] ?? 0)
        let uploadsPending = uploadTotals.pendingCount + (uploadTotals.countsByStatus[.failed] ?? 0)
        if downloadsPending == 0, uploadsPending == 0, browserTransfers.isEmpty { return }

        let fileIds = context.rows.filter { !$0.isFolder }.map(\.downloadId)
        let downloadFolderIds = context.rows.filter(\.isFolder).map(\.downloadId)
        let uploadFolderIds = context.rows.compactMap(\.uploadFolderId)
        let (uploads, uploadFolders, downloads, downloadFolders) = await Task.detached(priority: .userInitiated) {
            (context.uploadParentId.map { db.uploadsInFolder(provider: context.provider, parentId: $0) } ?? [],
             db.transferAggregates(kind: "u", provider: context.provider, folderIds: uploadFolderIds),
             db.activeDownloads(provider: context.provider, fileIds: fileIds),
             db.transferAggregates(kind: "d", provider: context.provider, folderIds: downloadFolderIds))
        }.value
        // Пока шёл запрос, пользователь мог уйти в другую папку.
        guard context == browserTransferContext else { return }

        var result = BrowserTransfers()
        let key: (String) -> String = { context.caseInsensitiveNames ? $0.lowercased() : $0 }
        let fileRows = Dictionary(context.rows.filter { !$0.isFolder }.map { (key($0.name), $0.id) },
                                  uniquingKeysWith: { first, _ in first })

        // Отправка: индикатор у строки файла с тем же именем или строка-заглушка.
        var listingIsStale = false
        for task in uploads {
            let indicator = uploadIndicator(task)
            if let rowId = fileRows[key(task.fileName)] {
                if let indicator { result.indicators[rowId] = indicator }
            } else {
                let placeholder = Self.placeholder(for: task)
                result.placeholders.append(placeholder)
                if let indicator {
                    result.indicators[placeholder.id] = indicator
                } else if requestedListingRefresh.insert(task.id).inserted {
                    // Файл уже в облаке, но список папки ещё старый — заглушка ждёт обновления списка.
                    listingIsStale = true
                }
            }
        }
        // Скачивание: индикатор у файла по ID объекта.
        var downloadsById: [String: DownloadTask] = [:]
        for task in downloads {
            if let current = downloadsById[task.driveFileId], Self.rank(current.status) >= Self.rank(task.status) { continue }
            downloadsById[task.driveFileId] = task
        }
        for row in context.rows {
            if result.indicators[row.id] != nil { continue }
            if row.isFolder {
                if let folderId = row.uploadFolderId, let aggregate = uploadFolders[folderId] {
                    result.indicators[row.id] = aggregateIndicator(aggregate, subject: .uploadFolder(folderId))
                } else if let aggregate = downloadFolders[row.downloadId] {
                    result.indicators[row.id] = aggregateIndicator(aggregate, subject: .downloadFolder(row.downloadId))
                }
            } else if let task = downloadsById[row.downloadId] {
                result.indicators[row.id] = downloadIndicator(task)
            }
        }

        if result != browserTransfers {
            // Строки появляются и исчезают, индикаторы гаснут — с короткой анимацией.
            let changedRows = Set(result.indicators.keys) != Set(browserTransfers.indicators.keys)
                || result.placeholders.map(\.id) != browserTransfers.placeholders.map(\.id)
            withAnimation(changedRows ? .easeInOut(duration: 0.25) : nil) { browserTransfers = result }
        }
        if listingIsStale { browserListingStaleToken += 1 }
    }

    // MARK: - Indicators

    private func uploadIndicator(_ task: UploadTask) -> TransferIndicator? {
        let subject = TransferSubject.uploadTask(task.id)
        switch task.status {
        case .completed, .cancelled:
            return nil
        case .queued:
            return TransferIndicator(subject: subject, phase: .queued, fraction: 0, help: UploadStatus.queued.title)
        case .paused:
            return TransferIndicator(subject: subject, phase: .paused, fraction: task.fraction, help: UploadStatus.paused.title)
        case .failed:
            return TransferIndicator(subject: subject, phase: .failed, fraction: task.fraction,
                                     help: task.lastError ?? UploadStatus.failed.title)
        case .waitingForNetwork, .waitingForVolume, .waitingDailyLimit:
            return TransferIndicator(subject: subject, phase: .waiting, fraction: task.fraction,
                                     help: task.lastError ?? task.status.title)
        case .verifying:
            return TransferIndicator(subject: subject, phase: .active, fraction: 1, help: UploadStatus.verifying.title)
        case .uploading:
            let sent = uploadSnapshot.liveProgress[task.id] ?? task.uploadedBytes
            let fraction = task.fileSize > 0 ? min(1, Double(sent) / Double(task.fileSize)) : nil
            return TransferIndicator(subject: subject, phase: .active, fraction: fraction,
                                     help: Self.progressHelp(UploadStatus.uploading.title, done: sent, total: task.fileSize,
                                                             speed: uploadSnapshot.speeds[task.id]))
        }
    }

    private func downloadIndicator(_ task: DownloadTask) -> TransferIndicator? {
        let subject = TransferSubject.downloadTask(task.id)
        let fraction = task.expectedSize > 0 ? min(1, Double(task.downloadedSize) / Double(task.expectedSize)) : nil
        switch task.status {
        case .completed, .cancelled:
            return nil
        case .queued:
            return TransferIndicator(subject: subject, phase: .queued, fraction: 0, help: TaskStatus.queued.title)
        case .paused, .pausedAll:
            return TransferIndicator(subject: subject, phase: .paused, fraction: fraction, help: task.status.title)
        case .failed:
            return TransferIndicator(subject: subject, phase: .failed, fraction: fraction,
                                     help: task.lastError ?? TaskStatus.failed.title)
        case .waitingForVolume, .waitingForNetwork, .waitingForSpace, .waitingDailyLimit:
            return TransferIndicator(subject: subject, phase: .waiting, fraction: fraction,
                                     help: Self.waitingHelp(task))
        case .verifying:
            return TransferIndicator(subject: subject, phase: .active, fraction: 1, help: TaskStatus.verifying.title)
        case .downloading:
            let done = snapshot.liveProgress[task.id] ?? task.downloadedSize
            let live = task.expectedSize > 0 ? min(1, Double(done) / Double(task.expectedSize)) : nil
            let title = String(localized: "Downloading to \(PathResolver.displayPath(task.targetDirPath))")
            let connecting = task.retryCount > 0 && task.lastError != nil
                ? String(localized: "Attempt \(task.retryCount + 1): \(task.lastError ?? "")")
                : String(localized: "Connecting…")
            let help = snapshot.connecting.contains(task.id)
                ? title + " · " + connecting
                : Self.progressHelp(title, done: done, total: task.expectedSize, speed: snapshot.speeds[task.id])
            return TransferIndicator(subject: subject, phase: .active, fraction: live, help: help)
        }
    }

    /// Общий прогресс папки: ошибка важнее всего, затем передача, очередь, ожидание, пауза.
    private func aggregateIndicator(_ aggregate: TransferAggregate, subject: TransferSubject) -> TransferIndicator {
        let fraction = aggregate.bytes > 0 ? min(1, Double(aggregate.doneBytes) / Double(aggregate.bytes)) : nil
        let files = QueueSessionSummary.filesCount(aggregate.total)
        let phase: TransferIndicator.Phase
        let title: String
        if aggregate.failed > 0 {
            phase = .failed
            title = String(localized: "Errors: \(aggregate.failed)") + (aggregate.firstError.map { " — \($0)" } ?? "")
            return TransferIndicator(subject: subject, phase: phase, fraction: fraction, help: title)
        } else if aggregate.running > 0 {
            phase = .active
            title = subject.isUpload ? UploadStatus.uploading.title : TaskStatus.downloading.title
        } else if aggregate.queued > 0 {
            phase = .queued
            title = TaskStatus.queued.title
        } else if aggregate.waiting > 0 {
            phase = .waiting
            title = String(localized: "Waiting")
        } else {
            phase = .paused
            title = TaskStatus.paused.title
        }
        return TransferIndicator(subject: subject, phase: phase, fraction: fraction,
                                 help: Self.progressHelp(title + " · " + files, done: aggregate.doneBytes,
                                                         total: aggregate.bytes, speed: nil))
    }

    /// «Uploading · 1,2 GB of 4,7 GB · 26% · 18 MB/s»
    private static func progressHelp(_ title: String, done: Int64, total: Int64, speed: Double?) -> String {
        var parts = [title]
        if total > 0 {
            parts.append(String(localized: "\(Format.bytes(done)) of \(Format.bytes(total))"))
            parts.append(min(1, Double(done) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
        }
        if let speed, speed > 0 { parts.append(Format.speed(speed)) }
        return parts.joined(separator: " · ")
    }

    /// «Waiting for disk T7A» и т. п.: причина ожидания из задачи, иначе — название статуса.
    private static func waitingHelp(_ task: DownloadTask) -> String {
        if task.status == .waitingForVolume, let volume = PathResolver.volumeRoot(for: task.targetDirPath) {
            return String(localized: "Waiting for disk \((volume as NSString).lastPathComponent)")
        }
        return task.lastError ?? task.status.title
    }

    /// Какую из нескольких задач одного файла показывать (разные папки назначения).
    private static func rank(_ status: TaskStatus) -> Int {
        switch status {
        case .failed: 6
        case .downloading, .verifying: 5
        case .queued: 4
        case .waitingForVolume, .waitingForNetwork, .waitingForSpace, .waitingDailyLimit: 3
        case .paused, .pausedAll: 2
        case .completed, .cancelled: 0
        }
    }

    private static func placeholder(for task: UploadTask) -> CloudItem {
        var item = CloudItem(provider: task.provider, id: uploadPlaceholderPrefix + task.id, name: task.fileName, isFolder: false)
        item.size = task.fileSize
        item.contentType = UTType(filenameExtension: (task.fileName as NSString).pathExtension)?.preferredMIMEType
        item.permissions = CloudPermissions(canDownload: false, canAddChildren: false, canRename: false,
                                            canTrash: false, canMove: false)
        return item
    }

    // MARK: - Actions (контекстное меню строки)

    func pauseTransfer(_ subject: TransferSubject) { applyTransfer(subject, action: .pause) }
    func resumeTransfer(_ subject: TransferSubject) { applyTransfer(subject, action: .resume) }
    func cancelTransfer(_ subject: TransferSubject) { applyTransfer(subject, action: .cancel) }

    func showTransferManager(_ subject: TransferSubject) {
        selection = subject.isUpload ? .uploads : .downloads
    }

    private enum TransferAction { case pause, resume, cancel }

    private func applyTransfer(_ subject: TransferSubject, action: TransferAction) {
        guard let db, let provider = browserTransferContext?.provider else { return }
        let scheduler = scheduler, uploadScheduler = uploadScheduler
        Task {
            let ids: [String]
            switch subject {
            case .uploadTask(let id), .downloadTask(let id):
                ids = [id]
            case .uploadFolder(let folderId):
                ids = await Task.detached { db.transferTaskIds(kind: "u", provider: provider, folderId: folderId) }.value
            case .downloadFolder(let folderId):
                ids = await Task.detached { db.transferTaskIds(kind: "d", provider: provider, folderId: folderId) }.value
            }
            for id in ids {
                if subject.isUpload {
                    switch action {
                    case .pause: await uploadScheduler?.pauseTask(id)
                    case .resume: await uploadScheduler?.resumeTask(id)
                    case .cancel: await uploadScheduler?.cancelTask(id)
                    }
                } else {
                    switch action {
                    case .pause: await scheduler?.pauseTask(id)
                    case .resume: await scheduler?.resumeTask(id)
                    case .cancel: await scheduler?.cancelTask(id)
                    }
                }
            }
            await refresh()
        }
    }
}
