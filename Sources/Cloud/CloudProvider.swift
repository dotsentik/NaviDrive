import Foundation

enum CloudProviderKind: String, Sendable, Hashable, CaseIterable, Codable {
    case googleDrive
    case dropbox

    /// Название сервиса (торговая марка, не переводится).
    var displayName: String {
        switch self {
        case .googleDrive: "Google Drive"
        case .dropbox: "Dropbox"
        }
    }

    /// Значок облака (SF Symbols) в sidebar и у задач.
    var systemImage: String {
        switch self {
        case .googleDrive: "g.circle.fill"
        case .dropbox: "shippingbox.fill"
        }
    }

    /// Суффикс недокачанного файла рядом с целевым.
    var partialSuffix: String {
        switch self {
        case .googleDrive: ".gdrive.part"
        case .dropbox: ".dropbox.part"
        }
    }

    /// Каким хешем сервис подтверждает содержимое файла.
    var hashKind: CloudHashKind {
        switch self {
        case .googleDrive: .md5
        case .dropbox: .dropboxContentHash
        }
    }

    /// Формат экспорта для документа облака по его MIME-типу (nil — файл скачивается как есть).
    func exportFormat(forContentType contentType: String?) -> CloudExportFormat? {
        guard let contentType else { return nil }
        switch self {
        case .googleDrive: return GoogleDriveProvider.exportFormat(forContentType: contentType)
        case .dropbox: return DropboxProvider.exportFormat(forContentType: contentType)
        }
    }
}

/// Облачное хранилище. Движки скачивания и отправки, браузер, маршруты и менеджеры
/// работают только через этот протокол и не знают о конкретном API.
protocol CloudProvider: AnyObject, Sendable {
    var kind: CloudProviderKind { get }
    /// Сессия для запросов к API, скачивания и загрузки.
    var session: URLSession { get }
    /// В сборку вписаны учётные данные (или пользователь может ввести свои) — вход возможен.
    var canSignIn: Bool { get }

    // MARK: Авторизация

    /// При запуске был сохранённый вход.
    var hadSessionAtLaunch: Bool { get }
    func isSignedIn() async -> Bool
    /// Интерактивный вход; `openURL` открывает страницу входа в браузере.
    func signIn(openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> CloudSignInResult
    func signOut() async
    func currentAccount() async throws -> CloudAccount
    /// Ошибка чтения сохранённого входа при запуске (это не то же самое, что «входа нет»).
    func credentialLoadError() async -> String?
    /// Облако отозвало доступ: сохранённый вход уже удалён.
    func setAccessRevokedHandler(_ handler: @escaping @Sendable () -> Void) async
    /// Вход заведомо без права записи.
    func lacksWriteAccess() async -> Bool
    /// После HTTP 401: обновить учётные данные, если их ещё не обновил другой запрос.
    func refreshAuthorization(after failedCredential: String) async throws
    /// Ошибка означает, что входа нет или он больше недействителен.
    func isSignedOutError(_ error: Error) -> Bool

    // MARK: Просмотр и метаданные

    /// Корневая папка личного пространства.
    var rootFolder: UploadTarget { get }
    /// Страница содержимого. `stableOrder` — порядок, при котором одинаковые имена
    /// получают одинаковые суффиксы при повторных обходах.
    func listPage(_ location: CloudLocation, pageToken: String?, stableOrder: Bool) async throws -> CloudPage
    /// Рекурсивный обход папки (по страницам). Каждая папка обходится один раз.
    func traverse(_ folder: CloudItem, resolvingAliases: Bool) -> AsyncStream<CloudTraversalEvent>
    func item(id: String, accessKey: String?) async throws -> CloudItem
    /// Где лежит содержимое папки (обычная папка, папка внутри ссылки и т. п.).
    func location(of folder: CloudItem) -> CloudLocation
    /// Папка как цель для загрузки, создания папок и перемещения.
    func uploadTarget(for folder: CloudItem) -> UploadTarget
    /// Запись для раздела «Добавленные по ссылке» и обратно.
    func linkRecord(for item: CloudItem) -> LinkedItem
    func item(fromLinked record: LinkedItem) -> CloudItem
    /// Ярлык → объект-цель под именем ярлыка. Обычный объект возвращается как есть.
    func resolveAlias(_ item: CloudItem) async throws -> CloudItem
    func permissions(for item: CloudItem) -> CloudPermissions
    /// Ключ доступа объекта, открытого по ссылке (используется для него и его потомков).
    func rememberAccessKey(_ key: String?, for id: String)
    func parseLink(_ text: String) -> CloudLink?
    /// Папка в веб-интерфейсе облака.
    func webURL(forFolder id: String) -> URL?

    // MARK: Скачивание (HTTP Range)

    /// Подписанный запрос содержимого файла начиная с байта `offset`.
    func downloadRequest(for task: DownloadTask, offset: Int64) async throws -> CloudAuthorizedRequest
    /// Классификация неуспешного ответа на запрос скачивания.
    func downloadFailure(_ response: HTTPURLResponse, body: Data, task: DownloadTask, credential: String) -> CloudTransferError

    // MARK: Загрузка с возобновлением

    /// Размер части загрузки.
    var uploadChunkSize: Int64 { get }
    /// Сколько живёт сессия загрузки на сервере (старше — начинать новую).
    var uploadSessionLifetime: TimeInterval { get }
    /// Новая сессия загрузки; результат — непрозрачный идентификатор сессии.
    func startUploadSession(for task: UploadTask) async throws -> String
    /// Сколько байт принял сервер (или что загрузка завершена).
    func uploadState(session: String, task: UploadTask) async throws -> CloudUploadState
    func uploadChunk(_ data: Data, at offset: Int64, session: String, task: UploadTask,
                     delegate: (any URLSessionTaskDelegate)?) async throws -> CloudUploadState
    /// Отмена сессии (лучшее усилие).
    func cancelUploadSession(_ session: String) async

    // MARK: Изменение

    func createFolder(named name: String, in parent: UploadTarget) async throws -> CloudItem
    func rename(_ item: CloudItem, to name: String) async throws -> CloudItem
    func move(_ item: CloudItem, to parent: UploadTarget) async throws
    /// В корзину (не окончательное удаление).
    func trash(_ item: CloudItem) async throws
}

extension CloudProvider {
    func listPage(_ location: CloudLocation, pageToken: String?) async throws -> CloudPage {
        try await listPage(location, pageToken: pageToken, stableOrder: false)
    }

    func listAll(_ location: CloudLocation) async throws -> [CloudItem] {
        var result: [CloudItem] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await listPage(location, pageToken: token)
            result.append(contentsOf: page.items)
            token = page.nextPageToken
        } while token != nil
        return result
    }

    func permissions(for item: CloudItem) -> CloudPermissions { item.permissions }

    func location(of folder: CloudItem) -> CloudLocation {
        .folder(id: folder.targetId, spaceId: folder.targetSpaceId)
    }

    func uploadTarget(for folder: CloudItem) -> UploadTarget {
        UploadTarget(provider: kind, id: folder.targetId, name: folder.name, spaceId: folder.targetSpaceId)
    }

    func isSignedOutError(_ error: Error) -> Bool {
        (error as? OAuthError)?.meansSignedOut == true
    }

    /// Обход по страницам через `listPage`: стек папок, множество посещённых защищает от циклов
    /// (ярлык на папку-предка) и от повторного обхода одной папки.
    func traverse(_ folder: CloudItem, resolvingAliases: Bool) -> AsyncStream<CloudTraversalEvent> {
        walkFolders(folder, resolvingAliases: resolvingAliases)
    }

    /// Обход папка за папкой через `listPage` (основа `traverse` по умолчанию).
    func walkFolders(_ folder: CloudItem, resolvingAliases: Bool) -> AsyncStream<CloudTraversalEvent> {
        let walker = CloudTraversalWalker(provider: self, root: folder, resolvingAliases: resolvingAliases)
        return AsyncStream(unfolding: { await walker.next() })
    }
}

// MARK: - Traversal

enum CloudTraversalEvent: Sendable {
    /// Страница содержимого папки `folderId` (у каждой папки есть хотя бы одна, даже у пустой).
    /// Ярлыки раскрыты (если просили), уже посещённые папки исключены — все папки в `items` будут обойдены.
    case page(folderId: String, items: [CloudItem])
    /// Папку не удалось прочитать; обход продолжается с остальными.
    case folderFailed(folderId: String, error: any Error)
    /// Ярлык в папке `folderId` не удалось раскрыть.
    case itemFailed(folderId: String, name: String, error: any Error)
}

/// Состояние обхода по запросу потребителя (pull): следующая страница читается только когда нужна.
private actor CloudTraversalWalker {
    private let provider: any CloudProvider
    private let resolvingAliases: Bool
    private var stack: [(id: String, location: CloudLocation)]
    private var visited: Set<String>
    private var current: (id: String, location: CloudLocation, token: String?)?
    private var pending: [CloudTraversalEvent] = []

    init(provider: any CloudProvider, root: CloudItem, resolvingAliases: Bool) {
        self.provider = provider
        self.resolvingAliases = resolvingAliases
        stack = [(root.targetId, provider.location(of: root))]
        visited = [root.targetId]
    }

    func next() async -> CloudTraversalEvent? {
        while true {
            if !pending.isEmpty { return pending.removeFirst() }
            if Task.isCancelled { return nil }
            if current == nil {
                guard let folder = stack.popLast() else { return nil }
                current = (folder.id, folder.location, nil)
            }
            guard let folder = current else { return nil }

            let page: CloudPage
            do {
                page = try await provider.listPage(folder.location, pageToken: folder.token, stableOrder: true)
            } catch {
                current = nil
                return .folderFailed(folderId: folder.id, error: error)
            }

            var items: [CloudItem] = []
            items.reserveCapacity(page.items.count)
            for listed in page.items {
                var item = listed
                if resolvingAliases, item.isAlias {
                    do {
                        item = try await provider.resolveAlias(item)
                    } catch {
                        pending.append(.itemFailed(folderId: folder.id, name: listed.name, error: error))
                        continue
                    }
                }
                if item.isFolder {
                    // Цикл через ярлык или повторная ссылка на уже обойдённую папку — пропускаем.
                    guard visited.insert(item.targetId).inserted else { continue }
                    stack.append((item.targetId, provider.location(of: item)))
                }
                items.append(item)
            }
            current = page.nextPageToken.map { (folder.id, folder.location, $0) }
            // Ошибки раскрытия ярлыков — до страницы, как и при последовательном разборе.
            pending.append(.page(folderId: folder.id, items: items))
        }
    }
}

// MARK: - Registry

/// Подключённые облака. Задачи очередей исполняются провайдером из своей колонки `provider`.
final class CloudProviders: Sendable {
    private let providers: [CloudProviderKind: any CloudProvider]
    /// Облако, с которым работает интерфейс.
    let primary: any CloudProvider

    init(_ providers: [any CloudProvider]) {
        precondition(!providers.isEmpty)
        self.providers = Dictionary(providers.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        self.primary = providers[0]
    }

    subscript(kind: CloudProviderKind) -> (any CloudProvider)? { providers[kind] }

    /// Все подключённые к сборке облака в порядке `CloudProviderKind.allCases`.
    var all: [any CloudProvider] { CloudProviderKind.allCases.compactMap { providers[$0] } }

    static var unavailableMessage: String { String(localized: "This cloud service isn’t available in this version of NaviDrive") }

    struct UnavailableError: LocalizedError {
        var errorDescription: String? { CloudProviders.unavailableMessage }
    }

    /// Провайдер задачи или ошибка «облако недоступно».
    func provider(for kind: CloudProviderKind) throws -> any CloudProvider {
        guard let provider = providers[kind] else { throw UnavailableError() }
        return provider
    }
}

// MARK: - Network

enum CloudNetwork {
    static let backoff: [Double] = [2, 4, 8, 16, 32]

    /// Не меньше максимального предела потоков (16) плюс запас под листинг папок и обновление токена.
    /// Скачивание (до 16) и отправка (до 6) работают одновременно и не отнимают соединения друг у друга.
    static let maxConnectionsPerHost = AppSettings.concurrencyRange.upperBound + AppSettings.uploadConcurrencyRange.upperBound + 8

    /// Общая сессия приложения: API, OAuth, скачивание и загрузка.
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        // Файл на сотни гигабайт может качаться сутками.
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        return URLSession(configuration: configuration)
    }()

    /// Пауза перед повтором со случайным разбросом ±50%, чтобы параллельные запросы не повторялись синхронно.
    static func backoffDelay(_ attempt: Int) -> Duration {
        .seconds(backoff[min(attempt, backoff.count - 1)] * Double.random(in: 0.5...1.5))
    }

    static func isTransientError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .resourceUnavailable,
             .internationalRoamingOff, .dataNotAllowed, .badServerResponse:
            return true
        default:
            return false
        }
    }
}
