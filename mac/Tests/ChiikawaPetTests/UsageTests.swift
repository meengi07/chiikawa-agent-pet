import Foundation
import Testing
@testable import ChiikawaPet

struct UsageTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func remainingConversionAndMinimum() throws {
        let weekly = try QuotaWindow(title: "주간", usedPercent: 91, resetsAt: nil)
        let session = try QuotaWindow(title: "5시간", usedPercent: 23.4, resetsAt: nil)
        #expect(abs(session.remainingPercent - 76.6) < 0.0001)
        let reading = UsageReading(provider: .claude, windows: [weekly, session], fetchedAt: now)
        #expect(reading.remainingPercent == 9)
        let empty = UsageReading(provider: .claude, windows: [], fetchedAt: now)
        #expect(empty.remainingPercent == nil)
        #expect(try QuotaWindow(title: "", usedPercent: 0, resetsAt: nil).remainingPercent == 100)
        #expect(try QuotaWindow(title: "", usedPercent: 100, resetsAt: nil).remainingPercent == 0)
    }

    @Test(arguments: [-0.1, 100.1, Double.nan, Double.infinity, -Double.infinity])
    func invalidPercentages(used: Double) {
        #expect(throws: UsageFailure.self) {
            try QuotaWindow(title: "주간", usedPercent: used, resetsAt: nil)
        }
    }

    @Test func claudeMeasuredWindowsAndResets() throws {
        let data = Data(#"{"five_hour":{"utilization":25.5,"resets_at":"2026-05-22T18:00:00Z"},"seven_day":{"utilization":40,"resets_at":"2026-05-29T18:00:00.123Z"},"seven_day_sonnet":{"utilization":95}}"#.utf8)
        let reading = try UsageClient.decodeClaude(data, now: now)
        #expect(reading.windows.map(\.title) == ["5시간", "주간", "Sonnet 주간"])
        #expect(reading.windows[0].remainingPercent == 74.5)
        #expect(reading.remainingPercent == 5)
        #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_779_472_800))
        let fractionalReset = try #require(reading.windows[1].resetsAt)
        #expect(abs(fractionalReset.timeIntervalSince1970 - 1_780_077_600.123) < 0.001)
    }

    @Test func claudeAbsentMeasurementsAndScopedFallback() throws {
        let data = Data(#"{"five_hour":{"utilization":null},"seven_day":null,"seven_day_opus":{"utilization":90,"resets_at":null}}"#.utf8)
        let reading = try UsageClient.decodeClaude(data, now: now)
        #expect(reading.windows.map(\.title) == ["Opus 주간"])
        #expect(reading.remainingPercent == 10)
        #expect(reading.windows[0].resetsAt == nil)
    }

    @Test(arguments: ["{}", #"{"five_hour":null,"seven_day":null}"#, #"{"five_hour":{}}"#, #"{"five_hour":{"utilization":"25"}}"#, #"{"five_hour":{"utilization":25,"resets_at":"invalid"}}"#, #"{"five_hour":{"utilization":0},"seven_day_sonnet":{"utilization":101}}"#])
    func claudeRejectsMissingOrMalformedUsage(json: String) {
        #expect(throws: UsageFailure.self) { try UsageClient.decodeClaude(Data(json.utf8), now: now) }
    }

    private let swapCache = #"{"schemaVersion":2,"accounts":{"1":{"organizationUuid":"org-a","fetchedAt":1779999500,"lastGood":{"five_hour":{"pct":8.0,"resets_at":"2026-05-28T09:30:00.262955+00:00"},"seven_day":{"pct":57.0},"scoped":[{"name":"Fable","pct":44.0}]}},"2":{"organizationUuid":"org-b","fetchedAt":1779999900,"lastGood":{"five_hour":{"pct":1.0}}}}}"#

    @Test func swapCacheReadingForMatchingOrganization() throws {
        let reading = try #require(UsageClient.decodeSwapCache(Data(swapCache.utf8), organizationUUID: "org-a", now: now, maxAge: 900))
        #expect(reading.windows.map(\.title) == ["5시간", "주간", "Fable 주간"])
        #expect(reading.remainingPercent == 43)
        #expect(reading.fetchedAt == Date(timeIntervalSince1970: 1_779_999_500))
        let reset = try #require(reading.windows[0].resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_779_960_600.263) < 0.001)
    }

    @Test func swapCacheIgnoresStaleOrUnknownAccounts() {
        #expect(UsageClient.decodeSwapCache(Data(swapCache.utf8), organizationUUID: "org-a", now: now, maxAge: 300) == nil)
        #expect(UsageClient.decodeSwapCache(Data(swapCache.utf8), organizationUUID: "org-c", now: now, maxAge: 900) == nil)
        #expect(UsageClient.decodeSwapCache(Data(#"{"accounts":{}}"#.utf8), organizationUUID: "org-a", now: now, maxAge: 900) == nil)
    }

    @Test func codexWeeklyPrimaryAndReorderedWindows() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800,"reset_at":1785260773},"secondary_window":null}}"#.utf8)
        let weekly = try UsageClient.decodeCodex(data, now: now)
        #expect(weekly.windows.map(\.title) == ["주간"])
        #expect(weekly.remainingPercent == 99)
        #expect(weekly.windows[0].resetsAt == Date(timeIntervalSince1970: 1_785_260_773))
        let reordered = Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":604800},"secondary_window":{"used_percent":90,"limit_window_seconds":18000}}}"#.utf8)
        let reading = try UsageClient.decodeCodex(reordered, now: now)
        #expect(reading.windows.map(\.title) == ["주간", "5시간"])
        #expect(reading.remainingPercent == 10)
        #expect(PetMood.forRemaining(reading.remainingPercent) == .crying)
    }

    @Test func codexOptionalMeasurementsAndActualDuration() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":null},"secondary_window":{"used_percent":55,"limit_window_seconds":172800,"reset_at":null}}}"#.utf8)
        let reading = try UsageClient.decodeCodex(data, now: now)
        #expect(reading.windows.map(\.title) == ["2일 한도"])
        #expect(reading.remainingPercent == 45)
        #expect(reading.windows[0].resetsAt == nil)
        let missingDuration = Data(#"{"rate_limit":{"primary_window":{"used_percent":20}}}"#.utf8)
        let neutral = try UsageClient.decodeCodex(missingDuration, now: now)
        #expect(neutral.windows[0].title == "첫 번째 한도")
    }

    @Test(arguments: ["{}", #"{"rate_limit":null}"#, #"{"rate_limit":{}}"#, #"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#, #"{"rate_limit":{"primary_window":{"used_percent":null}}}"#, #"{"rate_limit":{"primary_window":{"used_percent":"10"}}}"#, #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":0}}}"#, #"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":-1}}}"#, #"{"rate_limit":{"primary_window":{"used_percent":-1},"secondary_window":{"used_percent":0}}}"#])
    func codexRejectsMissingOrMalformedUsage(json: String) {
        #expect(throws: UsageFailure.self) { try UsageClient.decodeCodex(Data(json.utf8), now: now) }
    }

    @Test func allMoodBoundaries() {
        #expect(PetMood.forRemaining(nil) == .unknown)
        #expect(PetMood.forRemaining(0) == .crying)
        #expect(PetMood.forRemaining(10) == .crying)
        #expect(PetMood.forRemaining(10.0001) == .sad)
        #expect(PetMood.forRemaining(29.999) == .sad)
        #expect(PetMood.forRemaining(30) == .uneasy)
        #expect(PetMood.forRemaining(59.999) == .uneasy)
        #expect(PetMood.forRemaining(60) == .happy)
        #expect(PetMood.forRemaining(94.999) == .happy)
        #expect(PetMood.forRemaining(95) == .delighted)
        #expect(PetMood.forRemaining(100) == .delighted)
    }

    @Test @MainActor func staleFailuresAreExcludedFromMoodAndRecoveryClearsErrors() async throws {
        let usageFetching = RefreshSequenceUsage()
        let store = UsageStore(usageFetching: usageFetching)
        await store.refresh()
        #expect(store.remainingPercent == 9)
        #expect(store.mood == .crying)
        let originalClaude = try #require(store.providers.first { $0.provider == .claude }?.reading)
        await usageFetching.fail([.claude])
        await store.refresh()
        let staleClaude = try #require(store.providers.first { $0.provider == .claude })
        #expect(staleClaude.reading?.windows == originalClaude.windows)
        #expect(staleClaude.reading?.fetchedAt == originalClaude.fetchedAt)
        #expect(staleClaude.error != nil)
        #expect(store.remainingPercent == 80)
        #expect(store.mood == .happy)
        await usageFetching.fail([.claude, .codex])
        await store.refresh()
        #expect(store.remainingPercent == nil)
        #expect(store.mood == .unknown)
        #expect(!store.isRefreshing)
        await usageFetching.fail([])
        await store.refresh()
        #expect(store.providers.allSatisfy { $0.error == nil })
        #expect(store.remainingPercent == 9)
        #expect(store.mood == .crying)
    }
}

private actor RefreshSequenceUsage: UsageFetching {
    private var failures: [UsageProvider] = []
    func fail(_ providers: [UsageProvider]) { failures = providers }
    func fetch(_ provider: UsageProvider, allowKeychainPrompt: Bool) async throws -> UsageReading {
        if failures.contains(provider) { throw UsageFailure.unauthorized(provider) }
        let usedPercent: Double = provider == .claude ? 91 : 20
        let window = try QuotaWindow(title: "주간", usedPercent: usedPercent, resetsAt: nil)
        return UsageReading(provider: provider, windows: [window], fetchedAt: Date(timeIntervalSince1970: 1_780_000_000))
    }
}
