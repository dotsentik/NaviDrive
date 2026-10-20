import Foundation

/// AIMD-регулятор числа потоков (additive increase / multiplicative decrease).
///
/// - Старт с 4 потоков (не выше предела пользователя).
/// - Раз в 15 с: если не было ответов о лимитах Google, все слоты заняты и суммарная скорость выросла
///   хотя бы на 5% относительно замера перед прошлым увеличением — +1 поток.
/// - Если скорость не выросла — канал загружен, потоки не добавляются. После 8 таких проверок (2 мин)
///   выполняется одна пробная попытка +1; если и она не дала прироста, лишний поток убирается.
/// - 429 / rateLimitExceeded — лимит сразу делится пополам (минимум 1). Повторные ответы о лимите
///   в течение 5 с считаются одним событием, иначе 16 потоков, получивших 429 одновременно,
///   обрушили бы лимит до 1.
struct AdaptiveConcurrency: Sendable {
    static let initialLimit = 4
    static let evaluationInterval: Duration = .seconds(15)
    static let evaluationWindowSeconds = 15
    static let growthThreshold = 1.05
    static let holdsBeforeReprobe = 8
    static let decreaseCooldown: TimeInterval = 5

    private(set) var limit: Int
    private(set) var userLimit: Int
    private(set) var status: String

    /// Скорость, измеренная непосредственно перед последним увеличением лимита.
    private var baselineSpeed: Double?
    private var holdCount = 0
    private var isReprobe = false
    private var rateLimitedSinceEvaluation = false
    private var lastDecrease: TimeInterval = -.infinity

    init(userLimit: Int) {
        self.userLimit = max(1, userLimit)
        self.limit = min(Self.initialLimit, self.userLimit)
        self.status = String(localized: "Start: \(limit)")
    }

    /// Пользователь изменил предел. Идущие загрузки не обрываются — просто не выдаются новые слоты.
    mutating func setUserLimit(_ value: Int) {
        userLimit = max(1, value)
        if limit > userLimit {
            limit = userLimit
            status = String(localized: "Capped at limit \(userLimit)")
        }
    }

    /// Новый разгон (после восстановления сети или включения после паузы).
    mutating func reset(reason: String) {
        limit = min(Self.initialLimit, userLimit)
        baselineSpeed = nil
        holdCount = 0
        isReprobe = false
        rateLimitedSinceEvaluation = false
        status = String(localized: "\(reason): starting at \(limit)")
    }

    /// Ответ 429 / rateLimitExceeded. Возвращает true, если лимит действительно уменьшен.
    @discardableResult
    mutating func rateLimitHit(now: TimeInterval) -> Bool {
        rateLimitedSinceEvaluation = true
        baselineSpeed = nil
        holdCount = 0
        isReprobe = false
        guard now - lastDecrease >= Self.decreaseCooldown else { return false }
        lastDecrease = now
        limit = max(1, limit / 2)
        status = String(localized: "Google rate limit: reduced to \(limit)")
        return true
    }

    /// Периодическая оценка (раз в 15 с).
    /// - Parameters:
    ///   - speed: средняя суммарная скорость за последние 15 с, байт/с.
    ///   - saturated: все слоты заняты и в очереди есть задачи (иначе прибавка потоков ничего не даст).
    mutating func evaluate(speed: Double, saturated: Bool) {
        if rateLimitedSinceEvaluation {
            rateLimitedSinceEvaluation = false
            status = String(localized: "Google rate limit: ramp-up paused (\(limit))")
            return
        }
        guard saturated, speed > 0 else {
            status = String(localized: "Not enough tasks to ramp up (\(limit))")
            return
        }

        guard let baseline = baselineSpeed else {
            // Первое измерение после старта/сброса — пробуем добавить поток.
            if limit < userLimit {
                baselineSpeed = speed
                limit += 1
                status = isReprobe ? String(localized: "Re-probe: +1 → \(limit)") : String(localized: "Ramp-up: +1 → \(limit)")
            } else {
                status = String(localized: "Reached limit \(userLimit)")
            }
            return
        }

        if speed >= baseline * Self.growthThreshold {
            isReprobe = false
            holdCount = 0
            if limit < userLimit {
                baselineSpeed = speed
                limit += 1
                status = String(localized: "Speed is increasing: +1 → \(limit)")
            } else {
                baselineSpeed = speed
                status = String(localized: "Reached limit \(userLimit)")
            }
            return
        }

        // Скорость не выросла на 5% — канал загружен.
        if isReprobe {
            // Пробный поток не дал прироста — возвращаемся на прежний уровень.
            isReprobe = false
            limit = max(1, limit - 1)
        }
        holdCount += 1
        status = String(localized: "Link saturated: holding at \(limit)")
        if holdCount >= Self.holdsBeforeReprobe, limit < userLimit {
            holdCount = 0
            baselineSpeed = nil
            isReprobe = true
        }
    }
}

/// Счётчик суммарной скорости по посекундным корзинам.
struct ThroughputMeter: Sendable {
    private var buckets: [Int64: Int64] = [:]

    mutating func add(_ bytes: Int64, at time: TimeInterval) {
        let second = Int64(time)
        buckets[second, default: 0] += bytes
        if buckets.count > 90 {
            buckets = buckets.filter { $0.key > second - 60 }
        }
    }

    /// Средняя скорость за последние `window` полностью завершённых секунд.
    func bytesPerSecond(window: Int, now: TimeInterval) -> Double {
        let current = Int64(now)
        let from = current - Int64(window)
        let total = buckets.reduce(Int64(0)) { sum, entry in
            entry.key >= from && entry.key < current ? sum + entry.value : sum
        }
        return Double(total) / Double(max(1, window))
    }

    mutating func reset() { buckets.removeAll() }
}
