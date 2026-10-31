import Foundation

/// Пределы записи скачиваемого файла: ответ сервера не может занять на диске больше, чем объявлено облаком.
enum DownloadLimits {
    /// Записано больше объявленного размера файла. Размер неизвестен (0, экспорт документов) — не ограничивается
    /// (экспорт у Google ограничен 10 МБ на стороне сервера).
    static func exceeds(written: Int64, expectedSize: Int64, isExport: Bool) -> Bool {
        !isExport && expectedSize > 0 && written > expectedSize
    }
}
