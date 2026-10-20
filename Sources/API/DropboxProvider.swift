import Foundation
import UniformTypeIdentifiers

/// Dropbox (HTTP API v2) за протоколом `CloudProvider`.
///
/// Идентификаторы: файлы — `id:…` (стабильны при переименовании и перемещении), папки как цели
/// загрузки — пути (Dropbox сохраняет файл по пути). Объекты из общей ссылки несут саму ссылку
/// в `accessKey` и путь относительно её корня в `path`.
final class DropboxProvider: CloudProvider {
    let kind = CloudProviderKind.dropbox
    let api: DropboxAPIClient
    private let tokenManager: DropboxTokenManager

    var session: URLSession { api.session }
    var canSignIn: Bool { DropboxAppKey.bundled != nil }

    /// Тип содержимого папок в записях «Добавленные по ссылке».
    static let folderContentType = "folder"
    /// Префикс типа экспортируемых документов (Dropbox Paper и т. п.): дальше — значение export_format.
    static let exportContentTypePrefix = "application/vnd.dropbox-export."

    init(keychain: KeychainStore) {
        tokenManager = DropboxTokenManager(keychain: keychain)
        api = DropboxAPIClient(tokenManager: tokenManager)
    }

    // MARK: - Авторизация

    var hadSessionAtLaunch: Bool { tokenManager.hadTokensAtLaunch }

    func isSignedIn() async -> Bool { await tokenManager.isSignedIn }

    func signIn(openURL: @escaping @MainActor @Sendable (URL) -> Void) async throws -> CloudSignInResult {
        guard let appKey = DropboxAppKey.bundled else { throw DropboxAuthError.missingAppKey }
        let tokens = try await DropboxOAuth.signIn(appKey: appKey, openURL: openURL)
        await api.resetRoot()
        do {
            try await tokenManager.store(tokens)
            return CloudSignInResult()
        } catch {
            return CloudSignInResult(persistenceError: error.localizedDescription)
        }
    }

    func signOut() async {
        await tokenManager.signOut()
        await api.resetRoot()
    }

    func currentAccount() async throws -> CloudAccount {
        let account = try await api.currentAccount()
        return CloudAccount(displayName: account.name?.display_name, email: account.email)
    }

    func credentialLoadError() async -> String? { await tokenManager.keychainLoadError }

    func setAccessRevokedHandler(_ handler: @escaping @Sendable () -> Void) async {
        await tokenManager.setAccessRevokedHandler(handler)
    }

    func lacksWriteAccess() async -> Bool { false }

    func refreshAuthorization(after failedCredential: String) async throws {
        _ = try await tokenManager.refreshAfterUnauthorized(failedToken: failedCredential)
    }

    func isSignedOutError(_ error: Error) -> Bool {
        (error as? DropboxAuthError)?.meansSignedOut == true
    }

    // MARK: - Просмотр

    var rootFolder: UploadTarget { UploadTarget(provider: kind, id: "", name: "Dropbox", spaceId: nil) }

    func listPage(_ location: CloudLocation, pageToken: String?, stableOrder: Bool) async throws -> CloudPage {
        switch location {
        case .root:
            return try await listFolder(path: "", link: nil, pageToken: pageToken)
        case .folder(let id, _):
            return try await listFolder(path: id, link: nil, pageToken: pageToken)
        case .linkFolder(let url, let path):
            return try await listFolder(path: path, link: url, pageToken: pageToken)
        case .sharedWithMe:
            return try await sharedWithMePage(pageToken)
        case .sharedSpaces:
            // Командные папки видны в корне благодаря Dropbox-API-Path-Root.
            return CloudPage(items: [], nextPageToken: nil)
        }
    }

    /// /2/files/list_folder и /continue: пагинация по cursor пока has_more.
    private func listFolder(path: String, link: String?, pageToken: String?) async throws -> CloudPage {
        let data: Data
        if let pageToken {
            data = try await api.rpc("/files/list_folder/continue", ["cursor": pageToken], pathRoot: link == nil)
        } else {
            var arguments: [String: Any] = ["path": path, "limit": 2000, "include_non_downloadable_files": true]
            if let link { arguments["shared_link"] = ["url": link] }
            data = try await api.rpc("/files/list_folder", arguments, pathRoot: link == nil)
        }
        let result = try JSONDecoder().decode(DropboxListFolderResult.self, from: data)
        let items = result.entries.compactMap { entry -> CloudItem? in
            guard entry.tag != "deleted" else { return nil }
            let relative = link.map { _ in (path.isEmpty ? "" : path) + "/" + entry.name }
            return Self.cloudItem(entry, link: link, relativePath: relative)
        }
        return CloudPage(items: items, nextPageToken: result.has_more ? result.cursor : nil)
    }

    /// «Доступные мне»: общие папки (/2/sharing/list_folders, смонтированные и нет),
    /// затем файлы (/2/sharing/list_received_files). Токен: «f:<cursor>», «r:» или «r:<cursor>».
    private func sharedWithMePage(_ token: String?) async throws -> CloudPage {
        if token == nil || token?.hasPrefix("f:") == true {
            let data: Data
            if let cursor = token.map({ String($0.dropFirst(2)) }) {
                data = try await api.rpc("/sharing/list_folders/continue", ["cursor": cursor])
            } else {
                data = try await api.rpc("/sharing/list_folders", ["limit": 1000])
            }
            let list = try JSONDecoder().decode(DropboxSharedFolderList.self, from: data)
            // Свои папки, которыми пользователь поделился, и так лежат в его Dropbox.
            let items = list.entries.filter { $0.access_type?.tag != "owner" }.map(Self.cloudItem)
            return CloudPage(items: items, nextPageToken: list.cursor.map { "f:" + $0 } ?? "r:")
        }
        let data: Data
        let cursor = String(token?.dropFirst(2) ?? "")
        if cursor.isEmpty {
            data = try await api.rpc("/sharing/list_received_files", ["limit": 300])
        } else {
            data = try await api.rpc("/sharing/list_received_files/continue", ["cursor": cursor])
        }
        let list = try JSONDecoder().decode(DropboxReceivedFileList.self, from: data)
        return CloudPage(items: list.entries.compactMap(Self.cloudItem), nextPageToken: list.cursor.map { "r:" + $0 })
    }

    func location(of folder: CloudItem) -> CloudLocation {
        if let link = folder.accessKey { return .linkFolder(url: link, path: folder.path ?? "") }
        return .folder(id: folder.id, spaceId: nil)
    }

    func uploadTarget(for folder: CloudItem) -> UploadTarget {
        UploadTarget(provider: kind, id: folder.path ?? folder.id, name: folder.name, spaceId: nil)
    }

    /// Обычная папка — один рекурсивный листинг (recursive=true) с пагинацией;
    /// папка из общей ссылки — по папкам (Dropbox не обходит ссылки рекурсивно).
    func traverse(_ folder: CloudItem, resolvingAliases: Bool) -> AsyncStream<CloudTraversalEvent> {
        if folder.accessKey != nil { return walkFolders(folder, resolvingAliases: resolvingAliases) }
        let walker = DropboxRecursiveWalker(provider: self, root: folder)
        return AsyncStream(unfolding: { await walker.next() })
    }

    /// Первая или следующая страница рекурсивного листинга.
    fileprivate func recursivePage(path: String, cursor: String?) async throws -> DropboxListFolderResult {
        let data: Data
        if let cursor {
            data = try await api.rpc("/files/list_folder/continue", ["cursor": cursor])
        } else {
            data = try await api.rpc("/files/list_folder", ["path": path, "recursive": true, "limit": 2000,
                                                            "include_non_downloadable_files": true])
        }
        return try JSONDecoder().decode(DropboxListFolderResult.self, from: data)
    }

    fileprivate func metadata(path: String) async throws -> DropboxEntry {
        let data = try await api.rpc("/files/get_metadata", ["path": path])
        return try JSONDecoder().decode(DropboxEntry.self, from: data)
    }

    func item(id: String, accessKey: String?) async throws -> CloudItem {
        if let link = accessKey {
            let data = try await api.rpc("/sharing/get_shared_link_metadata", ["url": link], pathRoot: false)
            let entry = try JSONDecoder().decode(DropboxEntry.self, from: data)
            return Self.cloudItem(entry, link: entry.url ?? link, relativePath: "")
        }
        return Self.cloudItem(try await metadata(path: id), link: nil, relativePath: nil)
    }

    /// У Dropbox нет ярлыков.
    func resolveAlias(_ item: CloudItem) async throws -> CloudItem { item }

    func rememberAccessKey(_ key: String?, for id: String) {}

    /// www.dropbox.com/s/…, /scl/fi/…, /scl/fo/…, /sh/… и короткие db.tt.
    func parseLink(_ text: String) -> CloudLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'")))
        let urlString = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: urlString), let host = components.host?.lowercased(),
              host == "dropbox.com" || host.hasSuffix(".dropbox.com") || host == "db.tt",
              components.path.count > 1 else { return nil }
        return CloudLink(id: urlString, accessKey: urlString)
    }

    func webURL(forFolder id: String) -> URL? {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return URL(string: "https://www.dropbox.com/home" + encoded)
    }

    func linkRecord(for item: CloudItem) -> LinkedItem {
        LinkedItem(provider: kind, driveId: item.id, name: item.name,
                   mimeType: item.isFolder ? Self.folderContentType : (item.contentType ?? "application/octet-stream"),
                   resourceKey: item.accessKey, size: item.size, sharedDriveId: nil,
                   addedAt: Int64(Date().timeIntervalSince1970))
    }

    func item(fromLinked record: LinkedItem) -> CloudItem {
        var item = CloudItem(provider: kind, id: record.driveId, name: record.name,
                             isFolder: record.mimeType == Self.folderContentType)
        item.path = ""
        item.size = record.size
        item.contentType = item.isFolder ? nil : record.mimeType
        item.accessKey = record.resourceKey
        item.permissions = Self.readOnly
        if !item.isFolder, let format = Self.exportFormat(forContentType: record.mimeType) {
            item.documentType = .document
            item.exportFormat = format
        }
        return item
    }

    // MARK: - Скачивание

    func downloadRequest(for task: DownloadTask, offset: Int64) async throws -> CloudAuthorizedRequest {
        var authorized: CloudAuthorizedRequest
        if let link = task.resourceKey {
            // Объект из общей ссылки: /2/sharing/get_shared_link_file (url + путь внутри ссылки).
            var argument: [String: Any] = ["url": link]
            if let path = task.cloudPath, !path.isEmpty { argument["path"] = path }
            authorized = try await api.contentRequest("/sharing/get_shared_link_file", argument: argument, pathRoot: false)
        } else if let export = task.exportFormat {
            authorized = try await api.contentRequest("/files/export", argument: ["path": task.driveFileId,
                                                                                  "export_format": export.mimeType])
        } else {
            authorized = try await api.contentRequest("/files/download", argument: ["path": task.driveFileId])
        }
        var request = authorized.request
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        authorized = CloudAuthorizedRequest(request: request, credential: authorized.credential)
        return authorized
    }

    func downloadFailure(_ response: HTTPURLResponse, body: Data, task: DownloadTask, credential: String) -> CloudTransferError {
        let summary = DropboxAPIClient.errorSummary(body)
        let message = "HTTP \(response.statusCode): \(summary)"
        switch response.statusCode {
        case 401:
            return .unauthorized(credential: credential)
        case 429:
            return .rateLimited(String(localized: "Dropbox rate-limited requests (HTTP 429)"),
                                retryAfter: DropboxAPIClient.retryAfter(response))
        case 409 where summary.contains("not_found"):
            return .fatal(String(localized: "File not found or no access (HTTP 404)"))
        case 409 where summary.contains("restricted_content") || summary.contains("access_denied")
                       || summary.contains("unsupported_file") || summary.contains("non_exportable"):
            return .fatal(DownloadTask.downloadForbiddenMessage)
        case 500, 502, 503, 504:
            return .transient(message)
        default:
            return .fatal("Dropbox: \(message)")
        }
    }

    // MARK: - Загрузка сессиями (upload_session)

    /// 32 МБ — кратно 4 МБ и меньше предела Dropbox в 150 МБ на запрос.
    let uploadChunkSize: Int64 = 32 * 1_048_576
    /// Dropbox держит сессию 7 дней; старше 6 дней — новая.
    let uploadSessionLifetime: TimeInterval = 6 * 24 * 3600

    func startUploadSession(for task: UploadTask) async throws -> String {
        struct Started: Decodable { let session_id: String }
        let (data, http, token) = try await api.upload("/files/upload_session/start", argument: ["close": false],
                                                       body: Data(), delegate: nil)
        guard (200..<300).contains(http.statusCode) else {
            throw uploadError(http, data: data, token: token)
        }
        guard let started = try? JSONDecoder().decode(Started.self, from: data) else {
            throw CloudAPIError.uploadSessionMissing
        }
        return started.session_id
    }

    /// Сколько принял сервер: пустая часть по сохранённому смещению — Dropbox либо принимает её,
    /// либо отвечает incorrect_offset с верным смещением. Если приняты все байты — фиксация файла.
    func uploadState(session: String, task: UploadTask) async throws -> CloudUploadState {
        let probe = try await append(Data(), at: min(task.uploadedBytes, task.fileSize), session: session, delegate: nil)
        guard case .incomplete(let offset) = probe else { return probe }
        if offset >= task.fileSize {
            return try await finish(Data(), at: task.fileSize, session: session, task: task, delegate: nil)
        }
        return probe
    }

    func uploadChunk(_ data: Data, at offset: Int64, session: String, task: UploadTask,
                     delegate: (any URLSessionTaskDelegate)?) async throws -> CloudUploadState {
        // Последняя часть отправляется вместе с фиксацией файла (upload_session/finish).
        if offset + Int64(data.count) >= task.fileSize {
            return try await finish(data, at: offset, session: session, task: task, delegate: delegate)
        }
        return try await append(data, at: offset, session: session, delegate: delegate)
    }

    /// У Dropbox нет отмены сессии: незавершённая сессия истекает сама.
    func cancelUploadSession(_ session: String) async {}

    private func append(_ data: Data, at offset: Int64, session: String,
                        delegate: (any URLSessionTaskDelegate)?) async throws -> CloudUploadState {
        let argument: [String: Any] = ["cursor": ["session_id": session, "offset": offset], "close": false]
        let (body, http, token) = try await api.upload("/files/upload_session/append_v2", argument: argument,
                                                       body: data, delegate: delegate)
        if (200..<300).contains(http.statusCode) { return .incomplete(nextOffset: offset + Int64(data.count)) }
        if let state = sessionState(http, data: body) { return state }
        throw uploadError(http, data: body, token: token)
    }

    private func finish(_ data: Data, at offset: Int64, session: String, task: UploadTask,
                        delegate: (any URLSessionTaskDelegate)?) async throws -> CloudUploadState {
        let parent = task.parentDriveId == "/" ? "" : task.parentDriveId
        let argument: [String: Any] = [
            "cursor": ["session_id": session, "offset": offset],
            "commit": ["path": parent + "/" + task.fileName,
                       // Новая версия существующего файла — перезапись, иначе — только новый файл.
                       "mode": task.replaceFileId == nil ? "add" : "overwrite",
                       "autorename": false, "mute": false],
        ]
        let (body, http, token) = try await api.upload("/files/upload_session/finish", argument: argument,
                                                       body: data, delegate: delegate)
        if (200..<300).contains(http.statusCode) {
            guard let entry = try? JSONDecoder().decode(DropboxEntry.self, from: body), let id = entry.id else {
                throw CloudAPIError.invalidResponse
            }
            return .complete(fileId: id, hash: entry.content_hash)
        }
        if let state = sessionState(http, data: body) { return state }
        throw uploadError(http, data: body, token: token)
    }

    /// 409 incorrect_offset → верное смещение; сессия не найдена или закрыта → истекла.
    private func sessionState(_ http: HTTPURLResponse, data: Data) -> CloudUploadState? {
        guard http.statusCode == 409 else { return nil }
        let summary = DropboxAPIClient.errorSummary(data)
        if summary.contains("incorrect_offset"),
           let correct = DropboxAPIClient.findValue("correct_offset", in: data) as? NSNumber {
            return .incomplete(nextOffset: correct.int64Value)
        }
        if summary.contains("lookup_failed/not_found") || summary.hasPrefix("not_found")
            || summary.contains("closed") || summary.contains("too_large") {
            return .expired
        }
        return nil
    }

    private func uploadError(_ http: HTTPURLResponse, data: Data, token: String) -> Error {
        let summary = DropboxAPIClient.errorSummary(data)
        switch http.statusCode {
        case 401:
            return CloudTransferError.unauthorized(credential: token)
        case 429:
            return CloudTransferError.rateLimited(String(localized: "Dropbox rate-limited requests (HTTP 429)"),
                                                  retryAfter: DropboxAPIClient.retryAfter(http))
        case 409 where summary.contains("insufficient_space"):
            return CloudTransferError.fatal(String(localized: "Dropbox is out of storage"))
        case 409 where summary.contains("no_write_permission"):
            return CloudTransferError.fatal(String(localized: "You don’t have permission to upload to this folder"))
        case 500, 502, 503, 504:
            return CloudTransferError.transient(String(localized: "Dropbox server is temporarily unavailable (HTTP \(http.statusCode))"))
        default:
            return CloudTransferError.fatal("Dropbox API: HTTP \(http.statusCode) — \(summary)")
        }
    }

    // MARK: - Изменение

    private struct MetadataResult: Decodable { let metadata: DropboxEntry }

    private static func join(_ parent: String, _ name: String) -> String {
        (parent == "/" ? "" : parent) + "/" + name
    }

    func createFolder(named name: String, in parent: UploadTarget) async throws -> CloudItem {
        let data = try await api.rpc("/files/create_folder_v2", ["path": Self.join(parent.id, name), "autorename": false])
        return Self.cloudItem(try JSONDecoder().decode(MetadataResult.self, from: data).metadata, link: nil,
                              relativePath: nil, forceFolder: true)
    }

    func rename(_ item: CloudItem, to name: String) async throws -> CloudItem {
        let parent = ((item.path ?? "/") as NSString).deletingLastPathComponent
        let data = try await api.rpc("/files/move_v2", ["from_path": item.id, "to_path": Self.join(parent, name),
                                                        "autorename": false])
        return Self.cloudItem(try JSONDecoder().decode(MetadataResult.self, from: data).metadata, link: nil, relativePath: nil)
    }

    func move(_ item: CloudItem, to parent: UploadTarget) async throws {
        _ = try await api.rpc("/files/move_v2", ["from_path": item.id, "to_path": Self.join(parent.id, item.name),
                                                 "autorename": false])
    }

    /// Удалённое в Dropbox восстанавливается из «Удалённых файлов» — это и есть корзина.
    func trash(_ item: CloudItem) async throws {
        _ = try await api.rpc("/files/delete_v2", ["path": item.id])
    }

    // MARK: - Преобразование

    static let readOnly = CloudPermissions(canDownload: true, canAddChildren: false, canRename: false,
                                           canTrash: false, canMove: false)

    /// - Parameters:
    ///   - link: общая ссылка, если объект открыт через неё.
    ///   - relativePath: путь внутри ссылки.
    ///   - forceFolder: ответ без `.tag`, про который известно, что это папка (create_folder_v2).
    static func cloudItem(_ entry: DropboxEntry, link: String?, relativePath: String?, forceFolder: Bool = false) -> CloudItem {
        let isFolder = forceFolder || entry.tag == "folder"
        let fallbackId = link.map { $0 + (relativePath ?? "") } ?? entry.name
        var item = CloudItem(provider: .dropbox, id: entry.id ?? entry.path_lower ?? fallbackId, name: entry.name,
                             isFolder: isFolder)
        item.path = link != nil ? (relativePath ?? "") : (entry.path_display ?? entry.path_lower)
        item.size = entry.size
        item.modifiedAt = entry.server_modified.flatMap(DriveDate.parse)
        item.hash = entry.content_hash.map { CloudHash(kind: .dropboxContentHash, value: $0) }
        item.accessKey = link
        if link != nil || entry.sharing_info?.read_only == true { item.permissions = readOnly }
        if !isFolder {
            let ext = (entry.name as NSString).pathExtension
            item.contentType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            if entry.is_downloadable == false {
                // Dropbox Paper и другие документы без файла: экспорт, если Dropbox его предлагает.
                let options = entry.export_info?.export_options ?? []
                let format = options.contains("docx") ? "docx"
                    : options.contains("markdown") ? "markdown" : entry.export_info?.export_as
                if let format {
                    item.contentType = exportContentTypePrefix + format
                    item.documentType = .document
                    item.exportFormat = exportFormat(forContentType: item.contentType ?? "")
                } else {
                    item.documentType = .other
                }
            }
        }
        return item
    }

    /// Общая папка: смонтированная — обычная папка по пути, несмонтированная — через её ссылку.
    static func cloudItem(_ folder: DropboxSharedFolder) -> CloudItem {
        var item = CloudItem(provider: .dropbox, id: folder.path_lower ?? "ns:" + folder.shared_folder_id,
                             name: folder.name, isFolder: true)
        item.spaceId = folder.shared_folder_id
        if let path = folder.path_lower {
            item.path = path
            if folder.access_type?.tag == "viewer" || folder.access_type?.tag == "viewer_no_comment" {
                item.permissions = readOnly
            }
        } else {
            item.accessKey = folder.preview_url
            item.path = ""
            item.permissions = readOnly
        }
        return item
    }

    /// Файл, которым поделились: скачивается через его ссылку (размер до скачивания неизвестен).
    static func cloudItem(_ file: DropboxReceivedFile) -> CloudItem? {
        guard let url = file.preview_url else { return nil }
        var item = CloudItem(provider: .dropbox, id: file.id, name: file.name, isFolder: false)
        item.accessKey = url
        item.path = ""
        item.permissions = readOnly
        item.modifiedAt = file.time_invited.flatMap(DriveDate.parse)
        item.contentType = UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType
        return item
    }

    /// `application/vnd.dropbox-export.<export_format>` → формат и расширение файла.
    static func exportFormat(forContentType contentType: String) -> CloudExportFormat? {
        guard contentType.hasPrefix(exportContentTypePrefix) else { return nil }
        let format = String(contentType.dropFirst(exportContentTypePrefix.count))
        guard !format.isEmpty else { return nil }
        let fileExtension = switch format {
        case "markdown": "md"
        default: format
        }
        return CloudExportFormat(mimeType: format, fileExtension: fileExtension)
    }
}

/// Рекурсивный листинг (recursive=true) → события обхода по папкам.
///
/// Dropbox отдаёт записи всего поддерева плоским списком. Записи группируются по родительской папке
/// (по path_lower), а запись, чья папка ещё не встретилась, ждёт её: страница папки всегда идёт
/// после страницы её родителя. Пустые папки получают пустую страницу в конце обхода.
private actor DropboxRecursiveWalker {
    private let provider: DropboxProvider
    private let root: CloudItem
    private var started = false
    private var finished = false
    private var cursor: String?
    private var rootLower = ""
    /// path_lower → ID уже выданной папки.
    private var folderIds: [String: String] = [:]
    /// path_lower родителя → записи, ждущие появления этой папки.
    private var waiting: [String: [(item: CloudItem, lower: String)]] = [:]
    private var discovered: [String] = []
    private var paged: Set<String> = []
    private var output: [CloudTraversalEvent] = []

    init(provider: DropboxProvider, root: CloudItem) {
        self.provider = provider
        self.root = root
    }

    func next() async -> CloudTraversalEvent? {
        while true {
            if !output.isEmpty { return output.removeFirst() }
            if finished || Task.isCancelled { return nil }
            let result: DropboxListFolderResult
            do {
                if !started {
                    started = true
                    rootLower = try await provider.metadata(path: root.id).path_lower ?? (root.path ?? "").lowercased()
                    folderIds[rootLower] = root.targetId
                    discovered.append(root.targetId)
                }
                result = try await provider.recursivePage(path: root.id, cursor: cursor)
            } catch {
                finished = true
                output.append(.folderFailed(folderId: root.targetId, error: error))
                continue
            }
            for entry in result.entries where entry.tag != "deleted" {
                guard let lower = entry.path_lower, lower != rootLower else { continue }
                let item = DropboxProvider.cloudItem(entry, link: nil, relativePath: nil)
                place(item, lower: lower)
            }
            if result.has_more {
                cursor = result.cursor
            } else {
                finished = true
                for id in discovered where !paged.contains(id) {
                    output.append(.page(folderId: id, items: []))
                }
            }
        }
    }

    private func place(_ item: CloudItem, lower: String) {
        let parent = (lower as NSString).deletingLastPathComponent
        guard let parentId = folderIds[parent] else {
            waiting[parent, default: []].append((item, lower))
            return
        }
        if case .page(let folderId, var items) = output.last, folderId == parentId {
            items.append(item)
            output[output.count - 1] = .page(folderId: folderId, items: items)
        } else {
            output.append(.page(folderId: parentId, items: [item]))
        }
        paged.insert(parentId)
        guard item.isFolder else { return }
        folderIds[lower] = item.targetId
        discovered.append(item.targetId)
        for child in waiting.removeValue(forKey: lower) ?? [] {
            place(child.item, lower: child.lower)
        }
    }
}
