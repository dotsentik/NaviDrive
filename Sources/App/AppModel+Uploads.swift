import AppKit
import Foundation

/// Отправка в Google Drive и изменение диска (папки, переименование, перемещение, корзина).
extension AppModel {
    // MARK: - Refresh

    func refreshUploads(includeTasks: Bool) async {
        guard let uploadScheduler, let db else { return }
        let newSnapshot = await uploadScheduler.snapshot()
        if newSnapshot != uploadSnapshot { uploadSnapshot = newSnapshot }
        if newSnapshot.reauthRequests > seenReauthRequests {
            seenReauthRequests = newSnapshot.reauthRequests
            showReauthPrompt = true
        }
        let filter = uploadFilter
        let (newTotals, newSections) = await Task.detached(priority: .userInitiated) {
            (db.uploadTotals(), includeTasks ? Self.loadUploadSections(filter.uploadSections, from: db) : nil)
        }.value
        if newTotals != uploadTotals { uploadTotals = newTotals }
        if let newSections, newSections != uploadSections { uploadSections = newSections }
    }

    nonisolated static func loadUploadSections(_ kinds: [UploadSectionKind], from db: DatabaseManager) -> [UploadSectionKind: [UploadTask]] {
        var result: [UploadSectionKind: [UploadTask]] = [:]
        for kind in kinds {
            var rows: [UploadTask] = []
            for status in kind.statuses {
                rows += db.uploads(status: status, newestFirst: kind.newestFirst, limit: kind.limit)
            }
            if kind.newestFirst, kind.statuses.count > 1 { rows.sort { $0.updatedAt > $1.updatedAt } }
            result[kind] = Array(rows.prefix(kind.limit))
        }
        return result
    }

    func setUploadFilter(_ filter: DownloadFilter) {
        uploadFilter = filter
        Task { await refreshUploads(includeTasks: true) }
    }

    // MARK: - Write access

    /// Вход заведомо без права записи — окно «нужно заново войти». Скачивание при этом продолжает работать.
    func ensureWriteAccess() async -> Bool {
        if await tokenManager.lacksWriteScope {
            showReauthPrompt = true
            return false
        }
        return true
    }

    /// Понятный текст ошибки изменения диска. Нехватка прав входа — окно повторного входа.
    private func reportEditError(_ error: Error, forbidden: String) {
        if case DriveAPIError.insufficientScope = error {
            showReauthPrompt = true
            Task { await uploadScheduler?.requireReauth() }
            return
        }
        if error is CancellationError { return }
        switch error {
        case DriveAPIError.http(403, let message):
            errorMessage = message.contains("storageQuotaExceeded") ? String(localized: "Google Drive is out of storage") : forbidden
        case DriveAPIError.http(404, _):
            errorMessage = String(localized: "Item not found — it may have been deleted or moved. Refresh the list.")
        case DriveAPIError.http(400, let message):
            errorMessage = String(localized: "Google Drive rejected the operation: \(message)")
        case let urlError as URLError where GoogleDriveAPIClient.isTransientNetworkError(urlError):
            errorMessage = String(localized: "Can’t connect to Google Drive. Check your internet connection and try again.")
        default:
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Editing

    /// «Новая папка» в текущей папке: первое свободное имя «Новая папка», «Новая папка 2», …
    func createFolder(in target: UploadTarget, existingNames: Set<String>) async -> DriveItem? {
        guard await ensureWriteAccess() else { return nil }
        var name = String(localized: "New Folder")
        var counter = 2
        while existingNames.contains(name) {
            name = String(localized: "New Folder \(counter)")
            counter += 1
        }
        do {
            return try await api.createFolder(name: name, parentId: target.id)
        } catch {
            reportEditError(error, forbidden: String(localized: "You don’t have permission to change folder “\(target.name)”"))
            return nil
        }
    }

    func rename(_ item: DriveItem, to newName: String) async -> DriveItem? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return nil }
        guard await ensureWriteAccess() else { return nil }
        do {
            return try await api.rename(id: item.id, to: name)
        } catch {
            reportEditError(error, forbidden: String(localized: "You don’t have permission to rename “\(item.name)”"))
            return nil
        }
    }

    /// Возвращает id перемещённых объектов (при ошибке остальные не трогаются).
    func move(_ items: [DriveItem], to target: UploadTarget) async -> Set<String> {
        guard await ensureWriteAccess() else { return [] }
        var moved = Set<String>()
        for item in items where item.id != target.id {
            do {
                try await api.move(id: item.id, to: target.id)
                moved.insert(item.id)
            } catch {
                reportEditError(error, forbidden: String(localized: "You don’t have permission to move “\(item.name)” to “\(target.name)”"))
                break
            }
        }
        return moved
    }

    /// В корзину (окончательное удаление не используется). Возвращает id перемещённых в корзину.
    func trash(_ items: [DriveItem]) async -> Set<String> {
        guard await ensureWriteAccess() else { return [] }
        var trashed = Set<String>()
        for item in items {
            do {
                try await api.trash(id: item.id)
                trashed.insert(item.id)
            } catch {
                reportEditError(error, forbidden: String(localized: "You don’t have permission to delete “\(item.name)”"))
                break
            }
        }
        return trashed
    }

    // MARK: - Upload

    /// Пачка файлов и папок в папку на диске: обход, один вопрос про конфликты имён,
    /// создание дерева подпапок, затем очередь отправки.
    func startUpload(_ urls: [URL], to target: UploadTarget) {
        guard let uploadScheduler, !urls.isEmpty else { return }
        let title = urls.count == 1 ? urls[0].lastPathComponent : String(localized: "\(urls.count) items")
        selection = .uploads
        let planner = UploadPlanner(api: api)
        Task {
            guard await ensureWriteAccess() else { return }
            await uploadScheduler.beginPreparing(title)
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try await planner.scan(urls, into: target)
                }.value
                var policy = UploadConflictPolicy.keepBoth
                if !plan.conflicts.isEmpty {
                    guard let chosen = askConflictPolicy(plan.conflicts, folder: target.name) else {
                        await uploadScheduler.endPreparing(title)
                        return
                    }
                    policy = chosen
                }
                let result = try await Task.detached(priority: .userInitiated) {
                    try await planner.materialize(plan, policy: policy)
                }.value
                let queued = try await uploadScheduler.enqueue(result.tasks)
                var report = UploadEnqueueReport(title: title)
                report.added = queued.added
                report.alreadyQueued = queued.alreadyQueued
                report.bytes = result.tasks.reduce(0) { $0 + $1.fileSize }
                report.foldersCreated = result.foldersCreated
                report.skipped = result.skipped
                report.unreadable = plan.unreadable
                showUploadBanner(report.message)
            } catch {
                reportEditError(error, forbidden: String(localized: "You don’t have permission to upload to folder “\(target.name)”"))
            }
            await uploadScheduler.endPreparing(title)
            await refresh()
        }
    }

    private func showUploadBanner(_ text: String) {
        uploadBanner = text
        Task {
            try? await Task.sleep(for: .seconds(8))
            if uploadBanner == text { uploadBanner = nil }
        }
    }

    /// Один вопрос на всю пачку. nil — отмена.
    private func askConflictPolicy(_ names: [String], folder: String) -> UploadConflictPolicy? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1
            ? String(localized: "“\(folder)” already contains a file named “\(names[0])”")
            : String(localized: "“\(folder)” already contains \(QueueSessionSummary.filesCount(names.count)) with the same names")
        var info = names.prefix(5).joined(separator: "\n")
        if names.count > 5 { info += "\n" + String(localized: "…and \(names.count - 5) more") }
        alert.informativeText = info + "\n\n" + String(localized: "“Replace” uploads a new version of the same file, “Keep Both” adds “ (1)” to the name. The choice applies to all files in this batch.")
        alert.addButton(withTitle: String(localized: "Keep Both"))
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Skip"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        case .alertThirdButtonReturn: return .skip
        default: return nil
        }
    }

    /// «Загрузить…»: выбор нескольких файлов и папок.
    func chooseFilesToUpload(into target: UploadTarget) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        panel.message = String(localized: "Files and folders to upload to “\(target.name)”")
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        startUpload(panel.urls, to: target)
    }

    // MARK: - Queue control

    func pauseUpload(_ task: UploadTask) { Task { await uploadScheduler?.pauseTask(task.id); await refresh() } }
    func resumeUpload(_ task: UploadTask) { Task { await uploadScheduler?.resumeTask(task.id); await refresh() } }
    func restartUpload(_ task: UploadTask) { Task { await uploadScheduler?.restartTask(task.id); await refresh() } }
    func cancelUpload(_ task: UploadTask) { Task { await uploadScheduler?.cancelTask(task.id); await refresh() } }
    func retryFailedUploads() { Task { await uploadScheduler?.retryFailed(); await refresh() } }
    func resumeAllPausedUploads() { Task { await uploadScheduler?.resumeAllPaused(); await refresh() } }

    func togglePauseAllUploads() {
        let paused = !uploadSnapshot.isPaused
        uploadSnapshot.isPaused = paused
        Task { await uploadScheduler?.setPaused(paused); await refresh() }
    }

    func clearUploadHistory() {
        guard let db else { return }
        Task {
            await Task.detached { db.deleteUploads(statuses: [.completed, .cancelled]) }.value
            await refresh()
        }
    }

    func revealUploadSource(_ task: UploadTask) {
        let url = URL(fileURLWithPath: task.localPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if case .missing(let message) = PathResolver.volumeState(for: task.localPath) {
            errorMessage = message
        } else {
            errorMessage = String(localized: "Source file not found: \(PathResolver.displayPath(task.localPath))")
        }
    }

    func openUploadFolderOnDrive(_ task: UploadTask) {
        if let url = task.parentWebURL { NSWorkspace.shared.open(url) }
    }

    /// Строка прогресса отправки для трея и шапки.
    var uploadProgressSummary: String {
        guard uploadTotals.totalBytes > 0 else { return String(localized: "No uploads") }
        return "\(Format.bytes(uploadTotals.uploadedBytes)) / \(Format.bytes(uploadTotals.totalBytes)) (\(Format.percent(uploadTotals.fraction)))"
    }
}
