import Foundation

struct UsageProjection: Sendable, Equatable {
    let remainingAtReset: Double
    let exhaustsAt: Date?
    let severity: Int
}

enum UsagePace {
    static func projection(for window: QuotaWindow, measuredAt: Date, now: Date) -> UsageProjection? {
        guard let reset = window.resetsAt, let duration = window.durationSeconds,
              duration.isFinite, duration > 0, reset > now,
              window.remainingPercent.isFinite, (0...100).contains(window.remainingPercent) else { return nil }
        let age = now.timeIntervalSince(measuredAt)
        guard age >= 0, age <= 15 * 60 else { return nil }
        let start = reset.addingTimeInterval(-duration)
        let elapsed = measuredAt.timeIntervalSince(start)
        let used = 100 - window.remainingPercent
        guard used > 0, elapsed >= max(60, duration * 0.01), elapsed <= duration else { return nil }
        let usedPerSecond = used / elapsed
        let projectedRemaining = 100 - usedPerSecond * duration
        guard projectedRemaining.isFinite else { return nil }
        let exhaustion = measuredAt.addingTimeInterval(window.remainingPercent / usedPerSecond)
        let severity = window.remainingPercent == 0 || projectedRemaining <= 0 ? 2 : projectedRemaining < 10 ? 1 : 0
        return UsageProjection(remainingAtReset: projectedRemaining,
                               exhaustsAt: exhaustion < reset ? exhaustion : nil,
                               severity: severity)
    }
}

struct UsageAlertEvent: Identifiable, Sendable {
    let id: String
    let metricTitle: String
    let message: String
}

struct UsageAlertPolicy: Sendable {
    private struct Key: Hashable, Sendable {
        let account: String
        let metric: String
    }
    private struct Baseline: Sendable {
        let remaining: Double
        let period: Date?
        let measuredAt: Date
        let paceSeverity: Int
    }
    private var baselines: [Key: Baseline] = [:]

    mutating func evaluate(accountID: String, reading: UsageReading, now: Date,
                           thresholds: [Double], paceEnabled: Bool) -> [UsageAlertEvent] {
        guard reading.isCurrent(at: now), reading.retryAt == nil else { return [] }
        var events: [UsageAlertEvent] = []
        let validThresholds = Set(thresholds.filter { $0.isFinite && $0 > 0 && $0 <= 100 }).sorted(by: >)
        for window in reading.windows {
            guard window.remainingPercent.isFinite, (0...100).contains(window.remainingPercent) else { continue }
            let key = Key(account: accountID, metric: window.id)
            let projection = UsagePace.projection(for: window, measuredAt: reading.fetchedAt, now: now)
            let severity = projection?.severity ?? 0
            let next = Baseline(remaining: window.remainingPercent, period: window.resetsAt,
                                measuredAt: reading.fetchedAt, paceSeverity: severity)
            guard let previous = baselines[key], previous.period == window.resetsAt else {
                baselines[key] = next
                continue
            }
            guard reading.fetchedAt > previous.measuredAt else { continue }
            baselines[key] = next
            for threshold in validThresholds where previous.remaining > threshold && window.remainingPercent <= threshold {
                let label = threshold.formatted(.number.precision(.fractionLength(0...2)))
                events.append(UsageAlertEvent(id: "\(accountID)/\(window.id)/\(reading.fetchedAt.timeIntervalSince1970)/\(threshold)",
                                              metricTitle: window.title,
                                              message: T("잔여량이 \(label)% 이하입니다.")))
            }
            if paceEnabled, severity > previous.paceSeverity {
                let message = severity == 2 ? T("이 속도면 초기화 전에 한도에 도달합니다.") : T("초기화 전 남을 여유가 적습니다.")
                events.append(UsageAlertEvent(id: "\(accountID)/\(window.id)/\(reading.fetchedAt.timeIntervalSince1970)/pace",
                                              metricTitle: window.title, message: message))
            }
        }
        return events
    }
}
