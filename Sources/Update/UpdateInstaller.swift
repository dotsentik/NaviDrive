import Foundation
import os
import Security

/// Ошибки обновления, понятные пользователю.
enum UpdateError: LocalizedError {
    case core(UpdateCoreError)
    case network(String)
    case http(Int)
    case rateLimited
    case notConfigured
    case redirectRejected
    case mountFailed
    case appNotFoundInImage
    case signatureInvalid
    case versionMismatch(found: String, expected: String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .core(.malformedRelease):
            String(localized: "GitHub returned an unexpected release description.")
        case .core(.unsupportedTag(let tag)):
            String(localized: "The latest release tag “\(tag)” is not a version number.")
        case .core(.missingAsset(let name)):
            String(localized: "The release has no file \(name).")
        case .core(.insecureURL), .redirectRejected:
            String(localized: "The download link points outside GitHub. The update was rejected.")
        case .core(.tooLarge):
            String(localized: "The update file is too large.")
        case .core(.malformedChecksum):
            String(localized: "The checksum file of the release is invalid.")
        case .core(.checksumMismatch):
            String(localized: "The downloaded file is damaged: its SHA-256 checksum doesn’t match. The file was deleted.")
        case .network(let message):
            message
        case .http(let status):
            String(localized: "GitHub responded with HTTP \(status).")
        case .rateLimited:
            String(localized: "GitHub request limit reached. Try again in an hour.")
        case .notConfigured:
            String(localized: "This copy of NaviDrive doesn’t know where to look for updates.")
        case .mountFailed:
            String(localized: "Couldn’t open the downloaded disk image.")
        case .appNotFoundInImage:
            String(localized: "NaviDrive.app was not found in the disk image.")
        case .signatureInvalid:
            String(localized: "The new version is not signed with the same certificate as this copy. Nothing was installed.")
        case .versionMismatch(let found, let expected):
            String(localized: "The disk image contains version \(found) instead of \(expected). Nothing was installed.")
        case .installFailed(let message):
            message
        }
    }
}

enum UpdateLog {
    static let logger = Logger(subsystem: "com.navidrive.NaviDrive", category: "update")
}

// MARK: - Сеть

/// Сессии без cookies и кеша; на каждый редирект — проверка хоста по `UpdatePolicy.allowedHosts`.
/// Заголовки: только User-Agent «NaviDrive/<версия>» (и If-None-Match для ETag).
enum UpdateNetwork {
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return configuration
    }

    static var userAgent: String { "NaviDrive/\(Bundle.main.shortVersion)" }

    enum LatestResult: Sendable {
        case notModified
        case fetched(data: Data, etag: String?)
    }

    static func fetchLatestRelease(repo: String, etag: String?) async throws -> LatestResult {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest"),
              UpdatePolicy.isAllowed(url) else { throw UpdateError.notConfigured }
        var request = URLRequest(url: url)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let session = URLSession(configuration: makeConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: RedirectGuard())
        } catch let error as URLError where error.code == .cancelled {
            throw UpdateError.redirectRejected
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, UpdatePolicy.isAllowed(http.url) else {
            throw UpdateError.redirectRejected
        }
        switch http.statusCode {
        case 200:
            return .fetched(data: data, etag: http.value(forHTTPHeaderField: "ETag"))
        case 304:
            return .notModified
        case 403, 429:
            throw http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || http.statusCode == 429
                ? UpdateError.rateLimited : UpdateError.http(http.statusCode)
        case 404:
            // Релизов ещё нет.
            return .fetched(data: Data(), etag: nil)
        default:
            throw UpdateError.http(http.statusCode)
        }
    }

    /// Маленький файл (.sha256) в память, не больше `limit` байт.
    static func fetchSmallFile(_ url: URL, limit: Int) async throws -> Data {
        guard UpdatePolicy.isAllowed(url) else { throw UpdateError.redirectRejected }
        let session = URLSession(configuration: makeConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: URLRequest(url: url), delegate: RedirectGuard())
        } catch let error as URLError where error.code == .cancelled {
            throw UpdateError.redirectRejected
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, UpdatePolicy.isAllowed(http.url) else {
            throw UpdateError.redirectRejected
        }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        guard data.count <= limit else { throw UpdateError.core(.malformedChecksum) }
        return data
    }

    /// DMG — сразу в файл `destination` (через временный файл URLSession), с прогрессом и пределом размера.
    static func download(_ url: URL, to destination: URL, maxBytes: Int64,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard UpdatePolicy.isAllowed(url) else { throw UpdateError.redirectRejected }
        let delegate = FileDownloadDelegate(destination: destination, maxBytes: maxBytes, progress: progress)
        let session = URLSession(configuration: makeConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(session.downloadTask(with: url), continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// Редирект только на разрешённый хост по HTTPS; иначе запрос отменяется.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard UpdatePolicy.isAllowed(request.url) else {
            UpdateLog.logger.error("Redirect to a disallowed host rejected: \(request.url?.host ?? "?", privacy: .public)")
            task.cancel()
            return nil
        }
        return request
    }
}

private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State: @unchecked Sendable {
        var task: URLSessionDownloadTask?
        var continuation: CheckedContinuation<Void, Error>?
        var failure: UpdateError?
        var finished = false
    }

    private let destination: URL
    private let maxBytes: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(destination: URL, maxBytes: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.maxBytes = maxBytes
        self.progress = progress
    }

    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
        state.withLock {
            $0.task = task
            $0.continuation = continuation
        }
        task.resume()
    }

    func cancel() {
        let task = state.withLock { $0.task }
        task?.cancel()
    }

    private func fail(_ error: UpdateError, task: URLSessionTask) {
        state.withLock { if $0.failure == nil { $0.failure = error } }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard UpdatePolicy.isAllowed(request.url) else {
            UpdateLog.logger.error("Redirect to a disallowed host rejected: \(request.url?.host ?? "?", privacy: .public)")
            fail(.redirectRejected, task: task)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            fail(.core(.tooLarge), task: downloadTask)
            return
        }
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let failure: UpdateError?
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = .http(http.statusCode)
        } else if !UpdatePolicy.isAllowed(downloadTask.response?.url) {
            failure = .redirectRejected
        } else if let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value,
                  size > maxBytes {
            failure = .core(.tooLarge)
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                failure = nil
            } catch {
                failure = .installFailed(error.localizedDescription)
            }
        }
        state.withLock {
            if let failure, $0.failure == nil { $0.failure = failure }
            if failure == nil { $0.finished = true }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure, finished) = state.withLock { state in
            defer { state.continuation = nil }
            return (state.continuation, state.failure, state.finished)
        }
        guard let continuation else { return }
        if let failure {
            continuation.resume(throwing: failure)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: UpdateError.network(error.localizedDescription))
            }
        } else if finished {
            continuation.resume()
        } else {
            continuation.resume(throwing: UpdateError.network(String(localized: "The download ended unexpectedly.")))
        }
    }
}

// MARK: - Проверка DMG и установка

enum UpdateInstaller {
    /// Временная папка обновлений: только для владельца (0700).
    static func workDirectory() throws -> URL {
        let url = workDirectoryURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true || !isDirectory.boolValue {
                try FileManager.default.removeItem(at: url)
            }
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw UpdateError.installFailed(String(localized: "The temporary update folder belongs to another user."))
        }
        return url
    }

    private static var workDirectoryURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("com.navidrive.NaviDrive.update", isDirectory: true)
    }

    static let helperLogName = "replace.log"

    /// Этапы вспомогательного процесса прошлого обновления — в os_log.
    static func forwardHelperLog() {
        let url = workDirectoryURL.appendingPathComponent(helperLogName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            UpdateLog.logger.info("Replacement helper: \(line, privacy: .public)")
        }
    }

    /// Остатки прошлых обновлений (DMG, точки монтирования, журнал вспомогательного процесса).
    static func cleanUpWorkDirectory() {
        try? FileManager.default.removeItem(at: workDirectoryURL)
    }

    // MARK: Место установки

    enum Location {
        case writable(appURL: URL)
        case readOnly
    }

    /// Запуск из DMG, App Translocation или из папки без права записи — обновляться на месте нельзя.
    static func currentLocation() -> Location {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let parent = appURL.deletingLastPathComponent()
        if appURL.path.contains("/AppTranslocation/") { return .readOnly }
        if let values = try? appURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]), values.volumeIsReadOnly == true {
            return .readOnly
        }
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: appURL.path) else { return .readOnly }
        return .writable(appURL: appURL)
    }

    // MARK: DMG

    struct MountedImage {
        let mountPoint: URL
    }

    static func mount(_ dmg: URL, under directory: URL) throws -> MountedImage {
        let mountRoot = directory.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let output = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen",
                                                  "-plist", "-mountrandom", mountRoot.path, dmg.path])
        guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.mountFailed
        }
        UpdateLog.logger.info("Update image mounted")
        return MountedImage(mountPoint: URL(fileURLWithPath: mountPath, isDirectory: true))
    }

    static func detach(_ image: MountedImage) {
        if (try? run("/usr/bin/hdiutil", ["detach", image.mountPoint.path, "-quiet"])) == nil {
            _ = try? run("/usr/bin/hdiutil", ["detach", image.mountPoint.path, "-quiet", "-force"])
        }
    }

    /// NaviDrive.app в корне образа — настоящая папка, не ссылка.
    static func appInImage(_ image: MountedImage) throws -> URL {
        let app = image.mountPoint.appendingPathComponent("NaviDrive.app", isDirectory: true)
        guard let values = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              values.isSymbolicLink == false, values.isDirectory == true else {
            throw UpdateError.appNotFoundInImage
        }
        return app
    }

    /// Подпись новой копии проверяется требованием designated requirement запущенной копии:
    /// принимается только приложение с тем же идентификатором и тем же сертификатом.
    static func verifySignature(of appURL: URL) throws {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { throw UpdateError.signatureInvalid }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else {
            throw UpdateError.signatureInvalid
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.signatureInvalid
        }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError.signatureInvalid
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(newCode, flags, requirement)
        guard status == errSecSuccess else {
            UpdateLog.logger.error("Update signature check failed: \(status, privacy: .public)")
            throw UpdateError.signatureInvalid
        }
        UpdateLog.logger.info("Update signature verified")
    }

    static func bundleVersion(of appURL: URL) -> String? {
        let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        return plist?["CFBundleShortVersionString"] as? String
    }

    /// Версия в образе = версия тега и выше текущей.
    static func verifyVersion(of appURL: URL, expected: SemanticVersion, current: SemanticVersion) throws {
        let found = bundleVersion(of: appURL) ?? "?"
        guard let version = SemanticVersion(found), version == expected, version > current else {
            throw UpdateError.versionMismatch(found: found, expected: expected.description)
        }
    }

    /// Копия нового .app рядом с текущим (тот же том — замена переименованием). Подпись копии проверяется ещё раз.
    static func stage(_ newApp: URL, nextTo currentApp: URL, version: SemanticVersion) throws -> URL {
        let staged = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".NaviDrive.app.update-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try run("/usr/bin/ditto", [newApp.path, staged.path])
            try verifySignature(of: staged)
            try verifyVersion(of: staged, expected: version, current: Bundle.main.semanticVersion)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        UpdateLog.logger.info("Update staged next to the current app")
        return staged
    }

    // MARK: Замена после выхода

    /// Вспомогательный процесс: ждёт выхода NaviDrive по PID, переименовывает старую копию в NaviDrive.app.old,
    /// ставит новую, запускает её; при успешном запуске удаляет .old, иначе возвращает старую копию.
    /// Этапы пишет в `helperLogName` (из shell в os_log не попасть); запущенная после замены копия
    /// пересылает их в os_log — `forwardHelperLog()`.
    private static let helperScript = #"""
    #!/bin/sh
    PID="$1"; APP="$2"; NEW="$3"; LOG="$4"; OLD="$2.old"
    log() { printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
    restore() {
        log "restoring the previous version"
        [ -e "$APP" ] && /bin/rm -rf "$APP"
        /bin/mv "$OLD" "$APP" && /usr/bin/open "$APP"
    }
    log "waiting for NaviDrive (pid $PID) to quit"
    i=0
    while /bin/kill -0 "$PID" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 600 ]; then log "NaviDrive did not quit, update cancelled"; /bin/rm -rf "$NEW"; exit 1; fi
        /bin/sleep 0.2
    done
    [ -e "$OLD" ] && /bin/rm -rf "$OLD"
    if ! /bin/mv "$APP" "$OLD"; then
        log "could not move the old version aside, update cancelled"
        /bin/rm -rf "$NEW"; /usr/bin/open "$APP"; exit 1
    fi
    if ! /bin/mv "$NEW" "$APP"; then
        log "could not put the new version in place"
        /bin/mv "$OLD" "$APP"; /bin/rm -rf "$NEW"; /usr/bin/open "$APP"; exit 1
    fi
    log "new version installed, launching"
    if /usr/bin/open "$APP"; then
        j=0
        while [ "$j" -lt 30 ]; do
            if /usr/bin/pgrep -x NaviDrive >/dev/null 2>&1; then
                /bin/rm -rf "$OLD"
                log "new version launched, previous version removed"
                exit 0
            fi
            j=$((j + 1)); /bin/sleep 0.5
        done
    fi
    log "new version failed to launch"
    restore
    exit 1
    """#

    /// Запуск вспомогательного процесса; после этого приложение должно завершиться.
    static func launchReplacementHelper(appURL: URL, stagedURL: URL, workDirectory: URL) throws {
        let script = workDirectory.appendingPathComponent("replace.sh")
        try? FileManager.default.removeItem(at: script)
        guard FileManager.default.createFile(atPath: script.path, contents: Data(helperScript.utf8),
                                             attributes: [.posixPermissions: 0o700]) else {
            throw UpdateError.installFailed(String(localized: "Couldn’t prepare the installer."))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(getpid()), appURL.path, stagedURL.path,
                             workDirectory.appendingPathComponent(helperLogName).path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
        UpdateLog.logger.info("Replacement helper started (pid \(process.processIdentifier, privacy: .public))")
    }

    /// Запуск системной утилиты по полному пути, без оболочки. Возвращает stdout.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            UpdateLog.logger.error("\(tool, privacy: .public) exited with \(process.terminationStatus, privacy: .public)")
            throw UpdateError.installFailed(String(localized: "A system tool failed while installing the update."))
        }
        return data
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var semanticVersion: SemanticVersion { SemanticVersion(shortVersion) ?? SemanticVersion("0")! }
}
