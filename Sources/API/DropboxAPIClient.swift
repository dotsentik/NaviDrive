import Foundation

/// Клиент официального HTTP API Dropbox v2 (без SDK).
///
/// - RPC-эндпоинты (`api.dropboxapi.com`): JSON в теле, JSON в ответе.
/// - Content-эндпоинты (`content.dropboxapi.com`): аргументы в заголовке `Dropbox-API-Arg`
///   (JSON, не-ASCII символы экранированы как `\uXXXX`), данные — в теле запроса или ответа.
/// - Командные аккаунты: заголовок `Dropbox-API-Path-Root` с root_namespace_id, чтобы были видны командные папки.
final class DropboxAPIClient: Sendable {
    let tokenManager: DropboxTokenManager
    let session: URLSession
    private let root = DropboxRootCache()

    static let apiBase = "https://api.dropboxapi.com/2"
    static let contentBase = "https://content.dropboxapi.com/2"
    static let maxRateLimitWaits = 6

    init(tokenManager: DropboxTokenManager) {
        self.tokenManager = tokenManager
        session = CloudNetwork.sharedSession
    }

    // MARK: - Аккаунт и корневое пространство

    struct Account: Decodable, Sendable {
        struct Name: Decodable, Sendable { let display_name: String? }
        struct RootInfo: Decodable, Sendable {
            let tag: String
            let root_namespace_id: String
            let home_namespace_id: String
            enum CodingKeys: String, CodingKey {
                case tag = ".tag", root_namespace_id, home_namespace_id
            }
        }
        let account_id: String
        let name: Name?
        let email: String?
        let root_info: RootInfo?
    }

    func currentAccount() async throws -> Account {
        let data = try await rpc("/users/get_current_account", nil, pathRoot: false)
        return try JSONDecoder().decode(Account.self, from: data)
    }

    /// Значение `Dropbox-API-Path-Root` (nil — личный аккаунт, заголовок не нужен). Запрашивается один раз.
    func pathRootHeader() async throws -> String? {
        if let cached = await root.value { return cached }
        let account = try await currentAccount()
        var header: String?
        if let info = account.root_info, info.root_namespace_id != info.home_namespace_id {
            header = try Self.headerJSON([".tag": "root", "root": info.root_namespace_id])
        }
        await root.set(header)
        return header
    }

    /// После входа другим аккаунтом или выхода корневое пространство определяется заново.
    func resetRoot() async { await root.reset() }

    // MARK: - JSON для заголовка

    /// JSON для `Dropbox-API-Arg`: символы вне ASCII (и DEL) — как `\uXXXX` (UTF-16), как требует Dropbox.
    static func headerJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        var result = ""
        result.reserveCapacity(json.utf8.count)
        for unit in json.utf16 {
            if unit < 0x7F {
                result.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            } else {
                result += String(format: "\\u%04x", unit)
            }
        }
        return result
    }

    // MARK: - Ошибки

    struct ErrorEnvelope: Decodable {
        let error_summary: String?
    }

    static func errorSummary(_ data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let summary = envelope.error_summary {
            return summary
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    /// Ищет поле (например, `correct_offset`) на любой глубине JSON ошибки.
    static func findValue(_ key: String, in data: Data) -> Any? {
        func search(_ value: Any) -> Any? {
            if let dict = value as? [String: Any] {
                if let found = dict[key] { return found }
                for nested in dict.values { if let found = search(nested) { return found } }
            } else if let array = value as? [Any] {
                for nested in array { if let found = search(nested) { return found } }
            }
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)).flatMap(search)
    }

    /// Пауза из заголовка Retry-After (секунды).
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    }

    /// Ошибка конечной точки (HTTP 409): `error_summary` → понятный код.
    static func endpointError(_ data: Data) -> CloudAPIError {
        let summary = errorSummary(data)
        if summary.contains("insufficient_space") { return .storageFull(.dropbox) }
        let status: Int
        if summary.contains("not_found") {
            status = 404
        } else if summary.contains("access_denied") || summary.contains("no_write_permission")
                    || summary.contains("no_permission") || summary.contains("restricted_content") {
            status = 403
        } else {
            status = 409
        }
        return .http(status: status, message: summary, provider: .dropbox)
    }

    // MARK: - RPC

    /// POST JSON к RPC-эндпоинту с токеном, обновлением после 401, ожиданием Retry-After при 429
    /// и повтором временных ошибок.
    func rpc(_ endpoint: String, _ arguments: [String: Any]?, pathRoot: Bool = true) async throws -> Data {
        guard let url = URL(string: Self.apiBase + endpoint) else { throw CloudAPIError.invalidResponse }
        let body = try arguments.map { try JSONSerialization.data(withJSONObject: $0) }
        let rootHeader = pathRoot ? try await pathRootHeader() : nil
        var refreshedAfter401 = false
        var attempt = 0
        var rateLimitWaits = 0
        while true {
            let token = try await tokenManager.validAccessToken()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            if let rootHeader { request.setValue(rootHeader, forHTTPHeaderField: "Dropbox-API-Path-Root") }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw CloudAPIError.invalidResponse }
                switch http.statusCode {
                case 200..<300:
                    return data
                case 401 where !refreshedAfter401 && !Self.errorSummary(data).hasPrefix("missing_scope"):
                    refreshedAfter401 = true
                    _ = try await tokenManager.refreshAfterUnauthorized(failedToken: token)
                    continue
                case 409:
                    throw Self.endpointError(data)
                case 429 where rateLimitWaits < Self.maxRateLimitWaits:
                    rateLimitWaits += 1
                    let wait = Self.retryAfter(http) ?? CloudNetwork.backoff[min(rateLimitWaits, CloudNetwork.backoff.count - 1)]
                    try await Task.sleep(for: .seconds(wait))
                    continue
                default:
                    let error = CloudAPIError.http(status: http.statusCode, message: Self.errorSummary(data), provider: .dropbox)
                    guard error.isTransient, attempt < CloudNetwork.backoff.count else { throw error }
                }
            } catch let error where CloudNetwork.isTransientError(error) {
                guard attempt < CloudNetwork.backoff.count else { throw error }
            }
            try await Task.sleep(for: CloudNetwork.backoffDelay(attempt))
            attempt += 1
        }
    }

    // MARK: - Content

    /// Подписанный запрос к content-эндпоинту (скачивание, экспорт, загрузка).
    func contentRequest(_ endpoint: String, argument: [String: Any], pathRoot: Bool = true) async throws -> CloudAuthorizedRequest {
        guard let url = URL(string: Self.contentBase + endpoint) else { throw CloudAPIError.invalidResponse }
        let token = try await tokenManager.validAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(try Self.headerJSON(argument), forHTTPHeaderField: "Dropbox-API-Arg")
        if pathRoot, let rootHeader = try await pathRootHeader() {
            request.setValue(rootHeader, forHTTPHeaderField: "Dropbox-API-Path-Root")
        }
        return CloudAuthorizedRequest(request: request, credential: token)
    }

    /// Загрузка данных в content-эндпоинт. Ответ не интерпретируется — это делает вызывающий код.
    func upload(_ endpoint: String, argument: [String: Any], body: Data,
                delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, HTTPURLResponse, String) {
        let authorized = try await contentRequest(endpoint, argument: argument)
        var request = authorized.request
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response): (Data, URLResponse)
        if body.isEmpty {
            request.httpBody = body
            (data, response) = try await session.data(for: request)
        } else {
            (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.invalidResponse }
        return (data, http, authorized.credential)
    }
}

/// Кэш заголовка корневого пространства: `.some(nil)` — уже известно, что заголовок не нужен.
private actor DropboxRootCache {
    private var cached: String??

    var value: String?? { cached }
    func set(_ header: String?) { cached = .some(header) }
    func reset() { cached = nil }
}

// MARK: - DTO

struct DropboxEntry: Decodable, Sendable {
    struct ExportInfo: Decodable, Sendable {
        let export_as: String?
        let export_options: [String]?
    }
    struct SharingInfo: Decodable, Sendable {
        let read_only: Bool?
    }

    /// Нет у FolderMetadata/FileMetadata без объединения (ответы create_folder_v2, upload_session/finish).
    let tag: String?
    let name: String
    let id: String?
    let path_lower: String?
    let path_display: String?
    let size: Int64?
    let server_modified: String?
    let content_hash: String?
    let is_downloadable: Bool?
    let export_info: ExportInfo?
    let sharing_info: SharingInfo?
    /// Только у метаданных общей ссылки.
    let url: String?

    enum CodingKeys: String, CodingKey {
        case tag = ".tag", name, id, path_lower, path_display, size, server_modified, content_hash
        case is_downloadable, export_info, sharing_info, url
    }
}

struct DropboxListFolderResult: Decodable, Sendable {
    let entries: [DropboxEntry]
    let cursor: String
    let has_more: Bool
}

struct DropboxSharedFolder: Decodable, Sendable {
    struct AccessType: Decodable, Sendable {
        let tag: String
        enum CodingKeys: String, CodingKey { case tag = ".tag" }
    }
    let name: String
    let shared_folder_id: String
    let path_lower: String?
    let preview_url: String?
    let access_type: AccessType?
}

struct DropboxSharedFolderList: Decodable, Sendable {
    let entries: [DropboxSharedFolder]
    let cursor: String?
}

struct DropboxReceivedFile: Decodable, Sendable {
    let id: String
    let name: String
    let preview_url: String?
    let path_display: String?
    let time_invited: String?
}

struct DropboxReceivedFileList: Decodable, Sendable {
    let entries: [DropboxReceivedFile]
    let cursor: String?
}
