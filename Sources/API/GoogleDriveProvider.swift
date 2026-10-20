import Foundation

/// Google Drive API v3 за протоколом `CloudProvider`: OAuth (loopback + PKCE), листинг с пагинацией,
/// ярлыки, общие диски, resourceKey, скачивание через Range и resumable upload.
final class GoogleDriveProvider: CloudProvider {
    let kind = CloudProviderKind.googleDrive
    let api: GoogleDriveAPIClient
    private let tokenManager: TokenManager
    private let keychain: KeychainStore

    var session: URLSession { api.session }
    /// Встроенные учётные данные или свои из настроек (их отсутствие объясняет ошибка входа).
    let canSignIn = true

    static let quotaReasons: Set<String> = ["downloadQuotaExceeded", "quotaExceeded"]
    static let rateLimitReasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded"]

    init(keychain: KeychainStore) {
        self.keychain = keychain
        tokenManager = TokenManager(keychain: keychain)
        api = GoogleDriveAPIClient(tokenManager: tokenManager)
    }

    // MARK: - Авторизация

    var hadSessionAtLaunch: Bool { tokenManager.hadTokensAtLaunch }

    func isSignedIn() async -> Bool { await tokenManager.isSignedIn }

    func signIn(openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> CloudSignInResult {
        let credentials = try OAuthCredentials.forSignIn(keychain)
        let tokens = try await OAuthService.signIn(clientId: credentials.clientId, clientSecret: credentials.clientSecret,
                                                   openURL: openURL)
        do {
            try await tokenManager.store(tokens)
            return CloudSignInResult()
        } catch {
            return CloudSignInResult(persistenceError: error.localizedDescription)
        }
    }

    func signOut() async { await tokenManager.signOut() }

    func currentAccount() async throws -> CloudAccount {
        let user = try await api.currentUser()
        return CloudAccount(displayName: user.displayName, email: user.emailAddress)
    }

    func credentialLoadError() async -> String? { await tokenManager.keychainLoadError }

    func setAccessRevokedHandler(_ handler: @escaping @Sendable () -> Void) async {
        await tokenManager.setAccessRevokedHandler(handler)
    }

    func lacksWriteAccess() async -> Bool { await tokenManager.lacksWriteScope }

    func refreshAuthorization(after failedCredential: String) async throws {
        _ = try await tokenManager.refreshAfterUnauthorized(failedToken: failedCredential)
    }

    // MARK: - Просмотр

    var rootFolder: UploadTarget {
        UploadTarget(provider: kind, id: "root", name: String(localized: "My Drive"), spaceId: nil)
    }

    func listPage(_ location: CloudLocation, pageToken: String?, stableOrder: Bool) async throws -> CloudPage {
        let scope: GoogleDriveAPIClient.ListScope
        switch location {
        case .root: scope = .folder("root")
        case .folder(let id, let spaceId): scope = .children(of: id, driveId: spaceId)
        case .sharedWithMe: scope = .sharedWithMe
        case .sharedSpaces: scope = .drives
        case .linkFolder:
            // Папки по ссылке у Google открываются по ID (resourceKey — заголовком).
            throw CloudAPIError.invalidResponse
        }
        let page = try await api.listPage(scope, pageToken: pageToken,
                                          orderBy: stableOrder ? "folder,name,createdTime" : "folder,name")
        return CloudPage(items: page.files.map(Self.cloudItem), nextPageToken: page.nextPageToken)
    }

    func item(id: String, accessKey: String?) async throws -> CloudItem {
        Self.cloudItem(try await api.file(id: id, resourceKey: accessKey))
    }

    /// Ярлык → цель: ID, тип, размер и md5 — от цели, имя — от ярлыка.
    /// Ошибки 404/403 означают, что цель удалена или к ней нет доступа.
    func resolveAlias(_ item: CloudItem) async throws -> CloudItem {
        guard item.isAlias else { return item }
        guard let targetId = item.aliasTargetId else { throw ShortcutError.missingTarget }
        let target: DriveItem
        do {
            target = try await api.file(id: targetId)
        } catch CloudAPIError.http(let code, _, _) where code == 404 || code == 403 {
            throw ShortcutError.targetUnavailable(code)
        }
        guard !target.isShortcut else { throw ShortcutError.missingTarget }
        return Self.cloudItem(target).renamed(item.name)
    }

    func rememberAccessKey(_ key: String?, for id: String) {
        api.resourceKeys.register(id: id, key: key)
    }

    func parseLink(_ text: String) -> CloudLink? {
        DriveLink.parse(text).map { CloudLink(id: $0.id, accessKey: $0.resourceKey) }
    }

    func webURL(forFolder id: String) -> URL? {
        URL(string: id == "root" ? "https://drive.google.com/drive/my-drive" : "https://drive.google.com/drive/folders/\(id)")
    }

    // MARK: - Скачивание

    func downloadRequest(for task: DownloadTask, offset: Int64) async throws -> CloudAuthorizedRequest {
        let token = try await tokenManager.validAccessToken()
        var request = URLRequest(url: api.downloadURL(fileId: task.driveFileId, export: task.exportFormat))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let key = task.resourceKey ?? api.resourceKeys.key(for: task.driveFileId) {
            request.setValue("\(task.driveFileId)/\(key)", forHTTPHeaderField: ResourceKeyRegistry.headerName)
        }
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        return CloudAuthorizedRequest(request: request, credential: token)
    }

    func downloadFailure(_ response: HTTPURLResponse, body: Data, task: DownloadTask, credential: String) -> CloudTransferError {
        let status = response.statusCode
        let message = "HTTP \(status): \(GoogleDriveAPIClient.errorMessage(from: body))"
        let reasons = Set(GoogleDriveAPIClient.errorReasons(from: body))
        switch status {
        case 401:
            return .unauthorized(credential: credential)
        case 403 where !reasons.isDisjoint(with: Self.quotaReasons):
            return .quotaExceeded(message)
        case 403 where reasons.contains("cannotDownloadFile"):
            return .fatal(DownloadTask.downloadForbiddenMessage)
        case 429:
            return .rateLimited(message, retryAfter: nil)
        case 403 where !reasons.isDisjoint(with: Self.rateLimitReasons) || message.lowercased().contains("ratelimit"):
            return .rateLimited(message, retryAfter: nil)
        case 500, 502, 503, 504:
            return .transient(message)
        case 404 where task.resourceKey != nil:
            return .fatal(String(localized: "File not found (HTTP 404). Check the link: it may need a resourceKey"))
        case 404:
            return .fatal(String(localized: "File not found or no access (HTTP 404)"))
        default:
            return .fatal(message)
        }
    }

    // MARK: - Resumable upload

    /// 32 МБ — кратно 256 КБ, как требует Drive API для всех частей, кроме последней.
    let uploadChunkSize: Int64 = 32 * 1_048_576
    /// Google держит сессию около недели; старше 6 дней — новая сессия.
    let uploadSessionLifetime: TimeInterval = 6 * 24 * 3600

    func startUploadSession(for task: UploadTask) async throws -> String {
        try await api.startUploadSession(name: task.fileName, parentId: task.parentDriveId, size: task.fileSize,
                                         replaceFileId: task.replaceFileId).absoluteString
    }

    /// PUT с пустым телом и `Content-Range: bytes */<размер>` → 308 + Range (сколько принял сервер) или 200/201.
    func uploadState(session: String, task: UploadTask) async throws -> CloudUploadState {
        try await send(session, range: "bytes */\(task.fileSize)", body: nil, delegate: nil)
    }

    func uploadChunk(_ data: Data, at offset: Int64, session: String, task: UploadTask,
                     delegate: (any URLSessionTaskDelegate)?) async throws -> CloudUploadState {
        let range = "bytes \(offset)-\(offset + Int64(data.count) - 1)/\(task.fileSize)"
        return try await send(session, range: range, body: data, delegate: delegate)
    }

    func cancelUploadSession(_ session: String) async {
        guard let uri = URL(string: session) else { return }
        await api.cancelUploadSession(uri)
    }

    /// Один запрос к session URI и разбор ответа.
    private func send(_ session: String, range: String, body: Data?,
                      delegate: (any URLSessionTaskDelegate)?) async throws -> CloudUploadState {
        guard let uri = URL(string: session) else { throw CloudAPIError.uploadSessionMissing }
        let (data, http, token) = try await api.sessionRequest(uri, contentRange: range, body: body,
                                                               delegate: body == nil ? nil : delegate)
        if let state = GoogleDriveAPIClient.resumableState(data, http) {
            switch state {
            case .incomplete(let next): return .incomplete(nextOffset: next)
            case .complete(let fileId, let md5): return .complete(fileId: fileId, hash: md5)
            case .expired: return .expired
            }
        }
        let message = GoogleDriveAPIClient.errorMessage(from: data)
        let reasons = Set(GoogleDriveAPIClient.errorReasons(from: data))
        switch http.statusCode {
        case 401:
            throw CloudTransferError.unauthorized(credential: token)
        case 403 where GoogleDriveAPIClient.isInsufficientScope(status: 403, data: data):
            throw CloudAPIError.insufficientScope
        case 403 where !reasons.isDisjoint(with: Self.rateLimitReasons):
            throw CloudTransferError.rateLimited(String(localized: "Google rate-limited requests (HTTP 403)"), retryAfter: nil)
        case 429:
            throw CloudTransferError.rateLimited(String(localized: "Google rate-limited requests (HTTP 429)"), retryAfter: nil)
        case 403 where reasons.contains("storageQuotaExceeded"):
            throw CloudTransferError.fatal(String(localized: "Google Drive is out of storage"))
        case 403:
            throw CloudTransferError.fatal(String(localized: "You don’t have permission to upload to this folder"))
        case 500, 502, 503, 504:
            throw CloudTransferError.transient(String(localized: "Google Drive server is temporarily unavailable (HTTP \(http.statusCode))"))
        default:
            throw CloudTransferError.fatal("Google Drive API: HTTP \(http.statusCode) — \(message)")
        }
    }

    // MARK: - Изменение

    func createFolder(named name: String, in parent: UploadTarget) async throws -> CloudItem {
        try await mapEditErrors { Self.cloudItem(try await api.createFolder(name: name, parentId: parent.id)) }
    }

    func rename(_ item: CloudItem, to name: String) async throws -> CloudItem {
        try await mapEditErrors { Self.cloudItem(try await api.rename(id: item.id, to: name)) }
    }

    func move(_ item: CloudItem, to parent: UploadTarget) async throws {
        try await mapEditErrors { try await api.move(id: item.id, to: parent.id) }
    }

    func trash(_ item: CloudItem) async throws {
        try await mapEditErrors { try await api.trash(id: item.id) }
    }

    /// 403 storageQuotaExceeded → `CloudAPIError.storageFull`.
    private func mapEditErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch CloudAPIError.http(403, let message, _) where message.contains("storageQuotaExceeded") {
            throw CloudAPIError.storageFull(.googleDrive)
        }
    }

    // MARK: - Преобразование

    static func cloudItem(_ item: DriveItem) -> CloudItem {
        let mime = item.effectiveMimeType
        var result = CloudItem(provider: .googleDrive, id: item.id, name: item.name, isFolder: item.isFolder)
        result.size = item.size.flatMap(Int64.init)
        result.modifiedAt = item.modifiedDate
        result.hash = item.md5Checksum.map { CloudHash(kind: .md5, value: $0) }
        let capabilities = item.capabilities
        result.permissions = CloudPermissions(
            canDownload: capabilities?.canDownload ?? true,
            canAddChildren: capabilities?.canAddChildren ?? true,
            canRename: capabilities?.canRename ?? true,
            canTrash: capabilities?.canTrash ?? true,
            canMove: capabilities?.canMoveItemWithinDrive ?? true)
        result.contentType = mime
        result.isAlias = item.isShortcut
        result.aliasTargetId = item.shortcutDetails?.targetId
        result.spaceId = item.driveId
        result.accessKey = item.resourceKey
        if !item.isFolder, mime.hasPrefix(DriveItem.workspacePrefix) {
            result.documentType = documentType(forContentType: mime)
        }
        result.exportFormat = exportFormat(forContentType: mime)
        return result
    }

    /// MIME-тип объекта Google Drive для хранения (обратное преобразование).
    static func mimeType(of item: CloudItem) -> String {
        item.contentType ?? (item.isFolder ? DriveItem.folderMimeType : "application/octet-stream")
    }

    private static func documentType(forContentType mime: String) -> CloudDocumentType {
        switch mime {
        case "application/vnd.google-apps.document": .document
        case "application/vnd.google-apps.spreadsheet": .spreadsheet
        case "application/vnd.google-apps.presentation": .presentation
        case "application/vnd.google-apps.drawing": .drawing
        default: .other
        }
    }

    /// Документы Google экспортируются в форматы Office / PDF.
    static func exportFormat(forContentType mime: String) -> CloudExportFormat? {
        switch mime {
        case "application/vnd.google-apps.document":
            CloudExportFormat(mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", fileExtension: "docx")
        case "application/vnd.google-apps.spreadsheet":
            CloudExportFormat(mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileExtension: "xlsx")
        case "application/vnd.google-apps.presentation":
            CloudExportFormat(mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation", fileExtension: "pptx")
        case "application/vnd.google-apps.drawing":
            CloudExportFormat(mimeType: "application/pdf", fileExtension: "pdf")
        default:
            nil
        }
    }
}

// MARK: - Добавленные по ссылке

extension GoogleDriveProvider {
    func linkRecord(for item: CloudItem) -> LinkedItem {
        LinkedItem(provider: kind, driveId: item.id, name: item.name, mimeType: Self.mimeType(of: item),
                   resourceKey: item.accessKey, size: item.size, sharedDriveId: item.spaceId,
                   addedAt: Int64(Date().timeIntervalSince1970))
    }

    func item(fromLinked record: LinkedItem) -> CloudItem {
        Self.cloudItem(DriveItem(id: record.driveId, name: record.name, mimeType: record.mimeType,
                                 size: record.size.map(String.init), md5Checksum: nil, modifiedTime: nil,
                                 resourceKey: record.resourceKey, driveId: record.sharedDriveId))
    }
}
