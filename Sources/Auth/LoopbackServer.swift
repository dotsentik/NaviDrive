import Foundation
import Network

/// Временный HTTP-сервер на 127.0.0.1 (свободный порт) для перехвата OAuth redirect с `code`.
/// Всё состояние меняется только на собственной последовательной очереди.
///
/// Защита: только 127.0.0.1; принимается один запрос на путь «/» с совпадающим `state`
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
        case cancelled
        case timedOut

        var errorDescription: String? {
            switch self {
            case .failedToStart(let m): String(localized: "Couldn’t start the local authorization server: \(m)")
            case .cancelled: String(localized: "Authorization cancelled")
            case .timedOut: String(localized: "No response from Google within 5 minutes. Try signing in again.")
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
    /// Ответ уже получен — новые соединения не принимаются.
    private var finished = false

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    /// Запускает сервер и возвращает выделенный системой порт.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
                    parameters.allowLocalEndpointReuse = true
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.portContinuation = continuation
                    // Цикл listener → handler → self разрывается в stop().
                    listener.stateUpdateHandler = { state in self.handleState(state) }
                    listener.newConnectionHandler = { connection in self.accept(connection) }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + Self.timeout) { [weak server = self] in
                        server?.deliver(.failure(ServerError.timedOut))
                    }
                } catch {
                    continuation.resume(throwing: ServerError.failedToStart(error.localizedDescription))
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
            portContinuation?.resume(throwing: ServerError.failedToStart(error.localizedDescription))
            portContinuation = nil
            deliver(.failure(error))
        default:
            break
        }
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
            respond(connection, status: "400 Bad Request", body: "")
            return
        }
        let requestLine = header.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        // Только GET на путь redirect_uri («/»); всё остальное — 404.
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path.isEmpty || components.path == "/" else {
            respond(connection, status: "404 Not Found", body: "")
            return
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        let code = value("code")
        let oauthError = value("error")
        // Запрос без кода или с чужим state отклоняется; сервер продолжает ждать настоящий ответ Google.
        guard code != nil || oauthError != nil, value("state") == expectedState else {
            respond(connection, status: "400 Bad Request", body: Self.page(success: false))
            return
        }

        respond(connection, status: "200 OK", body: Self.page(success: code != nil))
        deliver(.success(Callback(code: code, state: value("state"), error: oauthError)))
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Страница без единого параметра из запроса (защита от внедрения HTML/JS).
    private static func page(success: Bool) -> String {
        let title = success ? String(localized: "Authorization successful!") : String(localized: "Authorization failed")
        let subtitle = success
            ? String(localized: "Done! You can close this tab and return to NaviDrive.")
            : String(localized: "Sign-in didn’t complete. Return to NaviDrive and try again.")
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let icon = success ? "✓" : "!"
        let accent = success ? "#34c759" : "#ff3b30"
        return """
        <!doctype html>
        <html lang="\(language)"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>NaviDrive — \(title)</title>
        <style>
          :root { color-scheme: light dark; }
          body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
                 font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;
                 background:linear-gradient(135deg,#4285f4 0%,#34a853 50%,#fbbc05 100%); }
          .card { background:rgba(255,255,255,.92); color:#1d1d1f; border-radius:24px; padding:48px 56px;
                  text-align:center; box-shadow:0 30px 80px rgba(0,0,0,.25); max-width:440px; margin:16px; }
          @media (prefers-color-scheme: dark) { .card { background:rgba(30,30,32,.92); color:#f5f5f7; } }
          .icon { width:84px; height:84px; border-radius:50%; background:\(accent); color:#fff; font-size:46px;
                  line-height:84px; margin:0 auto 24px; font-weight:700; }
          h1 { font-size:26px; margin:0 0 12px; }
          p { font-size:16px; opacity:.75; margin:0; line-height:1.5; }
          .brand { margin-top:28px; font-size:13px; opacity:.5; letter-spacing:.08em; text-transform:uppercase; }
        </style></head>
        <body><div class="card"><div class="icon">\(icon)</div><h1>\(title)</h1><p>\(subtitle)</p>
        <div class="brand">NaviDrive</div></div></body></html>
        """
    }
}
