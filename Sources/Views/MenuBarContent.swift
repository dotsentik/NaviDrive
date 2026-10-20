import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Верхняя строка — самое важное текущее сообщение карточки статуса (красное, если есть).
        if model.isSignedIn, let top = model.topStatusMessage, !top.isIdle {
            Button {
                WindowOpener.openAction = { id in openWindow(id: id) }
                if top.target == .none { WindowOpener.showMainWindow() } else { model.openStatusTarget(top.target) }
            } label: {
                Label(top.title, systemImage: Self.symbol(for: top))
            }
            Divider()
        }

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
            QuitController.shared.quitFromMenu()
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var status: some View {
        Text("Speed: \(model.downloadSpeedText)")
        Text(model.threadsSummary)
        Text("Progress: \(model.progressSummary)")
        Text("Queued: \(model.totals.countsByStatus[.queued] ?? 0)")
        if let quota = model.totals.countsByStatus[.waitingDailyLimit], quota > 0 {
            if let resume = model.limit(.googleDrive, .download)?.resumeAt {
                Text("Waiting for daily limit: \(quota) · resumes around \(TransferLimiter.time(resume))")
            } else {
                Text("Waiting for daily limit: \(quota)")
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

    private static func symbol(for message: StatusMessage) -> String {
        switch message.severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .normal where message.isTrash: "trash"
        case .normal: message.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        }
    }
}

/// Значок трея: шаблонная иконка; при красном состоянии — с маленькой красной точкой,
/// во время передачи — с зелёной (без анимации).
struct MenuBarIcon: View {
    let alert: Bool
    var transferring = false

    var body: some View {
        if alert, let image = Self.alertImage {
            Image(nsImage: image)
        } else if transferring, let image = Self.transferImage {
            Image(nsImage: image)
        } else {
            // Шаблонная иконка (Render As: Template): система сама делает её белой в тёмной теме и чёрной в светлой.
            Image("MenuBarIcon")
        }
    }

    private static let alertImage = badged(.systemRed, description: String(localized: "NaviDrive: attention needed"))
    private static let transferImage = badged(.systemGreen, description: String(localized: "NaviDrive: transferring"))

    /// Иконка цвета текста строки меню (рисуется при каждой отрисовке — в текущем оформлении) и цветная точка.
    private static func badged(_ color: NSColor, description: String) -> NSImage? {
        guard let base = NSImage(named: "MenuBarIcon") else { return nil }
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            base.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            context.endTransparencyLayer()
            let diameter = (size.height * 0.4).rounded()
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = description
        return image
    }
}
