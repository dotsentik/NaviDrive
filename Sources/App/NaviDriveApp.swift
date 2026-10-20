import SwiftUI

/// Запускается из `NaviDriveMain`.
struct NaviDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        // До создания окна: сохранённая ширина sidebar шире предела (320) — к пределу.
        SidebarWidth.clampSavedWidth()
    }

    var body: some Scene {
        // Главное окно — только при сохранённом входе; без него при запуске открывается окно приветствия.
        // Восстановление окон отключено: какое окно показать, решает только наличие входа.
        Window("NaviDrive", id: WindowOpener.mainWindowId) {
            MainView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 560)
                .background(WindowOpenerInstaller())
        }
        .defaultSize(width: 1200, height: 760)
        .defaultLaunchBehavior(model.launchedSignedIn ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateController.shared.checkManually() }
            }
            // «Вид → Показать/Скрыть боковую панель» (⌃⌘S), как в Finder.
            SidebarCommands()
            #if DEBUG
            // Проверка лимитов и карточки статуса без реального превышения (только в Debug-сборке).
            CommandMenu("Debug") {
                Menu("Simulate") {
                    ForEach(DebugSimulation.allCases, id: \.self) { simulation in
                        Toggle(simulation.title, isOn: Binding(
                            get: { model.debugSimulations.contains(simulation) },
                            set: { _ in model.toggleDebugSimulation(simulation) }))
                    }
                }
            }
            #endif
        }

        // Окно приветствия: без sidebar и тулбара, фиксированного размера, по центру экрана.
        Window("Welcome to NaviDrive", id: WindowOpener.welcomeWindowId) {
            WelcomeWindow()
                .environment(model)
                .background(WindowOpenerInstaller())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.center)
        .defaultLaunchBehavior(model.launchedSignedIn ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        // Стандартное окно настроек: «Настройки…» (⌘,) в меню NaviDrive.
        Settings {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            // Состояние сети и скорость — в самом меню; красная точка — лимит, ошибка диска, нет входа;
            // зелёная — идёт передача.
            MenuBarIcon(alert: model.hasCriticalStatus, transferring: model.isTransferring)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Сохраняет `openWindow` / `dismissWindow` для вызова из AppKit-кода и модели (Services, Dock, вход и выход).
private struct WindowOpenerInstaller: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let action = openWindow
                WindowOpener.openAction = { id in action(id: id) }
                let dismiss = dismissWindow
                WindowOpener.dismissAction = { id in dismiss(id: id) }
                let settings = openSettings
                SettingsOpener.install { settings() }
            }
    }
}


