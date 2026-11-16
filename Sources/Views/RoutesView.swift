import SwiftUI

/// «Маршруты сохранения»: все объекты облака с назначенным кастомным путём (ключ — провайдер и ID).
/// Данные — `model.activeRoutes`: маршруты облака из переключателя sidebar (все — `model.routes`, грузятся из custom_routes в фоне);
/// статус диска — `model.routeVolumeMissing` / `model.routePathMissing`.
struct RoutesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<CustomRoute.ID>()

    var body: some View {
        Table(model.activeRoutes, selection: $selection) {
            TableColumn("Cloud Folder/File") { route in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        CloudBadge(cloud: route.provider)
                        Text(route.driveName.isEmpty ? "—" : route.driveName).lineLimit(1)
                    }
                    Text(route.driveId)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).textSelection(.enabled)
                }
            }
            .width(min: 180, ideal: 240)

            TableColumn("Local Path") { route in
                Text(PathResolver.displayPath(route.localPath))
                    .lineLimit(1).truncationMode(.middle)
                    .help(route.localPath)
            }
            .width(min: 200, ideal: 340)

            TableColumn("Disk Status") { route in
                DiskStatusLabel(path: route.localPath, missing: model.routeVolumeMissing.contains(route.id),
                                folderMissing: model.routePathMissing.contains(route.id))
            }
            .width(min: 120, ideal: 140)

            TableColumn("Actions") { route in
                HStack(spacing: 10) {
                    Button("Change Location…") { model.changeRoute(route) }
                    Button("Show in Finder") { model.revealRoute(route) }
                    Button("Remove Location", role: .destructive) { model.deleteRoute(route) }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            .width(min: 330, ideal: 350)
        }
        .contextMenu(forSelectionType: CustomRoute.ID.self) { ids in
            let selected = routes(for: ids)
            if selected.count == 1, let route = selected.first {
                Button("Change Location…") { model.changeRoute(route) }
                Button("Show in Finder") { model.revealRoute(route) }
                Divider()
            }
            if !selected.isEmpty {
                Button("Remove Location") { model.deleteRoutes(selected) }
                    .keyboardShortcut(.delete, modifiers: [])
            }
        }
        // Delete / ⌘⌫ / ⌦ удаляют выделенные привязки (⌘A — выделить все); файлы на диске не трогаются.
        .onDeleteCommand(perform: removeSelected)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard !selection.isEmpty else { return .ignored }
            removeSelected()
            return .handled
        }
        .overlay {
            if model.activeRoutes.isEmpty {
                ContentUnavailableView {
                    Label("No custom save locations", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Assign a location by right-clicking a file or folder: “Set Permanent Custom Location…”. The folder will be created inside the chosen location, and subfolders keep their structure.")
                }
            }
        }
        .mainContentFocus()
        .navigationTitle("Save Locations")
        .onAppear { model.reloadRoutes() }
    }

    private func routes(for ids: Set<CustomRoute.ID>) -> [CustomRoute] {
        model.activeRoutes.filter { ids.contains($0.id) }
    }

    private func removeSelected() {
        let selected = routes(for: selection)
        guard !selected.isEmpty else { return }
        model.deleteRoutes(selected)
        selection.removeAll()
    }
}

private struct DiskStatusLabel: View {
    let path: String
    let missing: Bool
    let folderMissing: Bool

    var body: some View {
        if missing {
            Label("Not connected", systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
        } else if folderMissing {
            Label("Folder not found", systemImage: "folder.badge.questionmark")
                .foregroundStyle(.orange)
        } else if PathResolver.volumeRoot(for: path) != nil {
            Label("Connected", systemImage: "externaldrive.badge.checkmark")
                .foregroundStyle(.green)
        } else {
            Label("Internal disk", systemImage: "internaldrive")
                .foregroundStyle(.secondary)
        }
    }
}

/// Маленькая иконка облака у задачи или маршрута (Менеджер загрузок, Отправка, Маршруты).
struct CloudBadge: View {
    let cloud: CloudProviderKind

    var body: some View {
        Image(systemName: cloud.systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(cloud.displayName)
            .accessibilityLabel(cloud.displayName)
    }
}
