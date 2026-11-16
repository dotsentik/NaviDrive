import AppKit
import SwiftUI

/// «Диагностика…» загрузки: вывод простыми словами (висит ли, почему, что на диске) и события
/// этого файла из журнала. «Скопировать отчёт» — чтобы прислать разбор целиком.
struct DownloadDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: DownloadTask
    @State private var report: DownloadDiagnosticsReport?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                CloudBadge(cloud: task.provider)
                Text(task.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
            }
            if let report {
                facts(report)
                verdict(report)
                events(report)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Show Log in Finder") { AppLog.reveal() }
                Spacer()
                Button("Refresh") { Task { await load() } }
                Button(copied ? String(localized: "Copied") : String(localized: "Copy Report")) {
                    guard let report else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.plainText, forType: .string)
                    copied = true
                }
                .disabled(report == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 680, height: 540)
        .task { await load() }
    }

    private func load() async {
        copied = false
        report = await model.downloadDiagnostics(for: task)
    }

    private func facts(_ report: DownloadDiagnosticsReport) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                Text(report.status.title)
            }
            GridRow {
                Text("On disk").foregroundStyle(.secondary)
                Text("\(report.partBytes.map(Format.bytes) ?? "—") / \(Format.bytes(report.expectedSize))").monospacedDigit()
            }
            GridRow {
                Text("Recorded progress").foregroundStyle(.secondary)
                Text(Format.bytes(report.recordedBytes)).monospacedDigit()
            }
            if let live = report.live {
                GridRow {
                    Text("No data for").foregroundStyle(.secondary)
                    Text("\(Int(live.secondsWithoutData)) s").monospacedDigit()
                }
            }
        }
        .font(.callout)
    }

    private func verdict(_ report: DownloadDiagnosticsReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(report.verdict.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }

    private func events(_ report: DownloadDiagnosticsReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent events").font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                Text(report.events.isEmpty
                     ? String(localized: "No events for this file in the log yet. Events are recorded from this version on.")
                     : report.events.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .defaultScrollAnchor(.bottom)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }
}
