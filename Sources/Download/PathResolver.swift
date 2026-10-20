import Foundation

/// Определяет локальную папку для объекта облака.
///
/// Приоритет: кастомный путь самого объекта → ближайшего предка (с сохранением структуры подпапок
/// от этого предка) → глобальный дефолтный путь. Кастомный путь означает «куда поместить объект»:
/// папка `X` с маршрутом `/Volumes/SSD` скачивается в `/Volumes/SSD/X/...`.
/// Маршруты ищутся по паре (провайдер, ID объекта).
enum PathResolver {
    /// - Parameters:
    ///   - item: скачиваемый объект.
    ///   - ancestors: цепочка родительских папок от корня браузера до непосредственного родителя.
    ///   - routes: таблица кастомных маршрутов `(provider, drive_id) → local_path`.
    /// - Returns: директория, в которую будет помещён объект.
    static func destinationDirectory(for item: CloudItem, ancestors: [CloudItem],
                                     routes: [RouteKey: String], defaultPath: String) -> String {
        if let own = routes[item.routeKey] { return expand(own) }
        for index in ancestors.indices.reversed() {
            guard let base = routes[ancestors[index].routeKey] else { continue }
            var path = expand(base)
            for folder in ancestors[index...] {
                path = (path as NSString).appendingPathComponent(sanitize(folder.name))
            }
            return path
        }
        return expand(defaultPath)
    }

    /// Локальный путь самого объекта (файла или папки).
    static func localPath(for item: CloudItem, ancestors: [CloudItem],
                          routes: [RouteKey: String], defaultPath: String) -> String {
        let dir = destinationDirectory(for: item, ancestors: ancestors, routes: routes, defaultPath: defaultPath)
        return (dir as NSString).appendingPathComponent(item.isFolder ? sanitize(item.name) : item.localFileName)
    }

    /// Путь для показа: домашняя папка как «~» (~/Downloads/Work), остальные пути — полностью (/Volumes/SSD/Backup).
    static func displayPath(_ path: String) -> String {
        (expand(path) as NSString).abbreviatingWithTildeInPath
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Имя, допустимое в файловой системе macOS.
    static func sanitize(_ name: String) -> String {
        var result = name.replacingOccurrences(of: "/", with: "∕").replacingOccurrences(of: ":", with: "꞉")
        // Управляющие символы (в том числе \0, перевод строки) в имени файла не допускаются.
        result = String(String.UnicodeScalarView(result.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty || result == "." || result == ".." { result = "untitled" }
        // Ограничение длины имени (255 байт UTF-8) с запасом под ".gdrive.part" / ".dropbox.part".
        while result.utf8.count > 230 { result.removeLast() }
        return result
    }

    /// Уникальное имя в пределах одной папки (облако может допускать одинаковые имена).
    static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var counter = 2
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    // MARK: - Path safety

    enum PathSafetyError: LocalizedError {
        case outsideRoot(String)
        case symlink(String)

        var errorDescription: String? {
            switch self {
            case .outsideRoot(let path):
                String(localized: "The path “\(path)” is outside the destination folder — the file was rejected")
            case .symlink(let path):
                String(localized: "“\(path)” is a symbolic link — NaviDrive doesn’t write through symbolic links")
            }
        }
    }

    /// `path` после стандартизации лежит внутри `root`, и ни один уже существующий компонент
    /// ниже `root` не является символической ссылкой (запись не уходит по подложенной ссылке).
    /// Сам `root` выбран пользователем и может быть ссылкой — его не проверяем.
    static func validate(_ path: String, inside root: String) throws {
        // Лексически: без «..», внутри корня. (standardizedFileURL не годится: у существующих путей
        // он убирает «/private», у несуществующих — нет.)
        let rootComponents = (expand(root) as NSString).pathComponents.filter { $0 != "." }
        let components = (expand(path) as NSString).pathComponents.filter { $0 != "." }
        guard !components.contains(".."), !rootComponents.contains(".."),
              components.count > rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents else {
            throw PathSafetyError.outsideRoot(path)
        }
        // Ни один уже существующий компонент ниже корня не является символической ссылкой.
        var current = expand(root) as NSString
        for component in components.dropFirst(rootComponents.count) {
            current = current.appendingPathComponent(component) as NSString
            guard let type = try? FileManager.default.attributesOfItem(atPath: current as String)[.type] as? FileAttributeType else {
                break   // дальше компонентов ещё нет — они будут созданы как обычные папки
            }
            if type == .typeSymbolicLink { throw PathSafetyError.symlink(current as String) }
        }
        // То же после раскрытия ссылок: итоговый путь обязан остаться внутри раскрытого корня.
        let resolvedRoot = resolved(expand(root)).pathComponents
        let resolvedPath = resolved(expand(path)).pathComponents
        guard resolvedPath.count > resolvedRoot.count, Array(resolvedPath.prefix(resolvedRoot.count)) == resolvedRoot else {
            throw PathSafetyError.outsideRoot(path)
        }
    }

    /// Путь с раскрытыми ссылками: realpath() ближайшего существующего предка + ещё не созданные компоненты.
    /// (`resolvingSymlinksInPath` убирает «/private» у /private/tmp и не годится для сравнения.)
    private static func resolved(_ path: String) -> URL {
        var existing = URL(fileURLWithPath: path)
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var base = existing
        if let real = realpath(existing.path, nil) {
            base = URL(fileURLWithPath: String(cString: real))
            free(real)
        }
        return tail.reduce(base) { $0.appendingPathComponent($1) }
    }

    /// Файл по пути — символическая ссылка (сама ссылка, без перехода по ней).
    static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    // MARK: - Volumes

    enum VolumeState: Sendable {
        case available
        case missing(String)
    }

    /// `/Volumes/<Name>` для путей на внешних томах, иначе nil.
    static func volumeRoot(for path: String) -> String? {
        let components = (expand(path) as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Volumes" else { return nil }
        return "/Volumes/\(components[1])"
    }

    /// Ключ тома для пути: `/Volumes/<Name>` для внешних томов, «/» — системный диск.
    static func volumeKey(for path: String) -> String {
        volumeRoot(for: path) ?? "/"
    }

    /// Проверяет, что для путей вида `/Volumes/<Name>/...` том действительно смонтирован.
    static func volumeState(for path: String) -> VolumeState {
        let components = (expand(path) as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Volumes" else { return .available }
        let volumeName = String(components[1])
        let volumePath = "/Volumes/\(volumeName)"
        let url = URL(fileURLWithPath: volumePath).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let values = try? url.resourceValues(forKeys: [.isVolumeKey]), values.isVolume == true else {
            return .missing(String(localized: "External disk “\(volumeName)” is not connected. The transfer will continue automatically once it is connected."))
        }
        return .available
    }

    /// Реально пустое место без очищаемого (как «Свободно» в Дисковой утилите).
    static func freeCapacity(at path: String) -> Int64? {
        var url = URL(fileURLWithPath: expand(path))
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
    }

    static func availableCapacity(at path: String) -> Int64? {
        var url = URL(fileURLWithPath: expand(path))
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
