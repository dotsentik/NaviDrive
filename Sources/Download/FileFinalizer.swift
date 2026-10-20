import CryptoKit
import Foundation

/// Завершение скачанного файла: потоковая сверка MD5 (на фоновой очереди, без загрузки файла в память),
/// переименование `.gdrive.part` → имя файла и дата изменения = modifiedTime из Drive.
enum FileFinalizer {
    enum VerificationResult: Sendable {
        case verified(Int64)
        case mismatch(expected: String, actual: String)
        case missingFile
        case failed(String)
    }

    static let readChunkSize = 8 * 1_048_576
    private static let queue = DispatchQueue(label: "com.navidrive.md5", qos: .utility, attributes: .concurrent)

    /// MD5 файла (hex, нижний регистр). Чтение блоками по 8 МБ; `progress` — прочитано байт.
    static func md5(ofFileAt path: String, progress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let handle = FileHandle(forReadingAtPath: path) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    defer { try? handle.close() }
                    var hasher = Insecure.MD5()
                    var total: Int64 = 0
                    var lastReport: Int64 = 0
                    while true {
                        let finished: Bool = try autoreleasepool {
                            guard let data = try handle.read(upToCount: readChunkSize), !data.isEmpty else { return true }
                            hasher.update(data: data)
                            total += Int64(data.count)
                            return false
                        }
                        if finished { break }
                        if total - lastReport >= 64 * 1_048_576 {
                            lastReport = total
                            progress(total)
                        }
                    }
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    continuation.resume(returning: digest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Сверка `.gdrive.part` с md5Checksum из Drive.
    static func verify(_ task: DownloadTask, progress: @escaping @Sendable (Int64) -> Void) async -> VerificationResult {
        guard let expected = task.md5Checksum?.lowercased(), !expected.isEmpty else {
            return .verified(DownloadWorker.fileSize(task.partPath) ?? 0)
        }
        guard let size = DownloadWorker.fileSize(task.partPath) else { return .missingFile }
        do {
            let actual = try await md5(ofFileAt: task.partPath, progress: progress)
            return actual == expected ? .verified(size) : .mismatch(expected: expected, actual: actual)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `.gdrive.part` → финальное имя (существующий файл заменяется) и дата изменения из Drive.
    static func finalize(_ task: DownloadTask) throws -> Int64 {
        let fm = FileManager.default
        if PathResolver.isSymlink(task.partPath) { throw PathResolver.PathSafetyError.symlink(task.partPath) }
        let size = DownloadWorker.fileSize(task.partPath) ?? 0
        if fm.fileExists(atPath: task.finalPath) {
            try fm.removeItem(atPath: task.finalPath)
        }
        try fm.moveItem(atPath: task.partPath, toPath: task.finalPath)
        applyDriveModificationDate(task)
        return size
    }

    static func applyDriveModificationDate(_ task: DownloadTask) {
        guard let modified = task.driveModifiedAt else { return }
        let date = Date(timeIntervalSince1970: TimeInterval(modified))
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: task.finalPath)
    }
}
