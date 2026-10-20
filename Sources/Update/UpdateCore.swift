import CryptoKit
import Foundation

// Чистая логика обновлений без сети и UI: версии, разбор релиза GitHub, допустимые хосты, SHA-256.
// Файл компилируется и в приложение, и в юнит-тесты (NaviDriveTests).

/// Версия вида 1.2.3 (с необязательным префиксом «v»). Сравнение по числам, недостающие части — нули:
/// 1.0 == 1.0.0, 1.9.0 < 1.10.0.
struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        components = numbers
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    private static func padded(_ lhs: SemanticVersion, _ rhs: SemanticVersion) -> ([Int], [Int]) {
        let count = max(lhs.components.count, rhs.components.count)
        return (lhs.components + Array(repeating: 0, count: count - lhs.components.count),
                rhs.components + Array(repeating: 0, count: count - rhs.components.count))
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let (a, b) = padded(lhs, rhs)
        return a == b
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let (a, b) = padded(lhs, rhs)
        return a.lexicographicallyPrecedes(b)
    }
}

/// Ответ `GET /repos/{owner}/{repo}/releases/latest` — только нужные поля.
struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int64
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body, draft, prerelease, assets
    }
}

/// Найденное обновление: версия из тега, заметки и ссылки на DMG и его .sha256.
struct UpdateRelease: Equatable, Sendable {
    let version: SemanticVersion
    let notes: String
    let dmgName: String
    let dmgURL: URL
    let dmgSize: Int64
    let checksumURL: URL
}

enum ReleaseEvaluation: Equatable, Sendable {
    case upToDate
    case available(UpdateRelease)
}

enum UpdateCoreError: Error, Equatable, Sendable {
    case malformedRelease
    case unsupportedTag(String)
    case missingAsset(String)
    case insecureURL
    case tooLarge
    case malformedChecksum
    case checksumMismatch
}

enum UpdatePolicy {
    /// Ссылки на релиз и ассеты принимаются только с этих хостов (точное совпадение, без поддоменов).
    static let allowedHosts: Set<String> = [
        "github.com",
        "api.github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    /// Верхний предел размера DMG.
    static let maxDownloadBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// Файл .sha256 — одна строка.
    static let maxChecksumBytes = 4096

    #if DEBUG
    /// Только Debug (Scripts/test-update-e2e.sh): NAVIDRIVE_UPDATE_FEED — адрес мока releases/latest вместо
    /// api.github.com. Принимается только http://127.0.0.1:<порт>/…; тот же хост и порт разрешаются
    /// для ссылок на ассеты. Без переменной список хостов прежний.
    static let debugFeedURL: URL? = {
        guard let text = ProcessInfo.processInfo.environment["NAVIDRIVE_UPDATE_FEED"],
              let components = URLComponents(string: text),
              components.scheme == "http", components.host == "127.0.0.1", components.port != nil else { return nil }
        return components.url
    }()
    #endif

    /// Отпечаток SHA-256 сертификата в каноническом виде: 64 шестнадцатеричных символа в нижнем регистре.
    /// Регистр, пробелы и «:» (формат `openssl x509 -fingerprint`) не важны; nil — строка не отпечаток SHA-256.
    static func normalizedFingerprint(_ text: String) -> String? {
        let hex = text.lowercased().filter { !$0.isWhitespace && $0 != ":" }
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    /// Отпечаток листового сертификата новой копии входит в NDTrustedSigningFingerprints запущенной копии.
    static func isTrustedFingerprint(_ fingerprint: String, trusted: [String]) -> Bool {
        guard let candidate = normalizedFingerprint(fingerprint) else { return false }
        return trusted.contains { normalizedFingerprint($0) == candidate }
    }

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        #if DEBUG
        if let feed = debugFeedURL, components.scheme == "http", components.host == "127.0.0.1",
           components.port == feed.port, components.user == nil, components.password == nil {
            return true
        }
        #endif
        guard components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    static func dmgName(for version: SemanticVersion) -> String { "NaviDrive-\(version).dmg" }

    /// Черновики и prerelease не считаются; тег должен быть версией; DMG и .sha256 — среди ассетов,
    /// по HTTPS с разрешённых хостов, размер DMG — в пределах `maxDownloadBytes`.
    static func evaluate(_ data: Data, currentVersion: SemanticVersion) throws -> ReleaseEvaluation {
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCoreError.malformedRelease
        }
        guard !release.draft, !release.prerelease else { return .upToDate }
        guard let version = SemanticVersion(release.tagName) else {
            throw UpdateCoreError.unsupportedTag(release.tagName)
        }
        guard version > currentVersion else { return .upToDate }

        // Тег v1.1 и ассет NaviDrive-1.1.dmg — имя ассета строится из тега как есть (без «v»).
        let tagVersion = String(release.tagName.drop(while: { $0 == "v" || $0 == "V" }))
        let dmgName = "NaviDrive-\(tagVersion).dmg"
        guard let dmg = release.assets.first(where: { $0.name == dmgName }) else {
            throw UpdateCoreError.missingAsset(dmgName)
        }
        guard let checksum = release.assets.first(where: { $0.name == dmgName + ".sha256" }) else {
            throw UpdateCoreError.missingAsset(dmgName + ".sha256")
        }
        guard isAllowed(dmg.browserDownloadURL), isAllowed(checksum.browserDownloadURL) else {
            throw UpdateCoreError.insecureURL
        }
        guard dmg.size > 0, dmg.size <= maxDownloadBytes else { throw UpdateCoreError.tooLarge }
        return .available(UpdateRelease(
            version: version,
            notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            dmgName: dmgName,
            dmgURL: dmg.browserDownloadURL,
            dmgSize: dmg.size,
            checksumURL: checksum.browserDownloadURL))
    }

    /// Строка формата `shasum -a 256`: «<hash>  <имя файла>» (имя необязательно; «*» — двоичный режим).
    /// Если имя указано, оно должно совпадать с именем DMG.
    static func parseChecksum(_ data: Data, expectedFileName: String) throws -> String {
        guard data.count <= maxChecksumBytes, let text = String(data: data, encoding: .utf8) else {
            throw UpdateCoreError.malformedChecksum
        }
        guard let line = text.split(whereSeparator: \.isNewline).first else {
            throw UpdateCoreError.malformedChecksum
        }
        let fields = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard let hashField = fields.first else { throw UpdateCoreError.malformedChecksum }
        let hash = hashField.lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw UpdateCoreError.malformedChecksum
        }
        if fields.count == 2 {
            var name = fields[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard name == expectedFileName else { throw UpdateCoreError.malformedChecksum }
        }
        return hash
    }

    /// SHA-256 файла потоком по 1 МБ: файл целиком в память не загружается.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifySHA256(ofFileAt url: URL, expected: String) throws {
        guard try sha256(ofFileAt: url) == expected.lowercased() else {
            throw UpdateCoreError.checksumMismatch
        }
    }
}
