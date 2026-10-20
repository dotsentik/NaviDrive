import SwiftUI

/// Маленький (14 pt) круговой индикатор передачи у имени файла, как в Finder при копировании.
/// Скачивание отличается стрелкой вниз внутри круга.
struct TransferIndicatorView: View, Equatable {
    let indicator: TransferIndicator

    private let size: CGFloat = 14
    private let lineWidth: CGFloat = 1.6

    var body: some View {
        content
            .frame(width: size, height: size)
            .help(indicator.help)
            .accessibilityElement()
            .accessibilityLabel(indicator.help)
            .animation(.easeInOut(duration: 0.25), value: indicator.phase)
            .animation(.linear(duration: 0.45), value: indicator.fraction)
    }

    @ViewBuilder
    private var content: some View {
        switch indicator.phase {
        case .queued:
            ring(progress: 0, tint: .secondary)
        case .active:
            ring(progress: indicator.fraction ?? 0, tint: .accentColor)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
        case .waiting:
            Image(systemName: "clock.fill")
                .resizable()
                .padding(1)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .resizable()
                .foregroundStyle(.red)
        }
    }

    /// Серая дорожка, заполняющаяся по часовой стрелке; у скачивания — стрелка вниз внутри.
    private func ring(progress: Double, tint: Color) -> some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.35), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if !indicator.isUpload {
                Image(systemName: "arrow.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            }
        }
        .padding(lineWidth / 2)
    }
}
