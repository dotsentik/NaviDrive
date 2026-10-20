import SwiftUI

/// Компактная строка диска в боковой панели: иконка, название, заполненность, индикаторы загрузок.
struct DiskSidebarRow: View {
    @Environment(AppModel.self) private var model
    let volume: DiskVolume

    var body: some View {
        Button { model.openVolume(volume) } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(volume.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        indicators
                    }
                    ProgressView(value: volume.usedFraction)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(barColor)
                    // Цифры не обрезаются многоточием: при нехватке ширины шрифт уменьшается до 80%.
                    Text(volume.freeLine)
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(volume.usageLine)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Подсветка, когда к строке ведёт сообщение карточки статуса.
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(model.highlightedVolume == volume.id ? 0.22 : 0))
                .padding(.horizontal, -4)
                .animation(.easeInOut(duration: 0.3), value: model.highlightedVolume)
        }
        .help(volume.details)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Open in Finder")
        .contextMenu {
            Button("Show in Finder") { model.openVolume(volume) }
            Button("Set as Default Folder…") { model.chooseDefaultFolder(on: volume) }
            if !volume.isInternal {
                Divider()
                Button("Eject") { model.eject(volume) }
            }
        }
    }

    @ViewBuilder
    private var indicators: some View {
        if volume.lacksSpace {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help(shortageText)
        }
        if volume.isDownloadingHere {
            Image(systemName: "arrow.down")
                .foregroundStyle(Color.accentColor)
                .help(downloadingText)
        }
    }

    /// До 80% — обычный цвет, 80–90% — оранжевый, выше 90% — красный.
    private var barColor: Color? {
        switch volume.usedFraction {
        case ..<0.8: nil
        case ..<0.9: .orange
        default: .red
        }
    }

    private var downloadingText: String {
        String(localized: "Downloading here: \(Format.diskBytes(volume.usage.remainingBytes)) remaining")
    }

    private var shortageText: String {
        String(localized: "Not enough space: \(Format.diskBytes(volume.usage.remainingBytes)) needed (+ \(Format.diskBytes(DownloadScheduler.spaceMargin)) reserve), \(Format.diskBytes(volume.freeBytes)) free")
    }

    private var accessibilityText: String {
        var parts = [volume.isInternal ? String(localized: "Internal disk \(volume.name)") : String(localized: "External disk \(volume.name)"),
                     volume.freeLine, volume.usageLine]
        if volume.isDownloadingHere { parts.append(downloadingText) }
        if volume.lacksSpace { parts.append(shortageText) }
        return parts.joined(separator: ". ")
    }
}
