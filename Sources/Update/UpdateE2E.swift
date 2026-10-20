#if DEBUG
import Foundation

/// Только Debug: сквозная проверка обновления (NAVIDRIVE_UPDATE_E2E=1, Scripts/test-update-e2e.sh).
/// Релиз берётся с NAVIDRIVE_UPDATE_FEED; DMG скачивается и проверяется теми же шагами, что и в окне обновления
/// (SHA-256, подпись, версия, хосты), новая копия ставится вспомогательным процессом, приложение завершается.
/// AppModel, база данных, Связка ключей, UserDefaults, аккаунты и окна не используются; рабочая папка обновления —
/// только во временной папке из TMPDIR, заданной тестом.
/// Этапы — строками в файл NAVIDRIVE_UPDATE_E2E_REPORT (если задан). Код выхода: 0 — обновление запущено
/// или обновлять нечего, 1 — обновление отклонено или не удалось.
enum UpdateE2E {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["NAVIDRIVE_UPDATE_E2E"] == "1" }

    static func runAndExit() -> Never {
        Task.detached {
            let code = await run()
            exit(code)
        }
        dispatchMain()
    }

    private static func run() async -> Int32 {
        let current = Bundle.main.semanticVersion
        report("start \(current) \(Bundle.main.bundleURL.path)")
        guard UpdatePolicy.debugFeedURL != nil else {
            report("error NAVIDRIVE_UPDATE_FEED is not set or is not http://127.0.0.1:<port>/…")
            return 1
        }
        // Рабочая папка обновления — в TMPDIR теста (UpdateInstaller.workDirectory), а не во временной папке пользователя.
        guard let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty,
              (try? UpdateInstaller.workDirectory())?.resolvingSymlinksInPath().path
                .hasPrefix(URL(fileURLWithPath: tmp).resolvingSymlinksInPath().path) == true else {
            report("error TMPDIR must point to a test folder")
            return 1
        }
        do {
            let repo = Bundle.main.object(forInfoDictionaryKey: "NDGitHubRepo") as? String ?? ""
            guard case .fetched(let data, _) = try await UpdateNetwork.fetchLatestRelease(repo: repo, etag: nil),
                  !data.isEmpty else {
                report("uptodate")
                return 0
            }
            let evaluation: ReleaseEvaluation
            do {
                evaluation = try UpdatePolicy.evaluate(data, currentVersion: current)
            } catch let error as UpdateCoreError {
                throw UpdateError.core(error)
            }
            guard case .available(let release) = evaluation else {
                report("uptodate")
                return 0
            }
            report("available \(release.version)")

            let work = try UpdateInstaller.workDirectory()
            let dmg = work.appendingPathComponent(release.dmgName)
            let expected = try await UpdateInstaller.expectedChecksum(for: release)
            let limit = min(UpdatePolicy.maxDownloadBytes, release.dmgSize + 1024 * 1024)
            try await UpdateNetwork.download(release.dmgURL, to: dmg, maxBytes: limit) { _, _ in }
            guard await UpdateInstaller.fileMatches(dmg, sha256: expected) else {
                try? FileManager.default.removeItem(at: dmg)
                throw UpdateError.core(.checksumMismatch)
            }
            report("checksum ok")

            let location = UpdateInstaller.currentLocation()
            guard let staged = try await UpdateInstaller.verifyAndStage(dmg: dmg, work: work, version: release.version,
                                                                        current: current, location: location),
                  case .writable(let appURL) = location else {
                throw UpdateError.installFailed("The app location is read-only")
            }
            try UpdateInstaller.launchReplacementHelper(appURL: appURL, stagedURL: staged, workDirectory: work,
                                                        directLaunch: true)
            report("installing \(release.version)")
            return 0
        } catch {
            report("error \(String(describing: error)) | \(error.localizedDescription)")
            return 1
        }
    }

    private static func report(_ line: String) {
        UpdateLog.logger.info("E2E: \(line, privacy: .public)")
        guard let path = ProcessInfo.processInfo.environment["NAVIDRIVE_UPDATE_E2E_REPORT"] else { return }
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
#endif
