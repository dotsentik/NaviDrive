import AppKit
import SwiftUI

/// HUD «Удерживайте ⌘Q для выхода» в стиле системных индикаторов громкости и яркости:
/// скруглённый квадрат 200×200 по центру экрана активного окна, кольцо заполняется за время удержания.
/// Окно не становится ключевым и не принимает мышь — клавиатура остаётся у текущего окна.
@MainActor
final class QuitHoldHUD {
    @MainActor
    @Observable
    final class State {
        /// 0…1; анимируется по времени (линейно за время удержания), а не по автоповтору клавиш.
        var progress: Double = 0
        /// Масштаб появления (без него при «Уменьшить движение»).
        var appeared = false
    }

    private static let size: CGFloat = 200
    private static let fadeOut: TimeInterval = 0.3

    private let state = State()
    private var panel: NSPanel?
    /// Растёт при каждом показе: затухание старого показа не прячет новый.
    private var generation = 0

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(duration: Duration) {
        generation += 1
        let panel = panel ?? makePanel()
        self.panel = panel
        if let screen = (NSApp.keyWindow ?? NSApp.mainWindow)?.screen ?? NSScreen.main {
            let frame = screen.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size / 2, y: frame.midY - Self.size / 2))
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            if !reduceMotion { state.appeared = false }
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        if reduceMotion {
            state.appeared = true
        } else {
            withAnimation(.spring(duration: 0.25, bounce: 0.2)) { state.appeared = true }
        }
        // Анимация начинается с текущего видимого значения (если окно ещё гаснет после отпускания)
        // и заканчивается ровно вместе с таймером удержания.
        withAnimation(.linear(duration: duration / .seconds(1))) { state.progress = 1 }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: String(localized: "Hold ⌘Q to Quit"),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Прячет окно с затуханием; `completed == false` — кольцо плавно сбрасывается.
    func hide(completed: Bool) {
        guard let panel, panel.isVisible else { return }
        let current = generation
        if !completed {
            withAnimation(.easeOut(duration: Self.fadeOut)) { state.progress = 0 }
        }
        if !reduceMotion {
            withAnimation(.easeIn(duration: Self.fadeOut)) { state.appeared = false }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOut
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard self.generation == current else { return }
                panel.orderOut(nil)
                self.state.progress = 0
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Тёмная подложка, как у системных HUD, в любой теме.
        panel.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: QuitHoldView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        panel.contentView = hosting
        return panel
    }
}

private struct QuitHoldView: View {
    let state: QuitHoldHUD.State

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.2), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: state.progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "power")
                    .font(.system(size: 30, weight: .semibold))
            }
            .frame(width: 92, height: 92)
            Text("Hold ⌘Q to Quit")
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 200, height: 200)
        .background(HUDMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .scaleEffect(state.appeared ? 1 : 0.9)
        .accessibilityElement(children: .combine)
    }
}

/// Полупрозрачная подложка системных HUD.
private struct HUDMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
