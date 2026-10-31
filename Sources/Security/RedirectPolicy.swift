import Foundation

/// Политика редиректов для запросов к API облаков: только HTTPS без логина/пароля в URL;
/// при переходе на другой хост учётные заголовки (Bearer-токен, ключи доступа Google) не пересылаются.
enum RedirectPolicy {
    /// Заголовки, которые нельзя отдавать другому хосту.
    static let credentialHeaders = ["Authorization", "X-Goog-Drive-Resource-Keys"]

    /// Запрос, которым продолжить редирект, или nil — редирект отклонён.
    /// - Parameters:
    ///   - request: запрос, предложенный URLSession (с заголовками исходного).
    ///   - previous: текущий запрос задачи (хост, с которого идёт редирект).
    static func redirect(_ request: URLRequest, from previous: URLRequest?) -> URLRequest? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        var result = request
        if previous?.url?.host?.lowercased() != host {
            for header in credentialHeaders { result.setValue(nil, forHTTPHeaderField: header) }
        }
        return result
    }
}

/// Делегат общей сессии облаков: применяет `RedirectPolicy` ко всем задачам без собственного делегата.
final class CloudSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        RedirectPolicy.redirect(request, from: task.currentRequest ?? task.originalRequest)
    }
}
