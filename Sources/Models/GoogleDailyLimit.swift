import Foundation

/// Направление передачи: у Google отдельные лимиты на скачивание и на отправку.
enum TransferDirection: String, Sendable, Hashable, CaseIterable {
    case download, upload
}

/// Переданные байты за скользящие 24 часа: корзины по минуте (минута Unix → байты).
struct TrafficLedger: Sendable, Equatable {
    static let windowMinutes: Int64 = 24 * 60
    private(set) var buckets: [Int64: Int64] = [:]

    static func minute(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 / 60) }

    /// Первая минута, которая ещё входит в окно.
    static func windowStart(_ now: Date) -> Int64 { minute(now) - windowMinutes + 1 }

    init(buckets: [Int64: Int64] = [:]) { self.buckets = buckets }

    mutating func add(_ bytes: Int64, at date: Date) {
        buckets[Self.minute(date), default: 0] += bytes
    }

    func used(at now: Date) -> Int64 {
        let start = Self.windowStart(now)
        return buckets.reduce(0) { $1.key >= start ? $0 + $1.value : $0 }
    }

    mutating func prune(at now: Date) {
        let start = Self.windowStart(now)
        buckets = buckets.filter { $0.key >= start }
    }

    /// Когда за окно останется не больше `target` байт: старые минуты по очереди выходят из окна.
    func date(whenUsedAtMost target: Int64, now: Date) -> Date {
        var used = used(at: now)
        guard used > target else { return now }
        let start = Self.windowStart(now)
        for (minute, bytes) in buckets.filter({ $0.key >= start }).sorted(by: { $0.key < $1.key }) {
            used -= bytes
            if used <= target { return Date(timeIntervalSince1970: TimeInterval((minute + Self.windowMinutes) * 60)) }
        }
        return now.addingTimeInterval(TimeInterval(Self.windowMinutes * 60))
    }
}

/// Какие задачи облака сейчас можно запускать с учётом своего лимита.
struct TransferBudget: Sendable {
    let provider: CloudProviderKind
    /// Остаток бюджета с учётом того, что ещё допишут идущие задачи.
    let remaining: Int64
    /// Свой лимит целиком: файл больше него качается частями по дням.
    let limit: Int64
    /// В остатке есть хотя бы порция: можно начинать файлы больше дневного лимита и продолжать начатые.
    let allowsOversized: Bool
}

/// Задачи облака, ждущие лимита: сколько их и сколько нужно бюджета, чтобы продолжить хоть одну.
struct LimitWaitingStats: Sendable, Equatable {
    var count = 0
    /// Наименьший остаток среди файлов, которые помещаются в дневной лимит.
    var smallestFitting: Int64?
    /// Есть файлы больше всего дневного лимита или начатые: им для продолжения хватает порции.
    var hasOversized = false
}

/// Состояние лимита одного облака и направления — для карточки статуса, менеджеров и уведомлений.
struct TransferLimitStatus: Sendable, Equatable, Identifiable {
    let provider: CloudProviderKind
    let direction: TransferDirection
    /// Передано за последние 24 часа.
    var used: Int64 = 0
    /// Свой лимит; nil — выключен или его нет (Dropbox).
    var limit: Int64?
    /// Облако само ответило, что лимит исчерпан.
    var serverBlocked = false
    /// Задач, ждущих лимита.
    var waitingCount = 0
    /// Когда продолжим: при своём лимите — оценка по счётчику, при ответе облака — следующая проверка.
    var resumeAt: Date?

    var id: String { "\(provider.rawValue).\(direction.rawValue)" }

    var fraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return Double(used) / Double(limit)
    }

    /// Передача этого облака и направления остановлена лимитом.
    var isReached: Bool { serverBlocked || (limit != nil && waitingCount > 0) }

    /// Порог предупреждения по своему счётчику: 95 или 80 (%), nil — ниже.
    var warningPercent: Int? {
        guard !isReached, let fraction else { return nil }
        if fraction >= 0.95 { return 95 }
        if fraction >= 0.8 { return 80 }
        return nil
    }
}

/// Лимит облака для одного направления: свой бюджет за скользящие 24 часа (только Google)
/// и остановка по ответу облака о лимите с пробным запросом раз в час.
///
/// Счётчик учитывает фактически переданные байты (включая повторы и докачку) и пишется
/// в SQLite пачками — не чаще раза в 5 секунд или 16 МБ.
struct TransferLimiter: Sendable {
    let provider: CloudProviderKind
    let direction: TransferDirection
    private(set) var ledger: TrafficLedger
    private var unflushed: [Int64: Int64] = [:]
    private var unflushedBytes: Int64 = 0
    private var lastFlush: TimeInterval = 0
    /// Облако сообщило о лимите: следующий пробный запрос (nil — облако не ограничено).
    private(set) var nextProbe: Date?
    /// Идущая пробная задача: первые полученные (или принятые сервером) байты снимают остановку.
    var probeTaskId: String?
    #if DEBUG
    /// Debug → Simulate: добавка к счётчику для проверки предупреждений (в базу не пишется).
    var debugExtraUsed: Int64 = 0
    #endif

    static let probeInterval: TimeInterval = 3600
    private static let flushBytes: Int64 = 16 * 1_048_576
    private static let flushSeconds: TimeInterval = 5

    init(provider: CloudProviderKind, direction: TransferDirection, db: DatabaseManager) {
        self.provider = provider
        self.direction = direction
        let now = Date()
        ledger = TrafficLedger(buckets: db.trafficBuckets(provider: provider, direction: direction,
                                                          sinceMinute: TrafficLedger.windowStart(now)))
        nextProbe = AppSettings.limitProbeDate(provider, direction)
    }

    // MARK: Свой бюджет

    /// Свой лимит за 24 часа; nil — выключен или его нет.
    var budget: Int64? { AppSettings.transferLimitBytes(provider, direction) }

    func used(at now: Date = Date()) -> Int64 {
        #if DEBUG
        return ledger.used(at: now) + debugExtraUsed
        #else
        return ledger.used(at: now)
        #endif
    }

    /// Порция, с которой продолжается файл больше дневного лимита: без неё он запускался бы
    /// и тут же останавливался, как только из окна выходит очередная минута.
    var resumeChunk: Int64 { max(1, min(1_000_000_000, (budget ?? 0) / 20)) }

    /// Свой лимит исчерпан: идущие задачи останавливаются.
    func isExhausted(at now: Date = Date()) -> Bool {
        guard let budget else { return false }
        return used(at: now) >= budget
    }

    /// Можно ли запускать задачи облака. `reserved` — сколько ещё допишут идущие задачи.
    func gate(reserved: Int64, now: Date = Date()) -> Gate {
        if nextProbe != nil { return .closed }
        guard let budget else { return .open }
        let remaining = budget - used(at: now) - reserved
        guard remaining > 0 else { return .closed }
        return .budget(TransferBudget(provider: provider, remaining: remaining, limit: budget,
                                      allowsOversized: remaining >= resumeChunk))
    }

    enum Gate {
        case open
        case budget(TransferBudget)
        case closed
    }

    /// Сколько бюджета нужно, чтобы продолжить хотя бы одну ждущую задачу.
    func neededToResume(_ stats: LimitWaitingStats) -> Int64? {
        let candidates = [stats.smallestFitting, stats.hasOversized ? resumeChunk : nil].compactMap { $0 }
        return candidates.min().map { max(1, $0) }
    }

    /// Оценка, когда бюджета хватит ждущим задачам (старые минуты выйдут из окна).
    func resumeEstimate(_ stats: LimitWaitingStats, reserved: Int64, now: Date = Date()) -> Date? {
        guard let budget, stats.count > 0, let needed = neededToResume(stats) else { return nil }
        #if DEBUG
        let target = budget - reserved - needed - debugExtraUsed
        #else
        let target = budget - reserved - needed
        #endif
        return ledger.date(whenUsedAtMost: max(0, target), now: now)
    }

    func status(_ stats: LimitWaitingStats, reserved: Int64, now: Date = Date()) -> TransferLimitStatus {
        TransferLimitStatus(provider: provider, direction: direction, used: used(at: now), limit: budget,
                            serverBlocked: nextProbe != nil, waitingCount: stats.count,
                            resumeAt: nextProbe ?? resumeEstimate(stats, reserved: reserved, now: now))
    }

    // MARK: Счётчик

    mutating func count(_ bytes: Int64, db: DatabaseManager, now: Date = Date()) {
        guard bytes > 0 else { return }
        ledger.add(bytes, at: now)
        unflushed[TrafficLedger.minute(now), default: 0] += bytes
        unflushedBytes += bytes
        if unflushedBytes >= Self.flushBytes || now.timeIntervalSinceReferenceDate - lastFlush >= Self.flushSeconds {
            flush(db: db, now: now)
        }
    }

    mutating func flush(db: DatabaseManager, now: Date = Date()) {
        lastFlush = now.timeIntervalSinceReferenceDate
        guard !unflushed.isEmpty else { return }
        db.addTraffic(provider: provider, direction: direction, buckets: unflushed)
        unflushed.removeAll()
        unflushedBytes = 0
    }

    /// Минуты старше 24 часов больше не нужны ни в памяти, ни в базе.
    mutating func prune(db: DatabaseManager, now: Date = Date()) {
        ledger.prune(at: now)
        db.pruneTraffic(beforeMinute: TrafficLedger.windowStart(now))
    }

    // MARK: Остановка по ответу облака

    var isServerBlocked: Bool { nextProbe != nil }
    var probeDue: Bool { nextProbe.map { $0 <= Date() } ?? false }

    /// Облако ответило «лимит исчерпан»: новых запросов нет, пробный — через час.
    mutating func block(now: Date = Date()) {
        probeTaskId = nil
        setNextProbe(now.addingTimeInterval(Self.probeInterval))
    }

    /// Пробный запрос прошёл: облако снова принимает запросы.
    mutating func unblock() {
        probeTaskId = nil
        setNextProbe(nil)
    }

    /// «Попробовать сейчас»: пробный запрос без ожидания часа.
    mutating func probeNow() {
        guard nextProbe != nil, probeTaskId == nil else { return }
        setNextProbe(Date())
    }

    /// Запущена пробная задача; если она зависнет, следующая проба — через час.
    mutating func beginProbe(_ id: String, now: Date = Date()) {
        probeTaskId = id
        setNextProbe(now.addingTimeInterval(Self.probeInterval))
    }

    private mutating func setNextProbe(_ date: Date?) {
        nextProbe = date
        AppSettings.setLimitProbeDate(date, provider, direction)
    }

    // MARK: Тексты

    /// Ждёт своего лимита (строка задачи в «Ожидают»).
    func budgetMessage(resumeAt: Date?) -> String {
        let name = provider.displayName
        let limit = Format.diskBytes(budget ?? 0)
        guard let resumeAt else {
            return direction == .download
                ? String(localized: "\(name) download limit reached (\(limit) per 24 hours)")
                : String(localized: "\(name) upload limit reached (\(limit) per 24 hours)")
        }
        let time = Self.time(resumeAt)
        return direction == .download
            ? String(localized: "\(name) download limit reached (\(limit) per 24 hours) — resumes around \(time)")
            : String(localized: "\(name) upload limit reached (\(limit) per 24 hours) — resumes around \(time)")
    }

    /// Облако ответило «лимит исчерпан» (строка задачи в «Ожидают»).
    func serverMessage() -> String {
        let name = provider.displayName
        let time = Self.time(nextProbe ?? Date().addingTimeInterval(Self.probeInterval))
        return direction == .download
            ? String(localized: "\(name) reported its download limit was reached — next check at \(time)")
            : String(localized: "\(name) reported its upload limit was reached — next check at \(time)")
    }

    /// Время в часовом поясе Mac («09:40»); дальше суток — с датой.
    static func time(_ date: Date) -> String {
        date.timeIntervalSinceNow > 20 * 3600
            ? date.formatted(date: .abbreviated, time: .shortened)
            : date.formatted(date: .omitted, time: .shortened)
    }
}
