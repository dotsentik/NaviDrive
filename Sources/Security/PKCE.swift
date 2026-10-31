import CryptoKit
import Foundation
import Security

/// PKCE (RFC 7636): `code_verifier` из криптослучайных байт и `code_challenge` = BASE64URL(SHA-256(verifier)).
/// SHA-256 — системный CryptoKit (раньше была собственная реализация).
enum PKCE {
    /// Криптослучайные байты (SecRandomCopyBytes; запасной путь — системный CSPRNG).
    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
        }
        return bytes
    }

    static func base64URL<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 32 байта → 43 символа base64url (RFC 7636: 43–128 символов).
    static func makeVerifier() -> String { base64URL(randomBytes(32)) }

    static func challenge(for verifier: String) -> String {
        base64URL(SHA256.hash(data: Data(verifier.utf8)))
    }
}
