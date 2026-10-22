import CryptoKit
import Foundation
import Testing
@testable import ChiikawaPet

struct UsageSnapshotCacheTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let fingerprint = String(repeating: "a", count: 64)
    private let account = UsageAccount(
        id: "synthetic-account", provider: .claude, label: "Configured label",
        directory: "/synthetic/credential-home", expectedEmail: "verified@example.invalid",
        expectedOrganizationID: "organization-a", expectedAccountID: "account-a",
        keychainService: "synthetic-keychain-service"
    )

    @Test func roundTripPreservesNormalizedSampleAndPrivatePermissions() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var original = try reading()
        original.accountLabel = "verified@example.invalid"
        original.plan = "Max"
        original.authSource = "Claude Code keychain"
        original.retryAt = now.addingTimeInterval(600)
        original.extras = [UsageExtra(id: "credits", title: "Credits", amount: 12.5, unit: "USD", limit: 30)]
        try fixture.cache.save(original, account: account, fingerprint: fingerprint, now: now)
        let loaded = try #require(fixture.cache.load(account: account, fingerprint: fingerprint, now: now))
        #expect(loaded.provider == original.provider)
        #expect(loaded.windows == original.windows)
        #expect(loaded.extras == original.extras)
        #expect(loaded.fetchedAt == original.fetchedAt)
        #expect(loaded.source == .diskCache)
        #expect(!loaded.isCurrent(at: now))
        #expect(loaded.accountID == account.id)
        #expect(loaded.credentialFingerprint == fingerprint)
        #expect(loaded.accountLabel == "verified@example.invalid")
        #expect(loaded.plan == "Max")
        #expect(loaded.authSource == "Claude Code keychain")
        #expect(loaded.retryAt == nil)
        let file = try fixture.onlyFile()
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(file.deletingPathExtension().lastPathComponent.count == 64)
        let serialized = try String(contentsOf: file, encoding: .utf8)
        #expect(!serialized.contains(account.id))
        #expect(!serialized.contains(account.directory!))
        #expect(!serialized.contains(account.keychainService!))
        #expect(!serialized.contains("retryAt"))
        #expect(!serialized.contains("credentialFingerprint"))
    }

    @Test func resetWindowsAreRemovedWithoutRenewingMeasurementTime() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try reading()
        try fixture.cache.save(original, account: account, fingerprint: fingerprint, now: now)
        let resetTime = now.addingTimeInterval(3_600)
        let loaded = try #require(fixture.cache.load(account: account, fingerprint: fingerprint, now: resetTime))
        #expect(loaded.windows.map(\.id) == ["weekly"])
        #expect(loaded.fetchedAt == original.fetchedAt)
        #expect(fixture.cache.load(account: account, fingerprint: fingerprint,
                                   now: now.addingTimeInterval(604_800)) == nil)
        let expired = try QuotaWindow(title: "Session", usedPercent: 20, resetsAt: now, id: "session")
        let valid = try QuotaWindow(title: "Weekly", usedPercent: 30, resetsAt: nil, id: "weekly")
        let mixed = try reading(windows: [expired, valid])
        try fixture.cache.save(mixed, account: account, fingerprint: fingerprint, now: now)
        #expect(fixture.cache.load(account: account, fingerprint: fingerprint, now: now)?.windows == [valid])
        let allExpired = try reading(windows: [expired])
        expectRejected(allExpired, fixture: fixture)
    }

    @Test func maximumAgeIsBoundedByOriginalFetchNotSaveTime() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try reading(fetchedAt: now)
        try fixture.cache.save(original, account: account, fingerprint: fingerprint,
                               now: now.addingTimeInterval(86_399))
        #expect(fixture.cache.load(account: account, fingerprint: fingerprint,
                                   now: now.addingTimeInterval(86_400))?.fetchedAt == now)
        #expect(fixture.cache.load(account: account, fingerprint: fingerprint,
                                   now: now.addingTimeInterval(86_400.001)) == nil)
        #expect(fixture.cache.load(account: account, fingerprint: fingerprint,
                                   now: now.addingTimeInterval(-0.001)) == nil)
        let future = try reading(fetchedAt: now.addingTimeInterval(0.001))
        expectRejected(future, fixture: fixture)
        let old = try reading(fetchedAt: now.addingTimeInterval(-86_400.001))
        expectRejected(old, fixture: fixture)
    }

    @Test func fingerprintAndSourceMustMatchVerifiedAccount() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try reading()
        try fixture.cache.save(original, account: account, fingerprint: fingerprint, now: now)
        for invalid in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64),
                        String(repeating: "g", count: 64), fingerprint + "\n"] {
            #expect(fixture.cache.load(account: account, fingerprint: invalid, now: now) == nil)
            #expect(throws: (any Error).self) {
                try fixture.cache.save(original, account: account, fingerprint: invalid, now: now)
            }
        }
        #expect(fixture.cache.load(account: account, fingerprint: String(repeating: "b", count: 64), now: now) == nil)
        var wrong = original
        wrong.accountID = nil
        expectRejected(wrong, fixture: fixture)
        wrong.accountID = "another-account"
        expectRejected(wrong, fixture: fixture)
        wrong.accountID = account.id
        wrong.credentialFingerprint = String(repeating: "b", count: 64)
        expectRejected(wrong, fixture: fixture)
        wrong.credentialFingerprint = fingerprint
        wrong.source = .diskCache
        expectRejected(wrong, fixture: fixture)
        let wrongProvider = UsageAccount(id: account.id, provider: .codex, label: account.label)
        #expect(throws: (any Error).self) {
            try fixture.cache.save(original, account: wrongProvider, fingerprint: fingerprint, now: now)
        }
        var swap = original
        swap.source = .swapCache
        try fixture.cache.save(swap, account: account, fingerprint: fingerprint, now: now)
        #expect(fixture.cache.load(account: account, fingerprint: fingerprint, now: now)?.source == .diskCache)
    }

    @Test func everyConfigurationFieldIsBoundEvenIfFileIsCopied() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try reading()
        try fixture.cache.save(original, account: account, fingerprint: fingerprint, now: now)
        let source = try fixture.onlyFile()
        var configurations: [UsageAccount] = []
        var changed = account
        changed.directory = "/synthetic/different-home"; configurations.append(changed)
        changed = account; changed.expectedEmail = "other@example.invalid"; configurations.append(changed)
        changed = account; changed.expectedOrganizationID = "organization-b"; configurations.append(changed)
        changed = account; changed.expectedAccountID = "account-b"; configurations.append(changed)
        changed = account; changed.keychainService = "other-service"; configurations.append(changed)
        changed = account; changed.label = "Renamed"; configurations.append(changed)
        configurations.append(UsageAccount(id: "other-id", provider: .claude, label: account.label))
        configurations.append(UsageAccount(id: account.id, provider: .codex, label: account.label))
        for configuration in configurations {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(configuration)
            let digest = SHA256.hash(data: encoded)
            let name = digest.map { String(format: "%02x", $0) }.joined() + ".json"
            let copied = fixture.directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: copied)
            #expect(fixture.cache.load(account: configuration, fingerprint: fingerprint, now: now) == nil)
        }
    }

    @Test func corruptAndMalformedEnvelopesFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try reading()
        try fixture.cache.save(original, account: account, fingerprint: fingerprint, now: now)
        let file = try fixture.onlyFile()
        let data = try Data(contentsOf: file)
        let valid = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var mutations: [[String: Any]] = []
        var changed = valid
        changed["schema"] = 2; mutations.append(changed)
        changed = valid; changed["binding"] = String(repeating: "b", count: 64); mutations.append(changed)
        changed = valid; changed["fingerprint"] = String(repeating: "b", count: 64); mutations.append(changed)
        changed = valid; changed["windows"] = []; mutations.append(changed)
        changed = valid; changed["fetchedAt"] = now.timeIntervalSinceReferenceDate + 1; mutations.append(changed)
        changed = valid; changed.removeValue(forKey: "extras"); mutations.append(changed)
        var windows = try #require(valid["windows"] as? [[String: Any]])
        windows[0]["remainingPercent"] = 101
        changed = valid; changed["windows"] = windows; mutations.append(changed)
        windows[0]["remainingPercent"] = -1
        changed = valid; changed["windows"] = windows; mutations.append(changed)
        windows[0]["remainingPercent"] = "NaN"
        changed = valid; changed["windows"] = windows; mutations.append(changed)
        for mutation in mutations {
            let malformed = try JSONSerialization.data(withJSONObject: mutation)
            try malformed.write(to: file)
            #expect(fixture.cache.load(account: account, fingerprint: fingerprint, now: now) == nil)
        }
        try Data("{broken".utf8).write(to: file)
        #expect(fixture.cache.load(account: account, fingerprint: fingerprint, now: now) == nil)
    }

    @Test func invalidAndNonfiniteMeasurementsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        for number in ["NaN", "Infinity", "-Infinity"] {
            let json = "{\"id\":\"session\",\"title\":\"Session\",\"remainingPercent\":\"\(number)\"}"
            let window = try decoder.decode(QuotaWindow.self, from: Data(json.utf8))
            let invalid = try reading(windows: [window])
            expectRejected(invalid, fixture: fixture)
        }
        for duration in ["0", "-1", "\"NaN\"", "\"Infinity\""] {
            let json = "{\"id\":\"session\",\"title\":\"Session\",\"remainingPercent\":80,\"durationSeconds\":\(duration)}"
            let window = try decoder.decode(QuotaWindow.self, from: Data(json.utf8))
            let invalid = try reading(windows: [window])
            expectRejected(invalid, fixture: fixture)
        }
        for reset in [Double.nan, Double.infinity, -Double.infinity, -1] {
            let window = try QuotaWindow(title: "Session", usedPercent: 20,
                                         resetsAt: Date(timeIntervalSince1970: reset), id: "session")
            let invalid = try reading(windows: [window])
            expectRejected(invalid, fixture: fixture)
        }
        for timestamp in [Double.nan, Double.infinity, -Double.infinity] {
            let invalid = try reading(fetchedAt: Date(timeIntervalSince1970: timestamp))
            expectRejected(invalid, fixture: fixture)
        }
        for amount in [-1, Double.nan, Double.infinity] {
            var invalid = try reading()
            invalid.extras = [UsageExtra(id: "credits", title: "Credits", amount: amount, unit: "USD")]
            expectRejected(invalid, fixture: fixture)
            invalid.extras = [UsageExtra(id: "credits", title: "Credits", amount: 1, unit: "USD", limit: amount)]
            expectRejected(invalid, fixture: fixture)
        }
        let window = try QuotaWindow(title: "Session", usedPercent: 20, resetsAt: nil, id: "session")
        let duplicate = try reading(windows: [window, window])
        expectRejected(duplicate, fixture: fixture)
        let emptyID = try QuotaWindow(title: "Session", usedPercent: 20, resetsAt: nil, id: " ")
        let empty = try reading(windows: [emptyID])
        expectRejected(empty, fixture: fixture)
    }

    @Test func metadataPathsAndUnexpectedAuthSourcesAreNotPersisted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var original = try reading()
        original.accountLabel = "/synthetic/private/account"
        original.plan = "Bearer synthetic-secret"
        original.authSource = "/synthetic/private/auth.json"
        try fixture.cache.save(original, account: account, fingerprint: fingerprint, now: now)
        let loaded = try #require(fixture.cache.load(account: account, fingerprint: fingerprint, now: now))
        #expect(loaded.accountLabel == nil)
        #expect(loaded.plan == nil)
        #expect(loaded.authSource == nil)
        let file = try fixture.onlyFile()
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("synthetic/private"))
        #expect(!text.contains("synthetic-secret"))
    }

    @Test func insecureOrSymlinkedFilesAndDirectoriesAreNotRead() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try reading()
        try fixture.cache.save(original, account: account, fingerprint: fingerprint, now: now)
        let file = try fixture.onlyFile()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(fixture.cache.load(account: account, fingerprint: fingerprint, now: now) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
        #expect(fixture.cache.load(account: account, fingerprint: fingerprint, now: now) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        let target = fixture.root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(fixture.cache.load(account: account, fingerprint: fingerprint, now: now) == nil)
        expectRejected(original, fixture: fixture)
    }

    private func reading(windows: [QuotaWindow]? = nil, fetchedAt: Date? = nil) throws -> UsageReading {
        let defaults = try [
            QuotaWindow(title: "Session", usedPercent: 26.75, resetsAt: now.addingTimeInterval(3_600),
                        id: "session", durationSeconds: 18_000),
            QuotaWindow(title: "Weekly", usedPercent: 40, resetsAt: now.addingTimeInterval(604_800),
                        id: "weekly", durationSeconds: 604_800)
        ]
        var reading = UsageReading(provider: .claude, windows: windows ?? defaults,
                                   fetchedAt: fetchedAt ?? now.addingTimeInterval(-120))
        reading.accountID = account.id
        reading.credentialFingerprint = fingerprint
        return reading
    }

    private func expectRejected(_ reading: UsageReading, fixture: Fixture) {
        #expect(throws: (any Error).self) {
            try fixture.cache.save(reading, account: account, fingerprint: fingerprint, now: now)
        }
    }

    private struct Fixture {
        let root: URL
        let directory: URL
        let cache: UsageSnapshotCache

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            directory = root.appendingPathComponent("snapshots", isDirectory: true)
            cache = UsageSnapshotCache(directory: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }

        func onlyFile() throws -> URL {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            #expect(files.count == 1)
            return try #require(files.first)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
