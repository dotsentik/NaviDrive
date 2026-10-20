import Foundation
import os
import Security

/// Ошибка Связки ключей с кодом OSStatus и текстом из SecCopyErrorMessageString.
struct KeychainError: LocalizedError, Sendable {
    let status: OSStatus
    let operation: String

    var message: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }

    /// Нет доступа к записи (другая подпись приложения, отказ пользователя, нет UI для запроса).
    var isAccessDenied: Bool { KeychainStore.accessDeniedStatuses.contains(status) }

    var errorDescription: String? { String(localized: "Keychain (\(operation)): \(message) [\(status)]") }
}

/// Секреты NaviDrive в одной записи Связки ключей (JSON). access_token сюда не попадает.
struct StoredSecrets: Codable, Sendable, Equatable {
    /// Свои Client ID / Client Secret (Настройки → Аккаунт → Дополнительно).
    var clientId: String?
    var clientSecret: String?
    var refreshToken: String?
    /// Client ID, которым выдан refresh_token.
    var tokenClientId: String?
    /// Выданные права (scope).
    var scope: String?

    var isEmpty: Bool { self == StoredSecrets() }
}

/// Хранение секретов (Client ID/Secret, OAuth-токены) в системном Keychain.
///
/// Ошибки не глотаются: `errSecItemNotFound` — это «записи нет» (nil), любая другая ошибка
/// логируется (os.Logger, subsystem com.navidrive.NaviDrive, category keychain) и бросается наверх,
/// чтобы приложение не выдавало «нет доступа» за «нет входа».
struct KeychainStore: Sendable {
    static let logger = Logger(subsystem: "com.navidrive.NaviDrive", category: "keychain")

    /// Текущий сервис. Запись создаётся сборкой, подписанной постоянным самоподписанным сертификатом («NaviDrive Signing»).
    static let currentService = "com.navidrive.NaviDrive.v2"
    /// Сервис ad-hoc сборок (до подписи сертификатом): их записи новой подписи обычно недоступны.
    static let legacyService = "com.navidrive.NaviDrive"

    static let accessDeniedStatuses: Set<OSStatus> = [
        errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNoAccessForItem,
        errSecInvalidOwnerEdit, errSecMissingEntitlement, errSecWrPerm,
    ]

    let service: String

    init(service: String = KeychainStore.currentService) {
        self.service = service
    }

    enum Account {
        /// Единственная текущая запись: все секреты одной JSON-структурой (`StoredSecrets`) —
        /// одно разрешение Связки ключей вместо трёх.
        static let secrets = "navidrive.secrets"
        // Отдельные записи прежних версий (переносятся в `secrets` и удаляются).
        static let clientId = "oauth.client_id"
        static let clientSecret = "oauth.client_secret"
        static let tokens = "oauth.tokens"
        static let all = [clientId, clientSecret, tokens]
    }

    /// Прочитанная запись `secrets` по сервисам: Связка ключей читается один раз за запуск.
    private static let cache = OSAllocatedUnfairLock<[String: StoredSecrets]>(initialState: [:])

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func failure(_ status: OSStatus, _ operation: String, _ account: String) -> KeychainError {
        let error = KeychainError(status: status, operation: operation)
        Self.logger.error("\(operation, privacy: .public) \(account, privacy: .public) [\(self.service, privacy: .public)]: \(status) \(error.message, privacy: .public)")
        return error
    }

    // MARK: - Low level

    /// nil — записи нет (норма). Любая другая ошибка бросается.
    func data(for account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw failure(status, String(localized: "read"), account)
        }
    }

    /// Запись. Если обновить существующую запись нельзя (ошибка доступа) — она удаляется
    /// и создаётся заново. Если и это не удалось — ошибка бросается наверх.
    func set(_ data: Data, for account: String) throws {
        let query = baseQuery(account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            let error = failure(status, String(localized: "update"), account)
            guard error.isAccessDenied else { throw error }
            let deleteStatus = SecItemDelete(query as CFDictionary)
            if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
                throw failure(deleteStatus, String(localized: "delete before re-create"), account)
            }
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw failure(addStatus, String(localized: "create"), account) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure(status, String(localized: "delete"), account)
        }
    }

    func string(for account: String) throws -> String? {
        try data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setString(_ value: String, for account: String) throws {
        if value.isEmpty {
            try delete(account)
        } else {
            try set(Data(value.utf8), for: account)
        }
    }

    // MARK: - Secrets (одна запись)

    /// Все секреты. Первый вызов читает Связку ключей (и при необходимости переносит старые
    /// отдельные записи), дальше — из памяти.
    func secrets() throws -> StoredSecrets {
        try Self.cache.withLock { cache in
            if let cached = cache[service] { return cached }
            let loaded = try loadOrMigrateSecrets()
            cache[service] = loaded
            return loaded
        }
    }

    /// Изменяет секреты и сохраняет запись (только если что-то изменилось).
    func updateSecrets(_ change: @Sendable (inout StoredSecrets) -> Void) throws {
        try Self.cache.withLock { cache in
            let current = try cache[service] ?? loadOrMigrateSecrets()
            var updated = current
            change(&updated)
            guard updated != current else {
                cache[service] = current
                return
            }
            if updated.isEmpty {
                try delete(Account.secrets)
            } else {
                try set(try JSONEncoder().encode(updated), for: Account.secrets)
            }
            cache[service] = updated
        }
    }

    private func loadOrMigrateSecrets() throws -> StoredSecrets {
        if let data = try data(for: Account.secrets) {
            do {
                return try JSONDecoder().decode(StoredSecrets.self, from: data)
            } catch {
                // Повреждённая запись — это не ошибка доступа: удаляем, понадобится новый вход.
                Self.logger.error("Keychain secrets are corrupted, the item was deleted: \(error.localizedDescription, privacy: .public)")
                try? delete(Account.secrets)
                return StoredSecrets()
            }
        }
        // Перенос отдельных записей прежних версий. Ошибка чтения (нет доступа) бросается наверх,
        // старые записи при этом не удаляются.
        var migrated = StoredSecrets()
        migrated.clientId = try string(for: Account.clientId)
        migrated.clientSecret = try string(for: Account.clientSecret)
        if let data = try data(for: Account.tokens) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let tokens = try? decoder.decode(OAuthTokens.self, from: data) {
                // access_token не переносится: он живёт только в памяти и обновляется при запуске.
                migrated.refreshToken = tokens.refreshToken
                migrated.tokenClientId = tokens.clientId
                migrated.scope = tokens.scope
            }
        }
        if !migrated.isEmpty {
            try set(try JSONEncoder().encode(migrated), for: Account.secrets)
            Self.logger.info("Keychain items merged into a single item")
        }
        for account in Account.all {
            do {
                try delete(account)
            } catch {
                Self.logger.error("Couldn’t delete the old item \(account, privacy: .public) after merging")
            }
        }
        return migrated
    }

    // MARK: - Typed helpers

    func clientId() throws -> String { try secrets().clientId ?? "" }
    func clientSecret() throws -> String { try secrets().clientSecret ?? "" }

    /// Свои Client ID / Client Secret (пустая строка — удалить).
    func setCustomCredentials(clientId: String, clientSecret: String) throws {
        try updateSecrets {
            $0.clientId = clientId.isEmpty ? nil : clientId
            $0.clientSecret = clientSecret.isEmpty ? nil : clientSecret
        }
    }

    /// Сохранённый вход. access_token в Связке ключей не хранится: возвращается пустым
    /// и уже истёкшим — при первом запросе он обновляется через refresh_token.
    func loadTokens() throws -> OAuthTokens? {
        let secrets = try secrets()
        guard let refreshToken = secrets.refreshToken, !refreshToken.isEmpty else { return nil }
        return OAuthTokens(accessToken: "", refreshToken: refreshToken, expiryDate: .distantPast,
                           clientId: secrets.tokenClientId, scope: secrets.scope)
    }

    /// Сохраняет refresh_token и его атрибуты (access_token остаётся только в памяти).
    /// Обычное обновление access_token запись не меняет и Связку ключей не трогает.
    func saveTokens(_ tokens: OAuthTokens) throws {
        try updateSecrets {
            $0.refreshToken = tokens.refreshToken
            $0.tokenClientId = tokens.clientId
            $0.scope = tokens.scope
        }
    }

    func deleteTokens() throws {
        try updateSecrets {
            $0.refreshToken = nil
            $0.tokenClientId = nil
            $0.scope = nil
        }
    }

    // MARK: - One-time migration from ad-hoc builds

    enum MigrationResult: Sendable, Equatable {
        /// Ничего переносить не нужно (уже перенесено или старых записей нет).
        case nothingToDo
        /// Старые записи доступны и перенесены — повторный вход не нужен.
        case migrated
        /// Старые записи недоступны новой подписи — удалены (по возможности), нужен один повторный вход.
        case reloginRequired
    }

    private static let migrationDoneKey = "keychainMigratedToSignedBuild"

    /// Одноразовый перенос записей ad-hoc сборок в сервис подписанной сборки.
    /// Если старая запись доступна (например, пользователь нажал «Разрешить») — переносится как есть.
    /// Если доступ запрещён — запись удаляется (если система позволит), и нужен один повторный вход.
    static func migrateLegacyItemsIfNeeded() -> MigrationResult {
        guard !UserDefaults.standard.bool(forKey: migrationDoneKey) else { return .nothingToDo }
        let legacy = KeychainStore(service: legacyService)
        let current = KeychainStore()
        var result = MigrationResult.nothingToDo
        var hadUnexpectedError = false

        for account in Account.all {
            do {
                guard let data = try legacy.data(for: account) else { continue }
                if try current.data(for: account) == nil {
                    try current.set(data, for: account)
                }
                try? legacy.delete(account)
                if result == .nothingToDo { result = .migrated }
                logger.info("Item \(account, privacy: .public) migrated to the signed service")
            } catch let error as KeychainError where error.isAccessDenied {
                // Запись создана ad-hoc сборкой с другим cdhash — новой подписи она недоступна.
                do {
                    try legacy.delete(account)
                } catch {
                    logger.error("Couldn’t delete the old item \(account, privacy: .public); it stays under the old service and is no longer used")
                }
                result = .reloginRequired
            } catch {
                // Неожиданная ошибка (не отказ доступа) — попробуем перенести при следующем запуске.
                hadUnexpectedError = true
                logger.error("Migration of \(account, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !hadUnexpectedError { UserDefaults.standard.set(true, forKey: migrationDoneKey) }
        return result
    }
}
