import AppKit
import SwiftUI

/// Ширины колонок строки показателей «Менеджера загрузок» и «Отправки». Колонки фиксированные:
/// смена длины чисел («20 MB/s» → «46,7 MB/s») не сдвигает соседей и левый край «Общего прогресса».
/// Ширины подобраны по самым длинным реалистичным значениям в обоих языках (шрифт .headline/.caption2):
enum TransferStatsLayout {
    static let spacing: CGFloat = 24
    /// «999,9 MB/s» (75 pt), «Подключение…» (107 pt).
    static let speedWidth: CGFloat = 110
    /// «Активно потоков: 16 из 16» (179 pt), «мелкие 16 · крупные 16 · экспорт 16» (186 pt),
    /// «Канал загружен: держим 8» (136 pt); подписи длиннее обрезаются.
    static let threadsWidth: CGFloat = 190
    /// «Ожидание интернета…» (157 pt).
    static let networkWidth: CGFloat = 160
    /// «1000,0 GB of 1000 GB» (147 pt).
    static let googleWidth: CGFloat = 150
}

extension View {
    /// Живое число в строке показателей: цифры одной ширины, одна строка, смена значения без анимации.
    func liveValue(_ value: some Equatable) -> some View {
        monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .animation(nil, value: value)
    }
}

/// Ячейка «подпись + значение» фиксированной ширины.
struct TransferStatCell: View {
    let title: LocalizedStringKey
    let value: String
    var color: Color = .primary
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.headline).foregroundStyle(color).liveValue(value)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Сегментированный переключатель с равными сегментами и моноширинными цифрами: смена счётчиков
/// («Active (9)» → «Active (12)») не сдвигает соседние вкладки. SwiftUI-`Picker(.segmented)` на macOS
/// подгоняет ширину сегментов под текст, поэтому здесь — `NSSegmentedControl` с `.fillEqually`.
struct EqualSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    let accessibilityLabel: String
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: [], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(SegmentTarget.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel(accessibilityLabel)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.onSelect = { index in
            guard options.indices.contains(index) else { return }
            selection = options[index]
        }
        if control.segmentCount != options.count { control.segmentCount = options.count }
        for (index, option) in options.enumerated() where control.label(forSegment: index) != title(option) {
            control.setLabel(title(option), forSegment: index)
        }
        let selected = options.firstIndex(of: selection) ?? -1
        if control.selectedSegment != selected { control.selectedSegment = selected }
    }

    func makeCoordinator() -> SegmentTarget { SegmentTarget() }
}

/// Цель действия `NSSegmentedControl` (не generic: `@objc`-метод).
@MainActor
final class SegmentTarget: NSObject {
    var onSelect: (Int) -> Void = { _ in }

    @objc func changed(_ sender: NSSegmentedControl) { onSelect(sender.selectedSegment) }
}
