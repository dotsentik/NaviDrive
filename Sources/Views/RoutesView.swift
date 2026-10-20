import SwiftUI

/// «Маршруты сохранения»: все объекты облака с назначенным кастомным путём (ключ — провайдер и ID).
/// Данные — `model.routes` (загружаются из custom_routes в фоне), статус диска — `model.routeVolumeMissing`.
struct RoutesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: CustomRoute.ID?

    var body: some View {
        Table(model.routes, selection: $selection) {
            TableColumn("Google Drive Folder/File") { route in
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.driveName.isEmpty ? "—" : route.driveName).lineLimit(1)
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
                DiskStatusLabel(path: route.localPath, missing: model.routeVolumeMissing.contains(route.id))
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
            if let id = ids.first, let route = model.routes.first(where: { $0.id == id }) {
                Button("Change Location…") { model.changeRoute(route) }
                Button("Show in Finder") { model.revealRoute(route) }
                Divider()
                Button("Remove Location") { model.deleteRoute(route) }
            }
        }
        .overlay {
            if model.routes.isEmpty {
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
}

private struct DiskStatusLabel: View {
    let path: String
    let missing: Bool

    var body: some View {
        if missing {
            Label("Not connected", systemImage: "externaldrive.badge.exclamationmark")
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
