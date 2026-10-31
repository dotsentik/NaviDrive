import Foundation
import Testing

@Suite("Redirect policy for cloud API requests (SEC-018)")
struct RedirectPolicyTests {
    private func request(_ string: String, token: Bool = true) -> URLRequest {
        var request = URLRequest(url: URL(string: string)!)
        if token {
            request.setValue("Bearer ya29.secret", forHTTPHeaderField: "Authorization")
            request.setValue("id/key", forHTTPHeaderField: "X-Goog-Drive-Resource-Keys")
        }
        request.setValue("bytes=10-", forHTTPHeaderField: "Range")
        return request
    }

    @Test func sameHostKeepsCredentials() throws {
        let previous = request("https://www.googleapis.com/drive/v3/files/a?alt=media")
        let next = try #require(RedirectPolicy.redirect(request("https://www.googleapis.com/drive/v3/files/b"), from: previous))
        #expect(next.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.secret")
    }

    @Test func otherHostDropsCredentials() throws {
        let previous = request("https://www.googleapis.com/drive/v3/files/a?alt=media")
        let next = try #require(RedirectPolicy.redirect(request("https://evil.example/steal"), from: previous))
        #expect(next.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(next.value(forHTTPHeaderField: "X-Goog-Drive-Resource-Keys") == nil)
        // Остальные заголовки (Range) сохраняются — скачивание с CDN продолжает работать.
        #expect(next.value(forHTTPHeaderField: "Range") == "bytes=10-")
    }

    @Test func subdomainCountsAsOtherHost() throws {
        let previous = request("https://content.dropboxapi.com/2/files/download")
        let next = try #require(RedirectPolicy.redirect(request("https://dl.dropboxusercontent.com/x"), from: previous))
        #expect(next.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func hostComparisonIgnoresCase() throws {
        let previous = request("https://WWW.googleapis.com/a")
        let next = try #require(RedirectPolicy.redirect(request("https://www.GoogleAPIs.com/b"), from: previous))
        #expect(next.value(forHTTPHeaderField: "Authorization") != nil)
    }

    @Test func rejectsDowngradeToHTTP() {
        let previous = request("https://www.googleapis.com/a")
        #expect(RedirectPolicy.redirect(request("http://www.googleapis.com/a"), from: previous) == nil)
    }

    @Test func rejectsOtherSchemesAndUserInfo() {
        let previous = request("https://www.googleapis.com/a")
        #expect(RedirectPolicy.redirect(request("file:///etc/passwd"), from: previous) == nil)
        #expect(RedirectPolicy.redirect(request("https://user:pass@www.googleapis.com/a"), from: previous) == nil)
    }

    @Test func unknownPreviousDropsCredentials() throws {
        let next = try #require(RedirectPolicy.redirect(request("https://www.googleapis.com/a"), from: nil))
        #expect(next.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
