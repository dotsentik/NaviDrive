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
            // Подключённые облака: аккаунт каждого (email или имя).
            ForEach(model.connectedClouds, id: \.self) { cloud in
                let account = model.account(cloud)
                Label {
                    Text(verbatim: "\(cloud.displayName): \(account.userEmail ?? account.userName ?? "…")")
                } icon: {
                    Image(systemName: cloud.systemImage)
                }
            }
            Divider()
            // Общий прогресс очередей обоих облаков.
            status
        } else {
            // Вместо статуса загрузок — вход: окно приветствия показывает ожидание входа в браузере.
            ForEach(CloudProviderKind.allCases, id: \.self) { cloud in
                Button(String(localized: "Connect \(cloud.displayName)…")) {
                    WindowOpener.openAction = { id in openWindow(id: id) }
                    WindowOpener.showWelcomeWindow()
                    model.signIn(cloud)
                }
                .disabled(!(model.providers[cloud]?.canSignIn ?? false) || model.account(cloud).isSigningIn)
            }
        }

        Divider()

        Button(model.pauseAllAction == .resume ? String(localized: "Resume All") : String(localized: "Pause All")) {
            model.togglePauseAll()
        }
        .disabled(!model.isSignedIn || model.pauseAllAction == .none)
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
        Text("Speed: \(model.downloadSpeedText)")
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
