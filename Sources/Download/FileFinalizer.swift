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

    /// Расширенный атрибут скачанного файла: «провайдер:ID в облаке». По нему файл узнаётся как свой.
    static let originAttribute = "com.navidrive.origin"

    /// `.gdrive.part` → финальное имя и дата изменения из облака. По итоговому пути ничего не удаляется:
    /// заменяется (одним rename) только файл, ранее скачанный NaviDrive из того же объекта облака.
    /// Папка, ссылка или чужой файл остаются на месте, а скачанный файл получает свободное имя («Отчёт (2).pdf»).
    static func finalize(_ task: DownloadTask) throws -> Int64 {
        if PathResolver.isSymlink(task.partPath) { throw PathResolver.PathSafetyError.symlink(task.partPath) }
        let size = DownloadWorker.fileSize(task.partPath) ?? 0
        let origin = "\(task.provider.rawValue):\(task.driveFileId)"
        // Метка ставится до переименования и переезжает вместе с файлом.
        setOrigin(origin, at: task.partPath)
        let path = try place(task, origin: origin)
        applyDriveModificationDate(task, at: path)
        return size
    }

    static func applyDriveModificationDate(_ task: DownloadTask, at path: String) {
        guard let modified = task.driveModifiedAt else { return }
        let date = Date(timeIntervalSince1970: TimeInterval(modified))
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// Переносит `.part` на итоговый путь и возвращает его.
    private static func place(_ task: DownloadTask, origin: String) throws -> String {
        if isOwnFile(task.finalPath, origin: origin) {
            // Прежняя версия этого же файла: атомарная замена.
            try rename(task.partPath, to: task.finalPath, exclusive: false)
            return task.finalPath
        }
        let dir = task.targetDirPath as NSString
        var used: Set<String> = [task.fileName.lowercased()]
        var candidate = task.finalPath
        while true {
            // Имя занято на диске или его `.part` принадлежит другой загрузке — берём следующее.
            let partTaken = candidate != task.finalPath && exists(candidate + task.provider.partialSuffix)
            if !exists(candidate), !partTaken {
                do {
                    try rename(task.partPath, to: candidate, exclusive: true)
                    return candidate
                } catch let error as POSIXError where error.code == .EEXIST {
                    // Имя заняли между проверкой и переименованием.
                }
            }
            candidate = dir.appendingPathComponent(PathResolver.uniqueName(task.fileName, used: &used))
        }
    }

    /// Обычный файл (не ссылка и не папка) с меткой этого же объекта облака.
    private static func isOwnFile(_ path: String, origin: String) -> Bool {
        guard let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType,
              type == .typeRegular else { return false }
        return Self.origin(at: path) == origin
    }

    /// Есть ли что-то по пути (без перехода по ссылкам: висячая ссылка тоже считается).
    private static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// `exclusive` — не перезаписывать существующее (RENAME_EXCL). Без него rename атомарно заменяет файл.
    private static func rename(_ source: String, to destination: String, exclusive: Bool) throws {
        if renamex_np(source, destination, exclusive ? UInt32(RENAME_EXCL) : 0) == 0 { return }
        let code = errno
        // Файловая система без RENAME_EXCL (например, FAT): проверка и обычный rename.
        if exclusive, code == ENOTSUP {
            guard !exists(destination) else { throw POSIXError(.EEXIST) }
            if Darwin.rename(source, destination) == 0 { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func setOrigin(_ value: String, at path: String) {
        _ = value.withCString { setxattr(path, originAttribute, $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }

    private static func origin(at path: String) -> String? {
        let length = getxattr(path, originAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(path, originAttribute, &buffer, length, 0, XATTR_NOFOLLOW) == length else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
}
