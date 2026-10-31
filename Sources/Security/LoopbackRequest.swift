import Foundation

/// Разбор HTTP-запроса, пришедшего на локальный OAuth-сервер (`LoopbackServer`): чистая функция без сети.
enum LoopbackRequest {
    enum Decision: Equatable, Sendable {
        /// Не GET или не путь redirect_uri — 404, сервер ждёт дальше.
        case notFound
        /// Заголовок Host не 127.0.0.1/localhost с портом сервера (DNS-rebinding) — 403, сервер ждёт дальше.
        case forbiddenHost
        /// Нет кода/ошибки или чужой `state` — 400, сервер ждёт дальше.
        case invalidState
        /// Настоящий ответ облака (`state` совпал).
        case callback(code: String?, error: String?)
    }

    /// - Parameters:
    ///   - header: заголовок запроса до пустой строки (без тела).
    ///   - callbackPath: путь redirect_uri («/» или, например, «/callback»).
    ///   - expectedState: `state` текущего входа.
    ///   - port: порт сервера — заголовок Host обязан указывать на него.
    static func evaluate(header: String, callbackPath: String, expectedState: String, port: UInt16) -> Decision {
        let lines = header.components(separatedBy: "\r\n")
        guard isLoopbackHost(hostHeader(lines), port: port) else { return .forbiddenHost }
        let parts = (lines.first ?? "").split(separator: " ")
        // Только GET с путём в origin-form («/callback?…»), без абсолютных URL и «@» в цели.
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/"),
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.host == "127.0.0.1",
              components.path == callbackPath || (callbackPath == "/" && components.path.isEmpty) else {
            return .notFound
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        let code = value("code")
        let error = value("error")
        guard code != nil || error != nil, let state = value("state"),
              constantTimeEquals(state, expectedState) else {
            return .invalidState
        }
        return .callback(code: code, error: error)
    }

    /// Значение заголовка Host (имя заголовка — без учёта регистра); nil — заголовка нет или их несколько.
    static func hostHeader(_ lines: [String]) -> String? {
        let values = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "host" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return values.count == 1 ? values[0] : nil
    }

    /// Host указывает на сам loopback-сервер: «127.0.0.1:<port>» или «localhost:<port>».
    static func isLoopbackHost(_ host: String?, port: UInt16) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    /// Сравнение без раннего выхода: время не зависит от того, в каком символе строки различаются.
    /// Длина `state` у NaviDrive фиксирована и не секретна.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
