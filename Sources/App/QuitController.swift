import AppKit

/// Состояние выхода. Выход решается ровно один раз: после решения (`confirmed`) и во время сохранения
/// прогресса (`terminating`) ⌘Q и повторные запросы выхода больше ничего не проверяют и не показывают.
enum QuitFlow: Equatable {
    case idle
    /// Идёт удержание ⌘Q, показан HUD.
    case holding
    /// Выход решён, `terminate` уже запрошен. `checkTransfers` — ещё спросить об идущих передачах
    /// (после удержания ⌘Q); false — без вопросов (перезапуск, «Выйти после завершения»).
    case confirmed(checkTransfers: Bool)
    /// applicationShouldTerminate вернул .terminateLater: передачи останавливаются, затем reply.
    case terminating
}

/// Выход из NaviDrive.
///
/// - ⌘Q с клавиатуры (если включено «Удерживать ⌘Q для выхода») перехватывает локальный монитор событий:
///   нужно держать 1,5 секунды, ход показывает HUD. Отпустили раньше — приложение продолжает работу.
/// - «Выйти из NaviDrive» в меню приложения или трея, выбранный мышью, и Quit в Dock — сразу проверка передач.
/// - Выход по команде системы (перезагрузка, выключение, выход из учётной записи) и Apple Event quit
///   от скриптов — без окон и вопросов: передачи останавливаются с сохранением прогресса, приложение завершается.
///
/// `NSApp.terminate` вызывается только из цикла выполнения (`RunLoop.main.perform`), а не из Task:
/// при .terminateLater AppKit крутит вложенный цикл внутри `terminate`, и если тот вызван из блока главной
/// очереди (а Task на MainActor — это он), очередь заблокирована — Task с `reply` не выполнится никогда.
@MainActor
final class QuitController {
    static let shared = QuitController()

    static let holdDuration: Duration = .milliseconds(1500)
    /// Дольше остановка передач выход не задерживает (выключение Mac, scripts/install.sh).
    private static let stopTimeout: Duration = .seconds(5)
    /// kVK_ANSI_Q: ⌘Q при раскладке без латинской «q» (например, русской).
    private static let qKeyCode: UInt16 = 12

    private(set) var flow = QuitFlow.idle
    private var keyMonitor: Any?
    private let hud = QuitHoldHUD()
    private var holdTask: Task<Void, Never>?
    private var hasReplied = false

    private init() {}

    func install() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let consumed = MainActor.assumeIsolated { QuitController.shared.handle(event) }
            return consumed ? nil : event
        }
        // Переключились в другое приложение во время удержания — отпускания уже не увидим.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuitController.shared.cancelHold() }
        }
    }

    /// «Выйти из NaviDrive» в меню трея: проверка передач, без удержания.
    func quitFromMenu() {
        guard flow == .idle else { return }
        terminateFromRunLoop()
    }

    /// Выход без удержания и без вопросов о передачах (перезапуск, «Выйти после завершения»).
    func terminateWithoutPrompt() {
        guard flow != .terminating else { return }
        cancelHold()
        flow = .confirmed(checkTransfers: false)
        terminateFromRunLoop()
    }

    private func terminateFromRunLoop() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    // MARK: - ⌘Q с клавиатуры

    /// true — событие поглощено (не дойдёт до пункта меню «Выйти»).
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            guard Self.isQuitShortcut(event) else { return false }
            switch flow {
            case .holding, .confirmed, .terminating:
                // Повторное нажатие и автоповтор не сбивают таймер; после решения о выходе ⌘Q ничего не делает.
                return true
            case .idle:
                // Автоповтор после удержания (окно подтверждения уже открыто) не должен ни выходить, ни пищать.
                if event.isARepeat { return true }
                guard AppSettings.holdToQuit, NSApp.modalWindow == nil else { return false }
                beginHold()
                return true
            }
        case .keyUp:
            if flow == .holding, Self.isQKey(event) { cancelHold() }
            return false
        case .flagsChanged:
            if flow == .holding, !event.modifierFlags.contains(.command) { cancelHold() }
            return false
        default:
            return false
        }
    }

    private static func isQuitShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        return flags == .command && isQKey(event)
    }

    private static func isQKey(_ event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return event.keyCode == qKeyCode }
        if characters == "q" { return true }
        return event.keyCode == qKeyCode && !characters.unicodeScalars.allSatisfy(\.isASCII)
    }

    private func beginHold() {
        flow = .holding
        hud.show(duration: Self.holdDuration)
        holdTask = Task {
            try? await Task.sleep(for: Self.holdDuration)
            guard !Task.isCancelled else { return }
            finishHold()
        }
    }

    private func finishHold() {
        guard flow == .holding else { return }
        // Главный поток мог быть занят: клавишу уже отпустили, но событие ещё ждёт в очереди.
        if Self.isReleasePending() {
            cancelHold()
            return
        }
        holdTask = nil
        hud.hide(completed: true)
        flow = .confirmed(checkTransfers: true)
        terminateFromRunLoop()
    }

    /// Необработанное отпускание Q или ⌘ в очереди событий (без извлечения из очереди).
    private static func isReleasePending() -> Bool {
        guard let event = NSApp.nextEvent(matching: [.keyUp, .flagsChanged], until: .distantPast,
                                          inMode: .default, dequeue: false) else { return false }
        return event.type == .keyUp ? isQKey(event) : !event.modifierFlags.contains(.command)
    }

    func cancelHold() {
        guard flow == .holding else { return }
        holdTask?.cancel()
        holdTask = nil
        flow = .idle
        hud.hide(completed: false)
    }

    // MARK: - applicationShouldTerminate

    func shouldTerminate() -> NSApplication.TerminateReply {
        switch flow {
        case .terminating:
            // Повторный запрос во время сохранения (например, выключение Mac): ничего не задерживаем.
            return .terminateNow
        case .confirmed(checkTransfers: false):
            return beginTerminating()
        case .holding:
            cancelHold()
        case .idle, .confirmed(checkTransfers: true):
            break
        }
        if Self.isExternalQuitEvent() { return beginTerminating() }

        let model = AppModel.shared
        let activity = model.quitActivity
        guard !activity.isEmpty, AppSettings.warnOnQuitDuringTransfers else { return beginTerminating() }
        switch confirm(activity) {
        case .quit:
            return beginTerminating()
        case .quitWhenDone:
            flow = .idle
            model.quitWhenDone = true
            model.rebuildStatusFeed()
            return .terminateCancel
        case .cancel:
            flow = .idle
            return .terminateCancel
        }
    }

    /// Apple Event quit от системы (перезагрузка, выключение, выход из учётной записи) или от скрипта
    /// (`osascript -e 'quit app "NaviDrive"'`). Quit из меню Dock — выбор пользователя, его проверяем как меню.
    private static func isExternalQuitEvent() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        if event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil { return true }
        if let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
           NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock" {
            return false
        }
        return true
    }

    /// Передачи останавливаются с сохранением прогресса (.part-файлы, offset сессий отправки),
    /// затем `reply(toApplicationShouldTerminate:)`; не дольше `stopTimeout`.
    private func beginTerminating() -> NSApplication.TerminateReply {
        flow = .terminating
        let model = AppModel.shared
        model.quitWhenDone = false
        Task {
            await model.stopForQuit()
            replyTerminate()
        }
        Task {
            try? await Task.sleep(for: Self.stopTimeout)
            replyTerminate()
        }
        return .terminateLater
    }

    private func replyTerminate() {
        guard !hasReplied else { return }
        hasReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: - Подтверждение

    private enum Choice { case quit, cancel, quitWhenDone }

    private func confirm(_ activity: QuitActivity) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.messageText = String(localized: "Quit NaviDrive?")
        alert.informativeText = String(localized: "In progress: \(activity.summary). Progress will be saved, and transfers will continue the next time NaviDrive starts.")
        let quit = alert.addButton(withTitle: String(localized: "Quit"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit When Done"))
        // Enter не должен случайно закрыть приложение: по умолчанию — «Отмена» (Enter и Esc).
        quit.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        let escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { cancel.performClick(nil) }
            return nil
        }
        defer { escapeMonitor.map(NSEvent.removeMonitor) }
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .quit
        case .alertThirdButtonReturn: return .quitWhenDone
        default: return .cancel
        }
    }
}
