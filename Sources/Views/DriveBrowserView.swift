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

    /// Корень Dropbox называется «Dropbox».
    func title(for cloud: CloudProviderKind) -> String {
        self == .myDrive && cloud == .dropbox ? cloud.displayName : title
    }
}

struct DriveBrowserView: View {
    @Environment(AppModel.self) private var model
    let scope: BrowserScope

    @State private var stack: [CloudItem] = []
    @State private var items: [CloudItem] = []
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
    @State private var selection = Set<CloudItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\CloudItem.name, comparator: .localizedStandard)]
    @State private var loadTask: Task<Void, Never>?
    // Редактирование диска
    @State private var renamingId: CloudItem.ID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var trashCandidates: [CloudItem] = []
    @State private var confirmTrash = false
    @State private var moveCandidates: [CloudItem] = []
    @State private var showMovePicker = false
    @State private var isDropTargeted = false
    @State private var downloadCancelCandidates: [TransferSubject] = []
    @State private var confirmDownloadCancel = false

    var body: some View {
        Group {
            if !model.isActiveCloudSignedIn {
                // Без входа главное окно закрывается и открывается окно приветствия.
                Color.clear
            } else {
                VStack(spacing: 0) {
                    if scope == .linked {
                        LinkInputBar(cloud: model.activeCloud, text: $linkText, error: linkError, isBusy: isOpeningLink,
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
                    model.startUpload(files, to: target, ancestorIds: uploadAncestorIds)
                    return true
                } isTargeted: { targeted in
                    isDropTargeted = targeted && uploadTarget != nil
                }
                .overlay { if isDropTargeted, let target = uploadTarget { DropZoneOverlay(folderName: target.name) } }
            }
        }
        .navigationTitle(stack.last?.name ?? scope.title(for: model.activeCloud))
        .background {
            // ⌘L «Добавить по ссылке» работает и после переноса кнопки в меню «…».
            Button("Add by Link…") { model.showAddLink = true }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .confirmationDialog(trashTitle, isPresented: $confirmTrash) {
            if deletesPermanently {
                Button("Delete", role: .destructive) { trash(trashCandidates) }
            } else {
                Button("Move to Trash", role: .destructive) { trash(trashCandidates) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if deletesPermanently {
                Text("Deleted items can be restored on the Dropbox website (Deleted files) during your plan’s file recovery period.")
            } else {
                Text("Items can be restored from the Google Drive trash within 30 days.")
            }
        }
        // Отмена скачивания удаляет уже скачанную часть — как в «Менеджере загрузок», с подтверждением.
        .confirmationDialog("Cancel the download?", isPresented: $confirmDownloadCancel) {
            Button("Cancel Download", role: .destructive) {
                downloadCancelCandidates.forEach { model.cancelTransfer($0) }
            }
            Button("Don’t Cancel", role: .cancel) {}
        } message: {
            Text("The part already downloaded will be deleted. To continue later, use Pause.")
        }
        .sheet(isPresented: $showMovePicker) {
            FolderPickerSheet(title: moveTitle, actionTitle: String(localized: "Move"),
                              excludedIds: Set(moveCandidates.filter(\.isFolder).map { model.provider.uploadTarget(for: $0).id })) { target in
                move(moveCandidates, to: target)
            }
            .environment(model)
        }
        .task(id: model.isActiveCloudSignedIn) {
            guard model.isActiveCloudSignedIn else { return }
            if stack.isEmpty, let saved = model.browserStacks[stackKey] { stack = saved }
            reload(resetting: true)
        }
        .onChange(of: stack) { _, newValue in model.browserStacks[stackKey] = newValue }
        // Тулбар (MainView) читает доступность кнопок из модели и шлёт команды сюда.
        .onChange(of: toolbarState, initial: true) { _, state in
            if model.browserToolbar != state { model.browserToolbar = state }
        }
        .onChange(of: model.browserCommand) { _, request in
            if let request { perform(request.command) }
        }
        .onChange(of: model.browserNavigationToken) {
            // Переход, запрошенный извне (например, «Открыть в браузере NaviDrive» из карточки ссылки).
            let requested = model.browserStacks[stackKey] ?? []
            if requested != stack {
                stack = requested
                reload(resetting: true)
            }
        }
        .onChange(of: model.linkedItems) {
            if isLinkedRoot { reload(resetting: false) }
        }
        // Индикаторы передач: модель читает очереди для строк текущей папки.
        .onChange(of: items, initial: true) { publishTransferContext() }
        .onChange(of: stack) { publishTransferContext() }
        // Отправленный файл уже в облаке или созданы папки — список папки обновляется тихо, без мерцания.
        .onChange(of: model.browserListingStaleToken) { if !isLoading { refresh() } }
        .onDisappear {
            cancelLoading()
            model.browserTransferContext = nil
        }
    }

    // MARK: - Subviews

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button(scope.title(for: model.activeCloud)) { navigate(toDepth: 0) }
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
                    if let indicator = model.browserTransfers.indicators[item.id] {
                        TransferIndicatorView(indicator: indicator)
                            .transition(.opacity)
                    }
                    if item.isAlias {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Shortcut — its target is downloaded and opened")
                    }
                    // Путь берётся из словаря маршрутов в модели (загружен в фоне), а не из SQLite в body.
                    if let path = model.routeMap[item.routeKey] {
                        RouteBadge(path: path, volumeMissing: model.routeVolumeMissing.contains(item.routeKey))
                    }
                }
            }
            .width(min: 240, ideal: 420)

            TableColumn("Size") { item in
                Text(sizeText(item)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 100)

            TableColumn("Modified") { item in
                Text(Format.date(item.modifiedAt)).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Kind") { item in
                Text(Self.kind(for: item)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
        }
        .contextMenu(forSelectionType: CloudItem.ID.self) { ids in
            contextMenu(for: items(for: ids))
        } primaryAction: { ids in
            let selected = items(for: ids)
            if selected.count == 1, let folder = selected.first, folder.isFolder, !isUploading(folder) {
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
    private func contextMenu(for selected: [CloudItem]) -> some View {
        if selected.isEmpty, uploadTarget != nil || !stack.isEmpty {
            // Пустое место списка: действия с текущей папкой (в папке только для чтения — неактивны).
            Button("New Folder") { createFolder() }
                .disabled(uploadTarget == nil)
            Button("Upload…") { if let target = uploadTarget { model.chooseFilesToUpload(into: target, ancestorIds: uploadAncestorIds) } }
                .disabled(uploadTarget == nil)
        }
        if !selected.isEmpty {
            transferMenu(for: selected)
            // Загружаемый файл нельзя открыть, скачать, переименовать или переместить.
            let uploading = selected.contains(where: isUploading)
            // Неподдерживаемые объекты не отбрасываются молча: итог покажет баннер в «Менеджере загрузок».
            Button("Download to Default Folder") {
                model.downloadToDefault(selected, ancestors: stack)
            }
            .disabled(uploading)
            Button("Download to Custom Folder / External SSD…") {
                model.downloadToCustom(selected, ancestors: stack)
            }
            .disabled(uploading)
            Button("Set Permanent Custom Location…") {
                model.setPermanentRoute(selected)
            }
            .disabled(uploading)
            if selected.count == 1, let item = selected.first, let route = model.route(for: item) {
                Button("Remove Custom Location") { model.deleteRoute(route) }
            }
            Divider()
            Button("Show in Finder") {
                if let first = selected.first { model.revealInFinder(first, ancestors: stack) }
            }
            .disabled(selected.contains { AppModel.isUploadPlaceholder($0.id) })
            Divider()
            if uploadTarget != nil || !stack.isEmpty {
                Button("New Folder") { createFolder() }
                    .disabled(uploadTarget == nil)
            }
            Button("Rename") {
                if let item = selected.first { beginRename(item) }
            }
            .disabled(selected.count != 1 || !(selected.first?.canRename ?? false) || uploading)
            Button("Move To…") {
                moveCandidates = selected
                showMovePicker = true
            }
            .disabled(!selected.allSatisfy(\.canMove) || uploading)
            Button {
                trashCandidates = selected
                confirmTrash = true
            } label: {
                if model.activeCloud == .dropbox { Text("Delete…") } else { Text("Move to Trash…") }
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
                    .disabled(uploading)
            }
        }
    }

    /// «Пауза»/«Продолжить», «Отменить», «Показать в …» для строк с идущей передачей.
    @ViewBuilder
    private func transferMenu(for selected: [CloudItem]) -> some View {
        let indicators = selected.compactMap { model.browserTransfers.indicators[$0.id] }
        if !indicators.isEmpty {
            if indicators.contains(where: \.canPause) {
                Button("Pause") { indicators.filter(\.canPause).forEach { model.pauseTransfer($0.subject) } }
            }
            if indicators.contains(where: \.canResume) {
                Button("Resume") { indicators.filter(\.canResume).forEach { model.resumeTransfer($0.subject) } }
            }
            let uploads = indicators.filter(\.isUpload)
            let downloads = indicators.filter { !$0.isUpload }
            if !uploads.isEmpty {
                Button("Cancel Upload") { uploads.forEach { model.cancelTransfer($0.subject) } }
            }
            if !downloads.isEmpty {
                Button("Cancel Download…") {
                    downloadCancelCandidates = downloads.map(\.subject)
                    confirmDownloadCancel = true
                }
            }
            if let first = uploads.first {
                Button("Show in Uploads") { model.showTransferManager(first.subject) }
            }
            if let first = downloads.first {
                Button("Show in Download Manager") { model.showTransferManager(first.subject) }
            }
            Divider()
        }
    }

    /// Файл ещё отправляется (строка-заглушка или замена существующего файла).
    private func isUploading(_ item: CloudItem) -> Bool {
        if AppModel.isUploadPlaceholder(item.id) { return true }
        guard let indicator = model.browserTransfers.indicators[item.id], indicator.isUpload else { return false }
        return !item.isFolder
    }

    /// Папки над целью загрузки (ID цели) — для общего прогресса у строк папок.
    private var uploadAncestorIds: [String] {
        stack.dropLast().map { model.provider.uploadTarget(for: $0).id }
    }

    private func publishTransferContext() {
        let provider = model.provider
        let rows = items.map { item in
            BrowserTransferContext.Row(id: item.id, name: item.name, isFolder: item.isFolder, downloadId: item.targetId,
                                       uploadFolderId: item.isFolder && !item.isAlias ? provider.uploadTarget(for: item).id : nil)
        }
        let context = BrowserTransferContext(provider: provider.kind, uploadParentId: uploadTarget?.id,
                                             caseInsensitiveNames: provider.caseInsensitiveNames, rows: rows)
        guard model.browserTransferContext != context else { return }
        model.browserTransferContext = context
        Task { await model.refreshBrowserTransfers() }
    }

    // MARK: - Editing

    /// Папка, в которую можно добавлять объекты (новая папка, загрузка, drag & drop).
    /// nil — в корне «Доступные мне», «Общие диски», «Добавленные по ссылке» и там, где нет прав.
    private var uploadTarget: UploadTarget? {
        if let folder = stack.last {
            guard folder.canAddChildren else { return nil }
            return model.provider.uploadTarget(for: folder)
        }
        return scope == .myDrive ? model.provider.rootFolder : nil
    }

    /// Dropbox удаляет без корзины: объект восстанавливается на сайте в течение срока хранения.
    private var deletesPermanently: Bool {
        (trashCandidates.first?.provider ?? model.activeCloud) == .dropbox
    }

    private var trashTitle: String {
        if deletesPermanently {
            return trashCandidates.count == 1
                ? String(localized: "Delete “\(trashCandidates[0].name)” from Dropbox?")
                : String(localized: "Delete \(trashCandidates.count) items from Dropbox?")
        }
        return trashCandidates.count == 1
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

    private func beginRename(_ item: CloudItem) {
        renameText = item.name
        renamingId = item.id
        Task {
            // Фокус — после появления поля в строке таблицы.
            try? await Task.sleep(for: .milliseconds(50))
            renameFocused = true
        }
    }

    private func commitRename(_ item: CloudItem) {
        guard renamingId == item.id else { return }
        renamingId = nil
        let newName = renameText
        Task {
            guard let updated = await model.rename(item, to: newName) else { return }
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = updated }
            refresh()
        }
    }

    private func move(_ selected: [CloudItem], to target: UploadTarget) {
        Task {
            let moved = await model.move(selected, to: target)
            guard !moved.isEmpty else { return }
            if target.id != uploadTarget?.id { items.removeAll { moved.contains($0.id) } }
            selection.subtract(moved)
            refresh()
        }
    }

    private func trash(_ selected: [CloudItem]) {
        Task {
            let trashed = await model.trash(selected)
            guard !trashed.isEmpty else { return }
            items.removeAll { trashed.contains($0.id) }
            selection.subtract(trashed)
            refresh()
        }
    }

    // MARK: - Data

    /// Строки списка: содержимое папки и строки-заглушки файлов, которые сейчас отправляются сюда.
    private var allRows: [CloudItem] {
        let placeholders = model.browserTransfers.placeholders.filter { $0.provider == model.activeCloud }
        return placeholders.isEmpty ? items : items + placeholders
    }

    private var displayedItems: [CloudItem] {
        let filter = model.browserFilter
        let rows = allRows
        let filtered = filter.isEmpty ? rows : rows.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        let folders = filtered.filter(\.isFolder).sorted(using: sortOrder)
        let files = filtered.filter { !$0.isFolder }.sorted(using: sortOrder)
        return folders + files
    }

    /// Выделение для команд тулбара (скачать и т. п.): без файлов, которые ещё отправляются.
    private var selectedItems: [CloudItem] { items(for: selection).filter { !isUploading($0) } }

    private func items(for ids: Set<CloudItem.ID>) -> [CloudItem] {
        allRows.filter { ids.contains($0.id) }
    }

    private var currentFolderRoute: String? {
        guard let folder = stack.last else { return nil }
        let ancestors = Array(stack.dropLast())
        let hasRoute = (ancestors + [folder]).contains { model.routeMap[$0.routeKey] != nil }
        guard hasRoute else { return nil }
        return PathResolver.localPath(for: folder, ancestors: ancestors, routes: model.routeMap,
                                      defaultPath: model.defaultDownloadPath)
    }

    private func sizeText(_ item: CloudItem) -> String {
        if item.isFolder { return "—" }
        if item.isAlias || item.isCloudDocument { return item.exportFormat.map { ".\($0.fileExtension)" } ?? "—" }
        return Format.bytes(item.sizeValue)
    }

    private func open(_ folder: CloudItem) {
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
        case .upload: if let target = uploadTarget { model.chooseFilesToUpload(into: target, ancestorIds: uploadAncestorIds) }
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

    private var stackKey: BrowserStackKey { BrowserStackKey(cloud: model.activeCloud, scope: scope) }

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
            let provider = model.provider
            let linked = model.activeLinkedItems.map(provider.item(fromLinked:))
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

        let location: CloudLocation
        if let folder = stack.last {
            location = model.provider.location(of: folder)
        } else {
            switch scope {
            case .myDrive: location = .root
            case .sharedWithMe: location = .sharedWithMe
            case .sharedDrives: location = .sharedSpaces
            case .linked: location = .root   // корень «Добавленные по ссылке» читается из БД выше
            }
        }
        let provider = model.provider
        loadTask = Task {
            var collected: [CloudItem] = []
            do {
                var token: String?
                repeat {
                    let page = try await provider.listPage(location, pageToken: token)
                    // После каждого await: если пользователь уже ушёл в другую папку — результат отбрасывается.
                    guard !Task.isCancelled, generation == loadGeneration else { return }
                    if progressive {
                        // Пустой экран заполняется постранично — первые строки видны сразу.
                        items.append(contentsOf: page.items)
                        showsSpinner = false
                    } else {
                        collected.append(contentsOf: page.items)
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

    static func icon(for item: CloudItem) -> String {
        if item.isAlias && item.aliasTargetId == nil { return "questionmark.folder" }
        if item.isFolder { return "folder.fill" }
        switch item.documentType {
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .drawing, .other: return "questionmark.square.dashed"
        case nil: break
        }
        switch item.contentType ?? "" {
        case "application/pdf": return "doc.richtext"
        case let m where m.hasPrefix("image/"): return "photo"
        case let m where m.hasPrefix("video/"): return "film"
        case let m where m.hasPrefix("audio/"): return "waveform"
        case let m where m.contains("zip") || m.contains("compressed") || m.contains("tar"): return "doc.zipper"
        default: return "doc"
        }
    }

    static func kind(for item: CloudItem) -> String {
        if item.isAlias {
            if item.isFolder { return String(localized: "Shortcut to folder") }
            if item.aliasTargetId == nil { return String(localized: "Shortcut (no target)") }
            return String(localized: "Shortcut to file")
        }
        if item.isFolder { return String(localized: "Folder") }
        switch item.documentType {
        case .document where item.provider == .dropbox: return String(localized: "Dropbox Paper")
        case .document: return String(localized: "Google Doc")
        case .spreadsheet: return String(localized: "Google Sheet")
        case .presentation: return String(localized: "Google Slides")
        case .drawing: return String(localized: "Google Drawing")
        case .other, nil:
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

/// Поле для ссылки на файл или папку облака в разделе «Добавленные по ссылке».
private struct LinkInputBar: View {
    let cloud: CloudProviderKind
    @Binding var text: String
    let error: String?
    let isBusy: Bool
    let open: () -> Void
    let details: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Group {
                    if cloud == .dropbox {
                        TextField("Paste a Dropbox shared link to a file or folder",
                                  text: $text, prompt: Text(verbatim: "https://www.dropbox.com/scl/fo/…"))
                    } else {
                        TextField("Paste a link to a Google Drive file or folder",
                                  text: $text, prompt: Text("https://drive.google.com/drive/folders/…  or ID"))
                    }
                }
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
