import Foundation

/// Выдаёт актуальный access_token. Обновляет его через refresh_token, если до истечения < 5 минут
/// или при HTTP 401. Параллельные запросы ожидают одно общее обновление.
actor TokenManager {
    private let keychain: KeychainStore
    private var tokens: OAuthTokens?
    private var refreshTask: Task<OAuthTokens, Error>?

    static let refreshMargin: TimeInterval = 300

    /// Ошибка чтения токенов при запуске (нет доступа к Связке ключей и т. п.) —
    /// это не то же самое, что «входа нет», и UI сообщает о ней отдельно.
    private(set) var keychainLoadError: String?

    /// При запуске в Связке ключей был сохранённый вход: главное окно или окно приветствия.
    nonisolated let hadTokensAtLaunch: Bool

    /// Google отклонил refresh_token (invalid_grant): токены уже удалены, нужен новый вход.
    private var accessRevokedHandler: (@Sendable () -> Void)?

    init(keychain: KeychainStore) {
        self.keychain = keychain
        do {
            self.tokens = try keychain.loadTokens()
        } catch {
            self.tokens = nil
            self.keychainLoadError = error.localizedDescription
        }
        self.hadTokensAtLaunch = tokens != nil
    }

    func setAccessRevokedHandler(_ handler: @escaping @Sendable () -> Void) {
        accessRevokedHandler = handler
    }

    var isSignedIn: Bool { tokens != nil }

    /// Сохранённый вход заведомо без права записи — для загрузки нужно войти заново.
    var lacksWriteScope: Bool { tokens?.lacksWriteScope ?? false }

    /// Сохраняет токены. Если Связка ключей не приняла запись, вход действует до перезапуска,
    /// а ошибка уходит наверх, чтобы UI сообщил о ней.
    func store(_ newTokens: OAuthTokens) throws {
        tokens = newTokens
        keychainLoadError = nil
        do {
            try keychain.saveTokens(newTokens)
        } catch {
            KeychainStore.logger.error("Failed to save tokens: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func signOut() async {
        refreshTask?.cancel()
        refreshTask = nil
        let token = tokens?.refreshToken
        tokens = nil
        do {
            try keychain.deleteTokens()
        } catch {
            KeychainStore.logger.error("Failed to delete tokens on sign-out: \(error.localizedDescription, privacy: .public)")
        }
        if let token { await OAuthService.revoke(token: token) }
    }

    func validAccessToken() async throws -> String {
        if let refreshTask { return try await refreshTask.value.accessToken }
        guard let tokens else { throw OAuthError.notSignedIn }
        if tokens.expiryDate.timeIntervalSinceNow > Self.refreshMargin {
            return tokens.accessToken
        }
        return try await refresh().accessToken
    }

    /// Вызывается после HTTP 401. Если токен уже обновил другой запрос — возвращает новый.
    func refreshAfterUnauthorized(failedToken: String) async throws -> String {
        if let refreshTask { return try await refreshTask.value.accessToken }
        guard let tokens else { throw OAuthError.notSignedIn }
        if tokens.accessToken != failedToken, tokens.expiryDate.timeIntervalSinceNow > Self.refreshMargin {
            return tokens.accessToken
        }
        return try await refresh().accessToken
    }

    private func refresh() async throws -> OAuthTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens else { throw OAuthError.notSignedIn }
        let credentials: OAuthCredentials
        do {
            credentials = try OAuthCredentials.forRefresh(clientId: current.clientId, keychain)
        } catch OAuthError.reauthenticationRequired {
            // Токен выдан Client ID, которого в этой сборке больше нет: обновить его нельзя.
            revokeLocally()
            throw OAuthError.reauthenticationRequired
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.keychainUnavailable(error.localizedDescription)
        }
        let clientId = credentials.clientId, clientSecret = credentials.clientSecret

        let task = Task<OAuthTokens, Error> {
            var lastError: Error = OAuthError.notSignedIn
            for attempt in 0..<4 {
                do {
                    var fresh = try await OAuthService.refresh(refreshToken: current.refreshToken,
                                                               clientId: clientId, clientSecret: clientSecret,
                                                               previousScope: current.scope)
                    // Запоминаем Client ID (у входа из старой версии его ещё не было).
                    fresh.clientId = clientId
                    return fresh
                } catch OAuthError.reauthenticationRequired {
                    throw OAuthError.reauthenticationRequired
                } catch {
                    lastError = error
                    try await Task.sleep(for: GoogleDriveAPIClient.backoffDelay(attempt))
                }
            }
            throw lastError
        }
        refreshTask = task
        do {
            let fresh = try await task.value
            refreshTask = nil
            if tokens != nil {
                tokens = fresh
                do {
                    try keychain.saveTokens(fresh)
                } catch {
                    // Обновлённый access_token живёт в памяти; refresh_token в Связке ключей не изменился.
                    KeychainStore.logger.error("Failed to save the refreshed token: \(error.localizedDescription, privacy: .public)")
                }
            }
            return fresh
        } catch {
            refreshTask = nil
            if case OAuthError.reauthenticationRequired = error { revokeLocally() }
            throw error
        }
    }

    /// Доступ отозван или истёк: удаляет токены из Связки ключей и сообщает приложению (один раз).
    private func revokeLocally() {
        guard tokens != nil else { return }
        tokens = nil
        do {
            try keychain.deleteTokens()
        } catch {
            KeychainStore.logger.error("Failed to delete revoked tokens: \(error.localizedDescription, privacy: .public)")
        }
        accessRevokedHandler?()
    }
}
