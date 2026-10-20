import AppKit
import SwiftUI

/// «Добавить по ссылке…»: поиск объекта по ссылке Google Drive, карточка с размером и свободным местом.
struct AddLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isLookingUp = false
    @State private var lookupError: String?
    @State private var item: DriveItem?
    @State private var stats = FolderSizeCounter.Stats()
    @State private var isCounting = false
    @State private var countFinished = false
    @State private var countError: String?
    @State private var lookupTask: Task<Void, Never>?
    @State private var countTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add by Link").font(.title2.weight(.semibold))

            HStack {
                TextField("Google Drive link or ID", text: $text,
                          prompt: Text("https://drive.google.com/drive/folders/…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(lookup)
                    .disabled(!model.isSignedIn)
                Button("Find", action: lookup)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isLookingUp || !model.isSignedIn)
            }

            if !model.isSignedIn {
                Label("Sign in to Google in Settings first.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else if isLookingUp {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Getting details…").foregroundStyle(.secondary)
                }
            } else if let lookupError {
                Label(lookupError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let item {
                card(for: item)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let item {
                    Button("Open in NaviDrive Browser") {
                        model.openInBrowser(item)
                        dismiss()
                    }
                    Button("Download To…") {
                        model.downloadLinked(item, chooseFolder: true, requiredBytes: requiredBytes)
                        dismiss()
                    }
                    Button("Download to Default Folder") {
                        model.downloadLinked(item, chooseFolder: false, requiredBytes: requiredBytes)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .frame(minHeight: 260)
        .onAppear(perform: prefillFromPasteboard)
        .onDisappear {
            lookupTask?.cancel()
            countTask?.cancel()
        }
    }

    // MARK: - Card

    @ViewBuilder
    private func card(for item: DriveItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: DriveBrowserView.icon(for: item))
                    .font(.system(size: 30))
                    .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.headline).lineLimit(2)
                    Text(DriveBrowserView.kind(for: item)).foregroundStyle(.secondary)
                }
            }

            Divider()

            if item.isFolder {
                folderStats
            } else {
                LabeledContent("Size") {
                    Text(item.exportFormat.map { String(localized: "export to .\($0.fileExtension)") } ?? Format.bytes(item.sizeValue))
                        .monospacedDigit()
                }
                if !item.canDownload {
                    Label("The owner has disabled downloading this file", systemImage: "nosign")
                        .foregroundStyle(.red)
                }
            }

            freeSpace
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var folderStats: some View {
        LabeledContent("Files") {
            HStack(spacing: 6) {
                Text("\(stats.files)").monospacedDigit()
                if stats.folders > 0 { Text("in \(stats.folders) folders").foregroundStyle(.secondary) }
            }
        }
        LabeledContent("Total size") {
            HStack(spacing: 6) {
                Text(Format.bytes(stats.bytes)).monospacedDigit()
                if stats.unsizedFiles > 0 {
                    Text("+ \(stats.unsizedFiles) Google docs / shortcuts without size").foregroundStyle(.secondary)
                }
            }
        }
        if stats.forbidden > 0 {
            Label("The owner has disabled downloading of \(stats.forbidden) files — they will be skipped", systemImage: "nosign")
                .foregroundStyle(.orange)
        }
        if isCounting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Counting…").foregroundStyle(.secondary)
                Spacer()
                Button("Stop Counting") { countTask?.cancel() }
                    .buttonStyle(.link)
            }
        } else if let countError {
            Label("Counting interrupted: \(countError)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if !countFinished {
            HStack {
                Text("Counting stopped — the data shown is incomplete").foregroundStyle(.secondary)
                Spacer()
                Button("Count Again") { startCounting(item!) }.buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private var freeSpace: some View {
        let path = PathResolver.expand(model.defaultDownloadPath)
        if let free = PathResolver.availableCapacity(at: path) {
            LabeledContent("Free in default folder") {
                Text(Format.bytes(free)).monospacedDigit()
            }
            if let required = requiredBytes, required > free {
                Label("Not enough space: \(Format.bytes(required)) needed, \(Format.bytes(free)) free. Choose another disk with “Download To…”.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Сколько места нужно (известный на данный момент объём).
    private var requiredBytes: Int64? {
        guard let item else { return nil }
        if item.isFolder { return stats.bytes > 0 ? stats.bytes : nil }
        return item.exportFormat == nil ? item.sizeValue : nil
    }

    // MARK: - Actions

    private func prefillFromPasteboard() {
        guard text.isEmpty, let string = NSPasteboard.general.string(forType: .string),
              string.count < 2_000, DriveLink.parse(string) != nil,
              string.contains("google.com") else { return }
        text = string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lookup() {
        let input = text
        lookupTask?.cancel()
        countTask?.cancel()
        item = nil
        lookupError = nil
        isLookingUp = true
        lookupTask = Task {
            do {
                let found = try await model.lookupLink(input)
                guard !Task.isCancelled else { return }
                item = found
                isLookingUp = false
                if found.isFolder { startCounting(found) }
            } catch {
                guard !Task.isCancelled else { return }
                lookupError = error.localizedDescription
                isLookingUp = false
            }
        }
    }

    private func startCounting(_ folder: DriveItem) {
        countTask?.cancel()
        stats = .init()
        countError = nil
        countFinished = false
        isCounting = true
        let counter = FolderSizeCounter(api: model.api)
        countTask = Task {
            do {
                let result = try await counter.count(folder) { partial in
                    await MainActor.run { stats = partial }
                }
                stats = result
                countFinished = true
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                countError = error.localizedDescription
            }
            isCounting = false
        }
    }
}
