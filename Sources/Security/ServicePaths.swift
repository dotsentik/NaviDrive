import Foundation

/// Пути, полученные сервисом «Upload to NaviDrive» с пасборда. Пасборд заполняет любое приложение,
/// поэтому принимаются только абсолютные пути к существующим объектам — стандартизованные и без повторов.
enum ServicePaths {
    static func sanitize(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in paths {
            guard raw.hasPrefix("/"), !raw.utf8.contains(0) else { continue }
            let path = (raw as NSString).standardizingPath
            guard path.hasPrefix("/"), path != "/",
                  (try? FileManager.default.attributesOfItem(atPath: path)) != nil,
                  seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }
}
