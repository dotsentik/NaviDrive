import Foundation
import Testing

/// Атакующие кейсы автообновления (аудит безопасности, этап 7): подмена тега, хостов, размеров и .sha256.
@Suite("Update policy under attack")
struct UpdateAttackTests {
    private let current = SemanticVersion("1.1.1")!

    private func release(tag: String, dmgName: String? = nil, dmgURL: String? = nil, checksumURL: String? = nil,
                         size: Int64 = 1000) -> Data {
        let version = String(tag.drop(while: { $0 == "v" || $0 == "V" }))
        let name = dmgName ?? "NaviDrive-\(version).dmg"
        let dmg = dmgURL ?? "https://github.com/o/r/releases/download/\(tag)/\(name)"
        let sum = checksumURL ?? "https://github.com/o/r/releases/download/\(tag)/\(name).sha256"
        let json = """
        {"tag_name":\(quoted(tag)),"body":"","draft":false,"prerelease":false,"assets":[
          {"name":\(quoted(name)),"browser_download_url":\(quoted(dmg)),"size":\(size)},
          {"name":\(quoted(name + ".sha256")),"browser_download_url":\(quoted(sum)),"size":90}]}
        """
        return Data(json.utf8)
    }

    private func quoted(_ string: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [string]), as: UTF8.self).dropFirst().dropLast().description
    }

    @Test(arguments: ["v9.9.9/../../evil", "v9.9.9 ", "vv9.9.9", "v9.9.9-rc1", "v9.9.9.1.2", "v９.9.9", "v9.9.9\u{0}"])
    func rejectsCraftedTags(_ tag: String) {
        #expect(throws: UpdateCoreError.self) { try UpdatePolicy.evaluate(release(tag: tag), currentVersion: current) }
    }

    @Test(arguments: ["v1.1.1", "v1.1.0", "V0.1", "v1.1.1.0"])
    func noDowngradeOrReinstall(_ tag: String) throws {
        #expect(try UpdatePolicy.evaluate(release(tag: tag), currentVersion: current) == .upToDate)
    }

    @Test(arguments: [
        "http://github.com/o/r/releases/download/v9.9.9/NaviDrive-9.9.9.dmg",
        "https://user@github.com/o/r/releases/download/v9.9.9/NaviDrive-9.9.9.dmg",
        "https://github.com@evil.example/NaviDrive-9.9.9.dmg",
        "https://github.com:444/NaviDrive-9.9.9.dmg",
        "https://127.0.0.1/NaviDrive-9.9.9.dmg",
        "file:///Applications/NaviDrive-9.9.9.dmg",
    ])
    func rejectsUntrustedDMGLocations(_ url: String) {
        #expect(throws: UpdateCoreError.insecureURL) {
            try UpdatePolicy.evaluate(release(tag: "v9.9.9", dmgURL: url), currentVersion: current)
        }
    }

    @Test func rejectsUntrustedChecksumLocation() {
        #expect(throws: UpdateCoreError.insecureURL) {
            try UpdatePolicy.evaluate(release(tag: "v9.9.9", checksumURL: "https://evil.example/x.sha256"), currentVersion: current)
        }
    }

    @Test func dmgAssetNameMustMatchTag() {
        #expect(throws: UpdateCoreError.missingAsset("NaviDrive-9.9.9.dmg")) {
            try UpdatePolicy.evaluate(release(tag: "v9.9.9", dmgName: "NaviDrive-9.9.8.dmg"), currentVersion: current)
        }
    }

    @Test(arguments: [Int64(0), -1, UpdatePolicy.maxDownloadBytes + 1])
    func rejectsImplausibleSizes(_ size: Int64) {
        #expect(throws: UpdateCoreError.tooLarge) {
            try UpdatePolicy.evaluate(release(tag: "v9.9.9", size: size), currentVersion: current)
        }
    }

    @Test(arguments: [
        "\(String(repeating: "a", count: 64))  ../NaviDrive-9.9.9.dmg",
        "\(String(repeating: "a", count: 64))  /tmp/NaviDrive-9.9.9.dmg",
        "\(String(repeating: "a", count: 63))g  NaviDrive-9.9.9.dmg",
        "\(String(repeating: "ａ", count: 64))  NaviDrive-9.9.9.dmg",
        "\(String(repeating: "a", count: 65))",
    ])
    func rejectsCraftedChecksumLines(_ line: String) {
        #expect(throws: UpdateCoreError.malformedChecksum) {
            try UpdatePolicy.parseChecksum(Data(line.utf8), expectedFileName: "NaviDrive-9.9.9.dmg")
        }
    }

    @Test func rejectsOversizedChecksumFile() {
        let data = Data((String(repeating: "a", count: 64) + String(repeating: " ", count: UpdatePolicy.maxChecksumBytes)).utf8)
        #expect(throws: UpdateCoreError.malformedChecksum) {
            try UpdatePolicy.parseChecksum(data, expectedFileName: "NaviDrive-9.9.9.dmg")
        }
    }
}
