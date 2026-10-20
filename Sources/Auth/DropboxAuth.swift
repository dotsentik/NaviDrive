import Foundation

/// App key Dropbox, вписанный при сборке: Config/Secrets.xcconfig (DROPBOX_APP_KEY) → Info.plist.
/// App secret не используется: вход через PKCE.
enum DropboxAppKey {
    static let infoKey = "NaviDriveDropboxAppKey"

    /// nil — в Secrets.xcconfig ничего не вписано.
    static var bundled: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Нераскрытая переменная «$(DROPBOX_APP_KEY)» — тоже «не задано».
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }
}

enum DropboxAuthError: LocalizedError {
    case missingAppKey
    case notSignedIn
    /// refresh_token отозван или истёк (invalid_grant) — нужен новый вход.
    case reauthenticationRequired
    case authorizationDenied(String)
    case stateMismatch
    case tokenEndpoint(String)

    /// Входа нет или он больше недействителен: задача возвращается в очередь до нового входа.
    var meansSignedOut: Bool {
        switch self {
        case .notSignedIn, .reauthenticationRequired: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingAppKey: String(localized: "This copy of NaviDrive was built without a Dropbox app key (DROPBOX_APP_KEY in Config/Secrets.xcconfig).")
        case .notSignedIn: String(localized: "Not signed in to Dropbox")
        case .reauthenticationRequired: String(localized: "Your Dropbox session has expired — sign in again in Settings")
        case .authorizationDenied(let reason): String(localized: "Dropbox denied authorization: \(reason)")
        case .stateMismatch: String(localized: "The authorization response failed the state check")
        case .tokenEndpoint(let message): String(localized: "Token request failed: \(message)")
        }
    }
}

struct DropboxTokens: Sendable {
    var accessToken: String
    var refreshToken: String
    var expiryDate: Date
    var accountId: String?
    var scope: String?

    var secrets: DropboxSecrets { DropboxSecrets(refreshToken: refreshToken, accountId: accountId, scope: scope) }
}

/// OAuth 2 Dropbox: PKCE (S256), короткоживущий access_token + refresh_token (token_access_type=offline),
/// redirect на фиксированный loopback-адрес — Dropbox требует точного совпадения с настройками приложения.
enum DropboxOAuth {
    static let authorizeEndpoint = "https://www.dropbox.com/oauth2/authorize"
    static let tokenEndpoint = URL(string: "https://api.dropboxapi.com/oauth2/token")!
    static let revokeEndpoint = URL(string: "https://api.dropboxapi.com/2/auth/token/revoke")!
    static let redirectPort: UInt16 = 53682
    static let redirectPath = "/callback"
    static var redirectURI: String { "http://127.0.0.1:\(redirectPort)\(redirectPath)" }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Double?
        let account_id: String?
        let scope: String?
        let error: String?
        let error_description: String?
    }

    /// Полный интерактивный вход: локальный сервер → браузер → обмен code на токены.
    static func signIn(appKey: String, openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> DropboxTokens {
        let verifier = PKCE.makeVerifier()
        let state = PKCE.base64URL(PKCE.randomBytes(16))
        let server = LoopbackServer(expectedState: state, port: redirectPort, callbackPath: redirectPath)
        defer { server.stop() }
        _ = try await server.start()

        var components = URLComponents(string: authorizeEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw DropboxAuthError.tokenEndpoint("bad auth URL") }
        await openURL(url)

        let callback = try await server.waitForCallback()
        if let error = callback.error { throw DropboxAuthError.authorizationDenied(error) }
        guard callback.state == state else { throw DropboxAuthError.stateMismatch }
        guard let code = callback.code else { throw DropboxAuthError.authorizationDenied("empty code") }

        let response = try await postToken([
            "code": code,
            "grant_type": "authorization_code",
            "client_id": appKey,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ])
        guard let access = response.access_token, let refresh = response.refresh_token else {
            throw DropboxAuthError.tokenEndpoint(response.error_description ?? response.error ?? "no tokens in response")
        }
        return DropboxTokens(accessToken: access, refreshToken: refresh,
                             expiryDate: Date().addingTimeInterval(response.expires_in ?? 14_400),
                             accountId: response.account_id, scope: response.scope)
    }

    static func refresh(_ current: DropboxTokens, appKey: String) async throws -> DropboxTokens {
        let response = try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": appKey,
        ])
        if response.error == "invalid_grant" { throw DropboxAuthError.reauthenticationRequired }
        guard let access = response.access_token else {
            throw DropboxAuthError.tokenEndpoint(response.error_description ?? response.error ?? "no access_token")
        }
        var fresh = current
        fresh.accessToken = access
        fresh.expiryDate = Date().addingTimeInterval(response.expires_in ?? 14_400)
        if let scope = response.scope { fresh.scope = scope }
        return fresh
    }

    /// Отзыв токена при выходе (лучшее усилие).
    static func revoke(accessToken: String) async {
        var request = URLRequest(url: revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        _ = try? await CloudNetwork.sharedSession.data(for: request)
    }

    private static func postToken(_ parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(parameters.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        request.timeoutInterval = 30
        let (data, _) = try await CloudNetwork.sharedSession.data(for: request)
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw DropboxAuthError.tokenEndpoint(String(decoding: data.prefix(300), as: UTF8.self))
        }
    }
}

/// Выдаёт актуальный access_token Dropbox. Обновляет его через refresh_token заранее
/// (до истечения < 5 минут) и после HTTP 401. Параллельные запросы ждут одно общее обновление.
actor DropboxTokenManager {
    private let keychain: KeychainStore
    private var tokens: DropboxTokens?
    private var refreshTask: Task<DropboxTokens, Error>?

    static let refreshMargin: TimeInterval = 300

    /// Ошибка чтения входа при запуске (нет доступа к Связке ключей) — не то же самое, что «входа нет».
    private(set) var keychainLoadError: String?
    nonisolated let hadTokensAtLaunch: Bool
    /// Dropbox отклонил refresh_token: вход уже удалён, нужен новый.
    private var accessRevokedHandler: (@Sendable () -> Void)?

    init(keychain: KeychainStore) {
        self.keychain = keychain
        do {
            tokens = try keychain.loadDropboxSecrets().map {
                DropboxTokens(accessToken: "", refreshToken: $0.refreshToken, expiryDate: .distantPast,
                              accountId: $0.accountId, scope: $0.scope)
            }
        } catch {
            tokens = nil
            keychainLoadError = error.localizedDescription
        }
        hadTokensAtLaunch = tokens != nil
    }

    func setAccessRevokedHandler(_ handler: @escaping @Sendable () -> Void) {
        accessRevokedHandler = handler
    }

    var isSignedIn: Bool { tokens != nil }

    /// Сохраняет вход. Если Связка ключей не приняла запись, вход действует до перезапуска.
    func store(_ newTokens: DropboxTokens) throws {
        tokens = newTokens
        keychainLoadError = nil
        do {
            try keychain.saveDropboxSecrets(newTokens.secrets)
        } catch {
            KeychainStore.logger.error("Failed to save Dropbox tokens: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func signOut() async {
        refreshTask?.cancel()
        refreshTask = nil
        let access = tokens.flatMap { $0.accessToken.isEmpty || $0.expiryDate < Date() ? nil : $0.accessToken }
        tokens = nil
        do {
            try keychain.deleteDropboxSecrets()
        } catch {
            KeychainStore.logger.error("Failed to delete Dropbox tokens on sign-out: \(error.localizedDescription, privacy: .public)")
        }
        if let access { await DropboxOAuth.revoke(accessToken: access) }
    }

    func validAccessToken() async throws -> String {
        if let refreshTask { return try await refreshTask.value.accessToken }
        guard let tokens else { throw DropboxAuthError.notSignedIn }
        if tokens.expiryDate.timeIntervalSinceNow > Self.refreshMargin { return tokens.accessToken }
        return try await refresh().accessToken
    }

    /// После HTTP 401. Если токен уже обновил другой запрос — возвращает новый.
    func refreshAfterUnauthorized(failedToken: String) async throws -> String {
        if let refreshTask { return try await refreshTask.value.accessToken }
        guard let tokens else { throw DropboxAuthError.notSignedIn }
        if tokens.accessToken != failedToken, tokens.expiryDate.timeIntervalSinceNow > Self.refreshMargin {
            return tokens.accessToken
        }
        return try await refresh().accessToken
    }

    private func refresh() async throws -> DropboxTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens else { throw DropboxAuthError.notSignedIn }
        guard let appKey = DropboxAppKey.bundled else { throw DropboxAuthError.missingAppKey }

        let task = Task<DropboxTokens, Error> {
            var lastError: Error = DropboxAuthError.notSignedIn
            for attempt in 0..<4 {
                do {
                    return try await DropboxOAuth.refresh(current, appKey: appKey)
                } catch DropboxAuthError.reauthenticationRequired {
                    throw DropboxAuthError.reauthenticationRequired
                } catch {
                    lastError = error
                    try await Task.sleep(for: CloudNetwork.backoffDelay(attempt))
                }
            }
            throw lastError
        }
        refreshTask = task
        do {
            let fresh = try await task.value
            refreshTask = nil
            // access_token живёт только в памяти; refresh_token в Связке ключей не меняется.
            if tokens != nil { tokens = fresh }
            return fresh
        } catch {
            refreshTask = nil
            if case DropboxAuthError.reauthenticationRequired = error { revokeLocally() }
            throw error
        }
    }

    /// Доступ отозван: удаляет вход из Связки ключей и сообщает приложению (один раз).
    private func revokeLocally() {
        guard tokens != nil else { return }
        tokens = nil
        do {
            try keychain.deleteDropboxSecrets()
        } catch {
            KeychainStore.logger.error("Failed to delete revoked Dropbox tokens: \(error.localizedDescription, privacy: .public)")
        }
        accessRevokedHandler?()
    }
}
