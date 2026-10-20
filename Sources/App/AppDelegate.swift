import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        AppModel.shared.startIfNeeded()
    }

    /// Закрытие окна не завершает приложение: загрузки продолжаются в фоне, управление — из трея.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.showAppropriateWindow() }
        return true
    }

    /// Показывать уведомления и когда окно NaviDrive на переднем плане.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    // MARK: - NSServices: «Upload to NaviDrive»

    @objc func uploadToNaviDrive(_ pasteboard: NSPasteboard, userData: String?,
                                   error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var paths: [String] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            paths = urls.map(\.path)
        }
        if paths.isEmpty,
           let legacy = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            paths = legacy
        }
        guard !paths.isEmpty else {
            error.pointee = String(localized: "No files selected for upload") as NSString
            return
        }
        let mainWindowWasClosed = !NSApp.windows.contains {
            $0.identifier?.rawValue.hasPrefix(WindowOpener.mainWindowId) == true && $0.isVisible
        }
        if AppModel.shared.isSignedIn { WindowOpener.showMainWindow() }
        AppModel.shared.upload(paths: paths, mainWindowWasClosed: mainWindowWasClosed)
    }
}

/// Открытие окна настроек из AppKit-кода и модели. Действие `openSettings` сохраняет
/// первое появившееся SwiftUI-представление (главное окно или меню трея); до этого запрос откладывается.
@MainActor
enum SettingsOpener {
    private static var openAction: (() -> Void)?
    private static var pending = false

    static func install(_ action: @escaping () -> Void) {
        openAction = action
        if pending {
            pending = false
            open()
        }
    }

    static func open() {
        guard let openAction else {
            pending = true
            return
        }
        openAction()
        // Окно настроек — на передний план, даже если главное окно закрыто.
        NSApp.activate()
    }
}

/// Открытие и закрытие окон из любого места (трей, Dock, Services, модель).
/// Главное окно — только при выполненном входе; без входа — компактное окно приветствия.
@MainActor
enum WindowOpener {
    static let mainWindowId = "main"
    static let welcomeWindowId = "welcome"
    static var openAction: ((String) -> Void)?
    static var dismissAction: ((String) -> Void)?

    static func showMainWindow() { show(mainWindowId) }
    static func showWelcomeWindow() { show(welcomeWindowId) }
    static func closeMainWindow() { close(mainWindowId) }
    static func closeWelcomeWindow() { close(welcomeWindowId) }

    /// Dock, трей: главное окно, если вход выполнен, иначе окно приветствия.
    static func showAppropriateWindow() {
        if AppModel.shared.isSignedIn { showMainWindow() } else { showWelcomeWindow() }
    }

    private static func show(_ id: String) {
        NSApp.activate()
        if let openAction {
            openAction(id)
        } else if let window = window(id) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func close(_ id: String) {
        if let dismissAction {
            dismissAction(id)
        } else {
            window(id)?.close()
        }
    }

    private static func window(_ id: String) -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }
    }
}
