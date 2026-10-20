import Foundation

/// Client ID / Client Secret для OAuth.
///
/// Встроенные значения попадают в Info.plist из `Config/Secrets.xcconfig` при сборке — человеку,
/// получившему приложение, достаточно нажать «Войти через Google». Свои учётные данные
/// (Настройки → Аккаунт → Дополнительно) хранятся в Keychain и имеют приоритет, если включены.
///
/// Для приложений типа «Desktop app» Google не считает Client Secret настоящим секретом:
/// он неизбежно лежит внутри приложения, защиту входа обеспечивают PKCE и loopback-redirect.
struct OAuthCredentials: Sendable, Equatable {
    let clientId: String
    let clientSecret: String

    static let bundledIdKey = "NaviDriveGoogleClientID"
    static let bundledSecretKey = "NaviDriveGoogleClientSecret"

    /// Встроенные при сборке значения (nil — в Secrets.xcconfig ничего не вписано).
    static var bundled: OAuthCredentials? {
        func value(_ key: String) -> String? {
            guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Нераскрытая переменная «$(GOOGLE_CLIENT_ID)» — тоже «не задано».
            return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
        }
        guard let id = value(bundledIdKey), let secret = value(bundledSecretKey) else { return nil }
        return OAuthCredentials(clientId: id, clientSecret: secret)
    }

    /// Свои значения из Keychain (nil — не введены).
    static func custom(_ keychain: KeychainStore) throws -> OAuthCredentials? {
        let id = try keychain.clientId().trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = try keychain.clientSecret().trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty || secret.isEmpty ? nil : OAuthCredentials(clientId: id, clientSecret: secret)
    }

    /// Учётные данные для нового входа: свои (если включены и заполнены), иначе встроенные.
    static func forSignIn(_ keychain: KeychainStore) throws -> OAuthCredentials {
        if AppSettings.useCustomOAuthCredentials {
            guard let custom = try custom(keychain) else { throw OAuthError.missingCustomCredentials }
            return custom
        }
        guard let bundled else { throw OAuthError.missingBundledCredentials }
        return bundled
    }

    /// Для обновления токена нужен тот же Client ID, которым выдан refresh_token.
    /// `clientId == nil` — вход сохранён старой версией: берутся текущие учётные данные.
    static func forRefresh(clientId: String?, _ keychain: KeychainStore) throws -> OAuthCredentials {
        guard let clientId else { return try forSignIn(keychain) }
        if let bundled, bundled.clientId == clientId { return bundled }
        if let custom = try custom(keychain), custom.clientId == clientId { return custom }
        throw OAuthError.reauthenticationRequired
    }
}
