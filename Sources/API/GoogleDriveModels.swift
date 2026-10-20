import Foundation

// MARK: - Google Drive API v3 DTO (используются только внутри GoogleDriveProvider)

struct DriveCapabilities: Codable, Sendable, Hashable {
    var canDownload: Bool? = nil
    var canAddChildren: Bool? = nil
    var canRename: Bool? = nil
    var canTrash: Bool? = nil
    var canMoveItemWithinDrive: Bool? = nil
}

struct ShortcutDetails: Codable, Sendable, Hashable {
    let targetId: String?
    let targetMimeType: String?
}

struct DriveItem: Codable, Sendable, Hashable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let md5Checksum: String?
    let modifiedTime: String?
    /// Заполнено только у ярлыков (`application/vnd.google-apps.shortcut`).
    var shortcutDetails: ShortcutDetails? = nil
    /// Ключ ресурса для старых ссылок «доступно всем, у кого есть ссылка».
    var resourceKey: String? = nil
    var capabilities: DriveCapabilities? = nil
    /// ID общего диска, если объект лежит на общем диске.
    var driveId: String? = nil

    static let folderMimeType = "application/vnd.google-apps.folder"
    static let shortcutMimeType = "application/vnd.google-apps.shortcut"
    static let workspacePrefix = "application/vnd.google-apps."

    var isShortcut: Bool { mimeType == Self.shortcutMimeType }
    /// mimeType цели для ярлыка, иначе собственный.
    var effectiveMimeType: String { isShortcut ? (shortcutDetails?.targetMimeType ?? mimeType) : mimeType }
    var isFolder: Bool { effectiveMimeType == Self.folderMimeType }

    var modifiedDate: Date? {
        guard let modifiedTime else { return nil }
        return DriveDate.parse(modifiedTime)
    }
}

enum DriveDate {
    static func parse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

struct DriveFileList: Decodable, Sendable {
    let nextPageToken: String?
    let files: [DriveItem]
}

struct DriveUser: Decodable, Sendable {
    let displayName: String?
    let emailAddress: String?
}

/// Разбор ссылок Google Drive: /drive/folders/<id>, /file/d/<id>/view, open?id=<id>,
/// docs.google.com/<тип>/d/<id>/edit, ?usp=sharing, resourcekey=<key>, а также «голый» ID.
struct DriveLink: Sendable, Equatable {
    let id: String
    let resourceKey: String?

    private static let idCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func isValidId(_ value: String) -> Bool {
        value.count >= 10 && value.unicodeScalars.allSatisfy { idCharacters.contains($0) }
    }

    static func parse(_ input: String) -> DriveLink? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'")))
        guard !text.isEmpty else { return nil }
        if isValidId(text) { return DriveLink(id: text, resourceKey: nil) }

        let urlString = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host.hasSuffix("google.com") || host.hasSuffix("googleusercontent.com") else { return nil }

        let query = components.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            query.first { $0.name.lowercased() == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let resourceKey = queryValue("resourcekey")

        // /folders/<id>, /file/d/<id>, /document/d/<id>, /d/<id>
        let parts = components.path.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() where index + 1 < parts.count {
            if part == "folders" || part == "d", isValidId(parts[index + 1]) {
                return DriveLink(id: parts[index + 1], resourceKey: resourceKey)
            }
        }
        // open?id=<id>, uc?id=<id>
        if let id = queryValue("id"), isValidId(id) {
            return DriveLink(id: id, resourceKey: resourceKey)
        }
        return nil
    }
}

/// Потокобезопасный реестр resourceKey: `id → key`. Пополняется из ссылок и ответов API,
/// используется для заголовка `X-Goog-Drive-Resource-Keys` в запросах к объекту и его потомкам.
final class ResourceKeyRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    static let headerName = "X-Goog-Drive-Resource-Keys"

    func register(id: String, key: String?) {
        guard let key, !key.isEmpty else { return }
        lock.lock(); keys[id] = key; lock.unlock()
    }

    func register(_ items: [DriveItem]) {
        lock.lock()
        for item in items {
            if let key = item.resourceKey, !key.isEmpty { keys[item.id] = key }
        }
        lock.unlock()
    }

    func key(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return keys[id]
    }

    /// Значение заголовка для набора ID (`id1/key1,id2/key2`) или nil, если ключей нет.
    func headerValue(for ids: [String]) -> String? {
        lock.lock(); defer { lock.unlock() }
        let pairs = ids.compactMap { id in keys[id].map { "\(id)/\($0)" } }
        return pairs.isEmpty ? nil : pairs.joined(separator: ",")
    }
}
