import CryptoKit
import Foundation
import Testing

@Suite("Semantic versions")
struct SemanticVersionTests {
    @Test func numericNotLexicographic() throws {
        let a = try #require(SemanticVersion("1.9.0"))
        let b = try #require(SemanticVersion("1.10.0"))
        #expect(a < b)
        #expect(!(b < a))
    }

    @Test func missingComponentsAreZero() throws {
        let short = try #require(SemanticVersion("1.0"))
        let long = try #require(SemanticVersion("1.0.0"))
        #expect(short == long)
        #expect(!(short < long) && !(long < short))
        #expect(try #require(SemanticVersion("1.1")) > long)
    }

    @Test func tagPrefix() throws {
        #expect(try #require(SemanticVersion("v2.3.4")) == SemanticVersion("2.3.4"))
        #expect(SemanticVersion("v2.3.4")?.description == "2.3.4")
    }

    @Test func rejectsGarbage() {
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("1..2") == nil)
        #expect(SemanticVersion("1.2.3-beta") == nil)
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("1.٢.3") == nil)
    }
}

@Suite("Release JSON")
struct ReleaseParsingTests {
    private let current = SemanticVersion("1.0.0")!

    private func releaseJSON(tag: String = "v1.1.0", draft: Bool = false, prerelease: Bool = false,
                             assets: [(String, String, Int64)]? = nil) -> Data {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let list = assets ?? [
            ("NaviDrive-\(version).dmg", "https://github.com/o/r/releases/download/\(tag)/NaviDrive-\(version).dmg", 12_345_678),
            ("NaviDrive-\(version).dmg.sha256", "https://github.com/o/r/releases/download/\(tag)/NaviDrive-\(version).dmg.sha256", 90),
            ("Source.zip", "https://github.com/o/r/archive/\(tag).zip", 1000),
        ]
        let assetsJSON = list.map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)","size":\#($0.2),"id":1}"# }
            .joined(separator: ",")
        return Data(#"""
        {"tag_name":"\#(tag)","name":"NaviDrive \#(version)","body":"## Changes\n- Faster","draft":\#(draft),
         "prerelease":\#(prerelease),"html_url":"https://github.com/o/r/releases/tag/\#(tag)","assets":[\#(assetsJSON)]}
        """#.utf8)
    }

    @Test func findsAssets() throws {
        let result = try UpdatePolicy.evaluate(releaseJSON(), currentVersion: current)
        guard case .available(let release) = result else { Issue.record("expected update"); return }
        #expect(release.version == SemanticVersion("1.1.0"))
        #expect(release.dmgName == "NaviDrive-1.1.0.dmg")
        #expect(release.dmgSize == 12_345_678)
        #expect(release.dmgURL.lastPathComponent == "NaviDrive-1.1.0.dmg")
        #expect(release.checksumURL.lastPathComponent == "NaviDrive-1.1.0.dmg.sha256")
        #expect(release.notes == "## Changes\n- Faster")
    }

    @Test func ignoresDraftAndPrerelease() throws {
        #expect(try UpdatePolicy.evaluate(releaseJSON(draft: true), currentVersion: current) == .upToDate)
        #expect(try UpdatePolicy.evaluate(releaseJSON(prerelease: true), currentVersion: current) == .upToDate)
    }

    @Test func sameOrOlderIsUpToDate() throws {
        #expect(try UpdatePolicy.evaluate(releaseJSON(tag: "v1.0"), currentVersion: current) == .upToDate)
        #expect(try UpdatePolicy.evaluate(releaseJSON(tag: "v0.9.9"), currentVersion: current) == .upToDate)
    }

    @Test func missingChecksumAsset() {
        let data = releaseJSON(assets: [("NaviDrive-1.1.0.dmg", "https://github.com/o/r/releases/download/v1.1.0/NaviDrive-1.1.0.dmg", 10)])
        #expect(throws: UpdateCoreError.missingAsset("NaviDrive-1.1.0.dmg.sha256")) {
            try UpdatePolicy.evaluate(data, currentVersion: current)
        }
    }

    @Test func rejectsForeignAssetHost() {
        let data = releaseJSON(assets: [
            ("NaviDrive-1.1.0.dmg", "https://evilgithub.com/NaviDrive-1.1.0.dmg", 10),
            ("NaviDrive-1.1.0.dmg.sha256", "https://github.com/o/r/releases/download/v1.1.0/NaviDrive-1.1.0.dmg.sha256", 10),
        ])
        #expect(throws: UpdateCoreError.insecureURL) { try UpdatePolicy.evaluate(data, currentVersion: current) }
    }

    @Test func rejectsHugeDMG() {
        let data = releaseJSON(assets: [
            ("NaviDrive-1.1.0.dmg", "https://github.com/o/r/releases/download/v1.1.0/NaviDrive-1.1.0.dmg", 3 * 1024 * 1024 * 1024),
            ("NaviDrive-1.1.0.dmg.sha256", "https://github.com/o/r/releases/download/v1.1.0/NaviDrive-1.1.0.dmg.sha256", 10),
        ])
        #expect(throws: UpdateCoreError.tooLarge) { try UpdatePolicy.evaluate(data, currentVersion: current) }
    }

    @Test func malformedJSON() {
        #expect(throws: UpdateCoreError.malformedRelease) {
            try UpdatePolicy.evaluate(Data("{\"message\":\"Not Found\"}".utf8), currentVersion: current)
        }
    }

    @Test func nonVersionTag() {
        #expect(throws: UpdateCoreError.unsupportedTag("nightly")) {
            try UpdatePolicy.evaluate(releaseJSON(tag: "nightly"), currentVersion: current)
        }
    }
}

@Suite("Allowed hosts")
struct HostPolicyTests {
    @Test(arguments: [
        "https://github.com/o/r/releases/download/v1/x.dmg",
        "https://api.github.com/repos/o/r/releases/latest",
        "https://objects.githubusercontent.com/github-production-release-asset/1",
        "https://release-assets.githubusercontent.com/github-production-release-asset/1",
        "https://GitHub.com/o/r",
    ])
    func allowed(_ string: String) {
        #expect(UpdatePolicy.isAllowed(URL(string: string)))
    }

    @Test(arguments: [
        "https://evilgithub.com/x.dmg",
        "https://github.com.evil.com/x.dmg",
        "https://evil.github.com/x.dmg",
        "https://githubusercontent.com/x.dmg",
        "https://evil.objects.githubusercontent.com/x.dmg",
        "http://github.com/x.dmg",
        "ftp://github.com/x.dmg",
        "https://user:pass@github.com/x.dmg",
        "https://github.com:8443/x.dmg",
        "file:///tmp/x.dmg",
    ])
    func rejected(_ string: String) {
        #expect(!UpdatePolicy.isAllowed(URL(string: string)))
    }

    @Test func nilURL() {
        #expect(!UpdatePolicy.isAllowed(nil))
    }
}

@Suite("SHA-256")
struct ChecksumTests {
    private static let helloHash = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9" // "hello world"

    private func temporaryFile(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("navidrive-test-\(UUID().uuidString)")
        try contents.write(to: url)
        return url
    }

    @Test func parsesShasumFormat() throws {
        let line = Data("\(Self.helloHash.uppercased())  NaviDrive-1.1.0.dmg\n".utf8)
        #expect(try UpdatePolicy.parseChecksum(line, expectedFileName: "NaviDrive-1.1.0.dmg") == Self.helloHash)
        let binary = Data("\(Self.helloHash) *NaviDrive-1.1.0.dmg".utf8)
        #expect(try UpdatePolicy.parseChecksum(binary, expectedFileName: "NaviDrive-1.1.0.dmg") == Self.helloHash)
        let bare = Data(Self.helloHash.utf8)
        #expect(try UpdatePolicy.parseChecksum(bare, expectedFileName: "NaviDrive-1.1.0.dmg") == Self.helloHash)
    }

    @Test func rejectsWrongNameOrHash() {
        #expect(throws: UpdateCoreError.malformedChecksum) {
            try UpdatePolicy.parseChecksum(Data("\(Self.helloHash)  Other.dmg".utf8), expectedFileName: "NaviDrive-1.1.0.dmg")
        }
        #expect(throws: UpdateCoreError.malformedChecksum) {
            try UpdatePolicy.parseChecksum(Data("abc123  NaviDrive-1.1.0.dmg".utf8), expectedFileName: "NaviDrive-1.1.0.dmg")
        }
        #expect(throws: UpdateCoreError.malformedChecksum) {
            try UpdatePolicy.parseChecksum(Data(), expectedFileName: "NaviDrive-1.1.0.dmg")
        }
    }

    @Test func hashesFile() throws {
        let url = try temporaryFile(Data("hello world".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try UpdatePolicy.sha256(ofFileAt: url) == Self.helloHash)
        try UpdatePolicy.verifySHA256(ofFileAt: url, expected: Self.helloHash.uppercased())
    }

    @Test func multiChunkFileMatchesOneShotHash() throws {
        var bytes = [UInt8](repeating: 0, count: 3 * (1 << 20) + 12_345)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31) }
        let data = Data(bytes)
        let url = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(try UpdatePolicy.sha256(ofFileAt: url) == expected)
    }

    @Test func mismatchThrows() throws {
        let url = try temporaryFile(Data("hello world!".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: UpdateCoreError.checksumMismatch) {
            try UpdatePolicy.verifySHA256(ofFileAt: url, expected: Self.helloHash)
        }
    }
}

@Suite("Trusted signing fingerprints")
struct TrustedFingerprintTests {
    static let current = "02D0DB17A0845C1F9BFFE83748155601D7B7C0DA065336F413E580BFAA9B3E77"
    static let other = String(repeating: "ab", count: 32)

    @Test func inList() {
        #expect(UpdatePolicy.isTrustedFingerprint(Self.current, trusted: [Self.other, Self.current]))
    }

    @Test func notInList() {
        #expect(!UpdatePolicy.isTrustedFingerprint(Self.other, trusted: [Self.current]))
        #expect(!UpdatePolicy.isTrustedFingerprint(Self.current, trusted: []))
    }

    @Test func caseInsensitive() {
        #expect(UpdatePolicy.isTrustedFingerprint(Self.current.lowercased(), trusted: [Self.current]))
        #expect(UpdatePolicy.isTrustedFingerprint(Self.current, trusted: [Self.current.lowercased()]))
    }

    @Test func colonsAndSpacesIgnored() {
        let pairs = stride(from: 0, to: 64, by: 2).map { i -> String in
            let start = Self.current.index(Self.current.startIndex, offsetBy: i)
            return String(Self.current[start..<Self.current.index(start, offsetBy: 2)])
        }
        let openssl = pairs.joined(separator: ":")
        #expect(UpdatePolicy.isTrustedFingerprint(openssl, trusted: [Self.current]))
        #expect(UpdatePolicy.isTrustedFingerprint(Self.current, trusted: [" " + pairs.joined(separator: " ") + "\n"]))
    }

    @Test func malformedNeverMatches() {
        #expect(UpdatePolicy.normalizedFingerprint("") == nil)
        #expect(UpdatePolicy.normalizedFingerprint(String(Self.current.dropLast())) == nil)
        #expect(UpdatePolicy.normalizedFingerprint(String(repeating: "zz", count: 32)) == nil)
        #expect(!UpdatePolicy.isTrustedFingerprint("", trusted: [""]))
        #expect(!UpdatePolicy.isTrustedFingerprint("garbage", trusted: ["garbage"]))
    }
}
