import CryptoKit
import Foundation

/// Потоковый хеш локального файла тем алгоритмом, которым облако подтверждает содержимое.
/// Файл читается блоками на фоновой очереди и целиком в память не загружается.
enum ContentHasher {
    static let readChunkSize = 8 * 1_048_576
    /// Размер блока Dropbox content_hash.
    static let dropboxBlockSize = 4 * 1_048_576
    private static let queue = DispatchQueue(label: "com.navidrive.content-hash", qos: .utility, attributes: .concurrent)

    /// Хеш файла (hex, нижний регистр). `progress` — прочитано байт.
    static func hash(ofFileAt path: String, kind: CloudHashKind,
                     progress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let handle = FileHandle(forReadingAtPath: path) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    defer { try? handle.close() }
                    var hasher = makeHasher(kind)
                    let chunkSize = readChunkSize
                    var total: Int64 = 0
                    var lastReport: Int64 = 0
                    while true {
                        let finished: Bool = try autoreleasepool {
                            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return true }
                            hasher.update(data)
                            total += Int64(data.count)
                            return false
                        }
                        if finished { break }
                        if total - lastReport >= 64 * 1_048_576 {
                            lastReport = total
                            progress(total)
                        }
                    }
                    continuation.resume(returning: hasher.finalize())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makeHasher(_ kind: CloudHashKind) -> any StreamingHasher {
        switch kind {
        case .md5: MD5Hasher()
        case .dropboxContentHash: DropboxContentHasher()
        }
    }
}

private protocol StreamingHasher {
    mutating func update(_ data: Data)
    func finalize() -> String
}

private extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private struct MD5Hasher: StreamingHasher {
    private var md5 = Insecure.MD5()
    mutating func update(_ data: Data) { md5.update(data: data) }
    func finalize() -> String { md5.finalize().hexString }
}

/// SHA-256 от конкатенации SHA-256 каждого блока по 4 МБ (последний — короче).
/// Данные копятся до целого блока: границы блоков не зависят от размера прочитанных кусков.
private struct DropboxContentHasher: StreamingHasher {
    private var overall = SHA256()
    private var block = SHA256()
    private var blockFill = 0

    mutating func update(_ data: Data) {
        var rest = data[...]
        while !rest.isEmpty {
            let take = min(ContentHasher.dropboxBlockSize - blockFill, rest.count)
            block.update(data: rest.prefix(take))
            blockFill += take
            rest = rest.dropFirst(take)
            if blockFill == ContentHasher.dropboxBlockSize { closeBlock() }
        }
    }

    private mutating func closeBlock() {
        overall.update(data: Data(block.finalize()))
        block = SHA256()
        blockFill = 0
    }

    func finalize() -> String {
        var copy = self
        if copy.blockFill > 0 { copy.closeBlock() }
        return copy.overall.finalize().hexString
    }
}
