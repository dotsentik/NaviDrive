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

    /// Одновременных отправок в Google Drive (отдельно от потоков скачивания).
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

    /// Доступ отозван Google: email аккаунта, чья очередь ждёт нового входа ("" — email неизвестен).
    /// Вошли тем же аккаунтом — очередь продолжается, другим — спрашиваем, что с ней сделать.
    static var queueOwnerAwaitingSignIn: String? {
        get { UserDefaults.standard.string(forKey: queueOwnerKey) }
        set { UserDefaults.standard.set(newValue, forKey: queueOwnerKey) }
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
