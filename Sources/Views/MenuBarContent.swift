import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Без входа пункты, которым нужен аккаунт, неактивны.
        Button("Show Main Window") {
            WindowOpener.openAction = { id in openWindow(id: id) }
            WindowOpener.showMainWindow()
        }
        .keyboardShortcut("m", modifiers: .command)
        .disabled(!model.isSignedIn)

        Button("Add by Link…") {
            WindowOpener.openAction = { id in openWindow(id: id) }
            WindowOpener.showMainWindow()
            model.showAddLink = true
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(!model.isSignedIn)

        Divider()

        if model.isSignedIn {
            // Вошедший аккаунт: имя и email.
            if let name = model.userName { Text(verbatim: name) }
            if let email = model.userEmail { Text(verbatim: email) }
            Divider()
            status
        } else {
            // Вместо статуса загрузок — вход: снова открывает окно приветствия.
            Button("Sign In with Google…") {
                WindowOpener.openAction = { id in openWindow(id: id) }
                WindowOpener.showWelcomeWindow()
            }
        }

        Divider()

        Button(model.snapshot.isPaused ? String(localized: "Resume All") : String(localized: "Pause All")) {
            model.togglePauseAll()
        }
        .disabled(!model.isSignedIn)
        Button("Open Downloads Folder in Finder") {
            model.openDefaultFolder()
        }

        Divider()

        Button("Settings…") {
            let settings = openSettings
            SettingsOpener.install { settings() }
            SettingsOpener.open()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit NaviDrive") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var status: some View {
        Text("Speed: \(Format.speed(model.snapshot.isPaused ? 0 : model.snapshot.bytesPerSecond))")
        Text(model.threadsSummary)
        Text("Progress: \(model.progressSummary)")
        Text("Queued: \(model.totals.countsByStatus[.queued] ?? 0)")
        if let quota = model.totals.countsByStatus[.waitingForQuota], quota > 0 {
            if let next = model.totals.nextQuotaAttemptAt {
                let time = Date(timeIntervalSince1970: TimeInterval(next)).formatted(date: .omitted, time: .shortened)
                Text("Waiting for Google quota: \(quota) · next attempt at \(time)")
            } else {
                Text("Waiting for Google quota: \(quota)")
            }
        }
        if model.snapshot.scanningFolders > 0 {
            Text("Scanning folders: \(model.snapshot.scannedFiles) files found")
        }
        if model.uploadTotals.pendingCount > 0 || model.uploadSnapshot.runningCount > 0 {
            Text("Uploading: \(model.uploadProgressSummary) · \(Format.speed(model.uploadSnapshot.isPaused ? 0 : model.uploadSnapshot.bytesPerSecond))")
        }
        Text("Network: \(model.networkStatusText)")
    }
}
