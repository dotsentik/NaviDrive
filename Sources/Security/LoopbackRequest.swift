import Foundation

/// Разбор HTTP-запроса, пришедшего на локальный OAuth-сервер (`LoopbackServer`): чистая функция без сети.
enum LoopbackRequest {
    enum Decision: Equatable, Sendable {
        /// Не GET или не путь redirect_uri — 404, сервер ждёт дальше.
        case notFound
        /// Нет кода/ошибки или чужой `state` — 400, сервер ждёт дальше.
        case invalidState
        /// Настоящий ответ облака (`state` совпал).
        case callback(code: String?, error: String?)
    }

    /// - Parameters:
    ///   - header: заголовок запроса до пустой строки (без тела).
    ///   - callbackPath: путь redirect_uri («/» или, например, «/callback»).
    ///   - expectedState: `state` текущего входа.
    static func evaluate(header: String, callbackPath: String, expectedState: String) -> Decision {
        let lines = header.components(separatedBy: "\r\n")
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
