import Foundation

// MARK: - Hash

/// Алгоритм хеша содержимого, который облако отдаёт для файлов.
enum CloudHashKind: String, Sendable, Hashable, Codable {
    /// MD5 всего файла (Google Drive `md5Checksum`).
    case md5
    /// Dropbox `content_hash`: SHA-256 от склеенных SHA-256 блоков по 4 МБ.
    case dropboxContentHash = "dropbox_content_hash"
}

struct CloudHash: Sendable, Hashable {
    let kind: CloudHashKind
    /// Hex в нижнем регистре.
    let value: String
}

// MARK: - Permissions

/// Что пользователь может делать с объектом. Неизвестные права не блокируют действие —
/// окончательно решает API облака, и его отказ показывается понятным текстом.
struct CloudPermissions: Sendable, Hashable {
    var canDownload = true
    var canAddChildren = true
    var canRename = true
    var canTrash = true
    var canMove = true
}

// MARK: - Export

/// Формат, в который документ облака конвертируется при скачивании (документы Google и т. п.).
struct CloudExportFormat: Sendable, Hashable {
    let mimeType: String
    let fileExtension: String
}

/// Документ облака без собственного файла (скачивается только экспортом или не скачивается вовсе).
enum CloudDocumentType: Sendable, Hashable {
    case document, spreadsheet, presentation, drawing
    /// Формы, сайты и прочие объекты, которые нельзя скачать.
    case other
}

// MARK: - Item

/// Файл или папка в облаке. Ярлык (alias) уже несёт свойства цели: `isFolder`, `contentType`, экспорт.
struct CloudItem: Sendable, Identifiable, Hashable {
    let provider: CloudProviderKind
    let id: String
    let name: String
    /// Путь в облаке, если сервис адресует объекты путями (nil — только по ID).
    var path: String? = nil
    let isFolder: Bool
    var size: Int64? = nil
    var modifiedAt: Date? = nil
    var hash: CloudHash? = nil
    var permissions = CloudPermissions()
    /// MIME-тип содержимого (для ярлыка — тип цели).
    var contentType: String? = nil
    /// Ярлык на другой объект; `aliasTargetId == nil` — цель неизвестна.
    var isAlias = false
    var aliasTargetId: String? = nil
    /// Отдельное пространство (общий диск и т. п.), в котором лежит объект.
    var spaceId: String? = nil
    /// Ключ доступа для объектов, открытых по ссылке.
    var accessKey: String? = nil
    var documentType: CloudDocumentType? = nil
    var exportFormat: CloudExportFormat? = nil

    /// Копия с новым именем — для мгновенного обновления списка после переименования.
    func renamed(_ newName: String) -> CloudItem {
        var copy = CloudItem(provider: provider, id: id, name: newName, isFolder: isFolder)
        copy.path = path
        copy.size = size
        copy.modifiedAt = modifiedAt
        copy.hash = hash
        copy.permissions = permissions
        copy.contentType = contentType
        copy.isAlias = isAlias
        copy.aliasTargetId = aliasTargetId
        copy.spaceId = spaceId
        copy.accessKey = accessKey
        copy.documentType = documentType
        copy.exportFormat = exportFormat
        return copy
    }

    var canDownload: Bool { permissions.canDownload }
    var canAddChildren: Bool { permissions.canAddChildren }
    var canRename: Bool { permissions.canRename }
    var canTrash: Bool { permissions.canTrash }
    var canMove: Bool { permissions.canMove }

    /// ID объекта, с которым реально работаем (цель ярлыка или сам объект).
    var targetId: String { isAlias ? (aliasTargetId ?? id) : id }
    /// Пространство цели. У ярлыка оно неизвестно (цель может лежать где угодно).
    var targetSpaceId: String? { isAlias ? nil : spaceId }
    var isCloudDocument: Bool { !isFolder && documentType != nil }
    var sizeValue: Int64 { size ?? 0 }

    /// Можно ли скачать объект как файл (обычный файл или экспортируемый документ).
    /// Для ярлыка на файл размер и хеш станут известны только после запроса метаданных цели.
    var isDownloadable: Bool {
        if isFolder { return false }
        if isAlias && aliasTargetId == nil { return false }
        if isCloudDocument { return exportFormat != nil }
        return true
    }

    /// Имя локального файла (для экспортируемых документов добавляется расширение экспорта).
    var localFileName: String {
        let base = PathResolver.sanitize(name)
        if let format = exportFormat, !base.lowercased().hasSuffix("." + format.fileExtension) {
            return base + "." + format.fileExtension
        }
        return base
    }

    var routeKey: RouteKey { RouteKey(provider: provider, id: id) }
}

/// Ключ кастомного маршрута: пара (провайдер, ID объекта).
struct RouteKey: Sendable, Hashable {
    let provider: CloudProviderKind
    let id: String
}

// MARK: - Listing

/// Что показать в браузере / обойти.
enum CloudLocation: Sendable, Hashable {
    /// Корень личного пространства («Мой диск»).
    case root
    /// Содержимое папки; `spaceId` — пространство (общий диск), в котором она лежит.
    case folder(id: String, spaceId: String?)
    /// Объекты, которыми поделились с пользователем.
    case sharedWithMe
    /// Список общих пространств (общих дисков) в виде папок.
    case sharedSpaces
}

struct CloudPage: Sendable {
    let items: [CloudItem]
    let nextPageToken: String?
}

/// Ссылка на объект облака, разобранная из текста.
struct CloudLink: Sendable, Equatable {
    let id: String
    let accessKey: String?
}

struct CloudAccount: Sendable, Equatable {
    let displayName: String?
    let email: String?
}

/// Итог входа. `persistenceError` — вход действует, но не сохранён (до перезапуска).
struct CloudSignInResult: Sendable {
    var persistenceError: String?
}

// MARK: - Transfers

/// Подписанный запрос и учётные данные, с которыми он отправлен (для обновления после HTTP 401).
struct CloudAuthorizedRequest: Sendable {
    let request: URLRequest
    let credential: String
}

/// Ответ облака на часть файла или на запрос состояния сессии загрузки.
enum CloudUploadState: Sendable {
    /// Сервер подтвердил байты до `nextOffset` (не включительно).
    case incomplete(nextOffset: Int64)
    /// Файл загружен; `hash` — хеш содержимого по версии облака (тип — `CloudProviderKind.hashKind`).
    case complete(fileId: String, hash: String?)
    /// Сессия истекла — нужна новая с нуля.
    case expired
}

/// Классифицированная ошибка передачи: решает, повторять ли запрос и как.
enum CloudTransferError: Error, Sendable {
    /// HTTP 401: учётные данные нужно обновить и повторить запрос.
    case unauthorized(credential: String)
    case rateLimited(String)
    /// Квота на скачивание файла исчерпана — повтор через часы.
    case quotaExceeded(String)
    case transient(String)
    case fatal(String)
}

/// Ошибка запроса к API облака.
enum CloudAPIError: LocalizedError {
    case http(status: Int, message: String, provider: CloudProviderKind)
    case invalidResponse
    case uploadSessionMissing
    /// Сохранённый вход выдан без права записи.
    case insufficientScope
    /// В облаке закончилось место.
    case storageFull

    var errorDescription: String? {
        switch self {
        case .http(let code, let message, let provider): "\(provider.displayName) API: HTTP \(code) — \(message)"
        case .invalidResponse: String(localized: "Invalid server response")
        case .uploadSessionMissing: String(localized: "The server didn’t return an upload session URL")
        case .insufficientScope: String(localized: "Sign in to Google again to upload and edit files")
        case .storageFull: String(localized: "Google Drive is out of storage")
        }
    }

    var isTransient: Bool {
        if case .http(let code, let message, _) = self {
            return [429, 500, 502, 503, 504].contains(code) || (code == 403 && message.lowercased().contains("ratelimit"))
        }
        return false
    }
}
