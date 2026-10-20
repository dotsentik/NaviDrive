import AppKit
import SwiftUI

/// Единственный тулбар главного окна. Висит на стабильном контейнере detail-колонки (не внутри switch
/// и без меняющегося `.id`), у каждого элемента постоянный id. Набор элементов меняется только
/// при выборе другого раздела sidebar, но не при его показе/скрытии; доступность кнопок берётся
/// из модели (`browserToolbar`), а не из временного состояния вида.
struct MainToolbar: ToolbarContent {
    let model: AppModel

    private var section: SidebarItem { model.selection ?? .myDrive }

    private var isBrowser: Bool {
        switch section {
        case .myDrive, .sharedWithMe, .sharedDrives, .linked: true
        case .downloads, .uploads, .routes: false
        }
    }

    var body: some ToolbarContent {
        if isBrowser {
            browserItems
        } else if section == .downloads {
            downloadItems
        } else if section == .uploads {
            uploadItems
        }
    }

    // MARK: - Браузер Drive

    @ToolbarContentBuilder
    private var browserItems: some ToolbarContent {
        let state = model.browserToolbar
        ToolbarItem(id: "browser.back", placement: .navigation) {
            Button { model.sendBrowserCommand(.back) } label: { Image(systemName: "chevron.left") }
                .disabled(!state.canGoBack)
                .help("Back")
        }
        ToolbarItem(id: "browser.refresh", placement: .primaryAction) {
            Button { model.sendBrowserCommand(.refresh) } label: {
                // Вращение иконки вместо спиннера: размер кнопки и капсулы Liquid Glass не меняется.
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: state.isLoading)
            }
            .help("Refresh")
            .keyboardShortcut("r", modifiers: .command)
        }
        ToolbarItem(id: "browser.newFolder", placement: .primaryAction) {
            Button { model.sendBrowserCommand(.newFolder) } label: { Image(systemName: "folder.badge.plus") }
                .help(state.uploadTarget == nil ? String(localized: "You can’t create folders here") : String(localized: "New Folder"))
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(state.uploadTarget == nil)
        }
        ToolbarItem(id: "browser.upload", placement: .primaryAction) {
            Button { model.sendBrowserCommand(.upload) } label: { Image(systemName: "square.and.arrow.up") }
                .help(state.uploadTarget.map { String(localized: "Upload files and folders to “\($0.name)”…") } ?? String(localized: "You can’t upload files here"))
                .disabled(state.uploadTarget == nil)
        }
        ToolbarItem(id: "browser.download", placement: .primaryAction) {
            Button { model.sendBrowserCommand(.download) } label: { Image(systemName: "arrow.down.circle") }
                .help("Download Selection to Default Folder")
                .disabled(!state.hasSelection)
        }
        // Редкие действия — в одном меню.
        ToolbarItem(id: "browser.more", placement: .primaryAction) {
            Menu {
                Button("Add by Link…") { model.showAddLink = true }
                Divider()
                Button("Download to Custom Folder / External SSD…") { model.sendBrowserCommand(.downloadToCustom) }
                    .disabled(!state.hasSelection)
                Button("Set Permanent Custom Location…") { model.sendBrowserCommand(.setPermanentRoute) }
                    .disabled(!state.hasSelection)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("More Actions")
        }
        // Своё поле фиксированной ширины: системное .searchable в тулбаре схлопывалось в лупу,
        // пока ширина колонки менялась при анимации sidebar.
        ToolbarItem(id: "browser.filter", placement: .primaryAction) {
            ToolbarSearchField(text: Binding(get: { model.browserFilter }, set: { model.browserFilter = $0 }),
                               prompt: String(localized: "Filter by Name"))
                .frame(minWidth: 160, idealWidth: 220, maxWidth: 260)
                .layoutPriority(1)
        }
    }

    // MARK: - Менеджер загрузок

    @ToolbarContentBuilder
    private var downloadItems: some ToolbarContent {
        ToolbarItem(id: "downloads.pause", placement: .primaryAction) {
            let action = model.pauseAllAction
            Button {
                model.togglePauseAll()
            } label: {
                Label(action == .resume ? String(localized: "Resume All") : String(localized: "Pause All"),
                      systemImage: action == .resume ? "play.fill" : "pause.fill")
            }
            .disabled(action == .none)
            .help(action.help)
        }
        ToolbarItem(id: "downloads.more", placement: .primaryAction) {
            Menu {
                Button("Retry All Failed") { model.retryFailed() }
                Button("Try Files Waiting for Quota Now") { model.retryQuotaNow() }
                    .disabled((model.totals.countsByStatus[.waitingForQuota] ?? 0) == 0)
                Button("Clear History (Completed and Cancelled)") { model.clearHistory() }
                Divider()
                Button("Open Downloads Folder") { model.openDefaultFolder() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Отправка

    @ToolbarContentBuilder
    private var uploadItems: some ToolbarContent {
        ToolbarItem(id: "uploads.pause", placement: .primaryAction) {
            Button {
                model.togglePauseAllUploads()
            } label: {
                Label(model.uploadSnapshot.isPaused ? String(localized: "Resume All") : String(localized: "Pause All"),
                      systemImage: model.uploadSnapshot.isPaused ? "play.fill" : "pause.fill")
            }
            .help(model.uploadSnapshot.isPaused ? String(localized: "Resume all uploads") : String(localized: "Pause all uploads"))
        }
        ToolbarItem(id: "uploads.more", placement: .primaryAction) {
            Menu {
                Button("Retry All Failed") { model.retryFailedUploads() }
                Button("Clear History (Completed and Cancelled)") { model.clearUploadHistory() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

/// Системное поле поиска AppKit (NSSearchField) фиксированной ширины для тулбара.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        // Действие приходит и при вводе, и при нажатии крестика очистки.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            update(field.stringValue)
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            update(sender.stringValue)
        }

        private func update(_ value: String) {
            if text.wrappedValue != value { text.wrappedValue = value }
        }
    }
}
