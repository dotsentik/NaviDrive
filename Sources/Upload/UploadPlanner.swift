import Foundation

/// Подготовка пачки к отправке в два шага:
/// 1. `scan` — обход локальных файлов и папок и поиск имён, уже занятых в облаке
///    (ничего не создаёт, чтобы спросить про конфликты один раз на всю пачку);
/// 2. `materialize` — создание на диске всего дерева подпапок, затем задачи в очередь.
///
/// Папка с тем же именем, что уже есть на диске, не дублируется: файлы попадают в существующую,
/// а конфликты имён файлов внутри неё решаются выбранным правилом.
struct UploadPlanner: Sendable {
    let provider: any CloudProvider

    struct PlanFile: Sendable {
        let path: String
        let name: String
        let size: Int64
        let modifiedAt: Int64
        /// Файл с таким именем уже есть в целевой папке.
        let existingId: String?
    }

    struct PlanFolder: Sendable {
        let name: String
        /// Папка с таким именем уже есть — файлы пойдут в неё.
        let existingId: String?
        /// Имена, уже занятые в существующей папке на диске.
        let remoteNames: Set<String>
        var folders: [PlanFolder] = []
        var files: [PlanFile] = []
    }

    struct Plan: Sendable {
        let target: UploadTarget
        var root: PlanFolder
        var conflicts: [String] = []
        var fileCount = 0
        var totalBytes: Int64 = 0
        var unreadable: [String] = []
    }

    // MARK: - Scan

    func scan(_ urls: [URL], into target: UploadTarget) async throws -> Plan {
        let remote = try await provider.listAll(.folder(id: target.id, spaceId: target.spaceId))
        var plan = Plan(target: target, root: PlanFolder(name: target.name, existingId: target.id,
                                                         remoteNames: Set(remote.map(\.name))))
        var root = plan.root
        try await add(urls, to: &root, remote: remote, plan: &plan, path: "")
        plan.root = root
        return plan
    }

    private func add(_ urls: [URL], to folder: inout PlanFolder, remote: [CloudItem], plan: inout Plan, path: String) async throws {
        let remoteByName = Dictionary(remote.map { (nameKey($0.name), $0) }, uniquingKeysWith: { first, second in
            // Если есть и папка, и файл с одним именем, для слияния папок важна папка.
            first.isFolder ? first : second
        })
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true { continue }
            let existing = remoteByName[nameKey(name)]
            if values?.isDirectory == true {
                let existingFolder = existing.flatMap { $0.isFolder && !$0.isAlias ? $0 : nil }
                var innerRemote: [CloudItem] = []
                if let existingFolder {
                    innerRemote = try await provider.listAll(provider.location(of: existingFolder))
                }
                // ID папки как цели загрузки (у Dropbox — путь).
                var child = PlanFolder(name: name, existingId: existingFolder.map { provider.uploadTarget(for: $0).id },
                                       remoteNames: Set(innerRemote.map(\.name)))
                let contents: [URL]
                do {
                    contents = try FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
                        options: [.skipsHiddenFiles])
                } catch {
                    plan.unreadable.append(url.path)
                    continue
                }
                try await add(contents, to: &child, remote: innerRemote, plan: &plan, path: path + name + "/")
                folder.folders.append(child)
            } else if values?.isRegularFile == true {
                guard let attributes = UploadTask.sourceAttributes(url.path) else {
                    plan.unreadable.append(url.path)
                    continue
                }
                let existingFile = existing.flatMap { $0.isFolder ? nil : $0 }
                if existingFile != nil { plan.conflicts.append(path + name) }
                folder.files.append(PlanFile(path: url.path, name: name, size: attributes.size,
                                             modifiedAt: attributes.modifiedAt, existingId: existingFile?.id))
                plan.fileCount += 1
                plan.totalBytes += attributes.size
            }
        }
    }

    /// Ключ сравнения имён: в облаке без учёта регистра «Фото» и «фото» — одно и то же имя.
    private func nameKey(_ name: String) -> String {
        provider.caseInsensitiveNames ? name.lowercased() : name
    }

    // MARK: - Materialize

    struct Result: Sendable {
        var tasks: [UploadTask] = []
        var foldersCreated = 0
        var skipped = 0
    }

    /// Создаёт недостающие папки (всё дерево) и возвращает задачи для очереди.
    /// - Parameter ancestorIds: папки над целевой (ID цели загрузки) — для общего прогресса у строк папок.
    func materialize(_ plan: Plan, policy: UploadConflictPolicy, ancestorIds: [String] = []) async throws -> Result {
        var result = Result()
        try await place(plan.root, in: plan.target, display: plan.target.name, policy: policy,
                        ancestors: ancestorIds, result: &result)
        return result
    }

    private func place(_ folder: PlanFolder, in target: UploadTarget, display: String,
                       policy: UploadConflictPolicy, ancestors: [String], result: inout Result) async throws {
        let chain = ancestors + [target.id]
        // Сначала подпапки — всё дерево создаётся до постановки файлов в очередь.
        for child in folder.folders {
            try Task.checkCancellation()
            let childId: String
            if let existing = child.existingId {
                childId = existing
            } else {
                childId = provider.uploadTarget(for: try await provider.createFolder(named: child.name, in: target)).id
                result.foldersCreated += 1
            }
            let childTarget = UploadTarget(provider: target.provider, id: childId, name: child.name, spaceId: target.spaceId)
            try await place(child, in: childTarget, display: display + " / " + child.name, policy: policy,
                            ancestors: chain, result: &result)
        }
        var used = folder.remoteNames
        for file in folder.files {
            var name = file.name
            var replaceId: String?
            if let existing = file.existingId {
                switch policy {
                case .skip:
                    result.skipped += 1
                    continue
                case .replace:
                    replaceId = existing
                case .keepBoth:
                    // Облако с autorename само подберёт свободное имя при фиксации файла.
                    if !provider.autorenamesOnConflict { name = Self.keepBothName(file.name, used: used) }
                }
            }
            used.insert(name)
            result.tasks.append(UploadTask(
                id: UUID().uuidString, localPath: file.path, fileName: name, fileSize: file.size,
                localModifiedAt: file.modifiedAt, parentDriveId: target.id, parentName: display, sharedDriveId: target.spaceId,
                replaceFileId: replaceId, sessionURI: nil, sessionCreatedAt: nil, uploadedBytes: 0, status: .queued,
                retryCount: 0, lastError: nil, errorKind: nil, driveFileId: nil, checksum: nil, updatedAt: 0,
                provider: target.provider, conflictPolicy: policy, folderIds: chain))
        }
    }

    /// «Отчёт.pdf» → «Отчёт (1).pdf», «Отчёт (2).pdf», … — первое свободное имя.
    static func keepBothName(_ name: String, used: Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var counter = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if !used.contains(candidate) { return candidate }
            counter += 1
        }
    }
}
