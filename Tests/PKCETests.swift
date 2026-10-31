import Testing

@Suite("PKCE (SEC-004)")
struct PKCETests {
    /// RFC 7636, Appendix B.
    @Test func rfc7636Vector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierLengthAndAlphabet() {
        let verifier = PKCE.makeVerifier()
        #expect((43...128).contains(verifier.count))
        #expect(verifier.unicodeScalars.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".unicodeScalars.contains($0) })
    }

    @Test func verifiersAreUnique() {
        let verifiers = Set((0..<100).map { _ in PKCE.makeVerifier() })
        #expect(verifiers.count == 100)
    }

    @Test func base64URLHasNoPaddingOrUnsafeCharacters() {
        #expect(PKCE.base64URL([0xFB, 0xFF, 0xFE]) == "-__-")
        #expect(PKCE.base64URL([0x00]) == "AA")
    }
}
