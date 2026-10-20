import AppKit
import SwiftUI

/// Карточка статуса внизу sidebar — центр уведомлений: поток коротких сообщений обо всех облаках сразу.
///
/// - Каждое сообщение держится 3,5 с, затем уезжает вверх с затуханием, новое приходит снизу
///   (при «Уменьшить движение» — только затухание). Высота карточки меняется плавно.
/// - Наведение ставит ротацию на паузу; колесо, свайп или клик по точкам — листать вручную.
/// - Красные сообщения (лимит, диск, вход) показываются через одно, вся карточка становится красной;
///   жёлтые — лёгкий оттенок, пока показывается само сообщение.
/// - Сообщение показывается по ключу: при обновлении цифр текст меняется на месте, ротация не сбрасывается.
/// - Пока байты реально идут, фон, обводка и точка мягко «дышат» зелёным, пока идёт перемещение
///   в корзину — оранжевым (цвет — по показываемому сообщению; красное > жёлтое > оранжевое > зелёное);
///   при «Уменьшить движение» — статичный оттенок.
struct StatusCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var currentId: String?
    /// Позиция в последовательности ротации (одно сообщение может стоять в ней несколько раз).
    @State private var position = 0
    /// Растёт при каждой смене сообщения — запускает анимацию перехода (не при обновлении текста).
    @State private var switchCount = 0
    @State private var lastSwitch = Date()
    @State private var isHovered = false
    @State private var scroll = ScrollStepper()
    /// Окно видно (не свёрнуто и не закрыто другими окнами) — иначе пульсация не рисуется.
    @State private var windowVisible = true
    /// Последнее показанное сообщение (со свежим текстом): если оно пропало из списка, карточка держит его,
    /// пока не уедет анимацией, — без кадра с чужим текстом.
    @State private var shown: StatusMessage?
    /// Ширина кнопки и точек ротации справа во второй строке — столько вторая строка текста не занимает.
    @State private var footerWidth: CGFloat = 0

    static let holdSeconds: TimeInterval = 3.5
    /// Переход в покой после «Готово: …»: пульсация, обводка, точки и текст — одним шагом.
    static let settleAnimation = Animation.easeInOut(duration: 0.5)
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    private var messages: [StatusMessage] { model.statusMessages }

    private var current: StatusMessage {
        if let match = messages.first(where: { $0.id == currentId }) { return match }
        // Переход в покой: «Online» — в той же анимации, что и вся карточка (одно обновление состояния модели).
        if messages.count == 1, let only = messages.first, only.isIdle { return only }
        if let shown { return shown }
        return sequence.first.flatMap { id in messages.first { $0.id == id } }
            ?? StatusMessage(id: "idle", title: model.snapshot.isOnline ? String(localized: "Online") : String(localized: "Offline"))
    }

    /// Порядок ротации: красные — через одно, пока проблема не решена.
    private var sequence: [String] {
        let critical = messages.filter { $0.severity == .critical }.map(\.id)
        let others = messages.filter { $0.severity != .critical }.map(\.id)
        guard !critical.isEmpty, !others.isEmpty else { return critical + others }
        return (0..<max(critical.count, others.count)).flatMap { [critical[$0 % critical.count], others[$0 % others.count]] }
    }

    private var hasCritical: Bool { messages.contains { $0.severity == .critical } }
    private var showsWarning: Bool { current.severity == .warning }
    /// Пульсация: идёт передача или перемещение в корзину, нет красного состояния и не показывается предупреждение.
    private var pulses: Bool {
        (model.pulseActive || model.trashPulseActive) && !hasCritical && !showsWarning && windowVisible
    }

    /// Цвет пульсации — по показываемому сообщению: оранжевый — корзина, зелёный — передача.
    private var pulseColor: Color {
        if current.isTrash { return .orange }
        return model.pulseActive ? .green : .orange
    }

    var body: some View {
        // Высота всегда двухстрочная (по скрытому образцу): смена сообщений, точки ротации и кнопка
        // не меняют её, и список sidebar над карточкой не перестраивается.
        HStack(alignment: .top, spacing: 7) {
            // Точка — вне сменяющегося сообщения: её свечение не прерывается ротацией.
            indicator
            ZStack(alignment: .topLeading) {
                lineTemplate
                messageView(current)
                    .id("\(current.id)#\(switchCount)")
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottomTrailing) { footer }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(tint))
        .background {
            // Анимацию начала и конца задаёт модель (0,4 с при старте, 0,5 с вместе с переходом в покой).
            if pulses {
                BreathingTint(shape: shape, color: pulseColor, isStatic: reduceMotion)
                    .transition(.opacity)
            }
        }
        .overlay {
            if hasCritical { shape.strokeBorder(Color.red.opacity(0.55), lineWidth: 1) }
        }
        // Уходящий и приходящий текст не выходят за скруглённые края карточки.
        .clipShape(shape)
        .modifier(StatusCardBackground(shape: shape))
        // Парящая карточка: отступ от краёв sidebar и от нижнего края окна.
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.4), value: hasCritical)
        .animation(.easeInOut(duration: 0.35), value: showsWarning)
        .onHover { hovering in
            isHovered = hovering
            if hovering { scroll.install { step in show(offset: step) } } else { scroll.remove() }
        }
        .onAppear { if currentId == nil { currentId = sequence.first } }
        .onDisappear { scroll.remove() }
        .background(WindowVisibilityReader { visible in
            if windowVisible != visible { windowVisible = visible }
        })
        .onChange(of: messages) { old, new in
            if let match = new.first(where: { $0.id == currentId }) {
                if shown != match { shown = match }
            }
            // Новая проблема, «Готово: …» или перемещение в корзину — показать сразу.
            let oldIds = Set(old.map(\.id))
            let fresh = new.first { !oldIds.contains($0.id) && ($0.severity == .critical || $0.isSuccess || $0.isTrash) }
            if let fresh {
                show(id: fresh.id)
            } else if !new.contains(where: { $0.id == currentId }) {
                if new.count == 1, let only = new.first, only.isIdle {
                    // Покой уже показан в анимации модели — только запомнить, без второго перехода.
                    currentId = only.id
                    shown = only
                    position = 0
                } else {
                    show(id: sequence.first)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !isHovered, sequence.count > 1, Date().timeIntervalSince(lastSwitch) >= Self.holdSeconds else { continue }
                show(offset: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Сообщение

    private func messageView(_ message: StatusMessage) -> some View {
        Button {
            model.openStatusTarget(message.target)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                // Ровно две строки: заголовок и мелкая вторая (пустая, если её нет).
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        icons(message)
                        Text(message.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .monospacedDigit()
                    }
                    Text(message.subtitle ?? " ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .monospacedDigit()
                        .padding(.trailing, footerWidth > 0 ? footerWidth + 6 : 0)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(message.target == .none)
        .pointerStyle(message.target == .none ? nil : .link)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([message.title, message.subtitle].compactMap { $0 }.joined(separator: ". "))
    }

    /// Образец высоты: строка с иконкой облака и мелкая вторая строка.
    private var lineTemplate: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                CloudLetterIcon(cloud: .googleDrive, size: 13)
                Text(verbatim: "Ag")
            }
            Text(verbatim: "Ag").font(.caption2)
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private var indicator: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 8, height: 8)
            .background {
                if pulses {
                    BreathingGlow(color: pulseColor, isStatic: reduceMotion)
                        .transition(.opacity)
                }
            }
            .padding(.top, 4)
            .animation(.easeInOut(duration: 0.35), value: indicatorColor)
    }

    /// Маленькая иконка облака (G/D) и направления (↓/↑) или значок сообщения.
    @ViewBuilder
    private func icons(_ message: StatusMessage) -> some View {
        if message.isSuccess {
            Image(systemName: "checkmark.circle.fill")
                .imageScale(.small)
                .foregroundStyle(message.isTrash ? .orange : .green)
        }
        if let cloud = message.cloud {
            CloudLetterIcon(cloud: cloud, size: 13)
            if message.isTrash, !message.isSuccess {
                Image(systemName: "trash")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        } else if let symbol = message.symbol, !message.isIdle, !message.isSuccess {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        if let direction = message.direction {
            Image(systemName: direction == .download ? "arrow.down" : "arrow.up")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Кнопка и точки

    /// Справа во второй строке: «Попробовать сейчас» и точки ротации (высоту карточки не меняют).
    private var footer: some View {
        HStack(spacing: 6) {
            if let action = current.action {
                Button(actionTitle(action)) { model.performStatusAction(action) }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
            if messages.count > 1 { dots }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { footerWidth = $0 }
    }

    private var dots: some View {
        let active = messages.firstIndex { $0.id == current.id }
        return HStack(spacing: 4) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                Button {
                    show(id: message.id)
                } label: {
                    Circle()
                        .fill(dotColor(message, active: index == active))
                        .frame(width: 5, height: 5)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(message.title)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Message \((active ?? 0) + 1) of \(messages.count)"))
        .accessibilityAdjustableAction { direction in
            show(offset: direction == .increment ? 1 : -1)
        }
    }

    private func actionTitle(_ action: StatusMessage.Action) -> String {
        switch action {
        case .signIn: return String(localized: "Sign In")
        case .undoTrash: return String(localized: "Undo")
        default: return String(localized: "Try Now")
        }
    }

    // MARK: - Цвета

    private var tint: Color {
        if hasCritical { return Color.red.opacity(colorScheme == .dark ? 0.18 : 0.12) }
        if showsWarning { return Color.yellow.opacity(colorScheme == .dark ? 0.14 : 0.12) }
        return .clear
    }

    private var indicatorColor: Color {
        if hasCritical { return .red }
        if showsWarning { return .yellow }
        if current.isTrash { return .orange }
        return model.snapshot.isOnline ? .green : .orange
    }

    private func dotColor(_ message: StatusMessage, active: Bool) -> Color {
        let base: Color = switch message.severity {
        case .critical: .red
        case .warning: .yellow
        case .normal: .primary
        }
        return base.opacity(active ? 0.85 : 0.25)
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .offset(y: 14).combined(with: .opacity),
                           removal: .offset(y: -14).combined(with: .opacity))
    }

    // MARK: - Ротация

    /// Следующее (или предыдущее) сообщение в последовательности ротации.
    private func show(offset: Int) {
        let order = sequence
        guard order.count > 1 else { return }
        let index = order.indices.contains(position) && order[position] == current.id
            ? position : (order.firstIndex(of: current.id) ?? -1)
        let next = ((index + offset) % order.count + order.count) % order.count
        switchTo(order[next], position: next)
    }

    private func show(id: String?) {
        guard let id else { return }
        switchTo(id, position: sequence.firstIndex(of: id) ?? 0)
    }

    private func switchTo(_ id: String, position newPosition: Int) {
        lastSwitch = Date()
        position = newPosition
        guard id != currentId else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            currentId = id
            shown = messages.first { $0.id == id }
            switchCount += 1
        }
    }
}

/// «Дыхание» фона и обводки карточки: 0,06 → 0,16 (обводка 0,15 → 0,45), цикл 2,4 с.
/// Цвет (зелёный — передача, оранжевый — корзина) и «дыхание» — разные анимируемые свойства:
/// смена цвета вместе со сменой сообщения плавная и не сбрасывает фазу пульсации.
/// Существует, только пока идёт пульсация: вместе с видом исчезает и повторяющаяся анимация.
private struct BreathingTint: View {
    let shape: RoundedRectangle
    let color: Color
    /// «Уменьшить движение»: статичный лёгкий оттенок.
    let isStatic: Bool
    @State private var inhale = false

    var body: some View {
        ZStack {
            shape.fill(color)
                .opacity(isStatic ? 0.1 : (inhale ? 0.16 : 0.06))
            shape.strokeBorder(color, lineWidth: 1)
                .opacity(isStatic ? 0.3 : (inhale ? 0.45 : 0.15))
        }
        .onAppear {
            guard !isStatic else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { inhale = true }
        }
    }
}

/// Мягкое свечение за точкой-индикатором, в такт с фоном.
private struct BreathingGlow: View {
    let color: Color
    let isStatic: Bool
    @State private var inhale = false

    var body: some View {
        Circle()
            .fill(color)
            .blur(radius: 3)
            .opacity(isStatic ? 0.4 : (inhale ? 0.75 : 0.25))
            .onAppear {
                guard !isStatic else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { inhale = true }
            }
            .allowsHitTesting(false)
    }
}

/// Сообщает, видно ли окно карточки: свёрнутое, скрытое или закрытое другими окнами — не видно.
private struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else {
                report(false)
                return
            }
            let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportWindowState() }
                })
            }
            reportWindowState()
        }

        private func reportWindowState() {
            guard let window else { return }
            report(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        /// Не во время обновления вида SwiftUI.
        private func report(_ visible: Bool) {
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }
    }
}

/// Колесо мыши и свайп по трекпаду над карточкой — пролистывание сообщений (монитор событий,
/// пока курсор над карточкой: события прокрутки до sidebar не доходят).
@MainActor
private final class ScrollStepper {
    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var firedInGesture = false

    func install(_ step: @escaping @MainActor (Int) -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, step: step) }
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent, step: @MainActor (Int) -> Void) {
        // Инерция после свайпа не листает дальше.
        guard event.momentumPhase.isEmpty else { return }
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        if !event.hasPreciseScrollingDeltas {
            // Колесо мыши: одно деление — одно сообщение.
            if delta != 0 { step(delta < 0 ? 1 : -1) }
            return
        }
        if event.phase.contains(.began) {
            accumulated = 0
            firedInGesture = false
        }
        accumulated += delta
        // Свайп: одно сообщение за жест.
        if !firedInGesture, abs(accumulated) > 18 {
            firedInGesture = true
            step(accumulated < 0 ? 1 : -1)
        }
    }
}

/// Фон карточки статуса: Liquid Glass на macOS 26+, на macOS 15 — материал с тонкой обводкой.
struct StatusCardBackground: ViewModifier {
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }
}
