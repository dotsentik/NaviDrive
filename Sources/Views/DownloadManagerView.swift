import SwiftUI

struct DownloadManagerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.enqueueBanner {
                EnqueueReportBanner(report: banner.report) {
                    model.enqueueBanner = nil
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            summary
            Divider()
            if !model.snapshot.scanErrors.isEmpty {
                scanErrors
                Divider()
            }
            filterBar
            Divider()
            taskList
                .mainContentFocus()
        }
        .animation(.easeInOut(duration: 0.2), value: model.enqueueBanner)
        .navigationTitle("Download Manager")
    }

    private func filterTitle(_ filter: DownloadFilter) -> String {
        let count = filter.statuses.reduce(0) { $0 + (model.totals.countsByStatus[$1] ?? 0) }
        return filter == .all ? filter.title : "\(filter.title) (\(count))"
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(alignment: .center, spacing: 24) {
            stat("Speed", model.downloadSpeedText)
            VStack(alignment: .leading, spacing: 4) {
                Text("Threads (limit \(model.snapshot.userLimit))").font(.caption).foregroundStyle(.secondary)
                Text(model.threadsSummary).font(.headline).monospacedDigit()
                Text(model.snapshot.balancerStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text("small \(model.snapshot.runningSmall) · large \(model.snapshot.runningLarge) · export \(model.snapshot.runningExports)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .help("The number of threads is tuned automatically (AIMD): +1 every 15 s while speed grows; ×½ when Google rate-limits.")
            stat("Network", model.networkStatusText, color: model.snapshot.isOnline ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Overall progress").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: model.totals.fraction)
                Text(model.progressSummary).font(.caption).monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            if let quota = model.totals.countsByStatus[.waitingForQuota], quota > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Waiting for Google quota: \(quota)", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.orange)
                    if let next = model.totals.nextQuotaAttemptAt {
                        Text("Next attempt: \(Date(timeIntervalSince1970: TimeInterval(next)).formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("Try Now") { model.retryQuotaNow() }
                        .buttonStyle(.link).font(.caption)
                }
                .help("Google has limited downloads of these files. NaviDrive will retry after 1 h, 2 h, 4 h … up to 24 h; other files keep downloading as usual.")
            }
            if model.snapshot.scanningFolders > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning: \(model.snapshot.scannedFiles) files")
                        .font(.caption).monospacedDigit()
                }
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

    private var scanErrors: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Folder Scan Errors", systemImage: "exclamationmark.triangle")
                .font(.headline).foregroundStyle(.orange)
            ForEach(Array(model.snapshot.scanErrors.suffix(5).enumerated()), id: \.offset) { _, message in
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // MARK: - Tasks

    private var filterBar: some View {
        Picker("Show", selection: Binding(get: { model.downloadFilter }, set: { model.setFilter($0) })) {
            ForEach(DownloadFilter.allCases) { filter in
                Text(filterTitle(filter)).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func sectionCount(_ kind: TaskSectionKind) -> Int {
        kind.statuses.reduce(0) { $0 + (model.totals.countsByStatus[$1] ?? 0) }
    }

    private var taskList: some View {
        let kinds = model.downloadFilter.sections
        return List {
            ForEach(kinds) { kind in
                let rows = model.sections[kind] ?? []
                // Строки и счётчики — из одного снимка состояния: число в заголовке совпадает со строками
                // (кроме секций длиннее предела загрузки, где строки показываются первыми N).
                let total = max(sectionCount(kind), rows.count)
                if !rows.isEmpty {
                    Section {
                        // Ленивая отрисовка; Equatable — строка перерисовывается, только если изменились её данные.
                        ForEach(rows) { task in
                            DownloadTaskRow(task: task, liveBytes: model.snapshot.liveProgress[task.id],
                                            verifyBytes: model.snapshot.verificationProgress[task.id],
                                            isConnecting: model.snapshot.connecting.contains(task.id))
                                .equatable()
                        }
                    } header: {
                        sectionHeader(kind, total: total)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if kinds.allSatisfy({ (model.sections[$0] ?? []).isEmpty }) {
                ContentUnavailableView("No Tasks", systemImage: "tray",
                                       description: Text("Download files using the context menu in My Drive."))
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ kind: TaskSectionKind, total: Int) -> some View {
        HStack(spacing: 8) {
            Text(kind.title).font(.headline)
            Text("\(total)").foregroundStyle(.secondary).monospacedDigit()
            if kind == .queued, let bytes = model.totals.bytesByStatus[.queued], bytes > 0 {
                Text("· \(Format.bytes(bytes))").foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            switch kind {
            case .paused:
                if model.totals.pausedAllCount > 0 {
                    Text("All paused").foregroundStyle(.secondary)
                }
                Button("Resume All") { model.resumeAllPaused() }
                    .buttonStyle(.link)
                    .help("Resumes every paused file, including files paused individually")
            case .failed:
                Button("Retry All") { model.retryFailed() }.buttonStyle(.link)
            case .completed:
                Button("Clear History") { model.clearHistory() }
                    .buttonStyle(.link)
                    .help("Removes only the history entries; downloaded files stay on disk")
            case .waiting:
                if (model.totals.countsByStatus[.waitingForQuota] ?? 0) > 0 {
                    Button("Try Quota Now") { model.retryQuotaNow() }.buttonStyle(.link)
                }
            case .downloading, .queued:
                EmptyView()
            }
        }
        .font(.callout)
    }
}

private struct DownloadTaskRow: View, Equatable {
    @Environment(AppModel.self) private var model
    let task: DownloadTask
    let liveBytes: Int64?
    /// Прочитано байт при проверке MD5.
    let verifyBytes: Int64?
    /// Поток запущен, первые байты ещё не пришли.
    let isConnecting: Bool
    @State private var confirmCancel = false

    nonisolated static func == (lhs: DownloadTaskRow, rhs: DownloadTaskRow) -> Bool {
        lhs.task == rhs.task && lhs.liveBytes == rhs.liveBytes && lhs.verifyBytes == rhs.verifyBytes
            && lhs.isConnecting == rhs.isConnecting
    }

    private var downloaded: Int64 { liveBytes ?? task.downloadedSize }

    private var fraction: Double? {
        guard task.expectedSize > 0 else { return task.status == .completed ? 1 : nil }
        return min(1, Double(downloaded) / Double(task.expectedSize))
    }

    private var canCancel: Bool { ![.completed, .cancelled, .verifying].contains(task.status) }

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
                Text(PathResolver.displayPath(task.targetDirPath))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                progressBar
                HStack(spacing: 8) {
                    Text(statusLine).monospacedDigit()
                    if task.status == .completed && task.verified {
                        Text("verified ✓")
                            .foregroundStyle(.green)
                            .help(task.provider == .dropbox
                                  ? String(localized: "content_hash matches the Dropbox checksum")
                                  : String(localized: "MD5 matches the Google Drive checksum"))
                    }
                    if task.retryCount > 0 && ![.completed, .paused, .pausedAll].contains(task.status) {
                        Text("Retries: \(task.retryCount)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if task.status == .waitingForQuota, let next = task.nextAttemptAt {
                    Label("Next attempt: \(Date(timeIntervalSince1970: TimeInterval(next)).formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.orange)
                }
                // Причина ожидания или ошибки: «Внешний диск «T7A» не подключён…», «Ожидание интернета…», текст ошибки.
                if let error = task.lastError, ![.completed, .paused, .pausedAll].contains(task.status) {
                    Text(error).font(.caption).foregroundStyle(task.status == .failed ? .red : .orange).lineLimit(2)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                switch task.status {
                case .downloading, .queued, .waitingForNetwork, .waitingForVolume, .waitingForSpace:
                    iconButton("pause.fill", "Pause") { model.pause(task) }
                case .paused, .pausedAll, .cancelled, .waitingForQuota:
                    iconButton("play.fill", "Resume") { model.resume(task) }
                case .failed:
                    iconButton("arrow.clockwise", "Retry") { model.resume(task) }
                case .completed, .verifying:
                    EmptyView()
                }
                if canCancel {
                    iconButton("xmark", "Cancel Download") { confirmCancel = true }
                }
                iconButton("magnifyingglass", "Show in Finder") { model.revealTask(task) }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Show in Finder") { model.revealTask(task) }
            if [.downloading, .queued, .waitingForNetwork, .waitingForVolume, .waitingForSpace].contains(task.status) {
                Button("Pause") { model.pause(task) }
            }
            if [.paused, .pausedAll, .cancelled, .waitingForQuota].contains(task.status) { Button("Resume") { model.resume(task) } }
            if task.status == .failed { Button("Retry") { model.resume(task) } }
            if canCancel {
                Divider()
                Button("Cancel Download…") { confirmCancel = true }
            }
        }
        // Отмена — в отличие от паузы — удаляет скачанную часть, поэтому спрашиваем подтверждение.
        .confirmationDialog("Cancel downloading “\(task.fileName)”?", isPresented: $confirmCancel) {
            Button("Cancel Download", role: .destructive) { model.cancel(task) }
            Button("Don’t Cancel", role: .cancel) {}
        } message: {
            Text(downloaded > 0
                 ? String(localized: "The part already downloaded (\(Format.bytes(downloaded))) will be deleted. To continue later, use Pause.")
                 : String(localized: "The task will be moved to history as cancelled."))
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        switch task.status {
        case .verifying:
            if let verifyBytes, task.expectedSize > 0 {
                ProgressView(value: min(1, Double(verifyBytes) / Double(task.expectedSize))).tint(.green)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.green)
            }
        case .downloading:
            if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
        case .paused, .pausedAll, .queued, .waitingForNetwork, .waitingForVolume, .waitingForSpace, .waitingForQuota, .failed:
            // Серый прогресс — сколько уже лежит в .gdrive.part.
            if downloaded > 0, let fraction { ProgressView(value: fraction).tint(.gray) }
        case .completed, .cancelled:
            EmptyView()
        }
    }

    /// «На паузе · 160 МБ из 2,89 ГБ · 5,4%»
    private var statusLine: String {
        var parts = [task.status == .downloading && isConnecting ? String(localized: "Connecting…") : task.status.title]
        if task.expectedSize > 0, task.status != .completed || downloaded > 0 {
            parts.append(String(localized: "\(Format.bytes(downloaded)) of \(Format.bytes(task.expectedSize))"))
            if let fraction, task.status != .completed { parts.append(Format.percent(fraction)) }
        } else if downloaded > 0 {
            parts.append(Format.bytes(downloaded))
        } else if task.exportFormat != nil {
            parts.append(String(localized: "export"))
        }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch task.status {
        case .completed: .green
        case .failed: .red
        case .downloading: .accentColor
        case .waitingForVolume, .waitingForSpace, .waitingForNetwork, .waitingForQuota: .orange
        default: .secondary
        }
    }

    private func iconButton(_ image: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: image) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// Итог «Скачать»: сколько добавлено, сколько уже было скачано, что не поддерживается.
private struct EnqueueReportBanner: View {
    let report: EnqueueReport
    let dismiss: () -> Void

    private var style: (icon: String, color: Color) {
        switch report.tone {
        case .success: ("checkmark.circle.fill", .green)
        case .info: ("info.circle.fill", .blue)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.message)
                    .lineLimit(3)
                if report.errors.count > 1 || (report.added + report.alreadyDownloaded > 0 && !report.errors.isEmpty) {
                    Text("See details in Folder Scan Errors below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.12))
    }
}
