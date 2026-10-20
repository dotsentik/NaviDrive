import SwiftUI

/// Точка входа. В Debug-сборке с NAVIDRIVE_UPDATE_E2E=1 — только проверка и установка обновления
/// (`UpdateE2E`): без окон, AppModel, базы данных и Связки ключей.
@main
enum NaviDriveMain {
    @MainActor
    static func main() {
        #if DEBUG
        if UpdateE2E.isRequested { UpdateE2E.runAndExit() }
        #endif
        NaviDriveApp.main()
    }
}
