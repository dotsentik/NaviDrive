import Foundation

/// Допустимые ссылки «Добавить по ссылке»: только веб-схемы и хосты облаков —
/// сам домен или его поддомен (`drive.google.com`, но не `evilgoogle.com`).
enum LinkHosts {
    static func isWebScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// `host` — это `domain` или его поддомен.
    static func host(_ host: String, isIn domain: String) -> Bool {
        let host = host.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }

    static func isGoogle(_ host: String) -> Bool {
        self.host(host, isIn: "google.com") || self.host(host, isIn: "googleusercontent.com")
    }

    static func isDropbox(_ host: String) -> Bool {
        self.host(host, isIn: "dropbox.com") || host.lowercased() == "db.tt"
    }
}
