import Foundation

/// Настройки в UserDefaults. UserDefaults потокобезопасен, поэтому доступ возможен из любого контекста.
enum AppSettings {
    private static let defaultPathKey = "defaultDownloadPath"
    private static let concurrencyKey = "maxConcurrentDownloads"

    static var defaultDownloadPath: String {
        get {
            if let path = UserDefaults.standard.string(forKey: defaultPathKey), !path.isEmpty {
                return path
            }
            return (NSHomeDirectory() as NSString).appendingPathComponent("Downloads/GDrive")
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultPathKey) }
    }

    static let concurrencyRange = 1...16
    static let defaultConcurrency = 8

    /// Верхний предел параллельных загрузок (фактическое число регулирует AIMD-балансировщик).
    static var maxConcurrentDownloads: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: concurrencyKey)
            return value == 0 ? defaultConcurrency : clampConcurrency(value)
        }
        set { UserDefaults.standard.set(clampConcurrency(newValue), forKey: concurrencyKey) }
    }

    static func clampConcurrency(_ value: Int) -> Int {
        min(concurrencyRange.upperBound, max(concurrencyRange.lowerBound, value))
    }

    private static let uploadConcurrencyKey = "maxConcurrentUploads"
    static let uploadConcurrencyRange = 1...6
    static let defaultUploadConcurrency = 3

    /// Одновременных отправок в облака (отдельно от потоков скачивания).
    static var maxConcurrentUploads: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: uploadConcurrencyKey)
            return value == 0 ? defaultUploadConcurrency : clampUploadConcurrency(value)
        }
        set { UserDefaults.standard.set(clampUploadConcurrency(newValue), forKey: uploadConcurrencyKey) }
    }

    static func clampUploadConcurrency(_ value: Int) -> Int {
        min(uploadConcurrencyRange.upperBound, max(uploadConcurrencyRange.lowerBound, value))
    }

    /// Свои дневные лимиты Google Drive (скользящие 24 часа): запас от лимитов Google —
    /// 1 ТБ скачивания в сутки на проект и 750 ГБ отправки в сутки на пользователя.
    static func defaultGoogleLimitGB(_ direction: TransferDirection) -> Int {
        direction == .download ? 900 : 700
    }
    static let googleLimitRange = 1...100_000

    /// Ключи скачивания — прежние («googleDailyLimit…»): уже выставленное значение сохраняется.
    private static func googleLimitKey(_ direction: TransferDirection, _ suffix: String) -> String {
        direction == .download ? "googleDailyLimit\(suffix)" : "googleUploadLimit\(suffix)"
    }

    /// «Дневной лимит Google Drive» для направления (по умолчанию включён).
    static func googleLimitEnabled(_ direction: TransferDirection) -> Bool {
        UserDefaults.standard.object(forKey: googleLimitKey(direction, "Enabled")) as? Bool ?? true
    }

    static func setGoogleLimitEnabled(_ enabled: Bool, _ direction: TransferDirection) {
        UserDefaults.standard.set(enabled, forKey: googleLimitKey(direction, "Enabled"))
    }

    /// Лимит в гигабайтах (десятичных, как в Finder).
    static func googleLimitGB(_ direction: TransferDirection) -> Int {
        let value = UserDefaults.standard.integer(forKey: googleLimitKey(direction, "GB"))
        return value == 0 ? defaultGoogleLimitGB(direction) : clampGoogleLimit(value)
    }

    static func setGoogleLimitGB(_ value: Int, _ direction: TransferDirection) {
        UserDefaults.standard.set(clampGoogleLimit(value), forKey: googleLimitKey(direction, "GB"))
    }

    static func clampGoogleLimit(_ value: Int) -> Int {
        min(googleLimitRange.upperBound, max(googleLimitRange.lowerBound, value))
    }

    /// Свой лимит за 24 часа в байтах; nil — выключен или у облака своих лимитов нет (Dropbox).
    static func transferLimitBytes(_ provider: CloudProviderKind, _ direction: TransferDirection) -> Int64? {
        guard provider == .googleDrive, googleLimitEnabled(direction) else { return nil }
        return Int64(googleLimitGB(direction)) * 1_000_000_000
    }

    /// Облако сообщило о лимите: время следующего пробного запроса (сохраняется,
    /// чтобы после перезапуска не засыпать облако запросами). nil — облако не ограничено.
    static func limitProbeDate(_ provider: CloudProviderKind, _ direction: TransferDirection) -> Date? {
        UserDefaults.standard.object(forKey: "limitProbe.\(provider.rawValue).\(direction.rawValue)") as? Date
    }

    static func setLimitProbeDate(_ date: Date?, _ provider: CloudProviderKind, _ direction: TransferDirection) {
        UserDefaults.standard.set(date, forKey: "limitProbe.\(provider.rawValue).\(direction.rawValue)")
    }

    static let useCustomOAuthKey = "useCustomOAuthCredentials"

    /// «Использовать свои учётные данные OAuth» (по умолчанию выключено — встроенные при сборке).
    static var useCustomOAuthCredentials: Bool {
        get { UserDefaults.standard.bool(forKey: useCustomOAuthKey) }
        set { UserDefaults.standard.set(newValue, forKey: useCustomOAuthKey) }
    }

    /// Одноразово для тех, кто уже вводил свои Client ID/Secret до появления встроенных:
    /// их вход продолжает работать с теми же учётными данными.
    static func migrateCustomOAuthChoice(hasCustomCredentials: Bool) {
        guard UserDefaults.standard.object(forKey: useCustomOAuthKey) == nil else { return }
        useCustomOAuthCredentials = hasCustomCredentials
    }

    /// Показывать боковую панель главного окна (меню «Вид», настройки, перетаскивание разделителя).
    static let showSidebarKey = "showSidebar"
    private static let queueOwnerKey = "queueOwnerAwaitingSignIn"

    /// Ключ для облака: у Google — прежний (совместимость), у остальных — с суффиксом.
    private static func queueOwnerKey(_ cloud: CloudProviderKind) -> String {
        cloud == .googleDrive ? queueOwnerKey : queueOwnerKey + "." + cloud.rawValue
    }

    /// Облако отозвало доступ: email аккаунта, чья очередь ждёт нового входа ("" — email неизвестен).
    /// Вошли тем же аккаунтом — очередь продолжается, другим — спрашиваем, что с ней сделать.
    static func queueOwnerAwaitingSignIn(for cloud: CloudProviderKind) -> String? {
        UserDefaults.standard.string(forKey: queueOwnerKey(cloud))
    }

    static func setQueueOwnerAwaitingSignIn(_ email: String?, for cloud: CloudProviderKind) {
        UserDefaults.standard.set(email, forKey: queueOwnerKey(cloud))
    }

    private static let activeCloudKey = "activeCloud"

    /// Облако, выбранное переключателем вверху sidebar.
    static var activeCloud: CloudProviderKind {
        get { UserDefaults.standard.string(forKey: activeCloudKey).flatMap(CloudProviderKind.init(rawValue:)) ?? .googleDrive }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: activeCloudKey) }
    }

    private static let preventSleepKey = "preventSleepDuringDownloads"

    /// «Не давать Mac засыпать во время загрузок» (по умолчанию включено).
    static var preventSleep: Bool {
        get { UserDefaults.standard.object(forKey: preventSleepKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preventSleepKey) }
    }

    // MARK: - Язык интерфейса

    /// Выбор языка в настройках. «Как в системе» — ключ AppleLanguages приложения не задан,
    /// и macOS сама выбирает русский или английский по списку предпочитаемых языков.
    enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
        case system, en, ru
        var id: String { rawValue }
    }

    private static let appleLanguagesKey = "AppleLanguages"
    /// Языки, на которые переведено приложение.
    static let supportedLanguages = ["en", "ru"]

    /// Значение только из домена приложения (без глобального списка языков системы).
    static var appLanguage: AppLanguage {
        get {
            let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
            guard let first = (domain?[appleLanguagesKey] as? [String])?.first else { return .system }
            return first.hasPrefix("ru") ? .ru : .en
        }
        set {
            switch newValue {
            case .system: UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
            case .en, .ru: UserDefaults.standard.set([newValue.rawValue], forKey: appleLanguagesKey)
            }
        }
    }

    /// Язык, который получит приложение при выборе `language` («en» или «ru»).
    static func effectiveLanguage(for language: AppLanguage) -> String {
        switch language {
        case .en, .ru:
            return language.rawValue
        case .system:
            let system = CFPreferencesCopyValue(appleLanguagesKey as CFString, kCFPreferencesAnyApplication,
                                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
            return Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: system ?? ["en"]).first ?? "en"
        }
    }

    /// Ресурсы приложения на заданном языке — чтобы показать алерт уже на новом языке до перезапуска.
    static func bundle(for language: String) -> Bundle {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NaviDrive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
