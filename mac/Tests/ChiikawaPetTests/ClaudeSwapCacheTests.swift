import Foundation
import Testing
@testable import ChiikawaPet

@Suite(.serialized)
struct ClaudeSwapCacheTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func matchesEmailAndOrganizationInsteadOfNewestOrganizationRow() throws {
        let data = cache([
            row(email: "active@example.invalid", fetchedAt: 1_799_999_880),
            row(email: "other@example.invalid", fetchedAt: 1_799_999_940, usage: #"{"five_hour":{"pct":95}}"#)
        ])
        let decoded = try reading(data)
        let reading = try #require(decoded)
        #expect(reading.remainingPercent == 90)
        #expect(reading.fetchedAt == Date(timeIntervalSince1970: 1_799_999_880))
        #expect(try self.reading(data, email: "missing@example.invalid") == nil)
        #expect(try self.reading(data, organization: "different-org") == nil)
        #expect(try self.reading(cache([row(), row()])) == nil)
    }

    @Test func preservesScopedQuotasResetAndLastSuccessfulTimestamp() throws {
        let usage = #"{"five_hour":{"pct":10,"resets_at":"2027-01-15T09:00:00.123Z"},"seven_day":{"pct":40},"scoped":[{"name":"Fable","pct":95}]}"#
        let decoded = try reading(cache([row(usage: usage)]))
        let result = try #require(decoded)
        #expect(result.windows.map(\.remainingPercent) == [90, 60, 5])
        #expect(result.windows.map(\.title) == ["5시간", "주간", "Fable 주간"])
        #expect(result.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_003_600.123))
        #expect(result.fetchedAt == Date(timeIntervalSince1970: 1_799_999_880))
        #expect(result.remainingPercent == 5)
    }

    @Test(arguments: [0.0, 900, 3_600])
    func acceptsMeasurementsUpToFallbackCeiling(age: Double) throws {
        let decoded = try reading(cache([row(fetchedAt: 1_800_000_000 - age)]))
        let result = try #require(decoded)
        #expect(result.remainingPercent == 90)
        #expect(result.fetchedAt == Date(timeIntervalSince1970: 1_800_000_000 - age))
    }

    @Test(arguments: [-0.001, 3_600.001])
    func rejectsFutureAndExpiredMeasurementsEvenWithRecentAttempt(age: Double) throws {
        #expect(try reading(cache([row(fetchedAt: 1_800_000_000 - age)])) == nil)
    }

    @Test(arguments: [
        #"{"five_hour":{"pct":100,"resets_at":"2027-01-15T07:59:00Z"}}"#,
        #"{"five_hour":{"pct":100,"resets_at":"2027-01-15T08:00:00Z"}}"#,
        #"{"five_hour":{"pct":10},"scoped":[{"name":"Fable","pct":95,"resets_at":"2027-01-15T07:59:00Z"}]}"#,
        #"{"five_hour":{"pct":10,"resets_at":"invalid"}}"#,
        #"{"five_hour":{"pct":-1}}"#,
        #"{"scoped":[{"name":" ","pct":10}]}"#,
        #"{}"#
    ])
    func rejectsResetOrInvalidWindows(usage: String) throws {
        #expect(try reading(cache([row(usage: usage)])) == nil)
    }

    @Test func freshCacheUsesVerifiedIdentityAndAvoidsRepeatedNetworkRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let measured = Date().timeIntervalSince1970 - 120
        let original = cache([row(fetchedAt: measured)])
        try fixture.writeCache(original)
        let first = try await fixture.client.fetch(.claude, allowKeychainPrompt: false)
        let second = try await fixture.client.fetch(.claude, allowKeychainPrompt: false)
        #expect(first.remainingPercent == 90)
        #expect(second.remainingPercent == 90)
        #expect(second.fetchedAt == Date(timeIntervalSince1970: measured))
        #expect(first.source == .swapCache)
        #expect(second.accountID == UsageAccount.claude.id)
        #expect(second.accountLabel == "active@example.invalid")
        #expect(second.authSource == "Claude Code keychain")
        #expect(second.credentialFingerprint == UsageClient.fingerprint(Data("token-a".utf8)))
        #expect(SwapHTTP.state.paths == ["/api/oauth/profile"])
        #expect(try Data(contentsOf: fixture.cachePath) == original)
    }

    @Test func oldCacheRequiresUsageRequestAndOnlyFallsBackOn429() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeCache(cache([row(fetchedAt: Date().timeIntervalSince1970 - 1_200)]))
        SwapHTTP.state.configure(usage: Reply(status: 429, body: "{}"))
        let result = try await fixture.client.fetch(.claude, allowKeychainPrompt: false)
        #expect(result.remainingPercent == 90)
        #expect(result.source == .swapCache)
        #expect(result.retryAt.map { $0 > Date() } == true)
        #expect(SwapHTTP.state.paths == ["/api/oauth/profile", "/api/oauth/usage"])
        SwapHTTP.state.configure(usage: Reply(status: 500, body: "{}"))
        await expectHTTP(429) { try await fixture.client.fetch(.claude, allowKeychainPrompt: false) }
        #expect(SwapHTTP.state.paths.isEmpty)
        let independent = fixture.makeClient()
        await expectHTTP(500) { try await independent.fetch(.claude, allowKeychainPrompt: false) }
    }

    @Test func switchedTokenIsVerifiedAgainAndCannotInheritPreviousAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let measured = Date().timeIntervalSince1970 - 120
        try fixture.writeCache(cache([
            row(fetchedAt: measured),
            row(email: "other@example.invalid", fetchedAt: measured + 60, usage: #"{"five_hour":{"pct":95}}"#)
        ]))
        SwapHTTP.state.configure(profiles: ["Bearer token-b": Reply(status: 200, body: profile(email: "other@example.invalid", uuid: "other-user"))])
        let first = try await fixture.client.fetch(.claude, allowKeychainPrompt: false)
        try fixture.credentials.setToken("token-b")
        let switched = try await fixture.client.fetch(.claude, allowKeychainPrompt: false)
        #expect(first.remainingPercent == 90)
        #expect(switched.remainingPercent == 5)
        #expect(first.accountIdentity != switched.accountIdentity)
        #expect(first.credentialFingerprint != switched.credentialFingerprint)
        #expect(switched.accountLabel == "other@example.invalid")
        SwapHTTP.state.configure(profiles: ["Bearer token-c": Reply(status: 403, body: "{}")], usage: Reply(status: 429, body: "{}"))
        try fixture.credentials.setToken("token-c")
        do {
            _ = try await fixture.client.fetch(.claude, allowKeychainPrompt: false)
            Issue.record("Expected changed-account failure, not another account's quota")
        } catch UsageFailure.accountChanged(let until) {
            #expect(until.map { $0 > Date() } == true)
        }
        #expect(SwapHTTP.state.paths == ["/api/oauth/profile", "/api/oauth/usage"])
    }

    @Test func sameAccountRotationRevalidatesCacheThroughAuthoritativeCredentialSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let measured = Date().timeIntervalSince1970 - 120
        let original = cache([row(fetchedAt: measured)])
        try fixture.writeCache(original)
        let first = try await fixture.client.fetch(.claude, allowKeychainPrompt: false)
        try fixture.credentials.setToken("rotated-token")
        SwapHTTP.state.configure(profiles: ["Bearer rotated-token": Reply(status: 200, body: profile())])
        let rotated = try await fixture.client.fetch(.claude, allowKeychainPrompt: false)
        #expect(rotated.source == .swapCache)
        #expect(rotated.remainingPercent == first.remainingPercent)
        #expect(rotated.fetchedAt == first.fetchedAt)
        #expect(rotated.accountIdentity == first.accountIdentity)
        #expect(rotated.credentialFingerprint != first.credentialFingerprint)
        #expect(SwapHTTP.state.paths == ["/api/oauth/profile"])
        #expect(try Data(contentsOf: fixture.cachePath) == original)
    }

    @Test(arguments: [401, 403])
    func rejectedLiveUsageCannotFallBackToAnOldSwapSnapshot(status: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeCache(cache([row(fetchedAt: Date().timeIntervalSince1970 - 1_200)]))
        SwapHTTP.state.configure(usage: Reply(status: status, body: "{}"))
        do {
            _ = try await fixture.client.fetch(.claude, allowKeychainPrompt: false)
            Issue.record("Expected rejected live credentials, not cached quota")
        } catch UsageFailure.unauthorized(.claude) {}
        #expect(SwapHTTP.state.paths == ["/api/oauth/profile", "/api/oauth/usage"])
    }

    @Test(arguments: ["{}", #"{"account":{"email":"active@example.invalid"},"organization":{"uuid":"shared-org"}}"#, #"{"account":{"uuid":"user-a","email":"active@example.invalid"}}"#])
    func unresolvedProfileUsesNormalFetchInsteadOfGuessing(profileBody: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeCache(cache([row(fetchedAt: Date().timeIntervalSince1970 - 120)]))
        SwapHTTP.state.configure(profiles: ["Bearer token-a": Reply(status: 200, body: profileBody)], usage: Reply(status: 200, body: #"{"five_hour":{"utilization":25}}"#))
        let result = try await fixture.client.fetch(.claude, allowKeychainPrompt: false)
        #expect(result.remainingPercent == 75)
        #expect(result.source == .live)
        #expect(result.accountIdentity == nil)
        #expect(result.accountLabel == nil)
        #expect(result.authSource == "Claude Code keychain")
        #expect(SwapHTTP.state.paths == ["/api/oauth/profile", "/api/oauth/usage", "/api/oauth/usage"])
        #expect(SwapHTTP.state.queries.last == "cedar_ember=1&skip_spend=1")
    }

    @Test(arguments: ["missing", "schema", "malformed", "unknown", "expired", "reset", "duplicate"])
    func unusableCacheDoesNotHideHTTP429(kind: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let measured = Date().timeIntervalSince1970 - 120
        var data = cache([row(fetchedAt: measured)])
        switch kind {
        case "schema": data = cache([row(fetchedAt: measured)], schema: 3)
        case "malformed": data = Data(#"{"schemaVersion":2,"accounts":{"0":{"email":false}}}"#.utf8)
        case "unknown": data = cache([row(email: "other@example.invalid", fetchedAt: measured)])
        case "expired": data = cache([row(fetchedAt: measured - 3_600)])
        case "reset": data = cache([row(fetchedAt: measured, usage: #"{"five_hour":{"pct":100,"resets_at":"2000-01-01T00:00:00Z"}}"#)])
        case "duplicate": data = cache([row(fetchedAt: measured), row(fetchedAt: measured + 60)])
        default: break
        }
        if kind != "missing" { try fixture.writeCache(data) }
        SwapHTTP.state.configure(usage: Reply(status: 429, body: "{}"))
        await expectHTTP(429) { try await fixture.client.fetch(.claude, allowKeychainPrompt: false) }
    }

    @Test(arguments: [false, true])
    func fileCredentialsNeverUseDefaultSwapCache(customDirectory: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeCache(cache([row(fetchedAt: Date().timeIntervalSince1970 - 120)]))
        let directory = fixture.home.appendingPathComponent(customDirectory ? "custom" : ".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let credential = Data(#"{"organizationUuid":"shared-org","claudeAiOauth":{"accessToken":"file-token"}}"#.utf8)
        try credential.write(to: directory.appendingPathComponent(".credentials.json"))
        let environment = customDirectory ? ["CLAUDE_CONFIG_DIR": directory.path] : [:]
        let client = UsageClient(session: fixture.session, homeDirectory: fixture.home, environment: environment,
                                 keychainReader: { _, _, _ in nil }, securityReader: { _ in nil })
        SwapHTTP.state.configure(usage: Reply(status: 429, body: "{}"))
        await expectHTTP(429) { try await client.fetch(UsageAccount.claude, allowKeychainPrompt: false) }
        #expect(SwapHTTP.state.paths == ["/api/oauth/profile", "/api/oauth/usage"])
    }

    @Test func emptyCustomDirectoryDoesNotFallBackToDefaultKeychain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let client = UsageClient(session: fixture.session, homeDirectory: fixture.home, environment: ["CLAUDE_CONFIG_DIR": fixture.home.appendingPathComponent("empty").path],
                                 keychainReader: { _, _, _ in nil }, securityReader: { _ in nil })
        do {
            _ = try await client.fetch(UsageAccount.claude, allowKeychainPrompt: false)
            Issue.record("Expected custom profile login requirement")
        } catch UsageFailure.loginRequired(.claude) {
            #expect(SwapHTTP.state.paths.isEmpty)
        }
    }

    @Test func codexRetainsItsOwnCredentialAndQuotaPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeCache(cache([row(fetchedAt: Date().timeIntervalSince1970 - 120)]))
        let directory = fixture.home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"codex-token","account_id":"codex-account"}}"#.utf8).write(to: directory.appendingPathComponent("auth.json"))
        SwapHTTP.state.configure(usage: Reply(status: 200, body: #"{"rate_limit":{"primary_window":{"used_percent":35,"limit_window_seconds":18000}}}"#))
        let result = try await fixture.client.fetch(UsageAccount.codex, allowKeychainPrompt: false)
        #expect(result.provider == .codex)
        #expect(result.remainingPercent == 65)
        #expect(SwapHTTP.state.paths == ["/backend-api/wham/usage"])
    }

    private func reading(_ data: Data, email: String = "active@example.invalid", organization: String = "shared-org") throws -> UsageReading? {
        let decoded = try JSONDecoder().decode(ClaudeSwapCache.self, from: data)
        return decoded.reading(email: email, organizationUUID: organization, now: now)
    }

    private func row(email: String = "active@example.invalid", fetchedAt: Double = 1_799_999_880, usage: String = #"{"five_hour":{"pct":10}}"#) -> String {
        "{\"email\":\"\(email)\",\"organizationUuid\":\"shared-org\",\"fetchedAt\":\(fetchedAt),\"lastAttemptAt\":1800000000,\"lastGood\":\(usage)}"
    }

    private func cache(_ rows: [String], schema: Int = 2) -> Data {
        let accounts = rows.enumerated().map { "\"\($0.offset)\":\($0.element)" }.joined(separator: ",")
        return Data("{\"schemaVersion\":\(schema),\"accounts\":{\(accounts)}}".utf8)
    }

    private func expectHTTP(_ status: Int, operation: () async throws -> UsageReading) async {
        do {
            _ = try await operation()
            Issue.record("Expected HTTP \(status), not a cached success")
        } catch UsageFailure.http(let actual) {
            #expect(actual == status)
        } catch UsageFailure.cooldown(let until) {
            #expect(status == 429)
            #expect(until > Date())
        } catch {
            Issue.record("Expected HTTP \(status), got \(error)")
        }
    }
}

private func profile(email: String = "active@example.invalid", uuid: String = "synthetic-user") -> String {
    "{\"account\":{\"uuid\":\"\(uuid)\",\"email\":\"\(email)\"},\"organization\":{\"uuid\":\"shared-org\"}}"
}

private struct Reply: Sendable {
    let status: Int
    let body: String
}

private struct Fixture {
    let home: URL
    let session: URLSession
    let client: UsageClient
    let credentials: SwapCredential
    var cachePath: URL { home.appendingPathComponent(".claude-swap-backup/cache/usage.json") }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pet-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        credentials = SwapCredential()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SwapHTTP.self]
        session = URLSession(configuration: configuration)
        let credentialSource = credentials
        client = UsageClient(session: session, homeDirectory: home, environment: [:],
                             keychainReader: { service, _, _ in service == "Claude Code-credentials" ? credentialSource.data : nil },
                             securityReader: { _ in nil })
        SwapHTTP.state.configure()
    }

    func makeClient() -> UsageClient {
        let credentialSource = credentials
        return UsageClient(session: session, homeDirectory: home, environment: [:],
                           keychainReader: { service, _, _ in service == "Claude Code-credentials" ? credentialSource.data : nil },
                           securityReader: { _ in nil })
    }

    func writeCache(_ data: Data) throws {
        try FileManager.default.createDirectory(at: cachePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cachePath)
    }

    func cleanup() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: home)
    }
}

private final class SwapCredential: @unchecked Sendable {
    private let lock = NSLock()
    private var credential = Data(#"{"claudeAiOauth":{"accessToken":"token-a"}}"#.utf8)
    var data: Data { lock.withLock { credential } }
    func setToken(_ token: String) throws {
        let document = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": token]])
        lock.withLock { credential = document }
    }
}

private final class SwapHTTP: URLProtocol, @unchecked Sendable {
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.response(for: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var profiles: [String: Reply] = [:]
        private var usage = Reply(status: 500, body: "{}")
        private var resetGrants = Reply(status: 200, body: #"{"cedar_ember":null}"#)
        var paths: [String] { lock.withLock { requests.map { $0.url!.path } } }
        var queries: [String] { lock.withLock { requests.map { $0.url?.query ?? "" } } }

        func configure(profiles: [String: Reply] = [:], usage: Reply = Reply(status: 500, body: "{}"),
                       resetGrants: Reply = Reply(status: 200, body: #"{"cedar_ember":null}"#)) {
            lock.withLock {
                requests = []
                self.profiles = profiles
                self.usage = usage
                self.resetGrants = resetGrants
            }
        }

        func response(for request: URLRequest) -> Reply {
            lock.withLock {
                requests.append(request)
                if request.url?.lastPathComponent == "profile" {
                    let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
                    return profiles[authorization] ?? Reply(status: 200, body: profile())
                }
                if request.url?.query == "cedar_ember=1&skip_spend=1" { return resetGrants }
                return usage
            }
        }
    }
}
