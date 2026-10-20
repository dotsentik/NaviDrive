import SwiftUI

/// Выбор папки в облаке в отдельном окне с деревом диска: «Мой Диск» и общие диски,
/// вложенные папки подгружаются при раскрытии.
struct FolderPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let title: String
    let actionTitle: String
    /// Папки, которые нельзя выбрать (перемещаемые папки — нельзя переместить папку в саму себя).
    var excludedIds: Set<String> = []
    let onPick: (UploadTarget) -> Void

    @State private var selection: UploadTarget?
    @State private var sharedDrives: [UploadTarget] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).lineLimit(2)
            List {
                FolderTreeRow(target: model.provider.rootFolder, icon: "externaldrive.connected.to.line.below",
                              selection: $selection, excludedIds: excludedIds, initiallyExpanded: true)
                if !sharedDrives.isEmpty {
                    Section("Shared Drives") {
                        ForEach(sharedDrives, id: \.id) { drive in
                            FolderTreeRow(target: drive, icon: "externaldrive.badge.person.crop",
                                          selection: $selection, excludedIds: excludedIds)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 320)
            HStack {
                if let selection {
                    Label(selection.name, systemImage: "folder").lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    if let selection { onPick(selection) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 480, height: 520)
        .task {
            let provider = model.provider
            let drives = (try? await provider.listAll(.sharedSpaces)) ?? []
            sharedDrives = drives
                .filter(\.canAddChildren)
                .map { UploadTarget(provider: provider.kind, id: $0.id, name: $0.name, spaceId: $0.spaceId ?? $0.id) }
        }
    }
}

private struct FolderTreeRow: View {
    @Environment(AppModel.self) private var model
    let target: UploadTarget
    var icon = "folder"
    @Binding var selection: UploadTarget?
    let excludedIds: Set<String>
    var initiallyExpanded = false

    @State private var isExpanded = false
    @State private var children: [UploadTarget]?
    @State private var loadError: String?

    private var isExcluded: Bool { excludedIds.contains(target.id) }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let children {
                if children.isEmpty {
                    Text("No subfolders").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(children, id: \.id) { child in
                    FolderTreeRow(target: child, selection: $selection, excludedIds: excludedIds)
                }
            } else if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red).lineLimit(2)
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            Label(target.name, systemImage: icon)
                .lineLimit(1)
                .foregroundStyle(isExcluded ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(selection == target ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { if !isExcluded { selection = target } }
                .help(isExcluded ? String(localized: "You can’t move a folder into itself") : "")
        }
        .disabled(isExcluded)
        .onChange(of: isExpanded) { _, expanded in
            if expanded, children == nil { load() }
        }
        .onAppear {
            if initiallyExpanded, !isExpanded { isExpanded = true }
        }
    }

    private func load() {
        let providers = model.providers
        let target = target
        Task {
            do {
                let provider = try providers.provider(for: target.provider)
                let items = try await provider.listAll(.folder(id: target.id, spaceId: target.spaceId))
                children = items
                    .filter { $0.isFolder && !$0.isAlias }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map { UploadTarget(provider: $0.provider, id: $0.id, name: $0.name, spaceId: $0.spaceId ?? target.spaceId) }
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
