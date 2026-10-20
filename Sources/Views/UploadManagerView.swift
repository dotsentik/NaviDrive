import SwiftUI

/// Экран «Отправка»: очередь загрузки файлов в Google Drive (устроен как «Менеджер загрузок»).
struct UploadManagerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.uploadBanner {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                    Text(banner).lineLimit(3)
                    Spacer(minLength: 8)
                    Button { model.uploadBanner = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Hide")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.green.opacity(0.12))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            summary
            Divider()
            filterBar
            Divider()
            taskList
                .mainContentFocus()
        }
        .animation(.easeInOut(duration: 0.2), value: model.uploadBanner)
        .navigationTitle("Uploads")
        .task { await model.refreshUploads(includeTasks: true) }
    }

    // MARK: - Summary

    private var summary: some View {
        let snapshot = model.uploadSnapshot
        return HStack(alignment: .center, spacing: 24) {
            stat("Speed", snapshot.isPaused ? String(localized: "Paused") : Format.speed(snapshot.bytesPerSecond))
            VStack(alignment: .leading, spacing: 4) {
                Text("Uploads (limit \(snapshot.userLimit))").font(.caption).foregroundStyle(.secondary)
                Text("Active: \(snapshot.runningCount) of \(snapshot.limit)").font(.headline).monospacedDigit()
                if snapshot.limit < snapshot.userLimit {
                    Text("Google is rate-limiting requests — the limit is temporarily reduced")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .help("The number of simultaneous uploads is set in Settings (1–6). Downloads run in parallel with their own limit.")
            stat("Network", snapshot.isOnline ? String(localized: "Online") : String(localized: "Waiting for network…"), color: snapshot.isOnline ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Overall progress").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: model.uploadTotals.fraction)
                Text(model.uploadProgressSummary).font(.caption).monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            if !snapshot.preparing.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Preparing: \(snapshot.preparing.formatted(.list(type: .and)))")
                        .font(.caption).lineLimit(2)
                }
                .help("Scanning files, checking names in the destination folder and creating subfolders on Drive")
            }
        }
        .padding(16)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().foregroundStyle(color)
        }
    }

    // MARK: - List

    private var filterBar: some View {
        Picker("Show", selection: Binding(get: { model.uploadFilter }, set: { model.setUploadFilter($0) })) {
            ForEach(DownloadFilter.allCases) { filter in
                Text(filterTitle(filter)).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func filterTitle(_ filter: DownloadFilter) -> String {
        guard filter != .all else { return filter.title }
        let count = filter.uploadSections.reduce(0) { $0 + sectionCount($1) }
        return "\(filter.title) (\(count))"
    }

    private func sectionCount(_ kind: UploadSectionKind) -> Int {
        kind.statuses.reduce(0) { $0 + (model.uploadTotals.countsByStatus[$1] ?? 0) }
    }

    private var taskList: some View {
        let kinds = model.uploadFilter.uploadSections
        return List {
            ForEach(kinds) { kind in
                let rows = model.uploadSections[kind] ?? []
                let total = max(sectionCount(kind), rows.count)
                if total > 0 {
                    Section {
                        ForEach(rows) { task in
                            UploadTaskRow(task: task,
                                          liveBytes: model.uploadSnapshot.liveProgress[task.id],
                                          speed: model.uploadSnapshot.speeds[task.id],
                                          verifyBytes: model.uploadSnapshot.verificationProgress[task.id])
                                .equatable()
                        }
                        if total > rows.count {
                            Text("…and \(total - rows.count) more").font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        sectionHeader(kind, total: total)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if kinds.allSatisfy({ (model.uploadSections[$0] ?? []).isEmpty && sectionCount($0) == 0 }) {
                ContentUnavailableView("No Uploads", systemImage: "arrow.up.circle",
                                       description: Text("Drag files or folders from Finder into a My Drive folder, or click Upload… in the browser toolbar."))
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ kind: UploadSectionKind, total: Int) -> some View {
        HStack(spacing: 8) {
            Text(kind.title).font(.headline)
            Text("\(total)").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            switch kind {
            case .paused:
                Button("Resume All") { model.resumeAllPausedUploads() }.buttonStyle(.link)
            case .failed:
                Button("Retry All") { model.retryFailedUploads() }
                    .buttonStyle(.link)
                    .help("Files that changed during upload or failed verification are restarted with the button in their row")
            case .completed:
                Button("Clear History") { model.clearUploadHistory() }
                    .buttonStyle(.link)
                    .help("Removes only the history entries; files on Google Drive stay")
            case .uploading, .queued, .waiting:
                EmptyView()
            }
        }
        .font(.callout)
    }
}

private struct UploadTaskRow: View, Equatable {
    @Environment(AppModel.self) private var model
    let task: UploadTask
    let liveBytes: Int64?
    let speed: Double?
    let verifyBytes: Int64?
    @State private var confirmCancel = false

    nonisolated static func == (lhs: UploadTaskRow, rhs: UploadTaskRow) -> Bool {
        lhs.task == rhs.task && lhs.liveBytes == rhs.liveBytes && lhs.speed == rhs.speed && lhs.verifyBytes == rhs.verifyBytes
    }

    private var uploaded: Int64 { min(task.fileSize, liveBytes ?? task.uploadedBytes) }

    private var fraction: Double? {
        guard task.fileSize > 0 else { return task.status == .completed ? 1 : nil }
        return min(1, Double(uploaded) / Double(task.fileSize))
    }

    private var canCancel: Bool { ![.completed, .cancelled, .verifying].contains(task.status) }
    private var canPause: Bool { [.uploading, .queued, .waitingForNetwork, .waitingForVolume].contains(task.status) }
    private var canResume: Bool { [.paused, .cancelled].contains(task.status) || (task.status == .failed && task.errorKind == nil) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.status.systemImage)
                .foregroundStyle(statusColor)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    CloudBadge(cloud: task.provider)
                    Text(task.fileName).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 4) {
                    Text(PathResolver.displayPath(task.localPath)).lineLimit(1).truncationMode(.head)
                    Image(systemName: "arrow.right")
                    Label(task.parentName, systemImage: "folder").lineLimit(1).truncationMode(.head)
                    if task.replaceFileId != nil {
                        Text("new version").foregroundStyle(.orange)
                            .help("Replaces the existing file: a new version of the same file is uploaded")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                progressBar
                HStack(spacing: 8) {
                    Text(statusLine).monospacedDigit()
                    if task.retryCount > 0 && ![.completed, .paused].contains(task.status) {
                        Text("Retries: \(task.retryCount)")
                    }
                    if task.status == .completed && task.checksum != nil {
                        Text("verified ✓").foregroundStyle(.green)
                            .help(task.provider == .dropbox
                                  ? String(localized: "The content hash of the file on this Mac matches the Dropbox content_hash")
                                  : String(localized: "The MD5 of the file on this Mac matches the Google Drive checksum"))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let error = task.lastError, ![.completed, .paused].contains(task.status) {
                    Text(error).font(.caption).foregroundStyle(task.status == .failed ? .red : .orange).lineLimit(2)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if let kind = task.errorKind, task.status == .failed {
                    Button(kind.restartTitle) { model.restartUpload(task) }
                        .controlSize(.small)
                        .help("New upload session: the file is sent from the beginning")
                } else if canPause {
                    iconButton("pause.fill", String(localized: "Pause")) { model.pauseUpload(task) }
                } else if canResume {
                    iconButton(task.status == .failed ? "arrow.clockwise" : "play.fill",
                               task.status == .failed ? String(localized: "Retry") : String(localized: "Resume")) { model.resumeUpload(task) }
                }
                if canCancel {
                    iconButton("xmark", String(localized: "Cancel Upload")) { confirmCancel = true }
                }
                iconButton("magnifyingglass", String(localized: "Show in Finder")) { model.revealUploadSource(task) }
                iconButton("arrow.up.forward.square", String(localized: "Open Folder on Drive")) { model.openUploadFolderOnDrive(task) }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Show in Finder") { model.revealUploadSource(task) }
            Button("Open Folder on Drive") { model.openUploadFolderOnDrive(task) }
            if canPause { Button("Pause") { model.pauseUpload(task) } }
            if canResume { Button(task.status == .failed ? String(localized: "Retry") : String(localized: "Resume")) { model.resumeUpload(task) } }
            if let kind = task.errorKind, task.status == .failed { Button(kind.restartTitle) { model.restartUpload(task) } }
            if canCancel {
                Divider()
                Button("Cancel Upload…") { confirmCancel = true }
            }
        }
        .confirmationDialog("Cancel uploading “\(task.fileName)”?", isPresented: $confirmCancel) {
            Button("Cancel Upload", role: .destructive) { model.cancelUpload(task) }
            Button("Don’t Cancel", role: .cancel) {}
        } message: {
            Text(uploaded > 0
                 ? String(localized: "The part already uploaded (\(Format.bytes(uploaded))) will be discarded. To continue later, use Pause.")
                 : String(localized: "The task will be moved to history as cancelled."))
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        switch task.status {
        case .verifying:
            if let verifyBytes, task.fileSize > 0 {
                ProgressView(value: min(1, Double(verifyBytes) / Double(task.fileSize))).tint(.green)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.green)
            }
        case .uploading:
            if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
        case .paused, .queued, .waitingForNetwork, .waitingForVolume, .failed:
            if uploaded > 0, let fraction { ProgressView(value: fraction).tint(.gray) }
        case .completed, .cancelled:
            EmptyView()
        }
    }

    /// «Отправляется · 1,2 ГБ из 40 ГБ · 3,0% · 12,4 МБ/с»
    private var statusLine: String {
        var parts = [task.status.title]
        if task.status == .completed {
            parts.append(Format.bytes(task.fileSize))
        } else if task.fileSize > 0 {
            parts.append(String(localized: "\(Format.bytes(uploaded)) of \(Format.bytes(task.fileSize))"))
            if let fraction { parts.append(Format.percent(fraction)) }
        }
        if task.status == .uploading, let speed, speed > 0 { parts.append(Format.speed(speed)) }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch task.status {
        case .completed: .green
        case .failed: .red
        case .uploading: .accentColor
        case .waitingForNetwork, .waitingForVolume: .orange
        default: .secondary
        }
    }

    /// `help` — уже локализованная строка.
    private func iconButton(_ image: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: image) }
            .buttonStyle(.borderless)
            .help(help)
    }
}
