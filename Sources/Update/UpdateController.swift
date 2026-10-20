import AppKit
import Observation
import SwiftUI

/// Обновление из GitHub Releases: ручная и еженедельная проверка, окно с заметками, загрузка,
/// проверка (SHA-256, подпись, версия) и замена приложения после выхода.
@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    enum WindowState: Equatable {
        case available(UpdateRelease)
        case downloading(UpdateRelease, fraction: Double?)
        case verifying(UpdateRelease)
        case installing(UpdateRelease)
        case moveToApplications(UpdateRelease)
        case failed(UpdateRelease, message: String)

        var release: UpdateRelease {
            switch self {
            case .available(let r), .downloading(let r, _), .verifying(let r), .installing(let r),
                 .moveToApplications(let r), .failed(let r, _): r
            }
        }
    }

    private enum Keys {
        static let automatic = "updates.checkAutomatically"
        static let lastCheck = "updates.lastCheckDate"
        static let skipped = "updates.skippedVersion"
        static let etag = "updates.etag"
        static let cachedRelease = "updates.cachedRelease"
    }

    static let checkInterval: TimeInterval = 7 * 24 * 3600

    private(set) var isChecking = false
    private(set) var lastCheckDate: Date?
    private(set) var windowState: WindowState?
    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic) }
    }

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var windowDelegate: UpdateWindowDelegate?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var activityScheduler: NSBackgroundActivityScheduler?

    let currentVersion = Bundle.main.semanticVersion
    var currentVersionText: String { Bundle.main.shortVersion }

    private init() {
        let defaults = UserDefaults.standard
        checksAutomatically = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        lastCheckDate = defaults.object(forKey: Keys.lastCheck) as? Date
    }

    // MARK: - Расписание

    /// При запуске: проверка, если с прошлой прошло 7 дней; затем раз в сутки — то же условие
    /// (на случай, если приложение не перезапускают неделями).
    func start() {
        removeStaleStagedCopies()
        Task {
            // Вспомогательный процесс прошлого обновления к этому времени закончил (удалил .old).
            try? await Task.sleep(for: .seconds(15))
            if windowState == nil {
                UpdateInstaller.forwardHelperLog()
                UpdateInstaller.cleanUpWorkDirectory()
            }
            await checkIfDue()
        }
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.navidrive.NaviDrive.update-check")
        scheduler.repeats = true
        scheduler.interval = 24 * 3600
        scheduler.tolerance = 3600
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            Task { @MainActor in
                await UpdateController.shared.checkIfDue()
                completion(.finished)
            }
        }
        activityScheduler = scheduler
    }

    private func checkIfDue() async {
        guard checksAutomatically, windowState == nil else { return }
        if let lastCheckDate, Date().timeIntervalSince(lastCheckDate) < Self.checkInterval { return }
        await check(userInitiated: false)
    }

    /// Незавершённые копии `.NaviDrive.app.update-*` рядом с приложением (обновление прервано).
    private func removeStaleStagedCopies() {
        guard case .writable(let appURL) = UpdateInstaller.currentLocation() else { return }
        let parent = appURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(".NaviDrive.app.update-") {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    // MARK: - Проверка

    /// «Check for Updates…» в меню и настройках.
    func checkManually() {
        if let window, windowState != nil {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let evaluation = try await fetchEvaluation()
            switch evaluation {
            case .upToDate:
                UpdateLog.logger.info("No update available")
                if userInitiated { showUpToDate() }
            case .available(let release):
                UpdateLog.logger.info("Update available: \(release.version.description, privacy: .public)")
                if !userInitiated, UserDefaults.standard.string(forKey: Keys.skipped) == release.version.description {
                    return
                }
                present(.available(release))
            }
        } catch {
            UpdateLog.logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            if userInitiated { showError(error) }
        }
    }

    private func fetchEvaluation() async throws -> ReleaseEvaluation {
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "NDGitHubRepo") as? String,
              Self.isValidRepo(repo) else { throw UpdateError.notConfigured }
        let defaults = UserDefaults.standard
        let cached = defaults.data(forKey: Keys.cachedRelease)
        let etag = cached == nil ? nil : defaults.string(forKey: Keys.etag)
        let data: Data
        switch try await UpdateNetwork.fetchLatestRelease(repo: repo, etag: etag) {
        case .notModified:
            guard let cached else { throw UpdateError.http(304) }
            data = cached
        case .fetched(let body, let newETag):
            data = body
            if let newETag, !body.isEmpty {
                defaults.set(newETag, forKey: Keys.etag)
                defaults.set(body, forKey: Keys.cachedRelease)
            } else {
                defaults.removeObject(forKey: Keys.etag)
                defaults.removeObject(forKey: Keys.cachedRelease)
            }
        }
        lastCheckDate = Date()
        defaults.set(lastCheckDate, forKey: Keys.lastCheck)
        guard !data.isEmpty else { return .upToDate }
        do {
            return try UpdatePolicy.evaluate(data, currentVersion: currentVersion)
        } catch let error as UpdateCoreError {
            throw UpdateError.core(error)
        }
    }

    /// «owner/name» из латиницы, цифр, «-», «_», «.».
    private static func isValidRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    // MARK: - Кнопки окна

    func skipVersion() {
        guard let release = windowState?.release else { return }
        UserDefaults.standard.set(release.version.description, forKey: Keys.skipped)
        closeWindow()
    }

    func later() {
        closeWindow()
    }

    func cancelDownload() {
        updateTask?.cancel()
    }

    func update() {
        guard let state = windowState else { return }
        switch state {
        case .available, .failed: break
        default: return
        }
        let release = state.release
        updateTask = Task { await performUpdate(release) }
    }

    func showDownloadedImage() {
        guard let url = downloadsCopyURL(for: windowState?.release) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Загрузка, проверка, установка

    private func performUpdate(_ release: UpdateRelease) async {
        windowState = .downloading(release, fraction: nil)
        var stagedURL: URL?
        do {
            let work = try UpdateInstaller.workDirectory()
            let dmg = work.appendingPathComponent(release.dmgName)

            let expected = try await UpdateInstaller.expectedChecksum(for: release)

            // Уже скачанный и проверенный образ (например, после «Later» в вопросе о загрузках) не качается заново.
            if !(await UpdateInstaller.fileMatches(dmg, sha256: expected)) {
                let limit = min(UpdatePolicy.maxDownloadBytes, release.dmgSize + 1024 * 1024)
                try await UpdateNetwork.download(release.dmgURL, to: dmg, maxBytes: limit) { written, total in
                    let fraction = total > 0 ? Double(written) / Double(total) : nil
                    Task { @MainActor in
                        let controller = UpdateController.shared
                        if case .downloading(let current, _) = controller.windowState, current == release {
                            controller.windowState = .downloading(release, fraction: fraction)
                        }
                    }
                }
                try Task.checkCancellation()
                windowState = .verifying(release)
                guard await UpdateInstaller.fileMatches(dmg, sha256: expected) else {
                    try? FileManager.default.removeItem(at: dmg)
                    throw UpdateError.core(.checksumMismatch)
                }
                UpdateLog.logger.info("Update checksum verified")
            }
            windowState = .verifying(release)

            let location = UpdateInstaller.currentLocation()
            let current = currentVersion
            stagedURL = try await UpdateInstaller.verifyAndStage(dmg: dmg, work: work, version: release.version,
                                                                 current: current, location: location)
            try Task.checkCancellation()

            guard let staged = stagedURL, case .writable(let appURL) = location else {
                // Запуск из DMG / App Translocation / папки без права записи: только показать образ.
                UpdateLog.logger.info("App location is read-only, offering the disk image")
                if let copy = downloadsCopyURL(for: release) {
                    try? FileManager.default.removeItem(at: copy)
                    try FileManager.default.copyItem(at: dmg, to: copy)
                    NSWorkspace.shared.activateFileViewerSelecting([copy])
                }
                windowState = .moveToApplications(release)
                return
            }

            guard confirmPausingTransfers() else {
                try? FileManager.default.removeItem(at: staged)
                stagedURL = nil
                closeWindow()
                return
            }
            windowState = .installing(release)
            try UpdateInstaller.launchReplacementHelper(appURL: appURL, stagedURL: staged, workDirectory: work)
            UpdateLog.logger.info("Quitting to install \(release.version.description, privacy: .public)")
            QuitController.shared.terminateWithoutPrompt()
        } catch {
            if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
            // Окно уже закрыто (отмена крестиком) — состояние не возвращаем.
            guard window != nil else { return }
            if error is CancellationError || Task.isCancelled {
                UpdateLog.logger.info("Update cancelled")
                windowState = .available(release)
                return
            }
            UpdateLog.logger.error("Update failed: \(error.localizedDescription, privacy: .public)")
            windowState = .failed(release, message: error.localizedDescription)
        }
    }

    private func downloadsCopyURL(for release: UpdateRelease?) -> URL? {
        guard let release,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        return downloads.appendingPathComponent(release.dmgName)
    }

    /// Идут передачи — «Pause Downloads and Update» или «Later». Прогресс сохраняется
    /// (.part-файлы, сессии отправки), после перезапуска очередь продолжается.
    private func confirmPausingTransfers() -> Bool {
        let activity = AppModel.shared.quitActivity
        guard activity.downloads + activity.uploads > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Transfers are in progress")
        alert.informativeText = String(localized: "Now: \(activity.summary). To update, NaviDrive will pause them and restart. Progress is saved, and transfers continue after the restart.")
        alert.addButton(withTitle: String(localized: "Pause Downloads and Update"))
        alert.addButton(withTitle: String(localized: "Later"))
        return runAlert(alert) == .alertFirstButtonReturn
    }

    // MARK: - Окна

    private func present(_ state: WindowState) {
        windowState = state
        if window == nil {
            let hosting = NSHostingController(rootView: UpdateView())
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "Software Update")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            let delegate = UpdateWindowDelegate { UpdateController.shared.windowWillClose() }
            window.delegate = delegate
            windowDelegate = delegate
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func closeWindow() {
        window?.close()
    }

    /// Закрытие окна крестиком — как «Later»; идущая загрузка отменяется.
    private func windowWillClose() {
        if case .installing = windowState { return }
        updateTask?.cancel()
        updateTask = nil
        windowState = nil
        window = nil
        windowDelegate = nil
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = String(localized: "You’re up to date (v\(currentVersionText))")
        alert.informativeText = String(localized: "NaviDrive \(currentVersionText) is the latest version.")
        alert.addButton(withTitle: String(localized: "OK"))
        runAlert(alert)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t check for updates")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        runAlert(alert)
    }

    @discardableResult
    private func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }
}

private final class UpdateWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}
