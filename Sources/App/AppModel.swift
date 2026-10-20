import AppKit
import Foundation
import Observation
import SwiftUI
import UserNotifications

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case myDrive, sharedWithMe, sharedDrives, linked, downloads, uploads, routes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .myDrive: String(localized: "My Drive")
        case .sharedWithMe: String(localized: "Shared with Me")
        case .sharedDrives: String(localized: "Shared Drives")
        case .linked: String(localized: "Added by Link")
        case .downloads: String(localized: "Download Manager")
        case .uploads: String(localized: "Uploads")
        case .routes: String(localized: "Save Locations")
        }
    }

    var systemImage: String {
        switch self {
        case .myDrive: "externaldrive.connected.to.line.below"
        case .sharedWithMe: "person.2"
        case .sharedDrives: "externaldrive.badge.person.crop"
        case .linked: "link"
        case .downloads: "arrow.down.circle"
        case .uploads: "arrow.up.circle"
        case .routes: "arrow.triangle.branch"
        }
    }

    /// Экран браузера облака (а не менеджеры и маршруты).
    var isCloudBrowser: Bool {
        switch self {
        case .myDrive, .sharedWithMe, .sharedDrives, .linked: true
        case .downloads, .uploads, .routes: false
        }
    }

    /// Разделы облака в sidebar: у Google — с общими дисками, у Dropbox — без них
    /// (командные папки видны в корне).
    static func cloudItems(for cloud: CloudProviderKind) -> [SidebarItem] {
        switch cloud {
        case .googleDrive: [.myDrive, .sharedWithMe, .sharedDrives, .linked]
        case .dropbox: [.myDrive, .sharedWithMe, .linked]
        }
    }

    /// Заголовок с учётом облака: корень Dropbox называется «Dropbox».
    func title(for cloud: CloudProviderKind) -> String {
        self == .myDrive && cloud == .dropbox ? cloud.displayName : title
    }

    func systemImage(for cloud: CloudProviderKind) -> String {
        self == .myDrive && cloud == .dropbox ? cloud.systemImage : systemImage
    }
}

/// Состояние входа одного облака.
struct CloudAccountState: Equatable {
    var isSignedIn = false
    var isSigningIn = false
    var userName: String?
    var userEmail: String?
    /// Понятный текст последней ошибки входа (окно приветствия и настройки).
    var signInError: String?
    /// Страница входа текущей попытки — «Открыть страницу входа ещё раз».
    var signInURL: URL?
}

/// Путь навигации браузера хранится отдельно для каждого облака и раздела.
struct BrowserStackKey: Hashable {
    let cloud: CloudProviderKind
    let scope: BrowserScope
}

/// Секции «Менеджера загрузок».
enum TaskSectionKind: String, CaseIterable, Identifiable, Sendable {
    case downloading, paused, queued, waiting, failed, completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .downloading: String(localized: "Downloading")
        case .paused: String(localized: "Paused")
        case .queued: String(localized: "Queued")
        case .waiting: String(localized: "Waiting")
        case .failed: String(localized: "Errors")
        case .completed: String(localized: "Completed")
        }
    }

    var statuses: [TaskStatus] {
        switch self {
        case .downloading: [.downloading, .verifying]
        case .paused: [.paused, .pausedAll]
        case .queued: [.queued]
        case .waiting: [.waitingForVolume, .waitingForSpace, .waitingForNetwork, .waitingDailyLimit]
        case .failed: [.failed]
        case .completed: [.completed, .cancelled]
        }
    }

    /// История и ошибки — новые сверху; остальное — в порядке очереди.
    var newestFirst: Bool { self == .failed || self == .completed }

    /// Сколько строк загружать за один снимок (List ленивый, строки отрисовываются по мере прокрутки).
    var limit: Int {
        switch self {
        case .downloading: 500
        case .waiting, .completed: 2_000
        case .paused, .queued, .failed: 5_000
        }
    }
}

/// Сегментированный фильтр над списком задач.
enum DownloadFilter: String, CaseIterable, Identifiable {
    case all, active, paused, errors, completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .active: String(localized: "Active")
        case .paused: String(localized: "Paused")
        case .errors: String(localized: "Errors")
        case .completed: String(localized: "Completed")
        }
    }

    var sections: [TaskSectionKind] {
        switch self {
        case .all: TaskSectionKind.allCases
        case .active: [.downloading, .queued, .waiting]
        case .paused: [.paused]
        case .errors: [.failed]
        case .completed: [.completed]
        }
    }

    var statuses: [TaskStatus] { sections.flatMap(\.statuses) }
}

/// Состояние кнопок тулбара браузера облака (публикует открытый DriveBrowserView).
struct BrowserToolbarState: Equatable {
    var canGoBack = false
    /// Текущая папка, в которую можно создавать и загружать (nil — нельзя).
    var uploadTarget: UploadTarget?
    var hasSelection = false
    /// В списке есть что скачать (для «Скачать всё» в разделе «Добавленные по ссылке»).
    var hasItems = false
    var isLoading = false
}

enum BrowserCommand: Equatable {
    case back, refresh, newFolder, upload, download, downloadAll, downloadToCustom, setPermanentRoute
}

struct BrowserCommandRequest: Equatable {
    let id: Int
    let command: BrowserCommand
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // Сервисы
    let keychain = KeychainStore()
    /// Подключённые облака; очереди исполняют задачи провайдером из их колонки `provider`.
    let providers: CloudProviders
    /// Облако, с которым работают браузер, ссылки и отправка (переключатель вверху sidebar).
    var provider: any CloudProvider { providers[activeCloud] ?? providers.primary }
    let db: DatabaseManager?
    let scheduler: DownloadScheduler?
    let uploadScheduler: UploadScheduler?
    private let networkMonitor = NetworkMonitor()

    // Авторизация: входы в облака независимы (можно подключить одно, другое или оба).
    var clientId: String
    var clientSecret: String
    /// Состояние входа каждого облака.
    var accounts: [CloudProviderKind: CloudAccountState] = [:]
    /// Облако, открытое в sidebar (запоминается между запусками).
    var activeCloud: CloudProviderKind = AppSettings.activeCloud {
        didSet {
            guard activeCloud != oldValue else { return }
            AppSettings.activeCloud = activeCloud
            browserFilter = ""
            if !SidebarItem.cloudItems(for: activeCloud).contains(selection ?? .myDrive),
               SidebarItem.cloudItems(for: oldValue).contains(selection ?? .myDrive) {
                selection = .myDrive
            }
        }
    }
    /// При запуске был сохранённый вход: сразу главное окно, иначе — только окно приветствия.
    let launchedSignedIn: Bool
    /// Пояснение в окне приветствия (например, «Доступ к Google Drive истёк»).
    var welcomeNotice: String?
    /// Вошли другим аккаунтом, а очередь осталась от предыдущего: что с ней сделать.
    var accountSwitch: AccountSwitch?

    struct AccountSwitch: Identifiable, Equatable {
        let id = UUID()
        let provider: CloudProviderKind
        /// Email предыдущего аккаунта ("" — неизвестен).
        let previousEmail: String
    }
    /// «Использовать свои учётные данные OAuth» Google (Настройки → Аккаунты → Дополнительно).
    var useCustomCredentials = false {
        didSet { AppSettings.useCustomOAuthCredentials = useCustomCredentials }
    }
    /// В эту копию при сборке вписаны Client ID/Secret Google.
    var hasBundledCredentials: Bool { OAuthCredentials.bundled != nil }
    @ObservationIgnored var signInTasks: [CloudProviderKind: Task<Void, Never>] = [:]

    // Настройки
    var defaultDownloadPath: String = AppSettings.defaultDownloadPath {
        didSet { AppSettings.defaultDownloadPath = defaultDownloadPath }
    }
    var preventSleep: Bool = AppSettings.preventSleep {
        didSet {
            AppSettings.preventSleep = preventSleep
            updateSleepAssertion()
        }
    }
    /// Активность ProcessInfo, запрещающая сон системы, пока идут загрузки.
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var lastNotifiedSession = 0

    var maxConcurrentUploads: Int = AppSettings.maxConcurrentUploads {
        didSet {
            AppSettings.maxConcurrentUploads = maxConcurrentUploads
            let value = maxConcurrentUploads
            Task { await uploadScheduler?.setUserLimit(value) }
        }
    }

    /// Свои лимиты Google Drive за скользящие 24 часа (Настройки → Скачивание / Отправка).
    var googleDownloadLimitEnabled: Bool = AppSettings.googleLimitEnabled(.download) {
        didSet { AppSettings.setGoogleLimitEnabled(googleDownloadLimitEnabled, .download); limitsChanged() }
    }
    var googleDownloadLimitGB: Int = AppSettings.googleLimitGB(.download) {
        didSet { AppSettings.setGoogleLimitGB(googleDownloadLimitGB, .download); limitsChanged() }
    }
    var googleUploadLimitEnabled: Bool = AppSettings.googleLimitEnabled(.upload) {
        didSet { AppSettings.setGoogleLimitEnabled(googleUploadLimitEnabled, .upload); limitsChanged() }
    }
    var googleUploadLimitGB: Int = AppSettings.googleLimitGB(.upload) {
        didSet { AppSettings.setGoogleLimitGB(googleUploadLimitGB, .upload); limitsChanged() }
    }

    private func limitsChanged() {
        Task {
            await scheduler?.limitsChanged()
            await uploadScheduler?.limitsChanged()
            await refresh()
        }
    }

    /// Лимиты обоих направлений и облаков: свой счётчик за 24 часа и остановка по ответу облака.
    var limits: [TransferLimitStatus] = []
    /// Остановки по лимиту, о которых уже было системное уведомление (nil — ещё не было первого снимка).
    @ObservationIgnored var notifiedLimits: Set<String>?

    /// Карточка статуса: сообщения о том, что происходит во всех облаках.
    var statusMessages: [StatusMessage] = []
    /// Передачи идут → «Готово: …» (~3 с) → покой; см. `updateTransferActivity`.
    @ObservationIgnored var transferActivity = TransferActivity.idle
    /// Файлы, которые передавались с начала текущей активности (для сообщения «Готово: …»).
    @ObservationIgnored var transferLog = TransferLog()
    @ObservationIgnored var completionMessage: StatusMessage?
    /// Байты реально идут (скачивание или отправка в любом облаке) — зелёная точка в трее.
    var isTransferring = false
    /// Зелёная пульсация карточки: пока идёт передача и во время «Готово: …»; гаснет вместе с переходом в покой.
    var pulseActive = false
    /// Оранжевая пульсация: пока идёт перемещение в корзину и во время «В корзину перемещено …».
    var trashPulseActive = false
    /// Текущее (или только что закончившееся) перемещение в корзину — для карточки статуса.
    @ObservationIgnored var trashOperation: TrashOperation?
    /// Перемещение с ошибками: красное сообщение, пока список причин не открыли.
    @ObservationIgnored var trashFailures: TrashOperation?
    /// «Выйти после завершения»: приложение закроется само, когда закончатся передачи.
    var quitWhenDone = false
    @ObservationIgnored var trashCounter = 0
    @ObservationIgnored var lastBytesFlowAt: Date?
    /// Строка диска, к которой ведёт сообщение карточки (подсвечивается в разделе «Диски»).
    var highlightedVolume: String?
    /// Секция менеджера, к которой ведёт сообщение карточки.
    var pendingDownloadSection: TaskSectionKind?
    var pendingUploadSection: UploadSectionKind?
    #if DEBUG
    /// Debug → Simulate: подставные сообщения для проверки карточки (диск, сеть).
    var debugSimulations: Set<DebugSimulation> = []
    #endif

    var maxConcurrentDownloads: Int = AppSettings.maxConcurrentDownloads {
        didSet {
            AppSettings.maxConcurrentDownloads = maxConcurrentDownloads
            let value = maxConcurrentDownloads
            Task { await scheduler?.setUserLimit(value) }
        }
    }

    // Состояние загрузок
    var snapshot = EngineSnapshot()
    /// Строки текущей папки браузера, для которых считаются индикаторы передач.
    @ObservationIgnored var browserTransferContext: BrowserTransferContext?
    /// Индикаторы передач и строки-заглушки загружаемых файлов для текущей папки.
    var browserTransfers = BrowserTransfers()
    /// Растёт, когда список папки устарел (отправленный файл уже в облаке, в очередь добавлены папки).
    var browserListingStaleToken = 0
    /// Отправки, после завершения которых список папки уже обновлялся.
    @ObservationIgnored var requestedListingRefresh: Set<String> = []
    @ObservationIgnored private var downloadStateVersion = 0
    var totals = QueueTotals()
    /// По умолчанию «Все»: задачи на паузе, в ожидании и с ошибками не должны «исчезать» из списка.
    var downloadFilter: DownloadFilter = .all
    /// Задачи по секциям для текущего фильтра (загружаются в фоне).
    var sections: [TaskSectionKind: [DownloadTask]] = [:]
    var routes: [CustomRoute] = []
    var routeMap: [RouteKey: String] = [:]
    /// Маршруты, чей внешний диск сейчас не подключён (проверяется в фоне, не в body).
    var routeVolumeMissing: Set<RouteKey> = []
    /// Посчитанные по запросу размеры папок облака (из SQLite).
    var folderSizes: [RouteKey: FolderSize] = [:]
    /// Папки, размер которых сейчас считается или ждёт очереди (промежуточный итог — у идущего подсчёта).
    var folderSizeJobs: [RouteKey: FolderSizeJob] = [:]
    /// Очередь подсчёта по облакам: одновременно идёт один подсчёт на облако.
    @ObservationIgnored var folderSizeQueue: [CloudProviderKind: [CloudItem]] = [:]
    @ObservationIgnored var folderSizeTasks: [RouteKey: Task<Void, Never>] = [:]
    /// Есть ли активная работа (загрузки, обход, проверка). Меняется только на переходах —
    /// в отличие от счётчиков, которые при скачивании мелких файлов меняются несколько раз в секунду.
    var hasActiveDownloads = false
    // Отправка в Google Drive
    var uploadSnapshot = UploadSnapshot()
    var uploadTotals = UploadTotals()
    var uploadFilter: DownloadFilter = .all
    var uploadSections: [UploadSectionKind: [UploadTask]] = [:]
    var uploadBanner: String?
    /// Окно «Для загрузки нужно заново войти в Google».
    var showReauthPrompt = false
    @ObservationIgnored var seenReauthRequests = 0
    /// Файлы из Finder Services, для которых выбирается папка на диске.
    var pendingServiceUpload: [URL]?
    /// Services вызваны при закрытом главном окне: после выбора папки окно открывается на ней.
    @ObservationIgnored var serviceUploadOpensTarget = false
    /// Раздел «Диски»: системный диск и подключённые внешние диски с заполненностью.
    var volumes: [DiskVolume] = []

    var selection: SidebarItem? = .myDrive
    /// Тулбар браузера Drive живёт на стабильном контейнере detail-колонки (MainView), а не в самом
    /// браузере: доступность кнопок и текст фильтра хранятся здесь и не сбрасываются при показе/скрытии sidebar.
    var browserToolbar = BrowserToolbarState()
    /// Текст поля «Фильтр по имени».
    var browserFilter = ""
    /// Команда кнопки тулбара для открытого браузера Drive (выполняет DriveBrowserView).
    var browserCommand: BrowserCommandRequest?
    @ObservationIgnored private var browserCommandSerial = 0

    func sendBrowserCommand(_ command: BrowserCommand) {
        browserCommandSerial += 1
        browserCommand = BrowserCommandRequest(id: browserCommandSerial, command: command)
    }
    /// Вкладка окна настроек.
    var settingsTab: SettingsTab = .account
    var errorMessage: String?
    /// Увеличивается, когда браузеру Drive нужно перезагрузить содержимое (вход/выход).
    var driveReloadToken = 0
    /// Путь навигации в браузерах Drive: сохраняется при переключении разделов
    /// (например, после «Скачать» — переход в «Менеджер загрузок» и обратно).
    var browserStacks: [BrowserStackKey: [CloudItem]] = [:]
    /// Увеличивается, когда браузер должен перейти к `browserStacks[scope]` (например, из карточки ссылки).
    var browserNavigationToken = 0
    /// Объекты, добавленные по ссылке.
    var linkedItems: [LinkedItem] = []
    var showAddLink = false
    /// Итог последней постановки в очередь — баннер вверху «Менеджера загрузок».
    var enqueueBanner: EnqueueBanner?

    struct EnqueueBanner: Identifiable, Equatable {
        let id = UUID()
        let report: EnqueueReport
    }

    private var started = false
    private var refreshLoop: Task<Void, Never>?
    private var volumeLoop: Task<Void, Never>?

    private init() {
        var notices: [String] = []
        let store = KeychainStore()

        // Одноразово: записи ad-hoc сборок недоступны сборке, подписанной сертификатом «NaviDrive Local».
        if KeychainStore.migrateLegacyItemsIfNeeded() == .reloginRequired {
            notices.append(Self.reloginAfterSigningChangeMessage)
        }

        do {
            clientId = try store.clientId()
            clientSecret = try store.clientSecret()
        } catch {
            clientId = ""
            clientSecret = ""
            notices.append(String(localized: "Couldn’t read the Client ID / Client Secret from the Keychain: \(error.localizedDescription)"))
        }
        let providers = CloudProviders([GoogleDriveProvider(keychain: store), DropboxProvider(keychain: store)])
        self.providers = providers
        let signedIn = providers.all.filter(\.hadSessionAtLaunch).map(\.kind)
        launchedSignedIn = !signedIn.isEmpty
        do {
            let database = try DatabaseManager()
            db = database
            scheduler = DownloadScheduler(db: database, providers: providers)
            uploadScheduler = UploadScheduler(db: database, providers: providers)
        } catch {
            db = nil
            scheduler = nil
            uploadScheduler = nil
            notices.append(String(localized: "Couldn’t open the database: \(error.localizedDescription)"))
        }
        for kind in signedIn { accounts[kind] = CloudAccountState(isSignedIn: true) }
        // Сохранённое облако без входа — показать подключённое.
        if let first = signedIn.first, !signedIn.contains(activeCloud) { activeCloud = first }
        // Кто уже вводил свои Client ID/Secret, продолжает входить с ними.
        AppSettings.migrateCustomOAuthChoice(hasCustomCredentials: !clientId.isEmpty && !clientSecret.isEmpty)
        useCustomCredentials = AppSettings.useCustomOAuthCredentials
        if !notices.isEmpty {
            errorMessage = notices.joined(separator: "\n\n")
        }
    }

    static var reloginAfterSigningChangeMessage: String {
        String(localized: "NaviDrive is now signed with the permanent “NaviDrive Local” certificate. Your saved sign-in was created by an earlier build with a temporary signature, and macOS doesn’t let the new signature access it, so the old items were removed. Open Settings, re-enter the Client ID and Client Secret if needed, and sign in to Google once more — from now on the sign-in will persist across rebuilds.")
    }

    // MARK: - Startup

    func startIfNeeded() {
        guard !started else { return }
        started = true
        reloadRoutes()
        reloadLinked()
        reloadFolderSizes()

        Task {
            var authorized: Set<CloudProviderKind> = []
            for provider in providers.all {
                let kind = provider.kind
                await provider.setAccessRevokedHandler {
                    Task { @MainActor in AppModel.shared.handleAccessRevoked(kind) }
                }
                let signedIn = await provider.isSignedIn()
                accounts[kind, default: CloudAccountState()].isSignedIn = signedIn
                if let keychainError = await provider.credentialLoadError() {
                    // Нет доступа ≠ нет входа: запись не удаляем, а объясняем, что произошло.
                    let message = String(localized: "Couldn’t read the saved sign-in from the Keychain: \(keychainError)\n\nThe sign-in was not deleted. Restart NaviDrive and, if macOS asks for Keychain access, click “Always Allow”.")
                    if errorMessage?.contains(message) != true {
                        errorMessage = [errorMessage, message].compactMap { $0 }.joined(separator: "\n\n")
                    }
                    openSettings(.account)
                }
                // Очередь аккаунта, чей доступ был отозван, ждёт решения после входа (см. resumeQueuesAfterSignIn).
                if signedIn && AppSettings.queueOwnerAwaitingSignIn(for: kind) == nil { authorized.insert(kind) }
            }
            if errorMessage?.contains(Self.reloginAfterSigningChangeMessage) == true { openSettings(.account) }
            await scheduler?.start(authorized: authorized)
            await uploadScheduler?.start(authorized: authorized)
            for kind in connectedClouds {
                await loadUser(kind)
                if !authorized.contains(kind) { await resumeQueuesAfterSignIn(kind) }
            }
        }

        let scheduler = scheduler
        let uploadScheduler = uploadScheduler
        networkMonitor.start { online in
            Task { await scheduler?.setOnline(online) }
            Task { await uploadScheduler?.setOnline(online) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await scheduler?.recheckVolumes() }
            Task { await uploadScheduler?.recheckVolumes() }
            Task { @MainActor in
                self?.reloadRoutes()
                await self?.refreshVolumes()
            }
        }
        // Отключили внешний диск — обновить пометку «Диск не подключён» у маршрутов.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadRoutes()
                await self?.refreshVolumes()
            }
        }
        // После сна задачи, ждущие повтора, пробуют сразу, а не досиживают паузу.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { await scheduler?.wakeUp() }
            Task { await uploadScheduler?.wakeUp() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Заполненность дисков: каждые 10 с, пока идут загрузки, и раз в минуту в простое.
        volumeLoop = Task { [weak self] in
            var secondsSinceRefresh = Int.max
            while !Task.isCancelled {
                let interval = self?.hasActiveDownloads == true ? 10 : 60
                if secondsSinceRefresh >= interval {
                    await self?.refreshVolumes()
                    secondsSinceRefresh = 0
                }
                try? await Task.sleep(for: .seconds(10))
                secondsSinceRefresh += 10
            }
        }

        refreshLoop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                // Прогресс в UI объединяется и обновляется не чаще 2 раз в секунду.
                await self?.refresh(includeTasks: tick % 2 == 0)
                tick += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func refresh(includeTasks: Bool = true) async {
        guard let scheduler else { return }
        // Снимок планировщика, счётчики и секции — одним вызовом актора (единый источник правды):
        // шапка, вкладки, секции, трей и кнопки всегда показывают одно и то же состояние.
        // На главном потоке только присвоение и только если данные изменились.
        let state = await scheduler.state(sections: downloadFilter.sections)
        if state.version > downloadStateVersion {
            downloadStateVersion = state.version
            // Переход задачи между секциями — с короткой анимацией; обновления прогресса — без неё.
            let moved = state.sections.mapValues { $0.map(\.id) } != sections.mapValues { $0.map(\.id) }
            withAnimation(moved ? .easeInOut(duration: 0.2) : nil) {
                if state.snapshot != snapshot { snapshot = state.snapshot }
                if state.totals != totals { totals = state.totals }
                if state.sections != sections { sections = state.sections }
            }
            let active = snapshot.runningCount > 0 || snapshot.scanningFolders > 0 || !snapshot.verificationProgress.isEmpty
            if active != hasActiveDownloads { hasActiveDownloads = active }
        }
        await refreshUploads(includeTasks: includeTasks && selection == .uploads)
        await refreshBrowserTransfers()
        let newLimits = state.limits + uploadSnapshot.limits
        if newLimits != limits { limits = newLimits }
        updateSleepAssertion()
        notifyIfQueueFinished()
        notifyLimitChanges()
        let transfersSettled = await updateTransferActivity()
        let trashSettled = updateTrashActivity()
        if transfersSettled || trashSettled {
            // Переход в покой — одним анимационным шагом из одного обновления состояния:
            // пульсация, обводка, точки ротации и текст «Online» меняются вместе.
            withAnimation(StatusCard.settleAnimation) {
                if transfersSettled { pulseActive = false }
                if trashSettled { trashPulseActive = false }
                rebuildStatusFeed()
            }
        } else {
            rebuildStatusFeed()
        }
        quitIfTransfersFinished()
    }

    // MARK: - Sleep & notifications

    /// Пока есть активные или ожидающие загрузки (и не всё на паузе), система не засыпает.
    private func updateSleepAssertion() {
        let counts = totals.countsByStatus
        let waiting = [TaskStatus.queued, .downloading, .verifying, .waitingForNetwork, .waitingDailyLimit]
            .reduce(0) { $0 + (counts[$1] ?? 0) }
        let busy = snapshot.runningCount > 0 || snapshot.scanningFolders > 0
            || !snapshot.verificationProgress.isEmpty || waiting > 0
        let uploadCounts = uploadTotals.countsByStatus
        let uploadsWaiting = [UploadStatus.queued, .uploading, .verifying, .waitingForNetwork]
            .reduce(0) { $0 + (uploadCounts[$1] ?? 0) }
        let uploadsBusy = !uploadSnapshot.isPaused
            && (uploadSnapshot.runningCount > 0 || uploadsWaiting > 0 || !uploadSnapshot.preparing.isEmpty)
        let needed = preventSleep && isSignedIn && ((!snapshot.isPaused && busy) || uploadsBusy)

        if needed, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "NaviDrive: downloading or uploading Google Drive files")
        } else if !needed, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    /// Системное уведомление «Проект „…“ скачан: N файлов, X ГБ, все проверены» — только для большой
    /// очереди (от 10 файлов или от 1 ГБ) и при ошибках; о малой хватает сообщения в карточке статуса.
    private func notifyIfQueueFinished() {
        guard let summary = snapshot.lastSession, summary.id != lastNotifiedSession else { return }
        lastNotifiedSession = summary.id
        guard summary.files >= 10 || summary.bytes >= 1_000_000_000 || summary.failed > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = summary.notificationTitle
        content.body = summary.notificationBody
        content.sound = .default
        let request = UNNotificationRequest(identifier: "navidrive.queue.\(summary.id).\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Routes

    // MARK: - Links

    enum LinkLookupError: LocalizedError {
        case invalidLink(CloudProviderKind)
        case notFound(hasResourceKey: Bool)
        /// Общая ссылка не найдена (удалена или устарела).
        case linkNotFound
        case noAccess

        var errorDescription: String? {
            switch self {
            case .invalidLink(.googleDrive):
                String(localized: "This doesn’t look like a Google Drive link. Paste a link like drive.google.com/drive/folders/… or an ID.")
            case .invalidLink(.dropbox):
                String(localized: "This doesn’t look like a Dropbox link. Paste a shared link like dropbox.com/scl/fo/…")
            case .linkNotFound:
                String(localized: "The shared link wasn’t found. It may have been deleted or have expired.")
            case .notFound(let hasKey):
                hasKey
                    ? String(localized: "Item not found (HTTP 404). Check the link: it may be outdated or have a wrong resourceKey.")
                    : String(localized: "Item not found (HTTP 404). Check the link: it may need a resourceKey — copy the full link including “resourcekey=…”.")
            case .noAccess:
                String(localized: "No access (HTTP 403). Ask the owner to share it by link or with your account.")
            }
        }
    }

    func reloadLinked() {
        Task { await reloadLinkedNow() }
    }

    private func reloadLinkedNow() async {
        guard let linked = await inBackground({ $0.linkedItems() }) else { return }
        for item in linked { providers[item.provider]?.rememberAccessKey(item.resourceKey, for: item.driveId) }
        if linked != linkedItems { linkedItems = linked }
    }

    /// Ссылки текущего облака (раздел «Добавленные по ссылке»).
    var activeLinkedItems: [LinkedItem] { linkedItems.filter { $0.provider == activeCloud } }

    /// Находит объект по ссылке текущего облака, раскрывает ярлык и сохраняет в «Добавленные по ссылке».
    func lookupLink(_ text: String) async throws -> CloudItem {
        let provider = provider
        guard let link = provider.parseLink(text) else { throw LinkLookupError.invalidLink(provider.kind) }
        var item: CloudItem
        do {
            item = try await provider.item(id: link.id, accessKey: link.accessKey)
            if item.isAlias { item = try await provider.resolveAlias(item) }
        } catch CloudAPIError.http(404, _, _) {
            if provider.kind == .dropbox { throw LinkLookupError.linkNotFound }
            throw LinkLookupError.notFound(hasResourceKey: link.accessKey != nil)
        } catch CloudAPIError.http(403, let message, _) where !message.lowercased().contains("ratelimit") {
            throw LinkLookupError.noAccess
        }
        let linked = provider.linkRecord(for: item)
        let failure = await inBackground { db -> String? in
            do { try db.saveLinked(linked); return nil } catch { return error.localizedDescription }
        }
        if let failure, let failure { errorMessage = failure }
        await reloadLinkedNow()
        return item
    }

    func removeLinked(_ item: CloudItem) {
        let id = item.id, kind = item.provider
        Task {
            _ = await inBackground { try? $0.deleteLinked(provider: kind, driveId: id) }
            await reloadLinkedNow()
        }
    }

    /// Браузер облака на папке, выбранной в дереве папок (`path` — от корня до папки).
    func openInBrowser(path: [UploadTarget]) {
        guard let target = path.last, let provider = providers[target.provider] else { return }
        let inMyDrive = path.first?.id == provider.rootFolder.id
        let scope: BrowserScope = inMyDrive ? .myDrive : .sharedDrives
        let stack = (inMyDrive ? Array(path.dropFirst()) : path).map { folder -> CloudItem in
            var item = CloudItem(provider: folder.provider, id: folder.id, name: folder.name, isFolder: true)
            // Dropbox адресует папки путями: ID цели загрузки и есть путь.
            if folder.provider == .dropbox { item.path = folder.id }
            item.spaceId = folder.spaceId
            return item
        }
        activeCloud = target.provider
        browserStacks[BrowserStackKey(cloud: target.provider, scope: scope)] = stack
        browserNavigationToken += 1
        selection = scope == .myDrive ? .myDrive : .sharedDrives
    }

    /// «Открыть в браузере NaviDrive»: раздел «Добавленные по ссылке», внутри папки.
    func openInBrowser(_ item: CloudItem) {
        activeCloud = item.provider
        browserStacks[BrowserStackKey(cloud: item.provider, scope: .linked)] = item.isFolder ? [item] : []
        browserNavigationToken += 1
        selection = .linked
    }

    /// Скачивание из карточки ссылки с проверкой свободного места.
    func downloadLinked(_ item: CloudItem, chooseFolder: Bool, requiredBytes: Int64?) {
        if chooseFolder {
            guard let path = chooseDirectory(message: String(localized: "Where should “\(item.name)” be downloaded? You can choose an external disk in /Volumes.")) else { return }
            guard confirmFreeSpace(requiredBytes, at: path) else { return }
            setRoute(for: item, path: path)
            enqueue([item], groups: [path: [item]], checksFreeSpace: false)
        } else {
            let dir = PathResolver.destinationDirectory(for: item, ancestors: [], routes: routeMap, defaultPath: defaultDownloadPath)
            guard confirmFreeSpace(requiredBytes, at: dir) else { return }
            enqueue([item], groups: [dir: [item]], checksFreeSpace: false)
        }
    }

    /// Предупреждение, если на целевом диске не хватает места. true — продолжать.
    private func confirmFreeSpace(_ required: Int64?, at path: String) -> Bool {
        guard let required, required > 0, let free = PathResolver.availableCapacity(at: path), free < required else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Not enough disk space")
        alert.informativeText = String(localized: "\(Format.bytes(required)) needed, \(Format.bytes(free)) free (\(path)). The download will stop when the disk is full.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Download Anyway"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Работа с SQLite вне главного потока: главный поток никогда не ждёт блокировку базы,
    /// которую в это время держат обход папок и планировщик.
    func inBackground<T: Sendable>(_ work: @escaping @Sendable (DatabaseManager) -> T) async -> T? {
        guard let db else { return nil }
        return await Task.detached(priority: .userInitiated) { work(db) }.value
    }

    func reloadRoutes() {
        Task { await reloadRoutesNow() }
    }

    private func reloadRoutesNow() async {
        guard let (newRoutes, missing) = await inBackground({ db -> ([CustomRoute], Set<RouteKey>) in
            let routes = db.allRoutes()
            let missing = routes.filter {
                if case .missing = PathResolver.volumeState(for: $0.localPath) { return true }
                return false
            }
            return (routes, Set(missing.map(\.id)))
        }) else { return }
        if newRoutes != routes { routes = newRoutes }
        let map = Dictionary(newRoutes.map { ($0.id, $0.localPath) }, uniquingKeysWith: { a, _ in a })
        if map != routeMap { routeMap = map }
        if missing != routeVolumeMissing { routeVolumeMissing = missing }
    }

    /// Запись маршрута в фоне; routeMap обновляется сразу, чтобы следующие действия уже видели путь.
    private func writeRoute(_ work: @escaping @Sendable (DatabaseManager) throws -> Void) {
        Task {
            let failure = await inBackground { db -> String? in
                do { try work(db); return nil } catch { return error.localizedDescription }
            }
            if let failure, let failure { errorMessage = failure }
            await reloadRoutesNow()
        }
    }

    func setRoute(for item: CloudItem, path: String) {
        routeMap[item.routeKey] = path
        let provider = item.provider, id = item.id, name = item.name
        writeRoute { try $0.setRoute(provider: provider, driveId: id, driveName: name, localPath: path) }
    }

    func changeRoute(_ route: CustomRoute) {
        guard let path = chooseDirectory(message: String(localized: "New location for “\(route.driveName)”"), initial: route.localPath) else { return }
        routeMap[route.id] = path
        writeRoute { try $0.setRoute(provider: route.provider, driveId: route.driveId, driveName: route.driveName, localPath: path) }
    }

    func deleteRoute(_ route: CustomRoute) {
        routeMap[route.id] = nil
        writeRoute { try $0.deleteRoute(provider: route.provider, driveId: route.driveId) }
    }

    /// Маршрут самого объекта (без учёта предков).
    func route(for item: CloudItem) -> CustomRoute? {
        routes.first { $0.id == item.routeKey }
    }

    // MARK: - Cloud actions (context menu)

    func downloadToDefault(_ items: [CloudItem], ancestors: [CloudItem]) {
        var groups: [String: [CloudItem]] = [:]
        for item in items {
            let dir = PathResolver.destinationDirectory(for: item, ancestors: ancestors, routes: routeMap,
                                                        defaultPath: defaultDownloadPath)
            groups[dir, default: []].append(item)
        }
        enqueue(items, groups: groups, ancestors: ancestors)
    }

    /// Постановка в очередь и баннер с итогом. Экран не переключается: прогресс виден
    /// индикаторами в списке файлов облака, «Менеджер загрузок» открывается только по запросу.
    private func enqueue(_ items: [CloudItem], groups: [String: [CloudItem]], ancestors: [CloudItem] = [],
                         checksFreeSpace: Bool = true) {
        guard let scheduler, !items.isEmpty else { return }
        var groups = groups
        if checksFreeSpace {
            // Свободное место проверяется, только если у папок есть свежий посчитанный размер.
            groups = groups.filter { dir, group in
                let known = group.compactMap { $0.isFolder ? freshFolderSize($0)?.tally.totalSize : nil }
                guard !known.isEmpty else { return true }
                let required = known.reduce(0, +) + group.filter { !$0.isFolder }.reduce(0) { $0 + $1.sizeValue }
                return confirmFreeSpace(required, at: dir)
            }
            guard !groups.isEmpty else { return }
        }
        let title = Self.title(for: items)
        let ancestorIds = ancestors.map(\.targetId)
        Task {
            var report = EnqueueReport(title: title)
            for (dir, group) in groups {
                report.merge(await scheduler.enqueue(group, destinationDir: dir, projectName: title, ancestorIds: ancestorIds))
            }
            showEnqueueReport(report)
        }
    }

    func downloadToCustom(_ items: [CloudItem], ancestors: [CloudItem]) {
        guard !items.isEmpty else { return }
        let message = items.count == 1
            ? String(localized: "Where should “\(items[0].name)” be downloaded? You can choose an external disk in /Volumes.")
            : String(localized: "Where should \(items.count) items be downloaded? You can choose an external disk in /Volumes.")
        guard let path = chooseDirectory(message: message) else { return }
        for item in items { setRoute(for: item, path: path) }
        enqueue(items, groups: [path: items], ancestors: ancestors)
    }

    private static func title(for items: [CloudItem]) -> String {
        items.count == 1 ? items[0].name : String(localized: "\(items.count) items")
    }

    /// Показывает итог на несколько секунд (предупреждения — дольше).
    private func showEnqueueReport(_ report: EnqueueReport) {
        // Экран больше не переключается на «Менеджер загрузок», где висит баннер: если ничего
        // не добавлено из-за ошибок или запрета, причина показывается сразу.
        if selection != .downloads, report.added == 0, report.alreadyDownloaded == 0, report.tone == .warning {
            errorMessage = report.message
        }
        let banner = EnqueueBanner(report: report)
        enqueueBanner = banner
        let seconds: Double = report.tone == .warning ? 12 : 6
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if enqueueBanner?.id == banner.id { enqueueBanner = nil }
        }
        Task { await refresh() }
    }

    func setPermanentRoute(_ items: [CloudItem]) {
        guard !items.isEmpty else { return }
        let message = items.count == 1
            ? String(localized: "Permanent save location for “\(items[0].name)”")
            : String(localized: "Permanent save location for \(items.count) items")
        guard let path = chooseDirectory(message: message) else { return }
        for item in items { setRoute(for: item, path: path) }
    }

    func revealInFinder(_ item: CloudItem, ancestors: [CloudItem]) {
        let path = PathResolver.localPath(for: item, ancestors: ancestors, routes: routeMap, defaultPath: defaultDownloadPath)
        revealPath(path, alternatives: [path + item.provider.partialSuffix])
    }

    func revealRoute(_ route: CustomRoute) {
        revealPath(PathResolver.expand(route.localPath), alternatives: [])
    }

    func revealTask(_ task: DownloadTask) {
        revealPath(task.finalPath, alternatives: [task.partPath])
    }

    private func revealPath(_ path: String, alternatives: [String]) {
        let fm = FileManager.default
        for candidate in [path] + alternatives where fm.fileExists(atPath: candidate) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate)])
            return
        }
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        while !fm.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        if case .missing(let message) = PathResolver.volumeState(for: path) {
            errorMessage = message
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openDefaultFolder() {
        let path = PathResolver.expand(defaultDownloadPath)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func chooseDefaultFolder() {
        if let path = chooseDirectory(message: String(localized: "Default download folder"), initial: defaultDownloadPath) {
            defaultDownloadPath = path
        }
    }

    func chooseDirectory(message: String, initial: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = message
        if let initial {
            panel.directoryURL = URL(fileURLWithPath: PathResolver.expand(initial))
        }
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    // MARK: - Queue control

    /// Что сделает кнопка общей паузы (тулбар, трей): пауза, если есть что останавливать;
    /// «продолжить», если есть задачи после общей паузы; иначе — ничего (кнопка неактивна).
    enum PauseAllAction {
        case pause, resume, none

        var help: String {
            switch self {
            case .pause: String(localized: "Pause all active and queued downloads")
            case .resume: String(localized: "Resume downloads stopped with Pause All (files paused individually stay paused)")
            case .none: String(localized: "No downloads to pause or resume")
            }
        }
    }

    var pauseAllAction: PauseAllAction {
        if totals.hasPausable { return .pause }
        return totals.pausedAllCount > 0 ? .resume : .none
    }

    func togglePauseAll() {
        let action = pauseAllAction
        Task {
            switch action {
            case .pause: await scheduler?.pauseAll()
            case .resume: await scheduler?.resumePausedAll()
            case .none: return
            }
            await refresh()
        }
    }

    func pause(_ task: DownloadTask) { Task { await scheduler?.pauseTask(task.id); await refresh() } }
    func resume(_ task: DownloadTask) { Task { await scheduler?.resumeTask(task.id); await refresh() } }
    func cancel(_ task: DownloadTask) { Task { await scheduler?.cancelTask(task.id); await refresh() } }
    func retryFailed() { Task { await scheduler?.retryFailed(); await refresh() } }
    func resumeAllPaused() { Task { await scheduler?.resumeAllPaused(); await refresh() } }
    /// «Попробовать сейчас» для скачиваний, ждущих лимита Google.
    func retryQuotaNow() { retryLimit(.googleDrive, .download) }

    func retryLimit(_ provider: CloudProviderKind, _ direction: TransferDirection) {
        Task {
            switch direction {
            case .download: await scheduler?.retryLimitNow()
            case .upload: await uploadScheduler?.retryLimitNow(provider)
            }
            await refresh()
        }
    }

    func limit(_ provider: CloudProviderKind, _ direction: TransferDirection) -> TransferLimitStatus? {
        limits.first { $0.provider == provider && $0.direction == direction }
    }

    func clearHistory() {
        Task {
            _ = await inBackground { $0.deleteTasks(statuses: [.completed, .cancelled]) }
            await scheduler?.clearScanErrors()
            await refresh()
        }
    }

    func setFilter(_ filter: DownloadFilter) {
        downloadFilter = filter
        Task { await refresh() }
    }

    // MARK: - Disks

    /// Список дисков и остаток очереди на каждый — в фоне; на главном потоке только присвоение.
    func refreshVolumes() async {
        let db = db
        let newVolumes = await Task.detached(priority: .utility) {
            DiskVolumes.load(usage: db?.volumeQueueUsage() ?? [:])
        }.value
        if newVolumes != volumes { volumes = newVolumes }
        // Место могли освободить — задачи «Не хватает места» пробуют снова.
        await scheduler?.recheckSpace()
    }

    func openVolume(_ volume: DiskVolume) {
        NSWorkspace.shared.open(volume.url)
    }

    func chooseDefaultFolder(on volume: DiskVolume) {
        if let path = chooseDirectory(message: String(localized: "Default download folder on “\(volume.name)”"),
                                      initial: volume.url.path) {
            defaultDownloadPath = path
        }
    }

    /// Извлечение внешнего диска. Если на него идёт скачивание — подтверждение, затем пауза его задач
    /// (идущие загрузки сначала закрывают файлы) и только после этого извлечение.
    func eject(_ volume: DiskVolume) {
        guard !volume.isInternal else { return }
        let hasDownloads = volume.isDownloadingHere
        if hasDownloads {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Files are being downloaded to “\(volume.name)”")
            alert.informativeText = String(localized: "Downloads to this disk will be paused, then the disk will be ejected. Already downloaded parts are kept; you can continue in the Download Manager with Resume.")
            alert.addButton(withTitle: String(localized: "Pause and Eject"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let url = volume.url, root = volume.id, name = volume.name
        Task {
            if hasDownloads { await scheduler?.pauseTasks(onVolume: root) }
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure {
                errorMessage = String(localized: "Couldn’t eject “\(name)”: \(failure)")
            }
            await refreshVolumes()
            await refresh()
        }
    }

    // MARK: - Language

    var appLanguage: AppSettings.AppLanguage = AppSettings.appLanguage

    /// Сохраняет выбор языка и спрашивает о перезапуске — уже на новом языке.
    func setAppLanguage(_ language: AppSettings.AppLanguage) {
        guard language != appLanguage else { return }
        appLanguage = language
        AppSettings.appLanguage = language
        let bundle = AppSettings.bundle(for: AppSettings.effectiveLanguage(for: language))
        let alert = NSAlert()
        alert.messageText = String(localized: "The language will change after NaviDrive restarts", bundle: bundle)
        alert.informativeText = String(localized: "Active downloads and uploads will be paused with their progress saved and will continue automatically after the restart.", bundle: bundle)
        alert.addButton(withTitle: String(localized: "Restart Now", bundle: bundle))
        alert.addButton(withTitle: String(localized: "Later", bundle: bundle))
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    /// Аккуратный перезапуск: очереди останавливаются с сохранением прогресса, запускается новый экземпляр
    /// (после завершения текущего), текущий завершается.
    func relaunch() {
        Task {
            await scheduler?.stopForRelaunch()
            await uploadScheduler?.stopForRelaunch()
            let pid = ProcessInfo.processInfo.processIdentifier
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Путь передаётся аргументом ($0), а не подставляется в команду.
            process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                                 Bundle.main.bundlePath]
            do {
                try process.run()
            } catch {
                errorMessage = String(localized: "Couldn’t restart NaviDrive: \(error.localizedDescription). Quit and open it again manually.")
                return
            }
            QuitController.shared.terminateWithoutPrompt()
        }
    }

    func openSystemLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Окно настроек (⌘,) на нужной вкладке — из любого места, в том числе когда главное окно закрыто.
    func openSettings(_ tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        SettingsOpener.open()
    }

    // MARK: - Uploads (Finder Services)

    /// «Upload to NaviDrive» в Finder: выбор облака и папки в нём, затем очередь отправки.
    func upload(paths: [String], mainWindowWasClosed: Bool = false) {
        serviceUploadOpensTarget = mainWindowWasClosed
        guard isSignedIn else {
            welcomeNotice = String(localized: "Connect Google Drive or Dropbox to upload files.")
            showWelcome()
            return
        }
        pendingServiceUpload = paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Derived

    /// «412 ГБ из 900 ГБ» за последние 24 часа или «412 ГБ», если лимит выключен.
    func googleUsageText(_ direction: TransferDirection) -> String {
        guard let status = limit(.googleDrive, direction) else { return Format.diskBytes(0) }
        let used = Format.diskBytes(status.used)
        guard let limit = status.limit else { return used }
        return String(localized: "\(used) of \(Format.diskBytes(limit))")
    }

    var networkStatusText: String { snapshot.isOnline ? String(localized: "Online") : String(localized: "Waiting for network…") }

    var progressSummary: String {
        guard totals.taskCount > 0 else { return String(localized: "No downloads") }
        return "\(Format.bytes(totals.downloadedBytes)) / \(Format.bytes(totals.expectedBytes)) (\(Format.percent(totals.fraction)))"
    }

    /// Сколько задач показывает «Менеджер загрузок» (List ленивый, строки отрисовываются по мере прокрутки).
    /// Загрузка секций: по одному запросу на статус в порядке индекса (без сортировки всей таблицы).
    nonisolated static func loadSections(_ kinds: [TaskSectionKind], from db: DatabaseManager) -> [TaskSectionKind: [DownloadTask]] {
        var result: [TaskSectionKind: [DownloadTask]] = [:]
        for kind in kinds {
            var rows: [DownloadTask] = []
            for status in kind.statuses {
                rows += db.tasks(status: status, newestFirst: kind.newestFirst, limit: kind.limit)
            }
            if kind.newestFirst, kind.statuses.count > 1 {
                rows.sort { $0.updatedAt > $1.updatedAt }
            }
            result[kind] = Array(rows.prefix(kind.limit))
        }
        return result
    }

    /// Скорость скачивания для шапки и трея: «Paused» при общей паузе, «Connecting…», пока
    /// возобновлённые потоки не получили первые байты, а не «Zero KB/s».
    var downloadSpeedText: String {
        if snapshot.isPaused { return String(localized: "Paused") }
        if snapshot.bytesPerSecond == 0, snapshot.runningCount > 0,
           snapshot.connecting.count == snapshot.runningCount {
            return String(localized: "Connecting…")
        }
        return Format.speed(snapshot.bytesPerSecond)
    }

    /// «Активно потоков: X из Y», где Y — текущий лимит AIMD-балансировщика.
    var threadsSummary: String {
        String(localized: "Active threads: \(snapshot.runningCount) of \(snapshot.adaptiveLimit)")
    }
}
