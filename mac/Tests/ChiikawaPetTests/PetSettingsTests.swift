import Foundation
import Testing
@testable import ChiikawaPet

struct PetSettingsTests {
    @Test @MainActor func smallerPetIsVisibleByDefault() throws {
        let suiteName = "PetSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = UsageStore(usageFetching: UsageClient(), preferences: preferences)

        #expect(store.petScale == 0.65)
        #expect(store.isPetVisible)
    }

    @Test(arguments: [0.4, 0.85, 1.2]) @MainActor
    func sizeAndHiddenStateSurviveReconstruction(scale: Double) throws {
        let suiteName = "PetSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = UsageStore(usageFetching: UsageClient(), preferences: preferences)
        store.setPetScale(scale)
        store.isPetVisible = false

        let reopenedPreferences = try #require(UserDefaults(suiteName: suiteName))
        let restored = UsageStore(usageFetching: UsageClient(), preferences: reopenedPreferences)
        #expect(restored.petScale == scale)
        #expect(!restored.isPetVisible)

        restored.setPetScale(UsageStore.defaultPetScale)
        let reset = UsageStore(usageFetching: UsageClient(), preferences: reopenedPreferences)
        #expect(reset.petScale == 0.65)
        #expect(!reset.isPetVisible)
    }

    @Test(arguments: [-1.0, 0.0, 0.399, 1.201, 2.0, Double.nan, Double.infinity, -Double.infinity]) @MainActor
    func invalidSavedSizeRecoversDefault(scale: Double) throws {
        let suiteName = "PetSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(scale, forKey: "petScale")
        let store = UsageStore(usageFetching: UsageClient(), preferences: preferences)

        #expect(store.petScale == 0.65)
    }

    @Test @MainActor func sizeClampsBoundsAndRejectsNonfiniteChanges() throws {
        let suiteName = "PetSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = UsageStore(usageFetching: UsageClient(), preferences: preferences)

        store.setPetScale(-1)
        #expect(store.petScale == 0.4)
        #expect(preferences.double(forKey: "petScale") == 0.4)
        store.setPetScale(2)
        #expect(store.petScale == 1.2)
        #expect(preferences.double(forKey: "petScale") == 1.2)
        store.setPetScale(0.85)
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            store.setPetScale(invalid)
            #expect(store.petScale == 0.85)
            #expect(preferences.double(forKey: "petScale") == 0.85)
            let restored = UsageStore(usageFetching: UsageClient(), preferences: preferences)
            #expect(restored.petScale == 0.85)
        }
    }

    @Test @MainActor func hidingAndShowingPreserveCharacterAndSize() throws {
        let suiteName = "PetSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = UsageStore(usageFetching: UsageClient(), preferences: preferences)
        store.selectedCharacter = .usagi
        store.setPetScale(0.75)

        for visible in [false, true, false, true] {
            store.isPetVisible = visible
            #expect(store.selectedCharacter == .usagi)
            #expect(store.petScale == 0.75)
            let restored = UsageStore(usageFetching: UsageClient(), preferences: preferences)
            #expect(restored.isPetVisible == visible)
            #expect(restored.selectedCharacter == .usagi)
            #expect(restored.petScale == 0.75)
        }
    }

    @Test @MainActor func menuBarShowsEachServicesLowestCurrentQuota() async throws {
        let suiteName = "PetSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let usageFetching = PetSettingsFixtureUsage(
            claudeJSON: #"{"five_hour":{"utilization":10},"seven_day":{"utilization":75}}"#,
            codexJSON: #"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000},"secondary_window":{"used_percent":65.5,"limit_window_seconds":604800}}}"#
        )
        let store = UsageStore(usageFetching: usageFetching, preferences: preferences)
        await store.refresh()

        #expect(store.menuBarTitle == "Claude 25% · Codex 34%")
        #expect(store.remainingPercent == 25)
        #expect(store.menuBarPresentation.claudePrimary == 90)
        #expect(store.menuBarPresentation.claudeSecondary == 25)
        #expect(store.menuBarPresentation.codex == 34.5)
    }

    @Test @MainActor func menuBarDistinguishesFullFromExhaustedQuota() async throws {
        let suiteName = "PetSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let usageFetching = PetSettingsFixtureUsage(
            claudeJSON: #"{"five_hour":{"utilization":0}}"#,
            codexJSON: #"{"rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":18000}}}"#
        )
        let store = UsageStore(usageFetching: usageFetching, preferences: preferences)
        await store.refresh()
        #expect(store.menuBarTitle == "Claude 100% · Codex 0%")
        #expect(store.remainingPercent == 0)

        await usageFetching.setJSON(#"{"five_hour":{"utilization":100}}"#, for: .claude)
        await usageFetching.setJSON(#"{"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000}}}"#, for: .codex)
        await store.refresh()
        #expect(store.menuBarTitle == "Claude 0% · Codex 100%")
        #expect(store.remainingPercent == 0)
    }

    @Test @MainActor func menuBarDoesNotInventPercentagesForAbsentMeasurements() async throws {
        let suiteName = "PetSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let usageFetching = PetSettingsFixtureUsage(
            claudeJSON: #"{"five_hour":{"utilization":null},"seven_day":null}"#,
            codexJSON: #"{"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000}}}"#
        )
        let store = UsageStore(usageFetching: usageFetching, preferences: preferences)
        #expect(store.menuBarTitle == "Claude — · Codex —")
        #expect(store.remainingPercent == nil)
        await store.refresh()
        #expect(store.menuBarTitle == "Claude — · Codex 100%")
        #expect(store.remainingPercent == 100)

        await usageFetching.setJSON(#"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#, for: .codex)
        await store.refresh()
        #expect(store.menuBarTitle == "Claude — · Codex —")
        #expect(store.remainingPercent == nil)
    }

    @Test @MainActor func menuBarHidesStaleReadingUntilCurrentUsageRecovers() async throws {
        let suiteName = "PetSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let usageFetching = PetSettingsFixtureUsage(
            claudeJSON: #"{"five_hour":{"utilization":10},"seven_day":{"utilization":91}}"#,
            codexJSON: #"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}}}"#
        )
        let store = UsageStore(usageFetching: usageFetching, preferences: preferences)
        await store.refresh()
        #expect(store.menuBarTitle == "Claude 9% · Codex 80%")
        let original = try #require(store.providers.first { $0.provider == .claude }?.reading)

        await usageFetching.fail([.claude])
        await store.refresh()
        let stale = try #require(store.providers.first { $0.provider == .claude })
        #expect(stale.reading?.windows == original.windows)
        #expect(stale.reading?.fetchedAt == original.fetchedAt)
        #expect(stale.error != nil)
        #expect(store.menuBarTitle == "Claude — · Codex 80%")
        #expect(store.remainingPercent == 80)
        #expect(store.menuBarPresentation.claudePrimary == nil)
        #expect(store.menuBarPresentation.claudeSecondary == nil)
        #expect(store.menuBarPresentation.codex == 80)

        await usageFetching.setJSON(#"{"five_hour":{"utilization":12.4},"seven_day":{"utilization":25.2}}"#, for: .claude)
        await usageFetching.fail([])
        await store.refresh()
        #expect(store.menuBarTitle == "Claude 74% · Codex 80%")
        let recovered = try #require(store.providers.first { $0.provider == .claude })
        #expect(recovered.error == nil)
        let remaining = try #require(recovered.reading?.remainingPercent)
        #expect(abs(remaining - 74.8) < 0.0001)
    }
}

private actor PetSettingsFixtureUsage: UsageFetching {
    private var claudeUsage: Data
    private var codexUsage: Data
    private var failures: [UsageProvider] = []

    init(claudeJSON: String, codexJSON: String) {
        claudeUsage = Data(claudeJSON.utf8)
        codexUsage = Data(codexJSON.utf8)
    }

    func setJSON(_ json: String, for provider: UsageProvider) {
        switch provider {
        case .claude: claudeUsage = Data(json.utf8)
        case .codex: codexUsage = Data(json.utf8)
        }
    }

    func fail(_ providers: [UsageProvider]) { failures = providers }

    func cached(_ account: UsageAccount) async -> UsageReading? { nil }

    func fetch(_ account: UsageAccount, allowKeychainPrompt: Bool) async throws -> UsageReading {
        let provider = account.provider
        if failures.contains(provider) { throw UsageFailure.http(503) }
        let now = Date()
        switch provider {
        case .claude: return try UsageClient.decodeClaude(claudeUsage, now: now)
        case .codex: return try UsageClient.decodeCodex(codexUsage, now: now)
        }
    }
}
