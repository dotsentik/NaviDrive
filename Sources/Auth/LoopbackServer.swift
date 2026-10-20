import Foundation
import Network

/// Временный HTTP-сервер на 127.0.0.1 для перехвата OAuth redirect с `code`: свободный порт (Google)
/// или фиксированный (Dropbox требует точного совпадения redirect_uri с настройками приложения).
/// Всё состояние меняется только на собственной последовательной очереди.
///
/// Защита: только 127.0.0.1; принимается один запрос на путь redirect_uri с совпадающим `state`
/// (остальные получают 400/404, сервер продолжает ждать); после него приём закрывается;
/// таймаут 5 минут; заголовок запроса не больше 16 КБ; параметры запроса в HTML не попадают.
final class LoopbackServer: @unchecked Sendable {
    static let timeout: TimeInterval = 5 * 60
    static let maxRequestBytes = 16 * 1024

    struct Callback: Sendable {
        let code: String?
        let state: String?
        let error: String?
    }

    enum ServerError: LocalizedError {
        case failedToStart(String)
        /// Фиксированный порт занят другой программой.
        case portInUse(UInt16)
        case cancelled
        /// Облако не вернуло ответ за отведённое время.
        case timedOut(cloudName: String)

        var errorDescription: String? {
            switch self {
            case .failedToStart(let m): String(localized: "Couldn’t start the local authorization server: \(m)")
            case .portInUse(let port): String(localized: "Port \(String(port)) on this Mac is used by another app, so NaviDrive can’t receive the sign-in response. Quit the app that uses it (or restart the Mac) and try again.")
            case .cancelled: String(localized: "Authorization cancelled")
            case .timedOut(let cloudName): String(localized: "No response from \(cloudName) within 5 minutes. Try signing in again.")
            }
        }
    }

    private let queue = DispatchQueue(label: "com.navidrive.oauth-loopback")
    private var listener: NWListener?
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<Callback, Error>?
    private var pendingCallback: Result<Callback, Error>?
    /// `state` текущего входа: запросы с другим значением отклоняются.
    private let expectedState: String
    /// nil — любой свободный порт.
    private let fixedPort: UInt16?
    /// Путь redirect_uri («/» или, например, «/callback»).
    private let callbackPath: String
    /// Ответ уже получен — новые соединения не принимаются.
    private var finished = false
    /// Ожидание завершилось по таймауту.
    private var timedOut = false
    /// Название облака для страницы в браузере.
    private let cloudName: String

    init(cloudName: String, expectedState: String, port: UInt16? = nil, callbackPath: String = "/") {
        self.cloudName = cloudName
        self.expectedState = expectedState
        self.fixedPort = port
        self.callbackPath = callbackPath
    }

    /// Запускает сервер и возвращает его порт (выделенный системой или фиксированный).
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    let port = self.fixedPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
                    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
                    // На фиксированном порту повторное использование адреса не включается: занятый порт — ошибка.
                    parameters.allowLocalEndpointReuse = self.fixedPort == nil
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.portContinuation = continuation
                    // Цикл listener → handler → self разрывается в stop().
                    listener.stateUpdateHandler = { state in self.handleState(state) }
                    listener.newConnectionHandler = { connection in self.accept(connection) }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + Self.timeout) { [weak server = self] in
                        guard let server, !server.finished else { return }
                        server.timedOut = true
                        server.deliver(.failure(ServerError.timedOut(cloudName: server.cloudName)))
                    }
                } catch {
                    continuation.resume(throwing: self.startError(error))
                }
            }
        }
    }

    /// Ожидает редирект браузера с кодом авторизации.
    func waitForCallback() async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let pending = self.pendingCallback {
                        self.pendingCallback = nil
                        continuation.resume(with: pending)
                    } else {
                        self.callbackContinuation = continuation
                    }
                }
            }
        } onCancel: {
            self.finish(.failure(ServerError.cancelled))
        }
    }

    func stop() {
        queue.async {
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    // MARK: - Private (queue)

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                portContinuation?.resume(returning: port)
                portContinuation = nil
            }
        case .failed(let error):
            portContinuation?.resume(throwing: startError(error))
            portContinuation = nil
            deliver(.failure(error))
        default:
            break
        }
    }

    private func startError(_ error: Error) -> ServerError {
        if let fixedPort, case NWError.posix(.EADDRINUSE) = error { return .portInUse(fixedPort) }
        if let fixedPort, (error as? POSIXError)?.code == .EADDRINUSE { return .portInUse(fixedPort) }
        return .failedToStart(error.localizedDescription)
    }

    private func finish(_ result: Result<Callback, Error>) {
        queue.async { self.deliver(result) }
    }

    private func deliver(_ result: Result<Callback, Error>) {
        guard !finished else { return }
        finished = true
        // Один ответ на вход: дальше соединения не принимаются.
        listener?.newConnectionHandler = nil
        listener?.cancel()
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        } else if pendingCallback == nil {
            pendingCallback = result
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !finished else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.handleRequest(header: header, connection: connection)
            } else if isComplete || error != nil || buffer.count > Self.maxRequestBytes {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handleRequest(header: String, connection: NWConnection) {
        guard !finished, header.utf8.count <= Self.maxRequestBytes else {
            // Соединение, открытое до таймаута, получает страницу о нём.
            respond(connection, status: "400 Bad Request",
                    body: timedOut ? Self.page(.timedOut, cloudName: cloudName) : "")
            return
        }
        let requestLine = header.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        // Только GET на путь redirect_uri; всё остальное — 404.
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path == callbackPath || (callbackPath == "/" && components.path.isEmpty) else {
            respond(connection, status: "404 Not Found", body: "")
            return
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        let code = value("code")
        let oauthError = value("error")
        // Запрос без кода или с чужим state отклоняется; сервер продолжает ждать настоящий ответ облака.
        guard code != nil || oauthError != nil, value("state") == expectedState else {
            respond(connection, status: "400 Bad Request", body: Self.page(.invalidState, cloudName: cloudName))
            return
        }

        let result: PageResult = code != nil ? .success : (oauthError == "access_denied" ? .accessDenied : .failed)
        respond(connection, status: "200 OK", body: Self.page(result, cloudName: cloudName))
        deliver(.success(Callback(code: code, state: value("state"), error: oauthError)))
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Итог входа, показываемый в браузере.
    enum PageResult {
        case success
        /// Пользователь отказал в доступе (`error=access_denied`).
        case accessDenied
        /// Облако вернуло другую ошибку.
        case failed
        /// Чужой или устаревший `state`, либо ответ без кода.
        case invalidState
        case timedOut
    }

    /// Страница без единого параметра из запроса (защита от внедрения HTML/JS):
    /// только локализованные строки приложения и название облака.
    static func page(_ result: PageResult, cloudName: String) -> String {
        let title: String
        let lines: [String]
        switch result {
        case .success:
            title = String(localized: "Authorization successful")
            lines = [String(localized: "\(cloudName) connected"),
                     String(localized: "You can close this tab and return to NaviDrive.")]
        case .accessDenied:
            title = String(localized: "Access denied")
            lines = [String(localized: "NaviDrive wasn’t allowed to access \(cloudName). To connect it, return to NaviDrive and sign in again.")]
        case .failed:
            title = String(localized: "Authorization failed")
            lines = [String(localized: "\(cloudName) couldn’t complete sign-in. Return to NaviDrive and try again.")]
        case .invalidState:
            title = String(localized: "Sign-in link is not valid")
            lines = [String(localized: "This sign-in link is outdated or wasn’t opened from NaviDrive. Return to NaviDrive and start signing in again.")]
        case .timedOut:
            title = String(localized: "Sign-in timed out")
            lines = [String(localized: "NaviDrive stopped waiting for a response from \(cloudName). Return to NaviDrive and start signing in again.")]
        }
        let success = result == .success
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        // Галочка или крестик — встроенный SVG, без внешних ресурсов.
        let glyph = success
            ? #"<path d="M19 33l9 9 17-19" />"#
            : #"<path d="M22 22l20 20M42 22L22 42" />"#
        let text = lines.enumerated().map { index, line in
            "<p class=\"\(index == 0 && lines.count > 1 ? "lead" : "note")\">\(escape(line))</p>"
        }.joined()
        return """
        <!doctype html>
        <html lang="\(escape(language))"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>NaviDrive — \(escape(title))</title>
        <style>
          :root { color-scheme: light dark; --bg:#F5F5F7; --card:#FFFFFF; --border:rgba(0,0,0,0.06);
                  --shadow:0 8px 30px rgba(0,0,0,0.08); --title:#1D1D1F; --text:#6E6E73; --brand:#AEAEB2;
                  --accent:\(success ? "#34C759" : "#FF3B30"); }
          @media (prefers-color-scheme: dark) {
            :root { --bg:#1C1C1E; --card:#2C2C2E; --border:rgba(255,255,255,0.08);
                    --shadow:0 8px 30px rgba(0,0,0,0.4); --title:#F5F5F7; --text:#AEAEB2; --brand:#636366;
                    --accent:\(success ? "#30D158" : "#FF453A"); }
          }
          html, body { height:100%; }
          body { margin:0; background:var(--bg); color:var(--text); display:flex; flex-direction:column;
                 align-items:center; justify-content:center; padding:24px; box-sizing:border-box; text-align:center;
                 font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;
                 -webkit-font-smoothing:antialiased; }
          main { width:420px; max-width:90%; box-sizing:border-box; padding:40px 32px; border-radius:20px;
                 background:var(--card); border:1px solid var(--border); box-shadow:var(--shadow);
                 animation:appear 250ms ease-out both; }
          @keyframes appear { from { opacity:0; transform:translateY(8px); } to { opacity:1; transform:none; } }
          @media (prefers-reduced-motion: reduce) { main { animation:none; } }
          .icon { width:64px; height:64px; border-radius:50%; background:var(--accent); margin:0 auto 20px;
                  display:flex; align-items:center; justify-content:center; }
          .icon svg { width:64px; height:64px; fill:none; stroke:#FFFFFF; stroke-width:5;
                      stroke-linecap:round; stroke-linejoin:round; }
          h1 { color:var(--title); font-size:22px; font-weight:600; margin:0 0 8px; letter-spacing:-.01em; }
          p { font-size:15px; line-height:1.45; margin:0; }
          p.lead { color:var(--title); font-size:16px; margin-bottom:4px; }
          footer { position:fixed; bottom:24px; left:0; right:0; font-size:11px; letter-spacing:.12em;
                   color:var(--brand); }
        </style></head>
        <body><main><div class="icon"><svg viewBox="0 0 64 64" aria-hidden="true">\(glyph)</svg></div>
        <h1>\(escape(title))</h1>\(text)</main><footer>NAVIDRIVE</footer></body></html>
        """
    }

    private static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
