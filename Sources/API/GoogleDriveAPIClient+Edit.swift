import Foundation
import UniformTypeIdentifiers

/// Изменение диска и resumable upload (Drive API v3, supportsAllDrives=true).
extension GoogleDriveAPIClient {
    // MARK: - Folders, rename, move, trash

    private func fileURL(_ id: String, query: [URLQueryItem] = []) -> URL? {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var components = URLComponents(string: "\(Self.baseURL)/files/\(encodedId)")!
        components.queryItems = [URLQueryItem(name: "supportsAllDrives", value: "true"),
                                 URLQueryItem(name: "fields", value: Self.itemFields)] + query
        return components.url
    }

    func createFolder(name: String, parentId: String) async throws -> DriveItem {
        var components = URLComponents(string: "\(Self.baseURL)/files")!
        components.queryItems = [URLQueryItem(name: "supportsAllDrives", value: "true"),
                                 URLQueryItem(name: "fields", value: Self.itemFields)]
        guard let url = components.url else { throw CloudAPIError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name, "mimeType": DriveItem.folderMimeType, "parents": [parentId],
        ])
        let (data, _) = try await send {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        return try JSONDecoder().decode(DriveItem.self, from: data)
    }

    func rename(id: String, to name: String) async throws -> DriveItem {
        guard let url = fileURL(id) else { throw CloudAPIError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, _) = try await send {
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        return try JSONDecoder().decode(DriveItem.self, from: data)
    }

    /// Перемещение: новый родитель добавляется, все текущие — снимаются.
    func move(id: String, to parentId: String) async throws {
        struct Parents: Decodable { let parents: [String]? }
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let parentsURL = URL(string: "\(Self.baseURL)/files/\(encodedId)?fields=parents&supportsAllDrives=true") else {
            throw CloudAPIError.invalidResponse
        }
        let (parentsData, _) = try await send { URLRequest(url: parentsURL) }
        let current = (try JSONDecoder().decode(Parents.self, from: parentsData).parents ?? []).filter { $0 != parentId }
        var query = [URLQueryItem(name: "addParents", value: parentId)]
        if !current.isEmpty { query.append(URLQueryItem(name: "removeParents", value: current.joined(separator: ","))) }
        guard let url = fileURL(id, query: query) else { throw CloudAPIError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: [String: Any]())
        _ = try await send {
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
    }

    /// В корзину (не окончательное удаление).
    func trash(id: String) async throws {
        guard let url = fileURL(id) else { throw CloudAPIError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: ["trashed": true])
        _ = try await send {
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
    }

    /// Имена дочерних объектов папки (для проверки конфликтов имён перед отправкой).
    func children(of folderId: String, driveId: String?) async throws -> [DriveItem] {
        try await listAll(.children(of: folderId, driveId: driveId))
    }

    // MARK: - Resumable upload

    /// Ответ сервера на часть файла или на запрос состояния сессии.
    enum ResumableState: Sendable {
        /// 308: сервер подтвердил байты до `nextOffset` (не включительно).
        case incomplete(nextOffset: Int64)
        /// 200/201: файл загружен.
        case complete(fileId: String, md5: String?)
        /// 404/410: сессия истекла — нужна новая с нуля.
        case expired
    }

    static let uploadResultFields = "id,md5Checksum,size"

    static func mimeType(forFileName name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// POST (новый файл) или PATCH (новая версия существующего файла) — создаёт сессию и возвращает session URI.
    func startUploadSession(name: String, parentId: String, size: Int64, replaceFileId: String?) async throws -> URL {
        let mime = Self.mimeType(forFileName: name)
        let url: URL
        let method: String
        let metadata: [String: Any]
        if let replaceFileId {
            let encodedId = replaceFileId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? replaceFileId
            url = URL(string: "\(Self.uploadURL)/\(encodedId)?uploadType=resumable&supportsAllDrives=true&fields=\(Self.uploadResultFields)")!
            method = "PATCH"
            metadata = ["mimeType": mime]
        } else {
            url = URL(string: "\(Self.uploadURL)?uploadType=resumable&supportsAllDrives=true&fields=\(Self.uploadResultFields)")!
            method = "POST"
            metadata = ["name": name, "parents": [parentId], "mimeType": mime]
        }
        let body = try JSONSerialization.data(withJSONObject: metadata)
        let (_, response) = try await send {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
            request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            request.httpBody = body
            return request
        }
        guard let location = response.value(forHTTPHeaderField: "Location"), let sessionURL = URL(string: location) else {
            throw CloudAPIError.uploadSessionMissing
        }
        return sessionURL
    }

    /// Запрос к session URI с токеном. Ответ не интерпретируется — это делает `resumableState`.
    func sessionRequest(_ sessionURI: URL, contentRange: String, body: Data?,
                        delegate: URLSessionTaskDelegate?) async throws -> (Data, HTTPURLResponse, String) {
        let token = try await tokenManager.validAccessToken()
        var request = URLRequest(url: sessionURI)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentRange, forHTTPHeaderField: "Content-Range")
        request.setValue(String(body?.count ?? 0), forHTTPHeaderField: "Content-Length")
        let (data, response): (Data, URLResponse)
        if let body, !body.isEmpty {
            (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.invalidResponse }
        return (data, http, token)
    }

    /// 308 → подтверждённый сервером край (заголовок Range «bytes=0-N»); 200/201 → готово; 404/410 → сессия истекла.
    /// Остальные коды — nil (их разбирает вызывающий код).
    static func resumableState(_ data: Data, _ http: HTTPURLResponse) -> ResumableState? {
        switch http.statusCode {
        case 308:
            guard let range = http.value(forHTTPHeaderField: "Range"),
                  let last = range.split(separator: "-").last.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }) else {
                return .incomplete(nextOffset: 0)
            }
            return .incomplete(nextOffset: last + 1)
        case 200, 201:
            struct Result: Decodable { let id: String; let md5Checksum: String? }
            guard let result = try? JSONDecoder().decode(Result.self, from: data) else { return nil }
            return .complete(fileId: result.id, md5: result.md5Checksum)
        case 404, 410:
            return .expired
        default:
            return nil
        }
    }

    /// Отмена сессии загрузки (лучшее усилие; ошибки неважны).
    func cancelUploadSession(_ sessionURI: URL) async {
        guard let token = try? await tokenManager.validAccessToken() else { return }
        var request = URLRequest(url: sessionURI)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        _ = try? await session.data(for: request)
    }
}
