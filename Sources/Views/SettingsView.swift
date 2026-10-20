import SwiftUI

enum SettingsTab: String, Hashable {
    case account, downloads, uploads, general
}

/// Окно настроек macOS (сцена `Settings`, ⌘,): вкладки «Аккаунты», «Скачивание», «Отправка», «Общие».
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            Tab("Accounts", systemImage: "person.crop.circle", value: SettingsTab.account) {
                SettingsPane { AccountSettings() }
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: SettingsTab.downloads) {
                SettingsPane { DownloadSettings() }
            }
            Tab("Uploads", systemImage: "arrow.up.circle", value: SettingsTab.uploads) {
                SettingsPane { UploadSettings() }
            }
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                SettingsPane { GeneralSettings() }
            }
        }
        .tabViewStyle(.automatic)
    }
}

/// Форма вкладки: фиксированная ширина, высота по содержимому (окно подстраивается под вкладку).
private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 520)
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        CloudAccountSection(cloud: .googleDrive)

        Section {
            Toggle("Use my own OAuth credentials", isOn: $model.useCustomCredentials)
                .disabled(model.account(.googleDrive).isSignedIn || model.account(.googleDrive).isSigningIn)
            if model.useCustomCredentials {
                TextField("Client ID", text: $model.clientId, prompt: Text("xxxxxxxx.apps.googleusercontent.com"))
                    .textContentType(.username)
                    .disabled(model.account(.googleDrive).isSignedIn)
                SecureField("Client Secret", text: $model.clientSecret, prompt: Text("GOCSPX-…"))
                    .disabled(model.account(.googleDrive).isSignedIn)
            }
        } header: {
            Text("Advanced")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.hasBundledCredentials
                     ? String(localized: "By default NaviDrive uses the Google credentials built into this copy. Your own credentials take priority and are stored in the Keychain. Sign out to change this option.")
                     : String(localized: "This copy has no built-in Google credentials — turn on this option and enter your own."))
                Text("Create an OAuth Client ID of type “Desktop app” in Google Cloud Console and enable the Google Drive API. Keys and tokens are stored in the system Keychain.")
            }
            .font(.caption).foregroundStyle(.secondary)
        }

        CloudAccountSection(cloud: .dropbox)
    }
}

/// Блок аккаунта облака: статус, имя и email, вход и выход.
private struct CloudAccountSection: View {
    @Environment(AppModel.self) private var model
    let cloud: CloudProviderKind

    private var state: CloudAccountState { model.account(cloud) }
    private var canSignIn: Bool { model.providers[cloud]?.canSignIn ?? false }

    var body: some View {
        Section {
            if state.isSignedIn {
                HStack(alignment: .top) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.userName ?? String(localized: "Signed in"))
                        if let email = state.userEmail {
                            Text(verbatim: email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button("Sign Out", role: .destructive) { model.signOut(cloud) }
                }
            } else if state.isSigningIn {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in in your browser…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Sign-In Page Again") { model.reopenSignInPage(cloud) }
                        .disabled(state.signInURL == nil)
                    Button("Cancel") { model.cancelSignIn(cloud) }
                }
            } else {
                HStack {
                    Text("Not signed in").foregroundStyle(.secondary)
                    Spacer()
                    Button(state.signInError == nil ? String(localized: "Connect \(cloud.displayName)") : String(localized: "Try Again")) {
                        model.signIn(cloud)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSignIn)
                }
            }
            if let error = state.signInError, !state.isSignedIn {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Label(cloud.displayName, systemImage: cloud.systemImage)
        } footer: {
            if cloud == .dropbox {
                VStack(alignment: .leading, spacing: 4) {
                    if !canSignIn {
                        Text("This copy of NaviDrive was built without a Dropbox app key (DROPBOX_APP_KEY in Config/Secrets.xcconfig).")
                    }
                    Text("The Dropbox app must allow the redirect URI \(DropboxOAuth.redirectURI). The sign-in token is stored in the system Keychain.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DownloadSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            LabeledContent("Default folder") {
                HStack {
                    Text(PathResolver.displayPath(model.defaultDownloadPath))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(model.defaultDownloadPath)
                    Button("Change…") { model.chooseDefaultFolder() }
                    Button { model.openDefaultFolder() } label: { Image(systemName: "folder") }
                        .help("Open in Finder")
                }
            }
        }

        Section {
            Stepper(value: $model.maxConcurrentDownloads, in: AppSettings.concurrencyRange) {
                LabeledContent("Maximum threads", value: "\(model.maxConcurrentDownloads)")
            }
            LabeledContent("Now") {
                Text("\(model.threadsSummary) · \(Format.speed(model.snapshot.bytesPerSecond))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("This is the upper limit. The engine starts with 4 threads and adds one every 15 seconds while total speed keeps growing. If Google reports rate limiting (429), the number of threads is halved immediately. Changes apply on the fly; running downloads are not interrupted.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct UploadSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Stepper(value: $model.maxConcurrentUploads, in: AppSettings.uploadConcurrencyRange) {
                LabeledContent("Simultaneous uploads", value: "\(model.maxConcurrentUploads)")
            }
            LabeledContent("Now") {
                Text("Active: \(model.uploadSnapshot.runningCount) of \(model.uploadSnapshot.limit) · \(Format.speed(model.uploadSnapshot.bytesPerSecond))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Separate from download threads: downloads and uploads run at the same time. If Google rate-limits requests, the number of uploads is temporarily reduced. Files are sent in 32 MB parts and continue from where they stopped after a connection drop.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    /// То же состояние, что у columnVisibility главного окна и пункта меню «Вид → Показать/Скрыть боковую панель».
    @AppStorage(AppSettings.showSidebarKey) private var showSidebar = true

    /// «English», «Русский» — название языка на нём самом.
    static func languageName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forLanguageCode: code).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? code
    }

    var body: some View {
        @Bindable var model = model
        Section {
            Picker("Language", selection: Binding(get: { model.appLanguage }, set: { model.setAppLanguage($0) })) {
                Text("System").tag(AppSettings.AppLanguage.system)
                // Названия языков — на самих этих языках, из системной локали.
                Text(verbatim: Self.languageName("en")).tag(AppSettings.AppLanguage.en)
                Text(verbatim: Self.languageName("ru")).tag(AppSettings.AppLanguage.ru)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("The app language can also be chosen in System Settings → General → Language & Region → Applications.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open macOS Language Settings") { model.openSystemLanguageSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        Section {
            Toggle("Show Sidebar", isOn: $showSidebar)
                .help("Also: View → Show/Hide Sidebar (⌃⌘S)")
        }
        Section {
            Toggle("Keep the Mac awake during downloads and uploads", isOn: $model.preventSleep)
                .help("While there are active or pending transfers, the system won’t sleep. The display still turns off as usual.")
        }
        Section("Storage") {
            LabeledContent("State database") {
                Text(model.db?.path ?? String(localized: "unavailable"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
            }
        }
    }
}
