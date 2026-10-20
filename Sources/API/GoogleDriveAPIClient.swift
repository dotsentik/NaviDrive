import Foundation

enum ShortcutError: LocalizedError {
    case missingTarget
    case targetUnavailable(Int)

    var errorDescription: String? {
        switch self {
        case .missingTarget: String(localized: "the shortcut has no target")
        case .targetUnavailable(404): String(localized: "the shortcut target was deleted or is unavailable (HTTP 404)")
        case .targetUnavailable(let code): String(localized: "no access to the shortcut target (HTTP \(code))")
        }
    }
}

/// Клиент Google Drive API v3.
final class GoogleDriveAPIClient: Sendable {
    let tokenManager: TokenManager
    /// Единственная общая сессия для API-запросов, скачивания и загрузки.
    let session: URLSession
    /// resourceKey объектов из ссылок и их потомков.
    let resourceKeys = ResourceKeyRegistry()

    static let baseURL = "https://www.googleapis.com/drive/v3"
    static let uploadURL = "https://www.googleapis.com/upload/drive/v3/files"
    static let itemFields = "id,name,mimeType,size,md5Checksum,modifiedTime,resourceKey,driveId,capabilities(canDownload,canAddChildren,canRename,canTrash,canMoveItemWithinDrive),shortcutDetails(targetId,targetMimeType)"
    static let listFields = "nextPageToken,files(\(itemFields))"
    static let fileFields = itemFields

    init(tokenManager: TokenManager) {
        self.tokenManager = tokenManager
        session = CloudNetwork.sharedSession
    }

    /// Значения `error.errors[].reason` из тела ошибки Google API.
    static func errorReasons(from data: Data) -> [String] {
        struct Envelope: Decodable {
            struct Body: Decodable {
                struct Item: Decodable { let reason: String? }
                let errors: [Item]?
            }
            let error: Body?
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        return envelope?.error?.errors?.compactMap(\.reason) ?? []
    }

    /// 403 «Request had insufficient authentication scopes»: токен выдан без права записи.
    static func isInsufficientScope(status: Int, data: Data) -> Bool {
        guard status == 403 else { return false }
        let text = String(decoding: data.prefix(2000), as: UTF8.self).lowercased()
        return text.contains("insufficient authentication scopes") || text.contains("access_token_scope_insufficient")
            || text.contains("insufficientscopes")
    }

    static func errorMessage(from data: Data) -> String {
        struct Envelope: Decodable {
            struct Body: Decodable {
                struct Item: Decodable { let reason: String? }
                let message: String?
                let errors: [Item]?
            }
            let error: Body?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), let body = envelope.error {
            let reasons = body.errors?.compactMap(\.reason).joined(separator: ",") ?? ""
            return [body.message, reasons.isEmpty ? nil : "(\(reasons))"].compactMap { $0 }.joined(separator: " ")
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    // MARK: - Generic request with auth, 401 refresh and exponential backoff

    func send(_ makeRequest: @Sendable () throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var refreshedAfter401 = false
        var attempt = 0
        while true {
            var request = try makeRequest()
            let token = try await tokenManager.validAccessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw CloudAPIError.invalidResponse }
                if (200..<300).contains(http.statusCode) { return (data, http) }
                if http.statusCode == 401, !refreshedAfter401 {
                    refreshedAfter401 = true
                    _ = try await tokenManager.refreshAfterUnauthorized(failedToken: token)
                    continue
                }
                if Self.isInsufficientScope(status: http.statusCode, data: data) { throw CloudAPIError.insufficientScope }
                let error = CloudAPIError.http(status: http.statusCode, message: Self.errorMessage(from: data), provider: .googleDrive)
                guard error.isTransient, attempt < CloudNetwork.backoff.count else { throw error }
            } catch let error where CloudNetwork.isTransientError(error) {
                guard attempt < CloudNetwork.backoff.count else { throw error }
            }
            try await Task.sleep(for: CloudNetwork.backoffDelay(attempt))
            attempt += 1
        }
    }

    // MARK: - Listing

    enum ListScope: Sendable, Hashable {
        case folder(String)
        case sharedWithMe
        /// Содержимое папки на общем диске (corpora=drive&driveId=…). Для корня диска folderId == driveId.
        case sharedDrive(driveId: String, folderId: String)
        /// Список общих дисков (drives.list).
        case drives

        /// Дочерние объекты папки: на общем диске — через corpora=drive, иначе — по родителю.
        static func children(of folderId: String, driveId: String?) -> ListScope {
            if let driveId { return .sharedDrive(driveId: driveId, folderId: folderId) }
            return .folder(folderId)
        }
    }

    private struct DriveList: Decodable {
        struct SharedDrive: Decodable {
            struct Capabilities: Decodable { let canAddChildren: Bool? }
            let id: String
            let name: String
            let capabilities: Capabilities?
        }
        let nextPageToken: String?
        let drives: [SharedDrive]?
    }

    /// Страница drives.list в виде списка «папок» (у каждой driveId = id диска).
    private func drivesPage(pageToken: String?) async throws -> DriveFileList {
        var components = URLComponents(string: "\(Self.baseURL)/drives")!
        var items = [
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "fields", value: "nextPageToken,drives(id,name,capabilities(canAddChildren))"),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = items
        guard let url = components.url else { throw CloudAPIError.invalidResponse }
        let (data, _) = try await send { URLRequest(url: url) }
        let list = try JSONDecoder().decode(DriveList.self, from: data)
        let folders = (list.drives ?? []).map {
            DriveItem(id: $0.id, name: $0.name, mimeType: DriveItem.folderMimeType, size: nil, md5Checksum: nil,
                      modifiedTime: nil,
                      // Сам общий диск нельзя переименовать, переместить или удалить через files API.
                      capabilities: DriveCapabilities(canAddChildren: $0.capabilities?.canAddChildren, canRename: false,
                                                      canTrash: false, canMoveItemWithinDrive: false),
                      driveId: $0.id)
        }
        return DriveFileList(nextPageToken: list.nextPageToken, files: folders)
    }

    /// URL files.list для области (без drives.list).
    static func listURL(_ scope: ListScope, pageToken: String?, orderBy: String) -> URL? {
        var components = URLComponents(string: "\(Self.baseURL)/files")!
        func parentQuery(_ id: String) -> String {
            let escaped = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            return "'\(escaped)' in parents and trashed = false"
        }
        let query: String
        var corpus: [URLQueryItem] = []
        switch scope {
        case .folder(let id):
            query = parentQuery(id)
        case .sharedWithMe:
            query = "sharedWithMe = true and trashed = false"
        case .sharedDrive(let driveId, let folderId):
            query = parentQuery(folderId)
            corpus = [URLQueryItem(name: "corpora", value: "drive"), URLQueryItem(name: "driveId", value: driveId)]
        case .drives:
            return nil
        }
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: Self.listFields),
            URLQueryItem(name: "orderBy", value: orderBy),
        ] + corpus
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = items
        // «+» в значениях запроса должен быть закодирован явно.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    func listPage(_ scope: ListScope, pageToken: String?, orderBy: String = "folder,name") async throws -> DriveFileList {
        if case .drives = scope { return try await drivesPage(pageToken: pageToken) }
        guard let url = Self.listURL(scope, pageToken: pageToken, orderBy: orderBy) else { throw CloudAPIError.invalidResponse }

        var keyIds: [String] = []
        switch scope {
        case .folder(let id), .sharedDrive(_, let id): keyIds.append(id)
        default: break
        }
        let keyHeader = resourceKeys.headerValue(for: keyIds)
        let (data, _) = try await send { Self.request(url, resourceKeys: keyHeader) }
        let list = try JSONDecoder().decode(DriveFileList.self, from: data)
        resourceKeys.register(list.files)
        return list
    }

    static func request(_ url: URL, resourceKeys: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if let resourceKeys { request.setValue(resourceKeys, forHTTPHeaderField: ResourceKeyRegistry.headerName) }
        return request
    }

    func listAll(_ scope: ListScope) async throws -> [DriveItem] {
        var result: [DriveItem] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await listPage(scope, pageToken: token)
            result.append(contentsOf: page.files)
            token = page.nextPageToken
        } while token != nil
        return result
    }

    /// Метаданные одного объекта (files.get). `resourceKey` из ссылки регистрируется до запроса.
    func file(id: String, resourceKey: String? = nil) async throws -> DriveItem {
        resourceKeys.register(id: id, key: resourceKey)
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var components = URLComponents(string: "\(Self.baseURL)/files/\(encodedId)")!
        components.queryItems = [
            URLQueryItem(name: "fields", value: Self.fileFields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        guard let url = components.url else { throw CloudAPIError.invalidResponse }
        let keyHeader = resourceKeys.headerValue(for: [id])
        let (data, _) = try await send { Self.request(url, resourceKeys: keyHeader) }
        let item = try JSONDecoder().decode(DriveItem.self, from: data)
        resourceKeys.register([item])
        return item
    }

    /// Превращает ярлык в обычный объект: ID, mimeType, размер и md5 — от цели, имя — от ярлыка.
    /// Ошибки 404/403 означают, что цель удалена или к ней нет доступа.
    func resolveShortcut(_ shortcut: DriveItem) async throws -> DriveItem {
        guard shortcut.isShortcut else { return shortcut }
        guard let targetId = shortcut.shortcutDetails?.targetId else { throw ShortcutError.missingTarget }
        let target: DriveItem
        do {
            target = try await file(id: targetId)
        } catch CloudAPIError.http(let code, _, _) where code == 404 || code == 403 {
            throw ShortcutError.targetUnavailable(code)
        }
        guard !target.isShortcut else { throw ShortcutError.missingTarget }
        return DriveItem(id: target.id, name: shortcut.name, mimeType: target.mimeType, size: target.size,
                         md5Checksum: target.md5Checksum, modifiedTime: target.modifiedTime,
                         resourceKey: target.resourceKey, capabilities: target.capabilities, driveId: target.driveId)
    }

    func currentUser() async throws -> DriveUser {
        struct About: Decodable { let user: DriveUser }
        let url = URL(string: "\(Self.baseURL)/about?fields=user(displayName,emailAddress)")!
        let (data, _) = try await send { URLRequest(url: url) }
        return try JSONDecoder().decode(About.self, from: data).user
    }

    // MARK: - Download request

    func downloadURL(fileId: String, export: CloudExportFormat?) -> URL {
        let encodedId = fileId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileId
        if let export {
            var components = URLComponents(string: "\(Self.baseURL)/files/\(encodedId)/export")!
            components.queryItems = [URLQueryItem(name: "mimeType", value: export.mimeType)]
            return components.url!
        }
        return URL(string: "\(Self.baseURL)/files/\(encodedId)?alt=media&acknowledgeAbuse=true&supportsAllDrives=true")!
    }
}
