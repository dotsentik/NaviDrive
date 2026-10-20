import SwiftUI

/// Finder Services «Upload to NaviDrive»: сначала облако (если подключено несколько), затем папка в нём.
struct ServiceUploadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let urls: [URL]

    @State private var cloud: CloudProviderKind?

    var body: some View {
        if let cloud = cloud ?? singleCloud {
            FolderPickerSheet(title: title, actionTitle: String(localized: "Upload"), cloud: cloud,
                              onPickPath: { path in
                                  guard let target = path.last else { return }
                                  model.startUpload(urls, to: target, ancestorIds: path.dropLast().map(\.id))
                                  // Окно было закрыто — оно открывается на целевой папке, а не на «Отправке».
                                  if model.serviceUploadOpensTarget { model.openInBrowser(path: path) }
                              }) { _ in }
            .id(cloud)
        } else {
            chooser
        }
    }

    /// Единственное подключённое облако — выбор не нужен.
    private var singleCloud: CloudProviderKind? {
        model.connectedClouds.count == 1 ? model.connectedClouds.first : nil
    }

    private var title: String {
        urls.count == 1
            ? String(localized: "Where should “\(urls[0].lastPathComponent)” be uploaded?")
            : String(localized: "Where should \(urls.count) items be uploaded?")
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).lineLimit(2)
            Text("Choose a cloud").foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(model.connectedClouds, id: \.self) { kind in
                    Button {
                        cloud = kind
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: kind.systemImage).font(.title2).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: kind.displayName).font(.body.weight(.medium))
                                if let email = model.account(kind).userEmail {
                                    Text(verbatim: email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 480, height: 520)
    }
}
