import Foundation
import Testing
@testable import ChiikawaPet

struct UsagePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func invalidOrExpiredNormalizedSnapshotsNeverCountAsCurrentQuota() throws {
        let empty = UsageReading(provider: .claude, windows: [], fetchedAt: now)
        #expect(!empty.isCurrent(at: now))
        let expiredWindow = try QuotaWindow(title: "Session", usedPercent: 100, resetsAt: now.addingTimeInterval(-1))
        let expired = UsageReading(provider: .claude, windows: [expiredWindow], fetchedAt: now)
        #expect(!expired.isCurrent(at: now))
        let json = """
        {"provider":"Claude","windows":[{"title":"Session","remainingPercent":101,"id":"session"}],
        "fetchedAt":\(now.timeIntervalSinceReferenceDate),"source":"live","extras":[]}
        """
        let decoded = try JSONDecoder().decode(UsageReading.self, from: Data(json.utf8))
        #expect(!decoded.isCurrent(at: now))
        for invalidDuration in [0.0, -1, .infinity, .nan] {
            #expect(throws: UsageFailure.self) {
                try QuotaWindow(title: "Session", usedPercent: 10, resetsAt: nil, durationSeconds: invalidDuration)
            }
        }
    }

    @Test func fractionalThresholdsHaveSeparateAlertIdentities() throws {
        var policy = UsageAlertPolicy()
        let healthy = try reading(remaining: 20, offset: -30)
        _ = policy.evaluate(accountID: "a", reading: healthy, now: now, thresholds: [9.9, 9.1], paceEnabled: false)
        let low = try reading(remaining: 9, offset: 0)
        let events = policy.evaluate(accountID: "a", reading: low, now: now, thresholds: [9.9, 9.1], paceEnabled: false)
        #expect(events.count == 2)
        #expect(Set(events.map(\.id)).count == 2)
    }

    @Test func pacingUsesWholeWindowAndDoesNotInventExactExhaustionAtReset() throws {
        let healthy = try window(remaining: 75)
        let healthyProjection = try #require(UsagePace.projection(for: healthy, measuredAt: now, now: now))
        #expect(healthyProjection.remainingAtReset == 50)
        #expect(healthyProjection.severity == 0)
        #expect(healthyProjection.exhaustsAt == nil)
        let tight = try window(remaining: 52.5)
        #expect(UsagePace.projection(for: tight, measuredAt: now, now: now)?.severity == 1)
        let boundary = try window(remaining: 55)
        #expect(UsagePace.projection(for: boundary, measuredAt: now, now: now)?.severity == 0)
        let exact = try window(remaining: 50)
        let exactProjection = try #require(UsagePace.projection(for: exact, measuredAt: now, now: now))
        #expect(exactProjection.remainingAtReset == 0)
        #expect(exactProjection.severity == 2)
        #expect(exactProjection.exhaustsAt == nil)
        let fast = try window(remaining: 25)
        let fastProjection = try #require(UsagePace.projection(for: fast, measuredAt: now, now: now))
        #expect(fastProjection.remainingAtReset == -50)
        #expect(fastProjection.exhaustsAt == now.addingTimeInterval(3_000))
    }

    @Test func pacingRefusesInsufficientOrStaleWindowEvidence() throws {
        let missingReset = try QuotaWindow(title: "Session", usedPercent: 10, resetsAt: nil, durationSeconds: 18_000)
        let missingDuration = try QuotaWindow(title: "Session", usedPercent: 10, resetsAt: now.addingTimeInterval(9_000))
        let justStarted = try QuotaWindow(title: "Session", usedPercent: 10, resetsAt: now.addingTimeInterval(17_950), durationSeconds: 18_000)
        let unused = try window(remaining: 100)
        for candidate in [missingReset, missingDuration, justStarted, unused] {
            #expect(UsagePace.projection(for: candidate, measuredAt: now, now: now) == nil)
        }
        let candidate = try window(remaining: 25)
        #expect(UsagePace.projection(for: candidate, measuredAt: now.addingTimeInterval(-901), now: now) == nil)
        #expect(UsagePace.projection(for: candidate, measuredAt: now.addingTimeInterval(1), now: now) == nil)
    }

    @Test func thresholdAlertsBaselineDeduplicateAndRearmAfterRecovery() throws {
        var policy = UsageAlertPolicy()
        let lowAtLaunch = try reading(remaining: 4, offset: -120)
        #expect(policy.evaluate(accountID: "a", reading: lowAtLaunch, now: now, thresholds: [10, 5], paceEnabled: false).isEmpty)
        let recovered = try reading(remaining: 20, offset: -90)
        #expect(policy.evaluate(accountID: "a", reading: recovered, now: now, thresholds: [10, 5], paceEnabled: false).isEmpty)
        let lowAgain = try reading(remaining: 4, offset: -60)
        let events = policy.evaluate(accountID: "a", reading: lowAgain, now: now, thresholds: [10, 5, 10, .nan], paceEnabled: false)
        #expect(events.count == 2)
        #expect(Set(events.map(\.id)).count == 2)
        #expect(policy.evaluate(accountID: "a", reading: lowAgain, now: now, thresholds: [10, 5], paceEnabled: false).isEmpty)
        let stillLow = try reading(remaining: 3, offset: -30)
        #expect(policy.evaluate(accountID: "a", reading: stillLow, now: now, thresholds: [10, 5], paceEnabled: false).isEmpty)
    }

    @Test func staleDiskAndCooldownReadingsCannotAlertOrPoisonBaseline() throws {
        var policy = UsageAlertPolicy()
        let healthy = try reading(remaining: 20, offset: -200)
        _ = policy.evaluate(accountID: "a", reading: healthy, now: now, thresholds: [10], paceEnabled: false)
        var disk = try reading(remaining: 4, offset: -90)
        disk.source = .diskCache
        var blocked = try reading(remaining: 4, offset: -80)
        blocked.source = .swapCache
        blocked.retryAt = now.addingTimeInterval(60)
        let stale = try reading(remaining: 4, offset: -901)
        for candidate in [disk, blocked, stale] {
            #expect(policy.evaluate(accountID: "a", reading: candidate, now: now, thresholds: [10], paceEnabled: false).isEmpty)
        }
        let liveLow = try reading(remaining: 9, offset: -10)
        #expect(policy.evaluate(accountID: "a", reading: liveLow, now: now, thresholds: [10], paceEnabled: false).count == 1)
    }

    @Test func accountAndResetBoundariesDoNotReuseAnotherBaseline() throws {
        var policy = UsageAlertPolicy()
        let healthy = try reading(remaining: 20, offset: -90)
        let low = try reading(remaining: 9, offset: -60)
        _ = policy.evaluate(accountID: "a", reading: healthy, now: now, thresholds: [10], paceEnabled: false)
        #expect(policy.evaluate(accountID: "b", reading: low, now: now, thresholds: [10], paceEnabled: false).isEmpty)
        #expect(policy.evaluate(accountID: "a", reading: low, now: now, thresholds: [10], paceEnabled: false).count == 1)
        let newReset = now.addingTimeInterval(18_000)
        let newLow = try reading(remaining: 4, offset: -30, reset: newReset)
        #expect(policy.evaluate(accountID: "a", reading: newLow, now: now, thresholds: [10], paceEnabled: false).isEmpty)
    }

    @Test func paceAlertsFireOnlyOnWorseningAndIgnoreThresholdsWhenDisabled() throws {
        var policy = UsageAlertPolicy()
        let healthy = try reading(remaining: 75, offset: -90)
        _ = policy.evaluate(accountID: "a", reading: healthy, now: now, thresholds: [], paceEnabled: true)
        let tight = try reading(remaining: 52, offset: -60)
        #expect(policy.evaluate(accountID: "a", reading: tight, now: now, thresholds: [], paceEnabled: true).count == 1)
        let worse = try reading(remaining: 25, offset: -30)
        #expect(policy.evaluate(accountID: "a", reading: worse, now: now, thresholds: [], paceEnabled: true).count == 1)
        let unchanged = try reading(remaining: 20, offset: 0)
        #expect(policy.evaluate(accountID: "a", reading: unchanged, now: now, thresholds: [], paceEnabled: true).isEmpty)
    }

    private func window(remaining: Double) throws -> QuotaWindow {
        try QuotaWindow(title: "Session", usedPercent: 100 - remaining,
                        resetsAt: now.addingTimeInterval(9_000), id: "session", durationSeconds: 18_000)
    }

    private func reading(remaining: Double, offset: TimeInterval, reset: Date? = nil) throws -> UsageReading {
        let quota = try QuotaWindow(title: "Session", usedPercent: 100 - remaining,
                                    resetsAt: reset ?? now.addingTimeInterval(9_000), id: "session", durationSeconds: 18_000)
        return UsageReading(provider: .claude, windows: [quota], fetchedAt: now.addingTimeInterval(offset))
    }
}
