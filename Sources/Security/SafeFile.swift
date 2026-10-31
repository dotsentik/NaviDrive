import Foundation

/// Открытие файлов без перехода по символической ссылке в последнем компоненте пути (`O_NOFOLLOW`)
/// и только для обычных файлов. Проверка и открытие — один системный вызов: ссылку нельзя подложить
/// между проверкой и записью (TOCTOU).
enum SafeFile {
    /// Открывает обычный файл для чтения и записи. `create` — создать, если файла нет (права 0644).
    static func openForUpdate(_ path: String, create: Bool = false) throws -> FileHandle {
        try open(path, flags: O_RDWR | (create ? O_CREAT : 0))
    }

    /// Открывает обычный файл только для чтения.
    static func openForReading(_ path: String) throws -> FileHandle {
        try open(path, flags: O_RDONLY)
    }

    /// Обрезает обычный файл до нуля (по дескриптору, без перехода по ссылке).
    static func truncate(_ path: String) throws {
        let handle = try open(path, flags: O_WRONLY)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
    }

    private static func open(_ path: String, flags: Int32) throws -> FileHandle {
        let fd = Darwin.open(path, flags | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw POSIXError(.EFTYPE)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
