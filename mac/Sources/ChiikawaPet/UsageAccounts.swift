import CryptoKit
import Foundation

struct UsageAccountDiscoveryResult: Sendable {
    let accounts: [UsageAccount]
    let warnings: [String]
}

struct ClaudeSwapRoute: Sendable {
    let root: URL
    let slot: String
    let email: String
    let sessionDirectory: URL

    var vaultCredentialFile: URL {
        root.appendingPathComponent("credentials/.creds-\(slot)-\(email).enc")
    }
    var keychainAccount: String { "account-\(slot)-\(email)" }
}

enum UsageAccountDiscovery {
    static func discover(
        includeSaved: Bool,
        additional: [UsageAccount],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [UsageAccount] {
        let result = discoverWithWarnings(includeSaved: includeSaved, additional: additional,
                                          homeDirectory: homeDirectory, environment: environment)
        return result.accounts
    }

    static func discoverWithWarnings(
        includeSaved: Bool,
        additional: [UsageAccount],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UsageAccountDiscoveryResult {
        var accounts = UsageAccount.defaults
        var warnings: [String] = []
        var identifiers = Set(accounts.map(\.id))
        for account in additional {
            if identifiers.insert(account.id).inserted {
                accounts.append(account)
            } else {
                warnings.append("An additional account has a duplicate identifier and was skipped.")
            }
        }
        if includeSaved {
            let claude = discoverClaude(homeDirectory: homeDirectory, warnings: &warnings)
            let codex = discoverCodex(homeDirectory: homeDirectory, environment: environment, warnings: &warnings)
            for account in claude + codex {
                if identifiers.insert(account.id).inserted {
                    accounts.append(account)
                } else {
                    warnings.append("A saved account has a duplicate identifier and was skipped.")
                }
            }
        }
        var uniqueWarnings: [String] = []
        for warning in warnings where !uniqueWarnings.contains(warning) {
            uniqueWarnings.append(warning)
        }
        return UsageAccountDiscoveryResult(accounts: accounts, warnings: uniqueWarnings)
    }

    static func claudeSwapRoute(
        for account: UsageAccount,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ClaudeSwapRoute? {
        let parts = account.id.split(separator: ":", omittingEmptySubsequences: false)
        guard account.provider == .claude, parts.count == 6, parts[0] == "claude-cswap",
              validSlot(String(parts[2])),
              let email = account.expectedEmail, validEmail(email),
              let userID = account.expectedAccountID, let user = UUID(uuidString: userID),
              let organizationID = account.expectedOrganizationID, let organization = UUID(uuidString: organizationID)
        else { return nil }
        let root = homeDirectory.appendingPathComponent(".claude-swap-backup", isDirectory: true)
        let route = claudeRoute(root: root, slot: String(parts[2]), email: email)
        let expectedID = claudeID(route: route, user: user, organization: organization)
        guard account.id == expectedID, account.directory == route.sessionDirectory.path else { return nil }
        return route
    }

    static func configDirectory(
        for account: UsageAccount,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let variable = account.provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        let override = account.directory ?? environment[variable]
        let raw = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else {
            return homeDirectory.appendingPathComponent(account.provider == .claude ? ".claude" : ".codex", isDirectory: true)
        }
        guard !raw.contains("\0"), account.provider != .claude || !raw.contains(",") else {
            throw UsageDataFailure.unsupportedConfigHome
        }
        let expanded = raw == "~" || raw.hasPrefix("~/") ? homeDirectory.path + raw.dropFirst() : raw
        guard expanded.hasPrefix("/") else { throw UsageDataFailure.unsupportedConfigHome }
        return URL(fileURLWithPath: String(expanded), isDirectory: true).standardizedFileURL
    }

    private static func discoverClaude(homeDirectory: URL, warnings: inout [String]) -> [UsageAccount] {
        let root = homeDirectory.appendingPathComponent(".claude-swap-backup", isDirectory: true)
        let sequenceFile = root.appendingPathComponent("sequence.json")
        guard let data = metadata(at: sequenceFile, source: "Claude Swap", warnings: &warnings) else { return [] }
        guard let sequence = try? JSONDecoder().decode(ClaudeSequence.self, from: data) else {
            warnings.append("Claude Swap account metadata is malformed; saved accounts were skipped.")
            return []
        }
        let slots = sequence.accounts.keys.sorted {
            if $0.count != $1.count { return $0.count < $1.count }
            return $0 < $1
        }
        var accounts: [UsageAccount] = []
        for slot in slots {
            guard validSlot(slot), let saved = sequence.accounts[slot]?.decoded,
                  saved.provider == nil || saved.provider == "claude",
                  saved.kind == nil || saved.kind == "oauth",
                  validEmail(saved.email),
                  let user = UUID(uuidString: saved.uuid),
                  let organization = UUID(uuidString: saved.organizationUuid) else {
                warnings.append("A Claude Swap slot has unsupported authentication or invalid slot, email, user, or organization metadata and was skipped.")
                continue
            }
            let route = claudeRoute(root: root, slot: slot, email: saved.email)
            let organizationName = displayLabel(saved.organizationName)
            let name = organizationName ?? "Organization \(organization.uuidString.lowercased().prefix(8))"
            let account = UsageAccount(
                id: claudeID(route: route, user: user, organization: organization),
                provider: .claude, label: "Claude: \(name) (\(saved.email))",
                directory: route.sessionDirectory.path, expectedEmail: saved.email,
                expectedOrganizationID: organization.uuidString.lowercased(),
                expectedAccountID: user.uuidString.lowercased(),
                keychainService: "Claude Code-credentials-\(digest(route.sessionDirectory.path.precomposedStringWithCanonicalMapping).prefix(8))")
            accounts.append(account)
            if saved.organizationName != nil && organizationName == nil {
                warnings.append("An invalid Claude Swap organization label was omitted.")
            }
        }
        return accounts
    }

    private static func discoverCodex(
        homeDirectory: URL, environment: [String: String], warnings: inout [String]
    ) -> [UsageAccount] {
        guard let root = codexRoot(homeDirectory: homeDirectory, environment: environment, warnings: &warnings) else { return [] }
        let registryFile = root.appendingPathComponent("accounts.json")
        guard let data = metadata(at: registryFile, source: "Codex Swap", warnings: &warnings) else { return [] }
        guard let registry = try? JSONDecoder().decode(CodexRegistry.self, from: data) else {
            warnings.append("Codex Swap account metadata is malformed; saved accounts were skipped.")
            return []
        }
        guard registry.schemaVersion == 1, validPath(registry.mainHome) else {
            warnings.append("Codex Swap registry has an unsupported version or unsafe main home; saved accounts were skipped.")
            return []
        }
        var numberCounts: [Int: Int] = [:]
        var homeCounts: [String: Int] = [:]
        for entry in registry.accounts {
            guard let saved = entry.decoded else { continue }
            numberCounts[saved.number, default: 0] += 1
            homeCounts[saved.home, default: 0] += 1
        }
        var accounts: [UsageAccount] = []
        let slots = registry.accounts.compactMap(\.decoded).sorted { $0.number < $1.number }
        if slots.count != registry.accounts.count {
            warnings.append("A malformed Codex Swap slot was skipped.")
        }
        for saved in slots {
            guard saved.number > 0, numberCounts[saved.number] == 1, homeCounts[saved.home] == 1,
                  validPath(saved.home), let identity = saved.identity,
                  validIdentityComponent(identity.accountId), let email = identity.email, validEmail(email) else {
                warnings.append("A Codex Swap slot has a duplicate slot or home, unsafe home, or incomplete account and email identity and was skipped.")
                continue
            }
            let alias = displayLabel(saved.alias)
            if saved.alias != nil && alias == nil {
                warnings.append("An invalid Codex Swap alias was omitted; aliases are labels only.")
            }
            let accountID = identity.accountId.lowercased()
            let normalizedEmail = email.lowercased()
            let identityDigest = digest(accountID + "|" + normalizedEmail)
            let id = "codex-xswap:\(digest(root.path)):\(saved.number):\(identityDigest)"
            let label = alias ?? "Workspace \(accountID.prefix(8))"
            accounts.append(UsageAccount(id: id, provider: .codex,
                                         label: "Codex: \(label) (\(normalizedEmail))", directory: saved.home,
                                         expectedEmail: normalizedEmail, expectedAccountID: accountID))
        }
        let defaultHome = environment["CODEX_HOME"] ?? homeDirectory.appendingPathComponent(".codex").path
        if registry.mainHome != defaultHome && !slots.contains(where: { $0.home == registry.mainHome }) {
            warnings.append("Codex Swap's custom main home has no saved account identity; add that home explicitly to use it.")
        }
        return accounts
    }

    private static func codexRoot(
        homeDirectory: URL, environment: [String: String], warnings: inout [String]
    ) -> URL? {
        if let configured = environment["XSWAP_HOME"], !configured.isEmpty {
            let expanded = configured.hasPrefix("~/") ? homeDirectory.path + String(configured.dropFirst()) : configured
            guard validPath(expanded) else {
                warnings.append("XSWAP_HOME is not a safe absolute directory; Codex Swap discovery was skipped.")
                return nil
            }
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        if let configured = environment["XDG_DATA_HOME"], !configured.isEmpty {
            if validPath(configured) {
                return URL(fileURLWithPath: configured, isDirectory: true).appendingPathComponent("codex-swap", isDirectory: true)
            }
            warnings.append("XDG_DATA_HOME is not a safe absolute directory; Codex Swap uses its default metadata location.")
        }
        return homeDirectory.appendingPathComponent(".local/share/codex-swap", isDirectory: true)
    }

    private static func metadata(at file: URL, source: String, warnings: inout [String]) -> Data? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                warnings.append("\(source) metadata is not a regular file; discovery was skipped.")
                return nil
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else {
                warnings.append("\(source) metadata exceeds the supported size; discovery was skipped.")
                return nil
            }
            return data
        } catch {
            let failure = error as NSError
            if failure.domain != NSCocoaErrorDomain
                || (failure.code != NSFileReadNoSuchFileError && failure.code != NSFileNoSuchFileError) {
                warnings.append("\(source) metadata could not be read; discovery was skipped.")
            }
            return nil
        }
    }

    private static func claudeRoute(root: URL, slot: String, email: String) -> ClaudeSwapRoute {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let slug = email.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            allowed.contains($0) ? String($0) : "_"
        }.joined()
        let session = root.appendingPathComponent("sessions/\(slot)-\(slug)", isDirectory: true)
        return ClaudeSwapRoute(root: root, slot: slot, email: email, sessionDirectory: session)
    }

    private static func claudeID(route: ClaudeSwapRoute, user: UUID, organization: UUID) -> String {
        "claude-cswap:\(digest(route.root.path)):\(route.slot):\(user.uuidString.lowercased()):\(organization.uuidString.lowercased()):\(digest(route.email))"
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validSlot(_ slot: String) -> Bool {
        guard !slot.isEmpty, slot.utf8.count <= 20 else { return false }
        return slot.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func validIdentityComponent(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 512 else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/\\|"))
        return text.rangeOfCharacter(from: forbidden) == nil
    }

    private static func validEmail(_ text: String) -> Bool {
        guard validIdentityComponent(text), text.utf8.count <= 254 else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
    }

    private static func validPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.contains("\\"),
              path.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return !components.contains("..") && !components.contains(".")
    }

    private static func displayLabel(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128,
              text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return trimmed
    }

    private struct DecodedEntry<Entry: Decodable>: Decodable {
        let decoded: Entry?
        init(from decoder: Decoder) throws { decoded = try? Entry(from: decoder) }
    }

    // Metadata contracts: OpenUsage 26132ff ClaudeSwapAccount/CodexSwapAccount;
    // claude-swap 4351e3c and claudeswitch 7586506 session.py/switcher.py; codex-swap 8afa275 store.rs/auth.rs.
    private struct ClaudeSequence: Decodable {
        let accounts: [String: DecodedEntry<ClaudeSlot>]
    }
    private struct ClaudeSlot: Decodable {
        let email: String
        let uuid: String
        let organizationUuid: String
        let organizationName: String?
        let provider: String?
        let kind: String?
    }
    private struct CodexRegistry: Decodable {
        let schemaVersion: Int
        let mainHome: String
        let accounts: [DecodedEntry<CodexSlot>]
    }
    private struct CodexSlot: Decodable {
        let number: Int
        let alias: String?
        let home: String
        let identity: CodexIdentity?
    }
    private struct CodexIdentity: Decodable {
        let accountId: String
        let email: String?
    }
}
