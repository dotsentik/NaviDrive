import SwiftUI

/// Окно «Software Update»: версия, заметки релиза, «Update» / «Later» / «Skip This Version», прогресс.
struct UpdateView: View {
    private var controller: UpdateController { UpdateController.shared }

    var body: some View {
        if let state = controller.windowState {
            content(state)
                .padding(20)
                .frame(width: 520)
        }
    }

    @ViewBuilder
    private func content(_ state: UpdateController.WindowState) -> some View {
        let release = state.release
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A new version of NaviDrive is available")
                        .font(.headline)
                    Text("NaviDrive \(release.version.description) is available — you have \(controller.currentVersionText).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Release notes")
                .font(.subheadline.weight(.semibold))
            ScrollView {
                Text(notes(release))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 200)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

            status(state)

            buttons(state)
        }
    }

    private func notes(_ release: UpdateRelease) -> AttributedString {
        guard !release.notes.isEmpty else { return AttributedString(String(localized: "No release notes.")) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: release.notes, options: options)) ?? AttributedString(release.notes)
    }

    @ViewBuilder
    private func status(_ state: UpdateController.WindowState) -> some View {
        switch state {
        case .available:
            EmptyView()
        case .downloading(_, let fraction):
            VStack(alignment: .leading, spacing: 4) {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying the update…").foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing — NaviDrive will restart…").foregroundStyle(.secondary)
            }
        case .moveToApplications:
            Label("NaviDrive is running from a disk image or a read-only folder, so it can’t update itself. Drag NaviDrive to the Applications folder first. The new version’s disk image is in Downloads.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(_, let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func buttons(_ state: UpdateController.WindowState) -> some View {
        HStack {
            switch state {
            case .available, .failed:
                Button("Skip This Version") { controller.skipVersion() }
                Spacer()
                Button("Later") { controller.later() }
                    .keyboardShortcut(.cancelAction)
                Button(isFailed(state) ? String(localized: "Try Again") : String(localized: "Update")) { controller.update() }
                    .keyboardShortcut(.defaultAction)
            case .downloading, .verifying:
                Spacer()
                Button("Cancel") { controller.cancelDownload() }
                    .keyboardShortcut(.cancelAction)
            case .installing:
                Spacer()
            case .moveToApplications:
                Spacer()
                Button("Show in Finder") { controller.showDownloadedImage() }
                Button("OK") { controller.later() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func isFailed(_ state: UpdateController.WindowState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
