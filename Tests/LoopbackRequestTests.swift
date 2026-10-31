import Testing

@Suite("Local OAuth redirect requests (SEC-002, SEC-003)")
struct LoopbackRequestTests {
    let state = "Zx8vQk3pLm0aBc1dEf2gHi"

    private func header(_ target: String, method: String = "GET", host: String = "127.0.0.1:53682") -> String {
        "\(method) \(target) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: test"
    }

    private func evaluate(_ header: String, path: String = "/callback") -> LoopbackRequest.Decision {
        LoopbackRequest.evaluate(header: header, callbackPath: path, expectedState: state)
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
        #expect(evaluate("") == .notFound)
        #expect(evaluate("GET") == .notFound)
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
}
