import Foundation
import Testing
@testable import ChiikawaPet

@Suite(.serialized)
struct UsageClientTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // Payload contracts: robinebers/openusage@26132ff ClaudeUsageMapper.swift and CodexUsageMapper.swift.
    @Test func modelWindowsAndDistinctExtraUnits() throws {
        let claude = Data(#"{"five_hour":{"utilization":10},"seven_day_sonnet":{"utilization":20},"limits":[null,{"kind":"weekly_scoped","percent":95,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":30,"scope":{"model":{"display_name":"Sonnet"}}}],"extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":5000},"cedar_ember":{"eligible":true,"grants":[{"id":"available","resets_left":2},{"id":"expired","resets_left":5,"ends_at":"2020-01-01T00:00:00Z"}]}}"#.utf8)
        let reading = try UsageClient.decodeClaude(claude, now: now)
        #expect(reading.windows.map(\.id) == ["session", "model:fable:weekly", "model:sonnet:weekly"])
        #expect(reading.windows.map(\.remainingPercent) == [90, 5, 70])
        #expect(reading.windows.map(\.durationSeconds) == [18_000, 604_800, 604_800])
        #expect(reading.extras == [UsageExtra(id: "extra-spend", title: "추가 사용", amount: 12.34, unit: "USD", limit: 50), UsageExtra(id: "reset-credits", title: "사용량 초기화", amount: 2, unit: "count")])
        let codex = Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800}},"additional_rate_limits":[null,{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":600},"secondary_window":{"used_percent":50,"limit_window_seconds":604800}}}],"credits":{"balance":"796.25","has_credits":true},"rate_limit_reset_credits":{"available_count":2}}"#.utf8)
        let result = try UsageClient.decodeCodex(codex, now: now)
        #expect(result.windows.map(\.id) == ["weekly", "model:gpt-5.3-codex-spark:session", "model:gpt-5.3-codex-spark:weekly"])
        #expect(result.windows[1].resetsAt == now.addingTimeInterval(600))
        #expect(result.extras.map(\.amount) == [796.25, 2])
        #expect(result.extras.map(\.unit) == ["credits", "count"])
        #expect(result.remainingPercent == 50)
        #expect(result.plan == "pro")
    }

    @Test(arguments: [nil, "0", "-1", "invalid", "NaN"])
    func missingZeroAndInvalidRetryAfterWait(header: String?) {
        #expect(UsageClient.retryDate(header, now: now) == now.addingTimeInterval(120))
    }

    @Test func retryAfterHonorsSecondsAndHTTPDate() {
        #expect(UsageClient.retryDate("0.5", now: now) == now.addingTimeInterval(1))
        #expect(UsageClient.retryDate("172800", now: now) == now.addingTimeInterval(172800))
        #expect(UsageClient.retryDate("Fri, 15 Jan 2027 08:03:00 GMT", now: now) == now.addingTimeInterval(180))
    }

    @Test func cooldownCannotBeBypassedButChangedFingerprintStartsFresh() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        try fixture.writeCodex(token: "account-a-token")
        ClientHTTP.state.configure([ClientReply(status: 429, headers: ["Retry-After": "0"])])
        let first = await cooldown(fixture.client, account: .codex)
        let second = await cooldown(fixture.client, account: .codex)
        #expect(first == now.addingTimeInterval(120))
        #expect(second == first)
        #expect(ClientHTTP.state.requests.count == 1)
        try fixture.writeCodex(token: "account-b-token", accountID: "b")
        ClientHTTP.state.configure([.codexSuccess])
        let switched = try await fixture.client.fetch(.codex, allowKeychainPrompt: true)
        #expect(switched.remainingPercent == 75)
        #expect(ClientHTTP.state.requests.count == 1)
        #expect(ClientHTTP.state.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer account-b-token")
    }

    @Test func sameCredentialCooldownIsSharedAcrossAliasesButOtherCredentialsRecoverIndependently() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        let first = UsageAccount(id: "one", provider: .codex, label: "One", directory: fixture.home.appendingPathComponent("one").path)
        let second = UsageAccount(id: "two", provider: .codex, label: "Two", directory: fixture.home.appendingPathComponent("two").path)
        try fixture.writeCodex(token: "same-token", directory: URL(fileURLWithPath: first.directory!))
        try fixture.writeCodex(token: "same-token", accountID: "other-route", directory: URL(fileURLWithPath: second.directory!))
        ClientHTTP.state.configure([ClientReply(status: 429, headers: ["Retry-After": "60"]), .codexSuccess])
        #expect(await cooldown(fixture.client, account: first) == now.addingTimeInterval(60))
        #expect(await cooldown(fixture.client, account: second) == now.addingTimeInterval(60))
        #expect(ClientHTTP.state.requests.count == 1)
        try fixture.writeCodex(token: "different-token", directory: URL(fileURLWithPath: second.directory!))
        #expect(try await fixture.client.fetch(second, allowKeychainPrompt: false).remainingPercent == 75)
        fixture.clock.advance(60)
        ClientHTTP.state.configure([.codexSuccess])
        #expect(try await fixture.client.fetch(first, allowKeychainPrompt: false).remainingPercent == 75)
    }

    @Test func persistentCacheRequiresCurrentSourceAndPreservesTimestamp() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        try fixture.writeCodex(token: "private-token-never-persist")
        ClientHTTP.state.configure([.codexSuccess])
        let live = try await fixture.client.fetch(.codex, allowKeychainPrompt: false)
        #expect(live.accountIdentity == nil)
        fixture.clock.advance(30)
        let reopened = fixture.makeClient()
        let cached = try #require(await reopened.cached(.codex))
        #expect(cached.source == .diskCache)
        #expect(cached.fetchedAt == live.fetchedAt)
        #expect(cached.accountID == UsageAccount.codex.id)
        #expect(cached.credentialFingerprint?.count == 64)
        #expect(ClientHTTP.state.requests.count == 1)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil)
        try fixture.writeCodex(token: "private-token-never-persist", accountID: "changed-routing-header")
        #expect(await reopened.cached(.codex) == nil)
        let bytes = try Data(contentsOf: #require(files.first))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("private-token-never-persist"))
        try fixture.writeCodex(token: "new-account-token", accountID: "new-account")
        #expect(await reopened.cached(.codex) == nil)
        ClientHTTP.state.configure([ClientReply(status: 401)])
        do { _ = try await fixture.client.fetch(.codex, allowKeychainPrompt: false); Issue.record("Expected changed identity") }
        catch UsageFailure.accountChanged(let retryAt) { #expect(retryAt == nil) }
    }

    @Test func switchingCredentialDuringRequestDiscardsResponse() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        try fixture.writeCodex(token: "old-token")
        let path = fixture.home.appendingPathComponent(".codex/auth.json")
        ClientHTTP.state.configure([.codexSuccess], duringResponse: {
            try? Data(#"{"tokens":{"access_token":"new-token","account_id":"new"}}"#.utf8).write(to: path)
        })
        do { _ = try await fixture.client.fetch(.codex, allowKeychainPrompt: false); Issue.record("Expected identity change") }
        catch UsageFailure.accountChanged(let retryAt) { #expect(retryAt == nil) }
        #expect(await fixture.client.cached(.codex) == nil)
    }

    @Test func savedCodexUsesAccessTokenClaimsNotUnrelatedIDToken() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        let account = UsageAccount(id: "saved", provider: .codex, label: "Saved", directory: fixture.home.appendingPathComponent("slot").path,
                                   expectedEmail: "a@example.invalid", expectedAccountID: "workspace-a")
        let directory = URL(fileURLWithPath: account.directory!)
        let token = jwt(#"{"exp":1900000000,"https://api.openai.com/auth":{"chatgpt_account_id":"workspace-a"},"https://api.openai.com/profile":{"email":"a@example.invalid"}}"#)
        try fixture.writeCodex(token: token, accountID: "workspace-a", directory: directory)
        ClientHTTP.state.configure([.codexSuccess])
        let reading = try await fixture.client.fetch(account, allowKeychainPrompt: false)
        #expect(reading.accountLabel == "a@example.invalid")
        #expect(ClientHTTP.state.requests[0].value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-a")
        let wrong = jwt(#"{"exp":1900000000,"https://api.openai.com/auth":{"chatgpt_account_id":"workspace-b"},"https://api.openai.com/profile":{"email":"a@example.invalid"}}"#)
        try fixture.writeCodex(token: wrong, accountID: "workspace-a", directory: directory)
        ClientHTTP.state.configure([])
        do { _ = try await fixture.makeClient().fetch(account, allowKeychainPrompt: false); Issue.record("Expected token/account conflict") }
        catch UsageFailure.identityMismatch {}
        #expect(ClientHTTP.state.requests.isEmpty)
        try fixture.writeCodex(token: "opaque", accountID: "workspace-a", directory: directory)
        do { _ = try await fixture.makeClient().fetch(account, allowKeychainPrompt: false); Issue.record("Expected unavailable identity") }
        catch UsageDataFailure.identityUnavailable {}
    }

    @Test func customHomeKeychainIsScopedAndUnknownKeychainCannotExposeCache() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        let directory = fixture.home.appendingPathComponent("custom")
        let account = UsageAccount(id: "custom", provider: .codex, label: "Custom", directory: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expected = "cli|" + UsageClient.fingerprint(Data(directory.resolvingSymlinksInPath().path.utf8)).prefix(16)
        let reads = CredentialReads()
        let client = fixture.makeClient(keychainReader: { service, key, _ in
            reads.record(service: service, account: key)
            guard service == "Codex Auth", key == expected else { throw UsageFailure.keychainDenied }
            return Data(#"{"tokens":{"access_token":"scoped-token","account_id":"a"}}"#.utf8)
        })
        ClientHTTP.state.configure([.codexSuccess])
        _ = try await client.fetch(account, allowKeychainPrompt: false)
        #expect(reads.all.allSatisfy { $0 == "Codex Auth:" + expected })
        let denied = fixture.makeClient(keychainReader: { _, _, _ in throw UsageFailure.keychainDenied })
        #expect(await denied.cached(account) == nil)
    }

    @Test func sameVerifiedIdentityRotationRetainsCooldownButNewAccountDropsOldSample() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        let first = jwt(#"{"exp":1900000000,"https://api.openai.com/auth":{"chatgpt_account_id":"a"},"https://api.openai.com/profile":{"email":"a@example.invalid"}}"#)
        try fixture.writeCodex(token: first)
        ClientHTTP.state.configure([.codexSuccess])
        _ = try await fixture.client.fetch(.codex, allowKeychainPrompt: false)
        let rotated = jwt(#"{"exp":1950000000,"https://api.openai.com/auth":{"chatgpt_account_id":"a"},"https://api.openai.com/profile":{"email":"a@example.invalid"}}"#)
        try fixture.writeCodex(token: rotated)
        ClientHTTP.state.configure([ClientReply(status: 429, headers: ["Retry-After": "300"])])
        #expect(await cooldown(fixture.client, account: .codex) == now.addingTimeInterval(300))
        #expect(await cooldown(fixture.client, account: .codex) == now.addingTimeInterval(300))
        let switched = jwt(#"{"exp":1950000000,"https://api.openai.com/auth":{"chatgpt_account_id":"b"},"https://api.openai.com/profile":{"email":"b@example.invalid"}}"#)
        try fixture.writeCodex(token: switched, accountID: "b")
        ClientHTTP.state.configure([ClientReply(status: 429, headers: ["Retry-After": "900"])])
        do { _ = try await fixture.client.fetch(.codex, allowKeychainPrompt: true); Issue.record("Expected account change") }
        catch UsageFailure.accountChanged(let until) { #expect(until == now.addingTimeInterval(900)) }
        #expect(await fixture.client.cached(.codex) == nil)
        #expect(ClientHTTP.state.requests.count == 1)
    }

    @Test func claudeSavedVaultRejectsWrongDefaultAndReadsOwnTokenOnly() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        let root = fixture.home.appendingPathComponent(".claude-swap-backup")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let user = "11111111-1111-4111-8111-111111111111"
        let org = "22222222-2222-4222-8222-222222222222"
        let metadata = "{\"accounts\":{\"1\":{\"email\":\"saved@example.invalid\",\"uuid\":\"\(user)\",\"organizationUuid\":\"\(org)\"}}}"
        try Data(metadata.utf8).write(to: root.appendingPathComponent("sequence.json"))
        let discovered = UsageAccountDiscovery.discover(includeSaved: true, additional: [], homeDirectory: fixture.home, environment: [:])
        let account = try #require(discovered.first { $0.expectedEmail == "saved@example.invalid" })
        let route = try #require(UsageAccountDiscovery.claudeSwapRoute(for: account, homeDirectory: fixture.home))
        try FileManager.default.createDirectory(at: route.vaultCredentialFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let secret = Data(#"{"claudeAiOauth":{"accessToken":"own-vault-token"}}"#.utf8).base64EncodedString()
        try Data(secret.utf8).write(to: route.vaultCredentialFile)
        let defaultHome = fixture.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
        try Data(#"{"claudeAiOauth":{"accessToken":"wrong-default-token"}}"#.utf8).write(to: defaultHome.appendingPathComponent(".credentials.json"))
        let wrong = ClientReply(body: #"{"account":{"uuid":"wrong","email":"other@example.invalid"},"organization":{"uuid":"other"}}"#)
        let own = ClientReply(body: "{\"account\":{\"uuid\":\"\(user)\",\"email\":\"saved@example.invalid\"},\"organization\":{\"uuid\":\"\(org)\",\"organization_type\":\"claude_max\"}}")
        let usage = ClientReply(body: #"{"five_hour":{"utilization":40}}"#)
        let grants = ClientReply(body: #"{"cedar_ember":{"eligible":true,"grants":[{"id":"g","resets_left":1}]}}"#)
        ClientHTTP.state.configure([wrong, own, usage, grants])
        let reading = try await fixture.client.fetch(account, allowKeychainPrompt: false)
        #expect(reading.authSource == "Claude Swap vault file")
        #expect(reading.accountLabel == "saved@example.invalid")
        let expectedIdentity = UsageClient.fingerprint(Data(("Claude\0" + user + "|" + org).utf8))
        #expect(reading.accountIdentity == expectedIdentity)
        #expect(reading.plan == "claude_max")
        #expect(reading.extras.first?.amount == 1)
        let quotaRequests = ClientHTTP.state.requests.filter { $0.url?.path == "/api/oauth/usage" }
        #expect(quotaRequests.count == 2)
        #expect(quotaRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer own-vault-token" })
        ClientHTTP.state.configure([usage])
        let second = try await fixture.client.fetch(account, allowKeychainPrompt: false)
        #expect(second.extras.first?.amount == 1)
        #expect(ClientHTTP.state.requests.count == 1)
    }

    @Test func defaultClaudeNeverUsesDifferentStaleFileAfterPreferredLoginFails() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        try fixture.writeClaude(token: "stale-file-account")
        let client = fixture.makeClient(keychainReader: { service, _, _ in
            guard service == "Claude Code-credentials" else { return nil }
            return Data(#"{"claudeAiOauth":{"accessToken":"active-keychain-account"}}"#.utf8)
        })
        let profile = ClientReply(body: #"{"account":{"uuid":"active-user","email":"active@example.invalid"},"organization":{"uuid":"active-org"}}"#)
        ClientHTTP.state.configure([profile, ClientReply(status: 401)])
        do { _ = try await client.fetch(.claude, allowKeychainPrompt: false); Issue.record("Expected current login failure") }
        catch UsageFailure.unauthorized(.claude) {}
        #expect(ClientHTTP.state.requests.count == 2)
        #expect(ClientHTTP.state.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer active-keychain-account" })
    }

    @Test func verifiedClaudeRotationDoesNotHideSameAccountAfterThrottling() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        try fixture.writeClaude(token: "original")
        let profile = ClientReply(body: #"{"account":{"uuid":"same-user","email":"same@example.invalid"},"organization":{"uuid":"same-org"}}"#)
        let usage = ClientReply(body: #"{"five_hour":{"utilization":20}}"#)
        ClientHTTP.state.configure([profile, usage, ClientReply(body: #"{"cedar_ember":null}"#)])
        _ = try await fixture.client.fetch(.claude, allowKeychainPrompt: false)
        try fixture.writeClaude(token: "rotated")
        ClientHTTP.state.configure([profile, ClientReply(status: 429, headers: ["Retry-After": "600"])])
        #expect(await cooldown(fixture.client, account: .claude) == now.addingTimeInterval(600))
        #expect(await cooldown(fixture.client, account: .claude) == now.addingTimeInterval(600))
        #expect(ClientHTTP.state.requests.count == 2)
    }

    @Test func missingSavedCodexLoginNeverBorrowsDefaultCredentials() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        try fixture.writeCodex(token: "unrelated-default-token")
        let root = fixture.home.appendingPathComponent(".local/share/codex-swap")
        let slot = fixture.home.appendingPathComponent("isolated-slot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = "{\"schemaVersion\":1,\"mainHome\":\"\(fixture.home.appendingPathComponent(".codex").path)\",\"accounts\":[{\"number\":1,\"home\":\"\(slot.path)\",\"identity\":{\"accountId\":\"saved-workspace\",\"email\":\"saved@example.invalid\"}}]}"
        try Data(registry.utf8).write(to: root.appendingPathComponent("accounts.json"))
        let accounts = UsageAccountDiscovery.discover(includeSaved: true, additional: [], homeDirectory: fixture.home, environment: [:])
        let saved = try #require(accounts.first { $0.expectedEmail == "saved@example.invalid" })
        ClientHTTP.state.configure([])
        do { _ = try await fixture.client.fetch(saved, allowKeychainPrompt: false); Issue.record("Expected account-specific login guidance") }
        catch UsageDataFailure.savedLoginRequired(.codex) {}
        #expect(ClientHTTP.state.requests.isEmpty)
        #expect(await fixture.client.cached(saved) == nil)
    }

    @Test(arguments: [
        #"{"five_hour":{"utilization":1},"limits":[{"kind":"weekly_scoped","percent":-1,"scope":{"model":{"display_name":"Fable"}}}]}"#,
        #"{"five_hour":{"utilization":1},"extra_usage":{"is_enabled":true,"used_credits":-1}}"#,
        #"{"five_hour":{"utilization":1},"cedar_ember":{"eligible":true}}"#
    ])
    func malformedClaudeAdditionalMeasurementsAreNotInvented(json: String) {
        #expect(throws: UsageFailure.self) { try UsageClient.decodeClaude(Data(json.utf8), now: now) }
    }

    @Test func creditsAloneCannotPretendToBeSubscriptionQuota() {
        let data = Data(#"{"credits":{"balance":"100"},"additional_rate_limits":[null],"rate_limit_reset_credits":{"available_count":2}}"#.utf8)
        #expect(throws: UsageFailure.self) { try UsageClient.decodeCodex(data, now: now) }
    }

    @Test func verifiedIdentitySurvivesTokenRotationButSeparatesWorkspaceUsers() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        let firstToken = jwt(#"{"exp":1900000000,"https://api.openai.com/auth":{"chatgpt_account_id":"shared-workspace"},"https://api.openai.com/profile":{"email":"first@example.invalid"}}"#)
        try fixture.writeCodex(token: firstToken, accountID: "shared-workspace")
        ClientHTTP.state.configure([.codexSuccess])
        let first = try await fixture.client.fetch(.codex, allowKeychainPrompt: false)
        let rotatedToken = jwt(#"{"exp":1950000000,"https://api.openai.com/auth":{"chatgpt_account_id":"shared-workspace"},"https://api.openai.com/profile":{"email":"first@example.invalid"}}"#)
        try fixture.writeCodex(token: rotatedToken, accountID: "shared-workspace")
        ClientHTTP.state.configure([.codexSuccess])
        let rotated = try await fixture.client.fetch(.codex, allowKeychainPrompt: false)
        #expect(first.accountIdentity != nil)
        #expect(first.accountIdentity == rotated.accountIdentity)
        #expect(first.credentialFingerprint != rotated.credentialFingerprint)
        let otherToken = jwt(#"{"exp":1950000000,"https://api.openai.com/auth":{"chatgpt_account_id":"shared-workspace"},"https://api.openai.com/profile":{"email":"second@example.invalid"}}"#)
        try fixture.writeCodex(token: otherToken, accountID: "shared-workspace")
        ClientHTTP.state.configure([.codexSuccess])
        let other = try await fixture.client.fetch(.codex, allowKeychainPrompt: false)
        #expect(other.accountIdentity != first.accountIdentity)
        #expect(other.accountID == first.accountID)
    }

    @Test(arguments: [#"{"claudeAiOauth":{"accessToken":"expired-current","expiresAt":1}}"#, "{broken", "{}"])
    func invalidAuthoritativeClaudeKeychainNeverUsesStaleFile(document: String) async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        try fixture.writeClaude(token: "different-stale-file-account")
        let data = Data(document.utf8)
        let client = fixture.makeClient(keychainReader: { _, _, _ in data })
        ClientHTTP.state.configure([])
        do { _ = try await client.fetch(.claude, allowKeychainPrompt: true); Issue.record("Expected authoritative credential failure") }
        catch UsageFailure.unauthorized(.claude) {}
        catch UsageFailure.loginRequired(.claude) {}
        #expect(ClientHTTP.state.requests.isEmpty)
        #expect(await client.cached(.claude) == nil)
    }

    @Test func malformedSecurityReaderOutputDoesNotFallThroughToOldNativeOrFileLogin() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        try fixture.writeClaude(token: "stale-file")
        let reads = CredentialReads()
        let client = fixture.makeClient(keychainReader: { service, key, _ in
            reads.record(service: service, account: key)
            return Data(#"{"claudeAiOauth":{"accessToken":"stale-native"}}"#.utf8)
        }, securityReader: { _ in Data("unparseable-hex".utf8) })
        ClientHTTP.state.configure([])
        do { _ = try await client.fetch(.claude, allowKeychainPrompt: true); Issue.record("Expected malformed authoritative security value") }
        catch UsageFailure.loginRequired(.claude) {}
        #expect(reads.all.isEmpty)
        #expect(ClientHTTP.state.requests.isEmpty)
    }

    @Test(arguments: ["apikey", "expired", "malformed"])
    func explicitCodexFileFailureNeverReadsOldKeychain(kind: String) async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        let directory = fixture.home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch kind {
        case "apikey":
            try Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-key"}"#.utf8).write(to: directory.appendingPathComponent("auth.json"))
        case "expired":
            let token = jwt(#"{"exp":1,"https://api.openai.com/auth":{"chatgpt_account_id":"new"},"https://api.openai.com/profile":{"email":"new@example.invalid"}}"#)
            try fixture.writeCodex(token: token, accountID: "new")
        default:
            try Data("{broken".utf8).write(to: directory.appendingPathComponent("auth.json"))
        }
        let reads = CredentialReads()
        let client = fixture.makeClient(keychainReader: { service, key, _ in
            reads.record(service: service, account: key)
            return Data(#"{"tokens":{"access_token":"old-keychain-token","account_id":"old"}}"#.utf8)
        })
        ClientHTTP.state.configure([])
        do { _ = try await client.fetch(.codex, allowKeychainPrompt: true); Issue.record("Expected authoritative file failure") }
        catch UsageFailure.apiKeyMode {}
        catch UsageFailure.unauthorized(.codex) {}
        catch UsageFailure.loginRequired(.codex) {}
        #expect(await client.cached(.codex) == nil)
        #expect(reads.all.isEmpty)
        #expect(ClientHTTP.state.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func validAuthoritativeCodexFileDoesNotPromptOrGetVetoedByUnusedKeychain(pinned: Bool) async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        let token = jwt(#"{"exp":1900000000,"https://api.openai.com/auth":{"chatgpt_account_id":"a"},"https://api.openai.com/profile":{"email":"a@example.invalid"}}"#)
        try fixture.writeCodex(token: token)
        let account = pinned
            ? UsageAccount(id: "pinned", provider: .codex, label: "Pinned", directory: fixture.home.appendingPathComponent(".codex").path,
                           expectedEmail: "a@example.invalid", expectedAccountID: "a")
            : UsageAccount.codex
        let reads = CredentialReads()
        let client = fixture.makeClient(keychainReader: { service, key, _ in
            reads.record(service: service, account: key)
            throw UsageFailure.keychainDenied
        })
        ClientHTTP.state.configure([.codexSuccess])
        let reading = try await client.fetch(account, allowKeychainPrompt: true)
        #expect(reading.authSource == "Codex auth file")
        #expect(await client.cached(account) != nil)
        #expect(reads.all.isEmpty)
        #expect(ClientHTTP.state.requests.count == 1)
    }

    @Test func expiredCodexValidationCarriesIdentityBeforeRejectingChangedAccount() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        let valid = jwt(#"{"exp":1900000000,"https://api.openai.com/auth":{"chatgpt_account_id":"a"},"https://api.openai.com/profile":{"email":"a@example.invalid"}}"#)
        try fixture.writeCodex(token: valid)
        ClientHTTP.state.configure([.codexSuccess])
        _ = try await fixture.client.fetch(.codex, allowKeychainPrompt: false)
        let same = jwt(#"{"exp":1,"https://api.openai.com/auth":{"chatgpt_account_id":"a"},"https://api.openai.com/profile":{"email":"a@example.invalid"}}"#)
        try fixture.writeCodex(token: same)
        ClientHTTP.state.configure([])
        do { _ = try await fixture.client.fetch(.codex, allowKeychainPrompt: false); Issue.record("Expected same-account expiry") }
        catch UsageFailure.unauthorized(.codex) {}
        let switched = jwt(#"{"exp":1,"https://api.openai.com/auth":{"chatgpt_account_id":"b"},"https://api.openai.com/profile":{"email":"b@example.invalid"}}"#)
        try fixture.writeCodex(token: switched, accountID: "b")
        do { _ = try await fixture.client.fetch(.codex, allowKeychainPrompt: false); Issue.record("Expected changed expired account") }
        catch UsageFailure.accountChanged(let until) { #expect(until == nil) }
        try Data("{broken-new-source".utf8).write(to: fixture.home.appendingPathComponent(".codex/auth.json"))
        do { _ = try await fixture.client.fetch(.codex, allowKeychainPrompt: false); Issue.record("Expected unknown changed source") }
        catch UsageFailure.accountChanged(let until) { #expect(until == nil) }
        #expect(ClientHTTP.state.requests.isEmpty)
        #expect(await fixture.client.cached(.codex) == nil)
    }

    @Test func expiredAndMalformedClaudeAuthorityChangesHideOldAccountWithoutUsingStaleFile() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        try fixture.writeClaude(token: "unrelated-file")
        let document = CredentialDocument(Data(#"{"claudeAiOauth":{"accessToken":"known-a"}}"#.utf8))
        let client = fixture.makeClient(keychainReader: { _, _, _ in document.data })
        let profile = ClientReply(body: #"{"account":{"uuid":"a","email":"a@example.invalid"},"organization":{"uuid":"org-a"}}"#)
        ClientHTTP.state.configure([profile, ClientReply(body: #"{"five_hour":{"utilization":20}}"#), ClientReply(body: #"{"cedar_ember":null}"#)])
        _ = try await client.fetch(.claude, allowKeychainPrompt: false)
        ClientHTTP.state.configure([])
        document.set(Data(#"{"claudeAiOauth":{"accessToken":"known-a","expiresAt":1}}"#.utf8))
        do { _ = try await client.fetch(.claude, allowKeychainPrompt: false); Issue.record("Expected same token expiry") }
        catch UsageFailure.unauthorized(.claude) {}
        document.set(Data(#"{"claudeAiOauth":{"accessToken":"unknown-b","expiresAt":1}}"#.utf8))
        do { _ = try await client.fetch(.claude, allowKeychainPrompt: false); Issue.record("Expected changed expired Claude login") }
        catch UsageFailure.accountChanged(let until) { #expect(until == nil) }
        document.set(Data("{broken".utf8))
        do { _ = try await client.fetch(.claude, allowKeychainPrompt: false); Issue.record("Expected malformed changed Claude login") }
        catch UsageFailure.accountChanged(let until) { #expect(until == nil) }
        #expect(ClientHTTP.state.requests.isEmpty)
        #expect(await client.cached(.claude) == nil)
    }

    @Test func explicitlyPinnedCodexCanUseVerifiedMatchingKeychainAfterExpiredFile() async throws {
        let fixture = try ClientFixture(now: now)
        defer { fixture.cleanup() }
        let directory = fixture.home.appendingPathComponent("saved")
        let account = UsageAccount(id: "saved", provider: .codex, label: "Saved", directory: directory.path,
                                   expectedEmail: "a@example.invalid", expectedAccountID: "a")
        let expired = jwt(#"{"exp":1,"https://api.openai.com/auth":{"chatgpt_account_id":"b"},"https://api.openai.com/profile":{"email":"b@example.invalid"}}"#)
        try fixture.writeCodex(token: expired, accountID: "b", directory: directory)
        let valid = jwt(#"{"exp":1900000000,"https://api.openai.com/auth":{"chatgpt_account_id":"a"},"https://api.openai.com/profile":{"email":"a@example.invalid"}}"#)
        let credential = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": valid, "account_id": "a"]])
        let client = fixture.makeClient(keychainReader: { _, _, _ in credential })
        ClientHTTP.state.configure([.codexSuccess])
        let reading = try await client.fetch(account, allowKeychainPrompt: true)
        #expect(reading.accountLabel == "a@example.invalid")
        #expect(reading.authSource == "Codex home keychain")
        #expect(ClientHTTP.state.requests.count == 1)
        #expect(ClientHTTP.state.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer " + valid)
    }

    private func cooldown(_ client: UsageClient, account: UsageAccount) async -> Date? {
        do { _ = try await client.fetch(account, allowKeychainPrompt: true); Issue.record("Expected cooldown") }
        catch UsageFailure.cooldown(let until) { return until }
        catch { Issue.record("Unexpected sanitized error: \(error)") }
        return nil
    }
    private func jwt(_ payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).synthetic"
    }
}

private struct ClientFixture {
    let home: URL
    let cache: URL
    let session: URLSession
    let clock: ClientClock
    let client: UsageClient
    init(now: Date) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pet-client-\(UUID().uuidString)")
        cache = home.appendingPathComponent("cache")
        clock = ClientClock(now)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientHTTP.self]
        session = URLSession(configuration: configuration)
        let instant = clock
        client = UsageClient(session: session, homeDirectory: home, environment: [:], cacheDirectory: cache,
                             clock: { instant.now }, keychainReader: { _, _, _ in nil }, securityReader: { _ in nil })
    }
    func makeClient(keychainReader: @escaping @Sendable (String, String?, Bool) throws -> Data? = { _, _, _ in nil },
                    securityReader: @escaping @Sendable (String) -> Data? = { _ in nil }) -> UsageClient {
        let instant = clock
        return UsageClient(session: session, homeDirectory: home, environment: [:], cacheDirectory: cache,
                           clock: { instant.now }, keychainReader: keychainReader, securityReader: securityReader)
    }
    func writeCodex(token: String, accountID: String = "a", directory: URL? = nil) throws {
        let directory = directory ?? home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": token, "account_id": accountID]])
        try data.write(to: directory.appendingPathComponent("auth.json"))
    }
    func writeClaude(token: String) throws {
        let directory = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": token]])
        try data.write(to: directory.appendingPathComponent(".credentials.json"))
    }
    func cleanup() { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: home) }
}

private final class ClientClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    init(_ instant: Date) { self.instant = instant }
    var now: Date { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant.addTimeInterval(seconds) } }
}

private final class CredentialDocument: @unchecked Sendable {
    private let lock = NSLock()
    private var document: Data
    init(_ document: Data) { self.document = document }
    var data: Data { lock.withLock { document } }
    func set(_ document: Data) { lock.withLock { self.document = document } }
}

private final class CredentialReads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String] = []
    func record(service: String, account: String?) { lock.withLock { reads.append(service + ":" + (account ?? "")) } }
    var all: [String] { lock.withLock { reads } }
}

private struct ClientReply: Sendable {
    var status = 200
    var body = "{}"
    var headers: [String: String] = [:]
    static let codexSuccess = ClientReply(body: #"{"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000}}}"#)
}

private final class ClientHTTP: URLProtocol, @unchecked Sendable {
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.take(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [ClientReply] = []
        private var observed: [URLRequest] = []
        private var action: (@Sendable () -> Void)?
        var requests: [URLRequest] { lock.withLock { observed } }
        func configure(_ replies: [ClientReply], duringResponse: (@Sendable () -> Void)? = nil) {
            lock.withLock { self.replies = replies; observed = []; action = duringResponse }
        }
        func take(_ request: URLRequest) -> ClientReply {
            let (reply, callback) = lock.withLock {
                observed.append(request)
                let reply = replies.isEmpty ? ClientReply(status: 500) : replies.removeFirst()
                let callback = action
                action = nil
                return (reply, callback)
            }
            callback?()
            return reply
        }
    }
}
