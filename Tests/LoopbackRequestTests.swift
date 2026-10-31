import Testing

@Suite("Local OAuth redirect requests (SEC-002, SEC-003)")
struct LoopbackRequestTests {
    let state = "Zx8vQk3pLm0aBc1dEf2gHi"

    private func header(_ target: String, method: String = "GET", host: String = "127.0.0.1:53682") -> String {
        "\(method) \(target) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: test"
    }

    private func evaluate(_ header: String, path: String = "/callback") -> LoopbackRequest.Decision {
        LoopbackRequest.evaluate(header: header, callbackPath: path, expectedState: state, port: 53682)
    }

    @Test func acceptsCodeWithMatchingState() {
        #expect(evaluate(header("/callback?code=abc&state=\(state)")) == .callback(code: "abc", error: nil))
    }

    @Test func acceptsProviderErrorWithMatchingState() {
        #expect(evaluate(header("/callback?error=access_denied&state=\(state)")) == .callback(code: nil, error: "access_denied"))
    }

    @Test func rootCallbackPath() {
        #expect(evaluate(header("/?code=abc&state=\(state)"), path: "/") == .callback(code: "abc", error: nil))
        #expect(evaluate(header("?code=abc&state=\(state)"), path: "/") == .notFound)
    }

    @Test func rejectsForeignOrMissingState() {
        #expect(evaluate(header("/callback?code=attacker")) == .invalidState)
        #expect(evaluate(header("/callback?code=attacker&state=")) == .invalidState)
        #expect(evaluate(header("/callback?code=attacker&state=\(state)x")) == .invalidState)
        #expect(evaluate(header("/callback?code=attacker&state=Zx8vQk3pLm0aBc1dEf2gHj")) == .invalidState)
    }

    @Test func rejectsRequestWithoutCodeOrError() {
        #expect(evaluate(header("/callback?state=\(state)")) == .invalidState)
    }

    @Test func rejectsOtherMethodsAndPaths() {
        #expect(evaluate(header("/callback?code=a&state=\(state)", method: "POST")) == .notFound)
        #expect(evaluate(header("/other?code=a&state=\(state)")) == .notFound)
        #expect(evaluate(header("/callback/../callback?code=a&state=\(state)")) == .notFound)
        #expect(evaluate("\r\nHost: 127.0.0.1:53682") == .notFound)
        #expect(evaluate("GET\r\nHost: 127.0.0.1:53682") == .notFound)
        #expect(evaluate("") == .forbiddenHost)
    }

    @Test func rejectsAbsoluteAndUserInfoTargets() {
        #expect(evaluate(header("http://evil.example/callback?code=a&state=\(state)")) == .notFound)
        #expect(evaluate(header("@evil.example/callback?code=a&state=\(state)")) == .notFound)
    }

    @Test func constantTimeEquality() {
        #expect(LoopbackRequest.constantTimeEquals("abc", "abc"))
        #expect(!LoopbackRequest.constantTimeEquals("abc", "abd"))
        #expect(!LoopbackRequest.constantTimeEquals("abc", "abcd"))
        #expect(LoopbackRequest.constantTimeEquals("", ""))
    }

    @Test func rejectsForeignHostHeader() {
        let target = "/callback?code=a&state=\(state)"
        #expect(evaluate(header(target, host: "evil.example:53682")) == .forbiddenHost)
        #expect(evaluate(header(target, host: "127.0.0.1:1234")) == .forbiddenHost)
        #expect(evaluate(header(target, host: "127.0.0.1")) == .forbiddenHost)
        #expect(evaluate("GET \(target) HTTP/1.1\r\nUser-Agent: x") == .forbiddenHost)
        #expect(evaluate("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:53682\r\nHost: evil.example") == .forbiddenHost)
    }

    @Test func acceptsLoopbackHostVariants() {
        let target = "/callback?code=a&state=\(state)"
        #expect(evaluate(header(target, host: "localhost:53682")) == .callback(code: "a", error: nil))
        #expect(evaluate("GET \(target) HTTP/1.1\r\nhost:127.0.0.1:53682") == .callback(code: "a", error: nil))
    }
}
