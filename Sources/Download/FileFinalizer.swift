import Foundation

/// Завершение скачанного файла: потоковая сверка хеша тем алгоритмом, которым его считает облако
/// (на фоновой очереди, без загрузки файла в память), переименование `.gdrive.part` → имя файла
/// и дата изменения из облака.
enum FileFinalizer {
    enum VerificationResult: Sendable {
        case verified(Int64)
        case mismatch(expected: String, actual: String)
        case missingFile
        case failed(String)
    }

    /// Сверка `.gdrive.part` с хешем из облака (для Google — MD5).
    static func verify(_ task: DownloadTask, progress: @escaping @Sendable (Int64) -> Void) async -> VerificationResult {
        guard let expected = task.checksum?.lowercased(), !expected.isEmpty else {
            return .verified(DownloadWorker.fileSize(task.partPath) ?? 0)
        }
        guard let size = DownloadWorker.fileSize(task.partPath) else { return .missingFile }
        do {
            let actual = try await ContentHasher.hash(ofFileAt: task.partPath, kind: task.hashKind, progress: progress)
            return actual == expected ? .verified(size) : .mismatch(expected: expected, actual: actual)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `.gdrive.part` → финальное имя (существующий файл заменяется) и дата изменения из облака.
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
