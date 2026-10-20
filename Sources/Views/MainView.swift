import SwiftUI

/// Область главного окна с клавиатурным фокусом.
enum MainFocus: Hashable {
    case sidebar, content
}

extension EnvironmentValues {
    /// Фокус главного окна: основной список раздела помечает себя целью `.content`.
    @Entry var mainFocus: FocusState<MainFocus?>.Binding?
}

extension View {
    /// Основной список раздела (файлы, задачи, маршруты) — цель начального фокуса главного окна.
    func mainContentFocus() -> some View { modifier(MainContentFocus()) }
}

private struct MainContentFocus: ViewModifier {
    @Environment(\.mainFocus) private var focus

    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus, equals: .content)
        } else {
            content
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    /// Начальный фокус — на списке файлов, а не на первой кнопке (иначе кольцо фокуса
    /// появляется само на кнопке sidebar). Кнопки тулбара остаются доступны через Tab.
    @FocusState private var focus: MainFocus?
    /// Sidebar показан (общая настройка с «Вид → Показать/Скрыть боковую панель» и вкладкой «Общие»).
    @AppStorage(AppSettings.showSidebarKey) private var showSidebar = true

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showSidebar ? .all : .detailOnly },
            set: { showSidebar = $0 != .detailOnly }
        )
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            // Список и блок статуса — друг под другом, а не наложением: список заканчивается над блоком
            // и прокручивается, если пунктов (например, дисков) больше, чем помещается по высоте.
            // С .safeAreaInset прокрутка списка в sidebar macOS не всегда учитывала высоту блока,
            // и последние пункты («Настройки») оказывались под ним.
            VStack(spacing: 0) {
                // Переключатель облака вместо заголовка «Google Drive»: разделы ниже — выбранного облака.
                CloudSwitcher()
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                List(selection: $model.selection) {
                    Section {
                        ForEach(SidebarItem.cloudItems(for: model.activeCloud)) { item in
                            sidebarRow(item, badge: item == .linked ? model.activeLinkedItems.count : 0)
                        }
                    }
                    Section("Transfers") {
                        // Счётчик активных потоков в строке не показываем — активность видна в строке статуса.
                        sidebarRow(.downloads)
                        sidebarRow(.uploads, badge: model.uploadTotals.activeCount)
                        sidebarRow(.routes, badge: model.routes.count)
                    }
                    if !model.volumes.isEmpty {
                        // Строки дисков — кнопки без `.tag`: в выборе экрана через List(selection:) они не участвуют.
                        Section("Disks") {
                            ForEach(model.volumes) { DiskSidebarRow(volume: $0) }
                        }
                    }
                }
                .frame(minHeight: 160)
                .focused($focus, equals: .sidebar)
                SidebarStatus()
                    .contentShape(Rectangle())
                    .onTapGesture { focus = .sidebar }
            }
            // Ширину, выставленную перетаскиванием, SwiftUI запоминает сам
            // (UserDefaults «NSSplitView Subview Frames main, …») и восстанавливает при запуске.
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            // Как в Finder: кнопки sidebar в тулбаре нет, показ/скрытие — «Вид → Показать/Скрыть
            // боковую панель» (⌃⌘S), переключатель в настройках или перетаскивание разделителя.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // Стабильный контейнер detail-колонки: тулбар висит на нём один раз, а не на виде
            // внутри switch (у браузеров меняется .id), поэтому показ/скрытие sidebar его не пересоздаёт.
            ZStack {
                detailContent
            }
            .toolbar { MainToolbar(model: model) }
            .onChange(of: model.selection) { model.browserFilter = "" }
        }
        .environment(\.mainFocus, $focus)
        .defaultFocus($focus, .content)
        .sheet(isPresented: $model.showAddLink) {
            AddLinkSheet().environment(model)
        }
        // Finder Services «Upload to Google Drive (NaviDrive)»: выбор папки на диске.
        .sheet(isPresented: Binding(
            get: { model.pendingServiceUpload != nil },
            set: { if !$0 { model.pendingServiceUpload = nil } }
        )) {
            let urls = model.pendingServiceUpload ?? []
            FolderPickerSheet(title: urls.count == 1
                                  ? String(localized: "Where should “\(urls[0].lastPathComponent)” be uploaded?")
                                  : String(localized: "Where should \(urls.count) items be uploaded?"),
                              actionTitle: String(localized: "Upload")) { target in
                model.startUpload(urls, to: target)
            }
            .environment(model)
        }
        .alert("NaviDrive", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background {
            // Отдельный носитель для второго алерта, чтобы он не конфликтовал с алертом ошибок.
            Color.clear
                .alert("Sign in to Google again to upload", isPresented: $model.showReauthPrompt) {
                    Button("Sign In to Google") { model.signIn(.googleDrive) }
                    Button("Later", role: .cancel) {}
                } message: {
                    Text("Your saved sign-in only lets NaviDrive read files. To upload files and change folders, sign in again and allow access to Google Drive on the Google screen. Downloads keep working in the meantime.")
                }
        }
        .background {
            // Вошли другим аккаунтом, а в очереди остались загрузки предыдущего.
            Color.clear
                .alert("You signed in with a different account", isPresented: Binding(
                    get: { model.accountSwitch != nil },
                    set: { _ in }
                ), presenting: model.accountSwitch) { _ in
                    Button("Keep Paused") { model.resolveAccountSwitch(keepPaused: true) }
                    Button("Remove from Queue", role: .destructive) { model.resolveAccountSwitch(keepPaused: false) }
                } message: { change in
                    if change.previousEmail.isEmpty, change.provider == .dropbox {
                        Text("The download and upload queue belongs to the previous Dropbox account. What should be done with it?")
                    } else if change.previousEmail.isEmpty {
                        Text("The download and upload queue belongs to the previous Google account. What should be done with it?")
                    } else {
                        Text("The download and upload queue belongs to \(change.previousEmail). What should be done with it?")
                    }
                }
        }
        .task { model.startIfNeeded() }
        .onAppear {
            // Главное окно без входа (например, из меню «Окно») заменяется окном приветствия.
            if !model.isSignedIn { model.showWelcome() }
        }
    }

    /// Содержимое detail-колонки для выбранного раздела sidebar.
    @ViewBuilder
    private var detailContent: some View {
        // Облако в .id: при переключении браузер создаётся заново со своим путём навигации.
        let cloud = model.activeCloud.rawValue
        switch model.selection ?? .myDrive {
        case .myDrive:
            DriveBrowserView(scope: .myDrive).id("myDrive-\(cloud)-\(model.driveReloadToken)")
        case .sharedWithMe:
            DriveBrowserView(scope: .sharedWithMe).id("shared-\(cloud)-\(model.driveReloadToken)")
        case .sharedDrives:
            DriveBrowserView(scope: .sharedDrives).id("drives-\(cloud)-\(model.driveReloadToken)")
        case .linked:
            DriveBrowserView(scope: .linked).id("linked-\(cloud)-\(model.driveReloadToken)")
        case .downloads:
            DownloadManagerView()
        case .uploads:
            UploadManagerView()
        case .routes:
            RoutesView()
        }
    }

    /// Строка sidebar. `.tag` обязательно последний модификатор: если применить `.badge` после `.tag`,
    /// строка остаётся видимой, но перестаёт выбираться (SwiftUI не находит у неё значения выбора) —
    /// именно так не открывались «Маршруты сохранения» и «Добавленные по ссылке».
    private func sidebarRow(_ item: SidebarItem, badge: Int = 0) -> some View {
        Label(item.title(for: model.activeCloud), systemImage: item.systemImage(for: model.activeCloud))
            .badge(badge)
            .tag(item)
    }
}

/// Переключатель облака вверху sidebar: сегменты «Google Drive | Dropbox», когда подключены оба;
/// иначе — подключённое облако и кнопка подключения второго.
private struct CloudSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let connected = model.connectedClouds
        if connected.count > 1 {
            Picker("Cloud", selection: $model.activeCloud) {
                ForEach(connected, id: \.self) { cloud in
                    Label(cloud.displayName, systemImage: cloud.systemImage).tag(cloud)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .help("Cloud shown in the sidebar")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label(model.activeCloud.displayName, systemImage: model.activeCloud.systemImage)
                    .font(.headline)
                if let missing = CloudProviderKind.allCases.first(where: { !connected.contains($0) }) {
                    HStack(spacing: 6) {
                        Button(String(localized: "Connect \(missing.displayName)…")) { model.signIn(missing) }
                            .buttonStyle(.link)
                            .disabled(model.account(missing).isSigningIn)
                        if model.account(missing).isSigningIn {
                            ProgressView().controlSize(.mini)
                            Button("Cancel") { model.cancelSignIn(missing) }
                                .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                    if let error = model.account(missing).signInError {
                        Text(error)
                            .font(.caption2).foregroundStyle(.orange)
                            .lineLimit(3)
                            .help(error)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SidebarStatus: View {
    @Environment(AppModel.self) private var model
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    /// Идут скачивания (или обход папок) — показываются скорость и общий прогресс.
    private var downloadsActive: Bool { model.hasActiveDownloads }
    private var uploadsActive: Bool { model.uploadSnapshot.runningCount > 0 }

    var body: some View {
        // Без активных передач — одна строка с индикатором сети; высота по содержимому.
        // Строки скорости и прогресса появляются и исчезают с плавной анимацией высоты
        // (только на переходах, а не при каждом обновлении счётчиков).
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.snapshot.isOnline ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.networkStatusText)
                Spacer()
                if downloadsActive && model.snapshot.runningCount > 0 {
                    Text(Format.speed(model.snapshot.bytesPerSecond))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            if downloadsActive {
                VStack(alignment: .leading, spacing: 4) {
                    if model.snapshot.scanningFolders > 0 {
                        Text("Scanning folders: \(model.snapshot.scannedFiles) files found")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if model.totals.pendingCount > 0 {
                        ProgressView(value: model.totals.fraction)
                        Text(model.progressSummary)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if uploadsActive {
                Text("Uploading: \(model.uploadProgressSummary) · \(Format.speed(model.uploadSnapshot.isPaused ? 0 : model.uploadSnapshot.bytesPerSecond))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(StatusCardBackground(shape: shape))
        // Парящая карточка: отступ от краёв sidebar и от нижнего края окна.
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 6)
        .animation(.smooth(duration: 0.3), value: downloadsActive)
        .animation(.smooth(duration: 0.3), value: uploadsActive)
    }
}

/// Фон карточки статуса: Liquid Glass на macOS 26+, на macOS 15 — материал с тонкой обводкой.
private struct StatusCardBackground: ViewModifier {
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }
}
