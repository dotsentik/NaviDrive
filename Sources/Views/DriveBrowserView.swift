import SwiftUI

enum BrowserScope: Hashable {
    case myDrive, sharedWithMe, sharedDrives, linked

    var title: String {
        switch self {
        case .myDrive: String(localized: "My Drive")
        case .sharedWithMe: String(localized: "Shared with Me")
        case .sharedDrives: String(localized: "Shared Drives")
        case .linked: String(localized: "Added by Link")
        }
    }
}

struct DriveBrowserView: View {
    @Environment(AppModel.self) private var model
    let scope: BrowserScope

    @State private var stack: [DriveItem] = []
    @State private var items: [DriveItem] = []
    @State private var isLoading = false
    /// Ошибка, когда показать нечего (полноэкранный ContentUnavailableView).
    @State private var loadError: String?
    /// Ошибка обновления при уже показанных данных (ненавязчивая строка под хлебными крошками).
    @State private var refreshError: String?
    /// Центральный индикатор «Загрузка…» появляется с задержкой, чтобы не мелькать на быстрых ответах.
    @State private var showsSpinner = false
    @State private var spinnerTask: Task<Void, Never>?
    /// Поколение загрузки: результат устаревшего запроса никогда не попадает в новую папку.
    @State private var loadGeneration = 0
    // Строка «Вставьте ссылку» в разделе «Добавленные по ссылке».
    @State private var linkText = ""
    @State private var linkError: String?
    @State private var isOpeningLink = false
    @State private var selection = Set<DriveItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\DriveItem.name, comparator: .localizedStandard)]
    @State private var loadTask: Task<Void, Never>?
    // Редактирование диска
    @State private var renamingId: DriveItem.ID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var trashCandidates: [DriveItem] = []
    @State private var confirmTrash = false
    @State private var moveCandidates: [DriveItem] = []
    @State private var showMovePicker = false
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if !model.isSignedIn {
                // Без входа главное окно закрывается и открывается окно приветствия.
                Color.clear
            } else {
                VStack(spacing: 0) {
                    if scope == .linked {
                        LinkInputBar(text: $linkText, error: linkError, isBusy: isOpeningLink,
                                     open: openLink, details: { model.showAddLink = true })
                        Divider()
                    }
                    breadcrumbs
                    if let refreshError {
                        RefreshErrorBar(message: refreshError, retry: refresh) {
                            withAnimation(.easeOut(duration: 0.15)) { self.refreshError = nil }
                        }
                    }
                    // Полоса обновления лежит в overlay разделителя и не сдвигает вёрстку.
                    Divider()
                        .overlay(alignment: .top) {
                            if isLoading && !items.isEmpty {
                                ThinProgressBar().transition(.opacity)
                            }
                        }
                        .animation(.easeInOut(duration: 0.15), value: isLoading)
                        .zIndex(1)
                    table
                        .mainContentFocus()
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard let target = uploadTarget, !files.isEmpty else { return false }
                    model.startUpload(files, to: target)
                    return true
                } isTargeted: { targeted in
                    isDropTargeted = targeted && uploadTarget != nil
                }
                .overlay { if isDropTargeted, let target = uploadTarget { DropZoneOverlay(folderName: target.name) } }
            }
        }
        .navigationTitle(stack.last?.name ?? scope.title)
        .background {
            // ⌘L «Добавить по ссылке» работает и после переноса кнопки в меню «…».
            Button("Add by Link…") { model.showAddLink = true }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .confirmationDialog(trashTitle, isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { trash(trashCandidates) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items can be restored from the Google Drive trash within 30 days.")
        }
        .sheet(isPresented: $showMovePicker) {
            FolderPickerSheet(title: moveTitle, actionTitle: String(localized: "Move"),
                              excludedIds: Set(moveCandidates.filter(\.isFolder).map(\.id))) { target in
                move(moveCandidates, to: target)
            }
            .environment(model)
        }
        .task(id: model.isSignedIn) {
            guard model.isSignedIn else { return }
            if stack.isEmpty, let saved = model.browserStacks[scope] { stack = saved }
            reload(resetting: true)
        }
        .onChange(of: stack) { _, newValue in model.browserStacks[scope] = newValue }
        // Тулбар (MainView) читает доступность кнопок из модели и шлёт команды сюда.
        .onChange(of: toolbarState, initial: true) { _, state in
            if model.browserToolbar != state { model.browserToolbar = state }
        }
        .onChange(of: model.browserCommand) { _, request in
            if let request { perform(request.command) }
        }
        .onChange(of: model.browserNavigationToken) {
            // Переход, запрошенный извне (например, «Открыть в браузере NaviDrive» из карточки ссылки).
            let requested = model.browserStacks[scope] ?? []
            if requested != stack {
                stack = requested
                reload(resetting: true)
            }
        }
        .onChange(of: model.linkedItems) {
            if isLinkedRoot { reload(resetting: false) }
        }
        .onDisappear { cancelLoading() }
    }

    // MARK: - Subviews

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button(scope.title) { navigate(toDepth: 0) }
                    .buttonStyle(.link)
                ForEach(Array(stack.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    Button(folder.name) { navigate(toDepth: index + 1) }
                        .buttonStyle(.link)
                        .disabled(index == stack.count - 1)
                }
                Spacer()
                if let path = currentFolderRoute {
                    Label(path, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Custom save location for this folder")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var table: some View {
        Table(displayedItems, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 8) {
                    Image(systemName: Self.icon(for: item))
                        .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
                        .frame(width: 18)
                    if renamingId == item.id {
                        TextField("Name", text: $renameText)
                            .textFieldStyle(.roundedBorder)
                            .focused($renameFocused)
                            .onSubmit { commitRename(item) }
                            .onExitCommand { renamingId = nil }
                            .onChange(of: renameFocused) { _, focused in
                                if !focused, renamingId == item.id { commitRename(item) }
                            }
                    } else {
                        Text(item.name).lineLimit(1)
                    }
                    if item.isShortcut {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Shortcut — its target is downloaded and opened")
                    }
                    // Путь берётся из словаря маршрутов в модели (загружен в фоне), а не из SQLite в body.
                    if let path = model.routeMap[item.id] {
                        RouteBadge(path: path, volumeMissing: model.routeVolumeMissing.contains(item.id))
                    }
                }
            }
            .width(min: 240, ideal: 420)

            TableColumn("Size") { item in
                Text(sizeText(item)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 100)

            TableColumn("Modified") { item in
                Text(Format.date(item.modifiedDate)).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Kind") { item in
                Text(Self.kind(for: item)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
        }
        .contextMenu(forSelectionType: DriveItem.ID.self) { ids in
            contextMenu(for: items(for: ids))
        } primaryAction: { ids in
            let selected = items(for: ids)
            if selected.count == 1, let folder = selected.first, folder.isFolder {
                open(folder)
            }
        }
        .overlay {
            // Анимация ограничена содержимым оверлея, чтобы не анимировать подмену строк таблицы.
            ZStack {
                if items.isEmpty {
                    if let loadError {
                        ContentUnavailableView {
                            Label("Couldn’t Load", systemImage: "exclamationmark.icloud")
                        } description: {
                            Text(loadError)
                        } actions: {
                            Button("Retry") { refresh() }
                        }
                    } else if isLoading {
                        if showsSpinner {
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.regular)
                                Text("Loading…").foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.background)
                            .transition(.opacity)
                        }
                    } else {
                        ContentUnavailableView("Folder Is Empty", systemImage: "folder")
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showsSpinner)
        }
    }

    @ViewBuilder
    private func contextMenu(for selected: [DriveItem]) -> some View {
        if selected.isEmpty, let target = uploadTarget {
            // Пустое место списка: действия с текущей папкой.
            Button("New Folder") { createFolder() }
            Button("Upload…") { model.chooseFilesToUpload(into: target) }
        }
        if !selected.isEmpty {
            // Неподдерживаемые объекты не отбрасываются молча: итог покажет баннер в «Менеджере загрузок».
            Button("Download to Default Folder") {
                model.downloadToDefault(selected, ancestors: stack)
            }
            Button("Download to Custom Folder / External SSD…") {
                model.downloadToCustom(selected, ancestors: stack)
            }
            Button("Set Permanent Custom Location…") {
                model.setPermanentRoute(selected)
            }
            if selected.count == 1, let item = selected.first, let route = model.routes.first(where: { $0.driveId == item.id }) {
                Button("Remove Custom Location") { model.deleteRoute(route) }
            }
            Divider()
            Button("Show in Finder") {
                if let first = selected.first { model.revealInFinder(first, ancestors: stack) }
            }
            Divider()
            if uploadTarget != nil {
                Button("New Folder") { createFolder() }
            }
            Button("Rename") {
                if let item = selected.first { beginRename(item) }
            }
            .disabled(selected.count != 1 || !(selected.first?.canRename ?? false))
            Button("Move To…") {
                moveCandidates = selected
                showMovePicker = true
            }
            .disabled(!selected.allSatisfy(\.canMove))
            Button("Move to Trash…") {
                trashCandidates = selected
                confirmTrash = true
            }
            .disabled(!selected.allSatisfy(\.canTrash))
            if isLinkedRoot {
                Divider()
                Button("Remove from Added by Link") {
                    for item in selected { model.removeLinked(item) }
                }
            }
            if selected.count == 1, let folder = selected.first, folder.isFolder {
                Divider()
                Button("Open") { open(folder) }
            }
        }
    }

    // MARK: - Editing

    /// Папка, в которую можно добавлять объекты (новая папка, загрузка, drag & drop).
    /// nil — в корне «Доступные мне», «Общие диски», «Добавленные по ссылке» и там, где нет прав.
    private var uploadTarget: UploadTarget? {
        if let folder = stack.last {
            guard folder.canAddChildren else { return nil }
            return UploadTarget(id: folder.targetId, name: folder.name, driveId: folder.targetDriveId)
        }
        return scope == .myDrive ? .myDriveRoot : nil
    }

    private var trashTitle: String {
        trashCandidates.count == 1
            ? String(localized: "Move “\(trashCandidates[0].name)” to the Trash?")
            : String(localized: "Move \(trashCandidates.count) items to the Trash?")
    }

    private var moveTitle: String {
        moveCandidates.count == 1
            ? String(localized: "Move “\(moveCandidates[0].name)” to…")
            : String(localized: "Move \(moveCandidates.count) items to…")
    }

    /// Создаёт папку и сразу открывает поле ввода имени.
    private func createFolder() {
        guard let target = uploadTarget else { return }
        let names = Set(items.map(\.name))
        Task {
            guard let created = await model.createFolder(in: target, existingNames: names) else { return }
            items.append(created)
            selection = [created.id]
            beginRename(created)
        }
    }

    private func beginRename(_ item: DriveItem) {
        renameText = item.name
        renamingId = item.id
        Task {
            // Фокус — после появления поля в строке таблицы.
            try? await Task.sleep(for: .milliseconds(50))
            renameFocused = true
        }
    }

    private func commitRename(_ item: DriveItem) {
        guard renamingId == item.id else { return }
        renamingId = nil
        let newName = renameText
        Task {
            guard let updated = await model.rename(item, to: newName) else { return }
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = updated }
            refresh()
        }
    }

    private func move(_ selected: [DriveItem], to target: UploadTarget) {
        Task {
            let moved = await model.move(selected, to: target)
            guard !moved.isEmpty else { return }
            if target.id != uploadTarget?.id { items.removeAll { moved.contains($0.id) } }
            selection.subtract(moved)
            refresh()
        }
    }

    private func trash(_ selected: [DriveItem]) {
        Task {
            let trashed = await model.trash(selected)
            guard !trashed.isEmpty else { return }
            items.removeAll { trashed.contains($0.id) }
            selection.subtract(trashed)
            refresh()
        }
    }

    // MARK: - Data

    private var displayedItems: [DriveItem] {
        let filter = model.browserFilter
        let filtered = filter.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        let folders = filtered.filter(\.isFolder).sorted(using: sortOrder)
        let files = filtered.filter { !$0.isFolder }.sorted(using: sortOrder)
        return folders + files
    }

    private var selectedItems: [DriveItem] { items(for: selection) }

    private func items(for ids: Set<DriveItem.ID>) -> [DriveItem] {
        items.filter { ids.contains($0.id) }
    }

    private var currentFolderRoute: String? {
        guard let folder = stack.last else { return nil }
        let ancestors = Array(stack.dropLast())
        let hasRoute = (ancestors + [folder]).contains { model.routeMap[$0.id] != nil }
        guard hasRoute else { return nil }
        return PathResolver.localPath(for: folder, ancestors: ancestors, routes: model.routeMap,
                                      defaultPath: model.defaultDownloadPath)
    }

    private func sizeText(_ item: DriveItem) -> String {
        if item.isFolder { return "—" }
        if item.isShortcut { return item.exportFormat.map { ".\($0.fileExtension)" } ?? "—" }
        if item.isGoogleWorkspaceDocument { return item.exportFormat.map { ".\($0.fileExtension)" } ?? "—" }
        return Format.bytes(item.sizeValue)
    }

    private func open(_ folder: DriveItem) {
        stack.append(folder)
        reload(resetting: true)
    }

    private var toolbarState: BrowserToolbarState {
        BrowserToolbarState(canGoBack: !stack.isEmpty, uploadTarget: uploadTarget,
                            hasSelection: !selection.isEmpty, isLoading: isLoading)
    }

    private func perform(_ command: BrowserCommand) {
        switch command {
        case .back: goBack()
        case .refresh: refresh()
        case .newFolder: if uploadTarget != nil { createFolder() }
        case .upload: if let target = uploadTarget { model.chooseFilesToUpload(into: target) }
        case .download: model.downloadToDefault(selectedItems, ancestors: stack)
        case .downloadToCustom: model.downloadToCustom(selectedItems, ancestors: stack)
        case .setPermanentRoute: model.setPermanentRoute(selectedItems)
        }
    }

    private func goBack() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
        reload(resetting: true)
    }

    private func navigate(toDepth depth: Int) {
        guard depth < stack.count else { return }
        stack.removeSubrange(depth...)
        reload(resetting: true)
    }

    /// ⌘R / кнопка «Обновить»: текущий список остаётся на экране до полной замены.
    private var isLinkedRoot: Bool { scope == .linked && stack.isEmpty }

    /// Разбор ссылки → files.get → папка открывается сразу, файл появляется в списке выделенным.
    private func openLink() {
        let input = linkText
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty, !isOpeningLink else { return }
        linkError = nil
        isOpeningLink = true
        Task {
            defer { isOpeningLink = false }
            do {
                let item = try await model.lookupLink(input)
                linkText = ""
                if item.isFolder {
                    stack = [item]
                    reload(resetting: true)
                } else {
                    stack = []
                    reload(resetting: false)
                    selection = [item.id]
                }
            } catch {
                linkError = error.localizedDescription
            }
        }
    }

    private func refresh() {
        reload(resetting: false)
    }

    /// - Parameter resetting: true — переход в другую папку (список очищается сразу);
    ///   false — обновление текущей папки (новый список собирается отдельно и подменяется целиком).
    private func reload(resetting: Bool) {
        cancelLoading()
        loadGeneration += 1
        let generation = loadGeneration

        if resetting {
            items = []
            selection.removeAll()
            refreshError = nil
        }
        loadError = nil

        // Корень «Добавленные по ссылке» — локальный список из БД, без запроса к API.
        if isLinkedRoot {
            let linked = model.linkedItems.map(\.driveItem)
            let ids = Set(linked.map(\.id))
            selection = selection.filter { ids.contains($0) }
            items = linked
            return
        }

        isLoading = true
        let progressive = items.isEmpty

        if progressive {
            spinnerTask = Task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, generation == loadGeneration, isLoading, items.isEmpty else { return }
                showsSpinner = true
            }
        }

        let listScope: GoogleDriveAPIClient.ListScope
        if let folder = stack.last {
            listScope = .children(of: folder.targetId, driveId: folder.targetDriveId)
        } else {
            switch scope {
            case .myDrive: listScope = .folder("root")
            case .sharedWithMe: listScope = .sharedWithMe
            case .sharedDrives: listScope = .drives
            case .linked: listScope = .folder("root")   // корень «Добавленные по ссылке» читается из БД выше
            }
        }
        let api = model.api
        loadTask = Task {
            var collected: [DriveItem] = []
            do {
                var token: String?
                repeat {
                    let page = try await api.listPage(listScope, pageToken: token)
                    // После каждого await: если пользователь уже ушёл в другую папку — результат отбрасывается.
                    guard !Task.isCancelled, generation == loadGeneration else { return }
                    if progressive {
                        // Пустой экран заполняется постранично — первые строки видны сразу.
                        items.append(contentsOf: page.files)
                        showsSpinner = false
                    } else {
                        collected.append(contentsOf: page.files)
                    }
                    token = page.nextPageToken
                } while token != nil

                if !progressive {
                    let ids = Set(collected.map(\.id))
                    selection = selection.filter { ids.contains($0) }
                    items = collected
                }
                refreshError = nil
            } catch {
                guard !Self.isCancellation(error), !Task.isCancelled, generation == loadGeneration else { return }
                if items.isEmpty {
                    loadError = error.localizedDescription
                } else {
                    refreshError = error.localizedDescription
                }
            }
            finishLoading()
        }
    }

    private func finishLoading() {
        spinnerTask?.cancel()
        spinnerTask = nil
        showsSpinner = false
        isLoading = false
    }

    private func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        finishLoading()
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: - Presentation

    static func icon(for item: DriveItem) -> String {
        if item.isShortcut && item.shortcutDetails?.targetId == nil { return "questionmark.folder" }
        if item.isFolder { return "folder.fill" }
        switch item.effectiveMimeType {
        case "application/vnd.google-apps.document": return "doc.text"
        case "application/vnd.google-apps.spreadsheet": return "tablecells"
        case "application/vnd.google-apps.presentation": return "rectangle.on.rectangle"
        case "application/pdf": return "doc.richtext"
        case let m where m.hasPrefix("image/"): return "photo"
        case let m where m.hasPrefix("video/"): return "film"
        case let m where m.hasPrefix("audio/"): return "waveform"
        case let m where m.contains("zip") || m.contains("compressed") || m.contains("tar"): return "doc.zipper"
        case let m where m.hasPrefix("application/vnd.google-apps."): return "questionmark.square.dashed"
        default: return "doc"
        }
    }

    static func kind(for item: DriveItem) -> String {
        if item.isShortcut {
            if item.isFolder { return String(localized: "Shortcut to folder") }
            if item.shortcutDetails?.targetId == nil { return String(localized: "Shortcut (no target)") }
            return String(localized: "Shortcut to file")
        }
        if item.isFolder { return String(localized: "Folder") }
        switch item.mimeType {
        case "application/vnd.google-apps.document": return String(localized: "Google Doc")
        case "application/vnd.google-apps.spreadsheet": return String(localized: "Google Sheet")
        case "application/vnd.google-apps.presentation": return String(localized: "Google Slides")
        case "application/vnd.google-apps.drawing": return String(localized: "Google Drawing")
        case "application/vnd.google-apps.shortcut": return String(localized: "Shortcut")
        default:
            let ext = (item.name as NSString).pathExtension.uppercased()
            return ext.isEmpty ? String(localized: "File") : ext
        }
    }
}

/// Подсветка зоны сброса файлов из Finder: «Загрузить в <имя папки>».
private struct DropZoneOverlay: View {
    let folderName: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            Label("Upload to “\(folderName)”", systemImage: "arrow.up.doc")
                .font(.title3.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(8)
        .allowsHitTesting(false)
        .accessibilityLabel("Upload to “\(folderName)”")
    }
}

/// Тонкая (2 pt) неопределённая полоса прогресса для обновления без сдвига вёрстки.
private struct ThinProgressBar: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.linear)
            .controlSize(.small)
            .labelsHidden()
            .frame(height: 2)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityLabel("Refreshing list")
    }
}

/// Ненавязчивая строка об ошибке обновления, когда старые данные остаются на экране.
private struct RefreshErrorBar: View {
    let message: String
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Couldn’t refresh: \(message)")
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
                .buttonStyle(.link)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }
}

/// Оранжевый значок кастомного маршрута с подсказкой «Сохраняется в: …».
private struct RouteBadge: View {
    let path: String
    let volumeMissing: Bool

    private var displayPath: String { PathResolver.displayPath(path) }

    private var helpText: String {
        var text = String(localized: "Saved to: \(displayPath)")
        if volumeMissing { text += "\n" + String(localized: "Disk not connected") }
        return text
    }

    var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .foregroundStyle(.orange)
            .help(helpText)
            .accessibilityLabel("Custom save location")
            .accessibilityValue(volumeMissing ? String(localized: "\(displayPath), disk not connected") : displayPath)
    }
}

/// Поле для ссылки на файл или папку Google Drive в разделе «Добавленные по ссылке».
private struct LinkInputBar: View {
    @Binding var text: String
    let error: String?
    let isBusy: Bool
    let open: () -> Void
    let details: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Paste a link to a Google Drive file or folder",
                          text: $text, prompt: Text("https://drive.google.com/drive/folders/…  or ID"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(open)
                if isBusy { ProgressView().controlSize(.small) }
                Button("Open", action: open)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                Button("Details…", action: details)
                    .help("Folder size, number of files and free disk space")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
