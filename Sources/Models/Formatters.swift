import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    /// Размер посчитанной папки — как в Finder (десятичные единицы).
    static func folderBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Размеры дисков — десятичные единицы, как в Finder, не больше одного знака после запятой:
    /// «49,8 ГБ», «4 ТБ». Системный форматтер единиц в текущей локали.
    static func diskBytes(_ value: Int64) -> String {
        let units: [(UnitInformationStorage, Double)] = [
            (.terabytes, 1e12), (.gigabytes, 1e9), (.megabytes, 1e6), (.kilobytes, 1e3),
        ]
        let (unit, divisor) = units.first { Double(abs(value)) >= $0.1 * 0.9995 } ?? (.bytes, 1)
        return Measurement(value: Double(value) / divisor, unit: unit).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        // Размер — системным форматтером в текущей локали, «/с» — из каталога строк.
        let perSecond = ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .binary)
        return String(localized: "\(perSecond)/s")
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
