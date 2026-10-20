import AppKit
import Foundation

struct OAuthTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiryDate: Date
    /// Client ID, которым выдан refresh_token (обновлять токен можно только им).
    var clientId: String? = nil
    /// Выданные права (поле `scope` ответа Google). nil — вход сохранён старой версией, права неизвестны.
    var scope: String? = nil

    /// Известно, что вход выдан без права записи (например, пользователь снял галочку на экране согласия).
    var lacksWriteScope: Bool {
        guard let scope else { return false }
        return !scope.split(separator: " ").contains { $0 == Substring(OAuthService.scope) }
    }
}

enum OAuthError: LocalizedError {
    case missingClientCredentials
    /// Сборка без встроенных учётных данных и свои не включены.
    case missingBundledCredentials
    /// Включены свои учётные данные, но поля пустые.
    case missingCustomCredentials
    case notSignedIn
    case stateMismatch
    case authorizationDenied(String)
    case tokenEndpoint(String)
    case reauthenticationRequired
    case keychainUnavailable(String)

    /// Входа нет или он больше недействителен: задачу не считать ошибкой, а вернуть в очередь до нового входа.
    var meansSignedOut: Bool {
        switch self {
        case .notSignedIn, .reauthenticationRequired: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingClientCredentials: String(localized: "Enter the Client ID and Client Secret in Settings")
        case .missingBundledCredentials: String(localized: "This copy of NaviDrive was built without Google sign-in credentials. Turn on “Use my own OAuth credentials” in Settings → Account → Advanced and enter your Client ID and Client Secret.")
        case .missingCustomCredentials: String(localized: "“Use my own OAuth credentials” is on, but the Client ID or Client Secret is empty. Fill them in or turn the option off in Settings → Account → Advanced.")
        case .notSignedIn: String(localized: "Not signed in to Google")
        case .stateMismatch: String(localized: "The authorization response failed the state check")
        case .authorizationDenied(let e): String(localized: "Google denied authorization: \(e)")
        case .tokenEndpoint(let e): String(localized: "Token request failed: \(e)")
        case .reauthenticationRequired: String(localized: "Your Google session has expired — sign in again in Settings")
        case .keychainUnavailable(let message): String(localized: "No access to the Keychain: \(message)")
        }
    }
}

/// OAuth 2.0 для Desktop App: PKCE (S256) + loopback redirect на 127.0.0.1.
enum OAuthService {
    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let scope = "https://www.googleapis.com/auth/drive"

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
        let error: String?
        let error_description: String?
    }

    /// Полный интерактивный вход: локальный сервер → браузер → обмен code на токены.
    /// - Parameter openURL: открывает страницу входа в браузере (и запоминает её, чтобы открыть ещё раз).
    static func signIn(clientId: String, clientSecret: String,
                       openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> OAuthTokens {
        guard !clientId.isEmpty else { throw OAuthError.missingClientCredentials }

        let verifier = PKCE.makeVerifier()
        let state = PKCE.base64URL(PKCE.randomBytes(16))
        let server = LoopbackServer(expectedState: state)
        defer { server.stop() }
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var components = URLComponents(string: authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            // select_account — выбор аккаунта, если их несколько; consent — гарантированный refresh_token.
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        guard let url = components.url else { throw OAuthError.tokenEndpoint("bad auth URL") }
        await openURL(url)

        let callback = try await server.waitForCallback()
        if let error = callback.error { throw OAuthError.authorizationDenied(error) }
        guard callback.state == state else { throw OAuthError.stateMismatch }
        guard let code = callback.code else { throw OAuthError.authorizationDenied("empty code") }

        let response = try await postToken([
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let access = response.access_token, let refresh = response.refresh_token else {
            throw OAuthError.tokenEndpoint(response.error_description ?? response.error ?? "no tokens in response")
        }
        return OAuthTokens(accessToken: access, refreshToken: refresh,
                           expiryDate: Date().addingTimeInterval(response.expires_in ?? 3600), clientId: clientId,
                           scope: response.scope)
    }

    static func refresh(refreshToken: String, clientId: String, clientSecret: String,
                        previousScope: String? = nil) async throws -> OAuthTokens {
        let response = try await postToken([
            "refresh_token": refreshToken,
            "client_id": clientId,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
        ])
        if response.error == "invalid_grant" { throw OAuthError.reauthenticationRequired }
        guard let access = response.access_token else {
            throw OAuthError.tokenEndpoint(response.error_description ?? response.error ?? "no access_token")
        }
        return OAuthTokens(accessToken: access, refreshToken: response.refresh_token ?? refreshToken,
                           expiryDate: Date().addingTimeInterval(response.expires_in ?? 3600),
                           scope: response.scope ?? previousScope)
    }

    static func revoke(token: String) async {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(["token": token])
        _ = try? await CloudNetwork.sharedSession.data(for: request)
    }

    private static func postToken(_ parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(parameters)
        request.timeoutInterval = 30
        let (data, _) = try await CloudNetwork.sharedSession.data(for: request)
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthError.tokenEndpoint(String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    private static func formEncode(_ parameters: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = parameters.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
