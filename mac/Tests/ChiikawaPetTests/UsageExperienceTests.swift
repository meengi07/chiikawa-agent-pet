import Foundation
import Testing
@testable import ChiikawaPet

struct UsageExperienceTests {
    @Test func invasiveFeaturesDefaultOffAndThresholdsMatchExistingMoods() {
        let settings = UsagePreferences()
        #expect(!settings.notifications && !settings.launchAtLogin && !settings.historyEnabled && !settings.discoverSavedAccounts)
        #expect(settings.shortcut == nil && settings.additionalAccounts.isEmpty)
        for remaining in [0.0, 10, 11, 29, 30, 59, 60, 94, 95, 100] {
            #expect(settings.mood(for: remaining) == PetMood.forRemaining(remaining))
        }
        #expect(settings.mood(for: nil) == .unknown)
    }

    @Test func malformedPersistedSettingsRecoverWithoutChangingLegacyPreferences() throws {
        let suite = "UsageExperienceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "petVisible")
        defaults.set("momonga", forKey: "petCharacter")
        defaults.set(Data("not JSON".utf8), forKey: UsagePreferences.storageKey)
        #expect(UsagePreferences.load(from: defaults) == UsagePreferences())
        #expect(defaults.bool(forKey: "petVisible") == false)
        #expect(defaults.string(forKey: "petCharacter") == "momonga")
        var malformed = UsagePreferences()
        malformed.thresholds = [100, 2]
        malformed.additionalAccounts = [UsageAccount(id: "relative", provider: .codex, label: "unsafe", directory: "relative/home")]
        malformed.pricingFile = "relative/pricing.json"
        defaults.set(try JSONEncoder().encode(malformed), forKey: UsagePreferences.storageKey)
        let recovered = UsagePreferences.load(from: defaults)
        #expect(recovered.thresholds == [10, 30, 60, 95])
        #expect(recovered.additionalAccounts.isEmpty && recovered.pricingFile == nil)
    }

    @Test @MainActor func controlsPersistAndLegacyPetSettingsArePreserved() throws {
        let suite = "UsageExperienceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.8, forKey: "petScale")
        defaults.set(false, forKey: "wanders")
        defaults.set(true, forKey: "automaticUpdates")
        let fetching = ExperienceFetching()
        let store = UsageStore(usageFetching: fetching, preferences: defaults)
        store.settings.moodAccountID = "Codex"
        store.settings.moodMetricID = "weekly"
        store.settings.thresholds = [5, 20, 50, 90]
        store.settings.paceMood = true
        store.settings.menuPins = [MenuPin(accountID: UsageAccount.codex.id, metricID: "weekly")]
        store.settings.menuBars = true
        store.settings.menuCompact = true
        store.settings.countdown = true
        store.settings.showPace = true
        store.settings.notifications = true
        store.settings.paceNotifications = true
        store.settings.launchAtLogin = true
        store.settings.shortcut = RecordedShortcut(keyCode: 40, modifiers: 256, label: "⌘K")
        store.settings.hiddenAccountIDs = [UsageAccount.claude.id]
        store.settings.historyEnabled = true
        store.settings.pricingFile = "/synthetic/pricing.json"
        let restored = UsageStore(usageFetching: fetching, preferences: defaults)
        #expect(restored.settings == store.settings)
        #expect(restored.petScale == 0.8 && !restored.wanders && restored.automaticUpdates)
    }

    @Test @MainActor func duplicateProvidersRemainIsolatedAndHidingDoesNotChangeMood() async throws {
        let suite = "UsageExperienceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let second = UsageAccount(id: "codex-second", provider: .codex, label: "Second", directory: "/synthetic/second")
        let fetching = ExperienceFetching()
        await fetching.set(try reading(.claude, remaining: 90), for: UsageAccount.claude.id)
        await fetching.set(try reading(.codex, remaining: 70), for: UsageAccount.codex.id)
        await fetching.set(try reading(.codex, remaining: 5), for: second.id)
        let store = UsageStore(usageFetching: fetching, preferences: defaults)
        store.settings.additionalAccounts = [second]
        store.reloadAccounts()
        await store.refresh()
        #expect(Set(store.providers.map(\.id)).count == 3)
        #expect(store.providers.filter { $0.provider == .codex }.count == 2)
        #expect(store.moodCulprit?.display.id == second.id && store.mood == .crying)
        store.settings.hiddenAccountIDs = [second.id]
        #expect(store.visibleProviders.count == 2 && store.mood == .crying)
        store.settings.moodAccountID = UsageAccount.codex.id
        #expect(store.remainingPercent == 70 && store.mood == .happy)
        store.settings.moodMetricID = "missing"
        #expect(store.remainingPercent == nil && store.mood == .unknown)
        store.settings.menuPins = [MenuPin(accountID: second.id, metricID: "session"), MenuPin(accountID: UsageAccount.codex.id, metricID: "session")]
        #expect(store.menuBarPresentation.metrics.map(\.percent) == [5, 70])
        store.settings.menuPins.swapAt(0, 1)
        #expect(store.menuBarPresentation.metrics.map(\.percent) == [70, 5])
        store.settings.additionalAccounts = []
        store.reloadAccounts()
        #expect(!store.providers.contains { $0.id == second.id })
        #expect(store.menuBarPresentation.metrics.last?.percent == nil)
    }

    @Test @MainActor func diskSnapshotAndFailedReadingNeverDriveMoodOrExposeDiagnosticsSecrets() async throws {
        let suite = "UsageExperienceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fetching = ExperienceFetching()
        var snapshot = try reading(.claude, remaining: 0)
        snapshot.source = .diskCache
        snapshot.accountLabel = "private@example.invalid"
        snapshot.credentialFingerprint = "private-fingerprint"
        await fetching.setCache(snapshot, for: UsageAccount.claude.id)
        let store = UsageStore(usageFetching: fetching, preferences: defaults)
        await store.refresh()
        #expect(store.providers.first?.reading?.source == .diskCache)
        #expect(store.remainingPercent == nil && store.mood == .unknown)
        #expect(store.menuBarPresentation.claudePrimary == nil)
        let diagnostics = store.diagnosticText
        #expect(!diagnostics.contains("private@example.invalid") && !diagnostics.contains("private-fingerprint"))
        #expect(diagnostics.contains("diskCache") && diagnostics.contains("current=false"))
        await fetching.set(try reading(.claude, remaining: 0), for: UsageAccount.claude.id)
        await store.refresh()
        #expect(store.remainingPercent == 0 && store.mood == .crying)
        await fetching.clear(UsageAccount.claude.id)
        await store.refresh()
        #expect(store.providers.first?.reading?.remainingPercent == 0)
        #expect(store.remainingPercent == nil && store.menuBarPresentation.claudePrimary == nil)
        let counts = await fetching.cacheCounts
        #expect(counts[UsageAccount.claude.id] == 1)
    }

    @Test @MainActor func staleMeasurementsDoNotBecomeZeroAndCustomThresholdsAffectOnlyMood() async throws {
        let suite = "UsageExperienceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fetching = ExperienceFetching()
        await fetching.set(try reading(.claude, remaining: 25), for: UsageAccount.claude.id)
        await fetching.set(try reading(.codex, remaining: 0, measuredAt: Date().addingTimeInterval(-3600)), for: UsageAccount.codex.id)
        let store = UsageStore(usageFetching: fetching, preferences: defaults)
        await store.refresh()
        #expect(store.remainingPercent == 25 && store.mood == .sad)
        store.settings.thresholds = [2, 10, 20, 90]
        #expect(store.remainingPercent == 25 && store.mood == .happy)
        #expect(store.menuBarPresentation.codex == nil)
        #expect(store.providers.last?.reading?.remainingPercent == 0)
    }

    @Test @MainActor func changedAccountFailureDiscardsOldQuotaAndKeepsCooldown() async throws {
        let suite = "UsageExperienceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fetching = ExperienceFetching()
        await fetching.set(try reading(.claude, remaining: 88), for: UsageAccount.claude.id)
        let store = UsageStore(usageFetching: fetching, preferences: defaults)
        await store.refresh()
        #expect(store.providers.first?.reading?.remainingPercent == 88)
        let retry = Date().addingTimeInterval(300)
        await fetching.fail(.accountChanged(retry), for: UsageAccount.claude.id)
        await store.refresh()
        #expect(store.providers.first?.reading == nil)
        #expect(store.providers.first?.retryAt == retry)
        #expect(store.mood == .unknown && store.menuBarPresentation.claudePrimary == nil)
    }

    @Test func historyPeriodUsesLocalCalendarDaysAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 1)))
        let days = ["2026-10-03", "2026-10-04", "2026-11-01", "2026-11-02", "2026-11-03"].map {
            UsageHistoryDay(day: $0, inputTokens: 5, outputTokens: 3)
        }
        #expect(HistoryPeriod.today.days(from: days, now: now, calendar: calendar).map(\.day) == ["2026-11-02"])
        #expect(HistoryPeriod.yesterday.days(from: days, now: now, calendar: calendar).map(\.day) == ["2026-11-01"])
        #expect(HistoryPeriod.last30.days(from: days, now: now, calendar: calendar).map(\.day) == ["2026-10-04", "2026-11-01", "2026-11-02"])
    }


    @Test func untrustedErrorDescriptionsCannotLeakCredentialsOrPaths() {
        let error = NSError(domain: "remote", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bearer private-secret /private/account/auth.json"])
        let message = UsageStore.safeError(error)
        #expect(!message.contains("private-secret") && !message.contains("auth.json"))
    }

    @Test @MainActor func previewCannotRestoreOrChangeNativeRegistrationsOrTheirPreferences() throws {
        let suite = "UsageExperienceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = UsagePreferences()
        saved.notifications = true
        saved.launchAtLogin = true
        saved.shortcut = RecordedShortcut(keyCode: 40, modifiers: 256, label: "⌘K")
        let encoded = try JSONEncoder().encode(saved)
        defaults.set(encoded, forKey: UsagePreferences.storageKey)
        let store = UsageStore(usageFetching: ExperienceFetching(), previewPercent: 55, preferences: defaults)
        store.configureSystemFeatures(
            openPanel: { Issue.record("Preview installed a native open callback") },
            togglePanel: { Issue.record("Preview installed a native toggle callback") })
        store.setNotifications(false)
        store.setLaunchAtLogin(false)
        store.setShortcut(nil)
        store.resetExperience()
        #expect(store.settings == saved)
        #expect(defaults.data(forKey: UsagePreferences.storageKey) == encoded)
        #expect(!store.systemFeatures.notificationsEnabled)
        #expect(store.systemFeatures.openPanel == nil)
        #expect(store.systemFeatures.togglePanel == nil)
        #expect(store.systemError == nil)
    }

    @Test func normalInstanceLeaseIgnoresUnleasedPreviewsAndRecordsLockOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockFile = directory.appendingPathComponent("instance.lock")
        let preview = AppInstanceLease(lockFile: lockFile)
        #expect(preview.ownerProcessIdentifier == nil)
        var normal: AppInstanceLease? = AppInstanceLease(lockFile: lockFile)
        #expect(try normal?.acquire() == true)
        let duplicate = AppInstanceLease(lockFile: lockFile)
        #expect(try duplicate.acquire() == false)
        #expect(duplicate.ownerProcessIdentifier == ProcessInfo.processInfo.processIdentifier)
        normal = nil
        #expect(try duplicate.acquire())
    }

    @Test func alertBaselinesSeparateSuccessfulAccountSwitchesButNotVerifiedTokenRotation() throws {
        let now = Date()
        var alerts = AccountUsageAlerts()
        var first = try reading(.claude, remaining: 80, measuredAt: now.addingTimeInterval(-4))
        first.accountIdentity = "verified-A"
        first.credentialFingerprint = "token-A1"
        #expect(alerts.evaluate(accountID: "claude-default", reading: first, now: now, thresholds: [10, 30], paceEnabled: false).isEmpty)
        var rotated = try reading(.claude, remaining: 20, measuredAt: now.addingTimeInterval(-3))
        rotated.accountIdentity = "verified-A"
        rotated.credentialFingerprint = "token-A2"
        #expect(alerts.evaluate(accountID: "claude-default", reading: rotated, now: now, thresholds: [10, 30], paceEnabled: false).count == 1)
        var switched = try reading(.claude, remaining: 5, measuredAt: now.addingTimeInterval(-2))
        switched.accountIdentity = "verified-B"
        switched.credentialFingerprint = "token-B"
        #expect(alerts.evaluate(accountID: "claude-default", reading: switched, now: now, thresholds: [10, 30], paceEnabled: false).isEmpty)
        alerts.invalidate(accountID: "claude-default")
        var returning = try reading(.claude, remaining: 0, measuredAt: now.addingTimeInterval(-1))
        returning.accountIdentity = "verified-A"
        #expect(alerts.evaluate(accountID: "claude-default", reading: returning, now: now, thresholds: [10, 30], paceEnabled: false).isEmpty)
    }

    @Test func unknownAlertIdentityUsesFingerprintOrSuppressesAlertsRatherThanSharingBaseline() throws {
        let now = Date()
        var alerts = AccountUsageAlerts()
        var first = try reading(.codex, remaining: 80, measuredAt: now.addingTimeInterval(-4))
        first.credentialFingerprint = "unknown-token-A"
        #expect(alerts.evaluate(accountID: "codex-default", reading: first, now: now, thresholds: [30], paceEnabled: false).isEmpty)
        var changed = try reading(.codex, remaining: 20, measuredAt: now.addingTimeInterval(-3))
        changed.credentialFingerprint = "unknown-token-B"
        #expect(alerts.evaluate(accountID: "codex-default", reading: changed, now: now, thresholds: [30], paceEnabled: false).isEmpty)
        let unidentified = try reading(.codex, remaining: 0, measuredAt: now.addingTimeInterval(-2))
        #expect(alerts.evaluate(accountID: "codex-default", reading: unidentified, now: now, thresholds: [30], paceEnabled: false).isEmpty)
        var identifiedAgain = try reading(.codex, remaining: 0, measuredAt: now.addingTimeInterval(-1))
        identifiedAgain.credentialFingerprint = "unknown-token-B"
        #expect(alerts.evaluate(accountID: "codex-default", reading: identifiedAgain, now: now, thresholds: [30], paceEnabled: false).isEmpty)
    }

    private func reading(_ provider: UsageProvider, remaining: Double, measuredAt: Date = .now) throws -> UsageReading {
        let window = try QuotaWindow(title: "Session", usedPercent: 100 - remaining, resetsAt: nil, id: "session")
        return UsageReading(provider: provider, windows: [window], fetchedAt: measuredAt)
    }
}

private actor ExperienceFetching: UsageFetching {
    var readings: [String: UsageReading] = [:]
    var snapshots: [String: UsageReading] = [:]
    var cacheCounts: [String: Int] = [:]
    var failures: [String: UsageFailure] = [:]
    func set(_ reading: UsageReading, for id: String) { readings[id] = reading }
    func clear(_ id: String) { readings[id] = nil }
    func setCache(_ reading: UsageReading, for id: String) { snapshots[id] = reading }
    func fail(_ failure: UsageFailure, for id: String) { failures[id] = failure }
    func fetch(_ account: UsageAccount, allowKeychainPrompt: Bool) async throws -> UsageReading {
        if let failure = failures[account.id] { throw failure }
        guard let reading = readings[account.id] else { throw UsageFailure.loginRequired(account.provider) }
        return reading
    }
    func cached(_ account: UsageAccount) async -> UsageReading? {
        cacheCounts[account.id, default: 0] += 1
        return snapshots[account.id]
    }
}
