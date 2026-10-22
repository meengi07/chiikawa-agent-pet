import Foundation
import Testing
@testable import ChiikawaPet

struct UsageAccountTests {
    private let userID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let organizationID = "11111111-2222-4333-8444-555555555555"

    @Test func savedDiscoveryIsOptInAndExplicitHomesRemainAvailable() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try save("not-json SECRET-MARKER", at: home.appendingPathComponent(".claude-swap-backup/sequence.json"))
        try save("not-json SECRET-MARKER", at: home.appendingPathComponent(".local/share/codex-swap/accounts.json"))
        let explicit = UsageAccount(id: "my-codex", provider: .codex, label: "Work", directory: "/explicit/codex")
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: false, additional: [explicit],
                                                                homeDirectory: home, environment: [:])
        #expect(result.accounts == UsageAccount.defaults + [explicit])
        #expect(result.warnings.isEmpty)
        let defaults = UsageAccountDiscovery.discover(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        #expect(defaults == UsageAccount.defaults)
    }

    @Test func missingRegistriesAreNotErrorsAndNoSiblingHomesAreScanned() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try save(#"{"tokens":{"account_id":"not-discoverable"}}"#,
                 at: home.appendingPathComponent(".codex-other/auth.json"))
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [],
                                                                homeDirectory: home, environment: [:])
        #expect(result.accounts == UsageAccount.defaults)
        #expect(result.warnings.isEmpty)
    }

    @Test func claudeSequenceUsesUUIDIdentityAndActualSessionSlug() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // claude-swap 4351e3c and claudeswitch 7586506 switcher.py/session.py metadata contracts.
        let sequence = """
        {"activeAccountNumber":2,"lastUpdated":"2026-10-01T00:00:00Z","sequence":[2,10],"accounts":{
          "10":{"email":"later@example.com","uuid":"\(userID)","organizationUuid":"\(organizationID)","organizationName":"Team","added":"2026-10-01"},
          "2":{"email":"te\u{301}st+work@example.com","uuid":"\(userID.uppercased())","organizationUuid":"\(organizationID.uppercased())","organizationName":"Work","added":"2026-10-01"}
        }}
        """
        try save(sequence, at: home.appendingPathComponent(".claude-swap-backup/sequence.json"))
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        #expect(result.warnings.isEmpty)
        #expect(result.accounts.count == 4)
        let account = try #require(result.accounts.first { $0.directory?.contains("/sessions/2-") == true })
        #expect(account.expectedAccountID == userID)
        #expect(account.expectedOrganizationID == organizationID)
        #expect(account.expectedEmail == "te\u{301}st+work@example.com")
        #expect(account.directory == home.appendingPathComponent(".claude-swap-backup/sessions/2-t_st_work_example.com").path)
        #expect(account.keychainService?.hasPrefix("Claude Code-credentials-") == true)
        #expect(account.keychainService?.count == "Claude Code-credentials-".count + 8)
        #expect(!account.id.contains(home.path))
        #expect(!account.id.contains("example.com"))
        let route = try #require(UsageAccountDiscovery.claudeSwapRoute(for: account, homeDirectory: home))
        #expect(route.slot == "2")
        #expect(route.sessionDirectory.path == account.directory)
        #expect(route.vaultCredentialFile.path == home.appendingPathComponent(".claude-swap-backup/credentials/.creds-2-te\u{301}st+work@example.com.enc").path)
        #expect(route.keychainAccount == "account-2-te\u{301}st+work@example.com")
        #expect(result.accounts[3].directory?.contains("/sessions/10-") == true)
    }

    @Test func claudeRouteRejectsForgedIdentityPathsAndRoots() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try save(claudeSequence(), at: home.appendingPathComponent(".claude-swap-backup/sequence.json"))
        let discovered = UsageAccountDiscovery.discover(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        let account = try #require(discovered.last)
        var changed = account
        changed.directory = "/untrusted/session"
        #expect(UsageAccountDiscovery.claudeSwapRoute(for: changed, homeDirectory: home) == nil)
        changed = account
        changed.expectedEmail = "../../secret@example.com"
        #expect(UsageAccountDiscovery.claudeSwapRoute(for: changed, homeDirectory: home) == nil)
        changed = account
        changed.expectedAccountID = "ffffffff-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        #expect(UsageAccountDiscovery.claudeSwapRoute(for: changed, homeDirectory: home) == nil)
        #expect(UsageAccountDiscovery.claudeSwapRoute(for: account, homeDirectory: home.appendingPathComponent("other")) == nil)
        #expect(UsageAccountDiscovery.claudeSwapRoute(for: .claude, homeDirectory: home) == nil)
    }

    @Test func claudeMalformedAndUnsupportedSlotsDoNotHideValidAccounts() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let valid = claudeSlot()
        let sequence = """
        {"accounts":{
          "1":\(valid), "../2":\(valid), "٣":\(valid), "":\(valid),
          "3":{"email":"unsafe/SECRET-MARKER@example.com","uuid":"\(userID)","organizationUuid":"\(organizationID)"},
          "4":{"email":"safe@example.com","uuid":"not-a-uuid","organizationUuid":"\(organizationID)"},
          "5":{"email":"safe@example.com","uuid":"\(userID)","organizationUuid":""},
          "6":{"email":"safe@example.com","uuid":"\(userID)","organizationUuid":"\(organizationID)","provider":"codex"},
          "7":{"email":"safe@example.com","uuid":"\(userID)","organizationUuid":"\(organizationID)","kind":"api_key"},
          "8":null,"9":{"email":false}
        }}
        """
        try save(sequence, at: home.appendingPathComponent(".claude-swap-backup/sequence.json"))
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        #expect(result.accounts.count == 3)
        #expect(result.accounts.last?.expectedEmail == "person@example.com")
        #expect(!result.warnings.isEmpty)
        #expect(!result.warnings.joined().contains("SECRET-MARKER"))
        #expect(!result.warnings.joined().contains(home.path))
    }

    @Test func savedIDsStayStableAcrossLabelsButChangeWithIdentity() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".claude-swap-backup/sequence.json")
        try save(claudeSequence(), at: file)
        let first = UsageAccountDiscovery.discover(includeSaved: true, additional: [], homeDirectory: home, environment: [:]).last
        try save(claudeSequence(organization: "Renamed"), at: file)
        let renamed = UsageAccountDiscovery.discover(includeSaved: true, additional: [], homeDirectory: home, environment: [:]).last
        #expect(first?.id == renamed?.id)
        #expect(first?.label != renamed?.label)
        try save(claudeSequence(email: "other@example.com"), at: file)
        let switched = UsageAccountDiscovery.discover(includeSaved: true, additional: [], homeDirectory: home, environment: [:]).last
        #expect(first?.id != switched?.id)
    }

    @Test func codexRegistryBindsWorkspaceAndEmailWithoutExecutingAlias() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let savedHome = home.appendingPathComponent("codex/work").path
        // codex-swap 8afa275 store.rs Registry/Account and auth.rs Identity.
        let registry = """
        {"schemaVersion":1,"mainHome":\(json(savedHome)),"nextNumber":3,"default":2,"originalAccount":2,"directoryMappings":{},"preferences":{"codexBin":null},"accounts":[
          {"number":2,"alias":"../../alias $(never-run)","home":\(json(savedHome)),"managed":true,"shareHistory":false,"enabled":false,
           "identity":{"accountId":"Workspace-ABC","userId":"user-123","email":"PERSON@example.com","plan":"pro"}}
        ]}
        """
        try save(registry, at: home.appendingPathComponent(".local/share/codex-swap/accounts.json"))
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        #expect(result.warnings.isEmpty)
        #expect(result.accounts.count == 3)
        let account = try #require(result.accounts.last)
        #expect(account.provider == .codex)
        #expect(account.expectedEmail == "person@example.com")
        #expect(account.expectedAccountID == "workspace-abc")
        #expect(account.directory == savedHome)
        #expect(account.label.contains("../../alias $(never-run)"))
        #expect(!account.id.contains("never-run"))
        #expect(!account.id.contains(savedHome))
        #expect(account.id.hasPrefix("codex-xswap:"))
        #expect(account.keychainService == nil)
    }

    @Test func codexRejectsDuplicateSlotsHomesUnsafePathsAndMissingOwnerEmail() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let entries = [
            codexSlot(number: 1, home: "/safe/one"), codexSlot(number: 1, home: "/safe/two"),
            codexSlot(number: 2, home: "/same/home"), codexSlot(number: 3, home: "/same/home"),
            codexSlot(number: 0, home: "/safe/zero"), codexSlot(number: -1, home: "/safe/negative"),
            codexSlot(number: 4, home: "relative/SECRET-MARKER"),
            codexSlot(number: 5, home: "/safe/../SECRET-MARKER"),
            codexSlot(number: 6, home: "/safe/\0SECRET-MARKER"),
            codexSlot(number: 7, home: "/safe/seven", email: nil),
            codexSlot(number: 8, home: "/safe/eight", email: "bad\\SECRET-MARKER@example.com"),
            codexSlot(number: 9, home: "/safe/nine", accountID: "workspace|SECRET-MARKER"),
            "null", #"{"number":"10","home":"/safe/ten"}"#,
            codexSlot(number: 11, home: "/safe/eleven")
        ]
        try save(codexRegistry(mainHome: home.appendingPathComponent(".codex").path, entries: entries),
                 at: home.appendingPathComponent(".local/share/codex-swap/accounts.json"))
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        #expect(result.accounts.count == 3)
        #expect(result.accounts.last?.directory == "/safe/eleven")
        #expect(!result.warnings.isEmpty)
        #expect(!result.warnings.joined().contains("SECRET-MARKER"))
        #expect(!result.warnings.joined().contains(home.path))
    }

    @Test(arguments: ["relative", "/unsafe/../main", "/unsafe/\0main", "/"])
    func codexRequiresSafeAbsoluteMainHome(mainHome: String) throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try save(codexRegistry(mainHome: mainHome, entries: [codexSlot(number: 1, home: "/safe/one")]),
                 at: home.appendingPathComponent(".local/share/codex-swap/accounts.json"))
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        #expect(result.accounts == UsageAccount.defaults)
        #expect(!result.warnings.isEmpty)
    }

    @Test(arguments: [#"{"schemaVersion":2,"mainHome":"/safe/main","accounts":[]}"#,
                      #"{"schemaVersion":true,"mainHome":"/safe/main","accounts":[]}"#,
                      #"{"schemaVersion":1,"mainHome":"/safe/main","accounts":{}}"#,
                      "broken SECRET-MARKER"])
    func malformedOrUnsupportedRegistriesHaveSanitizedWarnings(registry: String) throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try save(registry, at: home.appendingPathComponent(".local/share/codex-swap/accounts.json"))
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        #expect(result.accounts == UsageAccount.defaults)
        #expect(!result.warnings.isEmpty)
        #expect(!result.warnings.joined().contains("SECRET-MARKER"))
    }

    @Test func configuredXswapRootWinsOverXDGAndDefault() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = codexRegistry(mainHome: home.appendingPathComponent(".codex").path,
                                     entries: [codexSlot(number: 1, home: "/selected/home")])
        try save(registry, at: home.appendingPathComponent("custom/accounts.json"))
        try save("not-json", at: home.appendingPathComponent("data/codex-swap/accounts.json"))
        try save("not-json", at: home.appendingPathComponent(".local/share/codex-swap/accounts.json"))
        let environment = ["XSWAP_HOME": "~/custom", "XDG_DATA_HOME": home.appendingPathComponent("data").path]
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home, environment: environment)
        #expect(result.accounts.last?.directory == "/selected/home")
        #expect(result.warnings.isEmpty)
        let absolute = UsageAccountDiscovery.discover(includeSaved: true, additional: [], homeDirectory: home,
                                                      environment: ["XSWAP_HOME": home.appendingPathComponent("custom").path])
        #expect(absolute == result.accounts)
    }

    @Test func configuredXDGIsSupportedAndUnsafeOverrideDoesNotFallBack() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = codexRegistry(mainHome: home.appendingPathComponent(".codex").path,
                                     entries: [codexSlot(number: 1, home: "/xdg/home")])
        try save(registry, at: home.appendingPathComponent("data/codex-swap/accounts.json"))
        try save(registry, at: home.appendingPathComponent(".local/share/codex-swap/accounts.json"))
        let configured = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home,
                                                                    environment: ["XDG_DATA_HOME": home.appendingPathComponent("data").path])
        #expect(configured.accounts.last?.directory == "/xdg/home")
        #expect(configured.warnings.isEmpty)
        let unsafe = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home,
                                                                environment: ["XSWAP_HOME": "relative/SECRET-MARKER"])
        #expect(unsafe.accounts == UsageAccount.defaults)
        #expect(!unsafe.warnings.isEmpty)
        #expect(!unsafe.warnings.joined().contains("SECRET-MARKER"))
        let ignoredXDG = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home,
                                                                    environment: ["XDG_DATA_HOME": "relative"])
        #expect(ignoredXDG.accounts.count == 3)
        #expect(!ignoredXDG.warnings.isEmpty)
    }

    @Test func customMainHomeWithoutSavedIdentityExplainsExplicitHomeRequirement() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try save(codexRegistry(mainHome: "/custom/main", entries: []), at: home.appendingPathComponent(".local/share/codex-swap/accounts.json"))
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        #expect(result.accounts == UsageAccount.defaults)
        #expect(result.warnings.contains { $0.contains("add that home explicitly") })
        #expect(!result.warnings.joined().contains("/custom/main"))
    }

    @Test func symlinkedOrOversizedMetadataIsNotReadAsRegistry() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sequence = home.appendingPathComponent(".claude-swap-backup/sequence.json")
        try FileManager.default.createDirectory(at: sequence.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = home.appendingPathComponent("synthetic-private.json")
        try save(claudeSequence(), at: target)
        try FileManager.default.createSymbolicLink(at: sequence, withDestinationURL: target)
        try save(String(repeating: "x", count: 1_048_577), at: home.appendingPathComponent(".local/share/codex-swap/accounts.json"))
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        #expect(result.accounts == UsageAccount.defaults)
        #expect(result.warnings.count == 2)
    }

    @Test func codexIDsBindEmailEvenForMembersOfTheSameWorkspace() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".local/share/codex-swap/accounts.json")
        let mainHome = home.appendingPathComponent(".codex").path
        let firstOwner = codexSlot(number: 1, home: "/saved/one", email: "first@example.com")
        let secondOwner = codexSlot(number: 2, home: "/saved/two", email: "second@example.com")
        try save(codexRegistry(mainHome: mainHome, entries: [firstOwner, secondOwner]), at: file)
        let discovered = UsageAccountDiscovery.discover(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        #expect(discovered.count == 4)
        #expect(discovered[2].expectedAccountID == discovered[3].expectedAccountID)
        #expect(discovered[2].expectedEmail != discovered[3].expectedEmail)
        #expect(discovered[2].id != discovered[3].id)
        let replacement = codexSlot(number: 1, home: "/saved/one", email: "replacement@example.com")
        try save(codexRegistry(mainHome: mainHome, entries: [replacement]), at: file)
        let replaced = UsageAccountDiscovery.discover(includeSaved: true, additional: [], homeDirectory: home, environment: [:])
        #expect(discovered[2].id != replaced.last?.id)
    }

    @Test func duplicateExplicitIDsCannotReplaceCanonicalDefaults() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let duplicate = UsageAccount(id: UsageAccount.claude.id, provider: .claude, label: "Wrong", directory: "/other")
        let result = UsageAccountDiscovery.discoverWithWarnings(includeSaved: false, additional: [duplicate], homeDirectory: home, environment: [:])
        #expect(result.accounts == UsageAccount.defaults)
        #expect(result.warnings.count == 1)
    }

    @Test func quotaAndHistoryUseSameExplicitOrEnvironmentHome() throws {
        let home = URL(fileURLWithPath: "/synthetic/home", isDirectory: true)
        #expect(try UsageAccountDiscovery.configDirectory(for: .claude, homeDirectory: home, environment: [:]).path == "/synthetic/home/.claude")
        #expect(try UsageAccountDiscovery.configDirectory(for: .codex, homeDirectory: home, environment: ["CODEX_HOME": "~/work-codex"]).path == "/synthetic/home/work-codex")
        #expect(try UsageAccountDiscovery.configDirectory(for: .claude, homeDirectory: home, environment: ["CLAUDE_CONFIG_DIR": "/configured/claude"]).path == "/configured/claude")
        let explicit = UsageAccount(id: "explicit", provider: .codex, label: "Custom", directory: "/selected/home")
        #expect(try UsageAccountDiscovery.configDirectory(for: explicit, homeDirectory: home, environment: ["CODEX_HOME": "/ignored"]).path == "/selected/home")
        for invalid in ["relative", "/one,/two", "/unsafe\0home"] {
            #expect(throws: UsageDataFailure.self) {
                try UsageAccountDiscovery.configDirectory(for: .claude, homeDirectory: home, environment: ["CLAUDE_CONFIG_DIR": invalid])
            }
        }
    }

    private func temporaryHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func save(_ text: String, at file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func json(_ text: String) -> String {
        let encoded = try! JSONEncoder().encode(text)
        return String(decoding: encoded, as: UTF8.self)
    }

    private func claudeSlot(email: String = "person@example.com", organization: String = "Work") -> String {
        "{\"email\":\(json(email)),\"uuid\":\(json(userID)),\"organizationUuid\":\(json(organizationID)),\"organizationName\":\(json(organization))}"
    }

    private func claudeSequence(email: String = "person@example.com", organization: String = "Work") -> String {
        "{\"sequence\":[1],\"accounts\":{\"1\":\(claudeSlot(email: email, organization: organization))}}"
    }

    private func codexSlot(number: Int, home: String, email: String? = "person@example.com", accountID: String = "workspace") -> String {
        let ownerEmail = email.map { json($0) } ?? "null"
        return "{\"number\":\(number),\"alias\":null,\"home\":\(json(home)),\"managed\":true,\"shareHistory\":false,\"enabled\":true,\"identity\":{\"accountId\":\(json(accountID)),\"email\":\(ownerEmail),\"plan\":\"pro\"}}"
    }

    private func codexRegistry(mainHome: String, entries: [String]) -> String {
        "{\"schemaVersion\":1,\"mainHome\":\(json(mainHome)),\"nextNumber\":12,\"default\":null,\"accounts\":[\(entries.joined(separator: ","))]}"
    }
}
