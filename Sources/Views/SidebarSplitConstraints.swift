import AppKit
import SwiftUI

/// Пределы ширины колонок главного окна.
enum SidebarWidth {
    static let min: CGFloat = 200
    static let ideal: CGFloat = 240
    static let max: CGFloat = 320
    static let detailMin: CGFloat = 600
    static let detailIdeal: CGFloat = 900

    /// Ширина, сохранённая системой («NSSplitView Subview Frames …»), шире предела —
    /// приводится к `max` до создания окна (осталась от версий, где предел не действовал).
    static func clampSavedWidth() {
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix("NSSplitView Subview Frames main") {
            guard var frames = value as? [String], frames.count >= 2 else { continue }
            var sidebar = frames[0].components(separatedBy: ", ")
            var detail = frames[1].components(separatedBy: ", ")
            guard sidebar.count >= 4, detail.count >= 4,
                  let width = Double(sidebar[2]), width > Double(max),
                  let detailX = Double(detail[0]), let detailWidth = Double(detail[2]) else { continue }
            let excess = width - Double(max)
            sidebar[2] = String(format: "%f", Double(max))
            detail[0] = String(format: "%f", detailX - excess)
            detail[2] = String(format: "%f", detailWidth + excess)
            frames[0] = sidebar.joined(separator: ", ")
            frames[1] = detail.joined(separator: ", ")
            defaults.set(frames, forKey: key)
        }
    }
}

/// Жёсткие пределы колонок на уровне AppKit: SwiftUI передаёт `navigationSplitViewColumnWidth`
/// в NSSplitViewItem не всегда (ширина, восстановленная из автосохранения, и пересоздание колонок
/// при показе/скрытии sidebar его сбрасывают). Ставится фоном detail-колонки и применяется
/// при каждом обновлении. Сворачивание sidebar перетаскиванием (canCollapse) не трогается.
struct SidebarSplitConstraints: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onWindow = { Self.apply(from: $0) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(from: nsView) }
    }

    private final class ProbeView: NSView {
        var onWindow: ((NSView) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onWindow?(self)
            }
        }
    }

    @MainActor
    private static func apply(from view: NSView) {
        guard let controller = splitViewController(from: view),
              controller.splitViewItems.count >= 2 else { return }
        let sidebar = controller.splitViewItems[0]
        let detail = controller.splitViewItems[controller.splitViewItems.count - 1]
        if sidebar.minimumThickness != SidebarWidth.min { sidebar.minimumThickness = SidebarWidth.min }
        if sidebar.maximumThickness != SidebarWidth.max { sidebar.maximumThickness = SidebarWidth.max }
        if detail.minimumThickness != SidebarWidth.detailMin { detail.minimumThickness = SidebarWidth.detailMin }
        // Уже растянутый sidebar (восстановлен до ограничения) — сразу к пределу.
        let splitView = controller.splitView
        if !sidebar.isCollapsed, let first = splitView.arrangedSubviews.first, first.frame.width > SidebarWidth.max {
            splitView.setPosition(SidebarWidth.max, ofDividerAt: 0)
        }
    }

    @MainActor
    private static func splitViewController(from view: NSView) -> NSSplitViewController? {
        var current: NSView? = view
        while let candidate = current {
            if let splitView = candidate as? NSSplitView,
               let controller = splitView.delegate as? NSSplitViewController {
                return controller
            }
            current = candidate.superview
        }
        return nil
    }
}
