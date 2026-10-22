import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

actor UsageClient: UsageFetching {
    private let session: URLSession
    private let homeDirectory: URL
    private let environment: [String: String]
    private var verifiedClaudeAccounts: [String: VerifiedClaudeAccount] = [:]
    private var cooldowns: [String: Date] = [:]
    private var resetGrants: [String: ResetGrantSample] = [:]
    private var displayedIdentities: [String: UsageIdentityBinding] = [:]
    private let snapshots: UsageSnapshotCache
    private let clock: @Sendable () -> Date
    private let keychainReader: (@Sendable (String, String?, Bool) throws -> Data?)?
    private let securityReader: (@Sendable (String) -> Data?)?

    init(session: URLSession? = nil,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         cacheDirectory: URL? = nil,
         clock: @escaping @Sendable () -> Date = { Date() },
         keychainReader: (@Sendable (String, String?, Bool) throws -> Data?)? = nil,
         securityReader: (@Sendable (String) -> Data?)? = nil) {
        self.clock = clock
        self.keychainReader = keychainReader
        self.securityReader = securityReader
        let storage = cacheDirectory ?? homeDirectory.appendingPathComponent("Library/Application Support/ChiikawaAgentPet/UsageSnapshots")
        snapshots = UsageSnapshotCache(directory: storage)
        self.homeDirectory = homeDirectory
        self.environment = environment
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func cached(_ account: UsageAccount) async -> UsageReading? {
        guard let candidates = try? credentials(for: account, allowPrompt: false, strict: true) else { return nil }
        for candidate in candidates {
            if candidate.localFailure != nil { continue }
            if let reading = snapshots.load(account: account, fingerprint: candidate.fingerprint, now: clock()) {
                displayedIdentities[account.id] = UsageIdentityBinding(fingerprint: candidate.fingerprint, identity: candidate.identityKey)
                return reading
            }
            if account.expectedAccountID == nil { break }
        }
        return nil
    }

    func fetch(_ account: UsageAccount, allowKeychainPrompt: Bool) async throws -> UsageReading {
        let candidates: [UsageCredential]
        do { candidates = try credentials(for: account, allowPrompt: allowKeychainPrompt) }
        catch let failure as CredentialSourceFailure {
            let previous = displayedIdentities[account.id]
            var observation = failure.observation
            if account.provider == .claude, let verified = verifiedClaudeAccounts[observation.fingerprint] {
                observation = UsageIdentityBinding(fingerprint: observation.fingerprint, identity: verified.identityKey)
            }
            if observation.changed(from: previous) { throw UsageFailure.accountChanged(nil) }
            throw failure.reason
        }
        catch {
            if displayedIdentities[account.id] != nil, case UsageFailure.loginRequired = error { throw UsageFailure.accountChanged(nil) }
            throw error
        }
        let previous = displayedIdentities[account.id]
        var observedChange = false
        var failure: Error = UsageFailure.loginRequired(account.provider)
        let pinned = account.expectedAccountID != nil || account.expectedOrganizationID != nil || account.expectedEmail != nil
        for (index, candidate) in candidates.enumerated() {
            if index > 0, !pinned { break }
            let key = cooldownKey(provider: account.provider, credential: candidate)
            let knownProfileIdentity = account.provider == .claude ? verifiedClaudeAccounts[candidate.fingerprint]?.identityKey : nil
            let knownIdentity = candidate.identityKey ?? knownProfileIdentity
            var binding = UsageIdentityBinding(fingerprint: candidate.fingerprint, identity: knownIdentity)
            observedChange = binding.changed(from: previous)
            if let until = cooldowns[key], until > clock() {
                if observedChange { throw UsageFailure.accountChanged(until) }
                throw UsageFailure.cooldown(until)
            }
            do {
                if let failure = candidate.localFailure { throw failure }
                var reading: UsageReading
                if account.provider == .claude {
                    let profile = await verifyClaudeAccount(candidate, cooldownKey: key)
                    binding = UsageIdentityBinding(fingerprint: candidate.fingerprint, identity: profile?.identityKey)
                    observedChange = binding.changed(from: previous)
                    if let until = cooldowns[key], until > clock() { throw UsageFailure.cooldown(until) }
                    try Self.validate(account, profile: profile)
                    reading = try await fetchClaudeUsage(candidate, profile: profile, cooldownKey: key)
                    reading.accountLabel = profile?.email
                    reading.plan = profile?.plan
                } else {
                    try Self.validate(account, credential: candidate)
                    var request = makeRequest(url: "https://chatgpt.com/backend-api/wham/usage", token: candidate.token)
                    request.setValue(candidate.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
                    request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
                    request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
                    let data = try await usageData(for: request, provider: .codex, cooldownKey: key)
                    reading = try Self.decodeCodex(data, now: clock())
                    reading.accountLabel = candidate.email
                }
                let current: [UsageCredential]
                do { current = try credentials(for: account, allowPrompt: false) }
                catch let failure as CredentialSourceFailure {
                    if failure.observation.changed(from: binding) { throw UsageFailure.accountChanged(nil) }
                    throw failure.reason
                }
                guard current.map(\.generation) == candidates.map(\.generation) else {
                    throw UsageFailure.accountChanged(nil)
                }
                reading.accountID = account.id
                reading.accountIdentity = binding.identity.map {
                    Self.fingerprint(Data((account.provider.rawValue + "\0" + $0).utf8))
                }
                reading.authSource = candidate.authSource
                reading.credentialFingerprint = candidate.fingerprint
                reading.retryAt = cooldowns[key].flatMap { $0 > clock() ? $0 : nil }
                try? snapshots.save(reading, account: account, fingerprint: candidate.fingerprint, now: clock())
                displayedIdentities[account.id] = binding
                return reading
            } catch UsageFailure.cooldown(let until) {
                if observedChange { throw UsageFailure.accountChanged(until) }
                throw UsageFailure.cooldown(until)
            } catch UsageFailure.identityMismatch {
                failure = UsageFailure.identityMismatch
            } catch {
                failure = error
            }
        }
        if observedChange, !pinned { throw UsageFailure.accountChanged(nil) }
        throw failure
    }

    private func cooldownKey(provider: UsageProvider, credential: UsageCredential) -> String {
        provider.rawValue + ":" + credential.tokenFingerprint
    }

    private func usageData(for request: URLRequest, provider: UsageProvider, cooldownKey: String? = nil) async throws -> Data {
        if let key = cooldownKey, let until = cooldowns[key], until > clock() { throw UsageFailure.cooldown(until) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageFailure.invalidResponse }
        switch response.statusCode {
        case 200...299: return data
        case 401, 403: throw UsageFailure.unauthorized(provider)
        case 429:
            let until = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: clock())
            if let key = cooldownKey { cooldowns[key] = until }
            throw UsageFailure.cooldown(until)
        default: throw UsageFailure.http(response.statusCode)
        }
    }

    nonisolated static func retryDate(_ header: String?, now: Date) -> Date {
        let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var delay: TimeInterval?
        if let seconds = Double(raw), seconds.isFinite, seconds > 0 { delay = seconds }
        if delay == nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
            if let date = formatter.date(from: raw), date > now { delay = date.timeIntervalSince(now) }
        }
        return now.addingTimeInterval(max(1, delay ?? 120))
    }


    private func fetchClaudeUsage(_ candidate: UsageCredential, profile: VerifiedClaudeAccount?, cooldownKey: String) async throws -> UsageReading {
        if let until = cooldowns[cooldownKey], until > clock() { throw UsageFailure.cooldown(until) }
        if candidate.useSwapCache, let profile, let cache = swapCache(),
           let reading = cache.reading(email: profile.email, organizationUUID: profile.organizationUUID, now: clock()),
           clock().timeIntervalSince(reading.fetchedAt) < 900 {
            return reading
        }
        let request = makeRequest(url: "https://api.anthropic.com/api/oauth/usage", token: candidate.token)
        do {
            let data = try await usageData(for: request, provider: .claude, cooldownKey: cooldownKey)
            var reading = try Self.decodeClaude(data, now: clock())
            if !reading.extras.contains(where: { $0.id == "reset-credits" }) {
                reading.extras += await claudeResetExtras(candidate, cooldownKey: cooldownKey)
            }
            return reading
        } catch UsageFailure.cooldown(let until) {
            if candidate.useSwapCache, let profile, let cache = swapCache(),
               var reading = cache.reading(email: profile.email, organizationUUID: profile.organizationUUID, now: clock()) {
                reading.retryAt = until
                return reading
            }
            throw UsageFailure.cooldown(until)
        }
    }

    private func claudeResetExtras(_ candidate: UsageCredential, cooldownKey: String) async -> [UsageExtra] {
        let fingerprint = candidate.fingerprint
        if let previous = resetGrants[fingerprint], clock().timeIntervalSince(previous.attemptedAt) < 3_600 {
            guard let grants = previous.grants else { return [] }
            return (try? Self.resetExtras(grants, now: clock())) ?? []
        }
        resetGrants[fingerprint] = ResetGrantSample(attemptedAt: clock(), grants: resetGrants[fingerprint]?.grants)
        let request = makeRequest(url: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1", token: candidate.token)
        do {
            let data = try await usageData(for: request, provider: .claude, cooldownKey: cooldownKey)
            let payload = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            resetGrants[fingerprint] = ResetGrantSample(attemptedAt: clock(), grants: payload.cedarEmber)
        } catch {}
        guard let grants = resetGrants[fingerprint]?.grants else { return [] }
        return (try? Self.resetExtras(grants, now: clock())) ?? []
    }

    private func swapCache() -> ClaudeSwapCache? {
        let path = homeDirectory.appendingPathComponent(".claude-swap-backup/cache/usage.json")
        guard let data = try? Data(contentsOf: path),
              let cache = try? JSONDecoder().decode(ClaudeSwapCache.self, from: data),
              cache.schemaVersion == 2, cache.accounts.values.contains(where: { $0.lastGood != nil }) else { return nil }
        return cache
    }

    private func verifyClaudeAccount(_ candidate: UsageCredential, cooldownKey: String) async -> VerifiedClaudeAccount? {
        let fingerprint = candidate.fingerprint
        if let account = verifiedClaudeAccounts[fingerprint] { return account }
        let request = makeRequest(url: "https://api.anthropic.com/api/oauth/profile", token: candidate.token)
        do {
            let data = try await usageData(for: request, provider: .claude, cooldownKey: cooldownKey)
            let profile = try JSONDecoder().decode(ClaudeProfile.self, from: data)
            guard let uuid = profile.account?.uuid, Self.validMetadata(uuid),
                  let organizationUUID = profile.organization?.uuid, Self.validMetadata(organizationUUID) else { return nil }
            let email = profile.account?.email.flatMap { Self.validMetadata($0) ? $0 : nil }
            let account = VerifiedClaudeAccount(uuid: uuid, email: email, organizationUUID: organizationUUID,
                                                plan: profile.organization?.organizationType ?? profile.organization?.rateLimitTier)
            verifiedClaudeAccounts[fingerprint] = account
            return account
        } catch { return nil }
    }

    private nonisolated static func validate(_ account: UsageAccount, profile: VerifiedClaudeAccount?) throws {
        if account.expectedAccountID != nil || account.expectedOrganizationID != nil || account.expectedEmail != nil {
            guard profile != nil else { throw UsageDataFailure.identityUnavailable }
        }
        if let expected = account.expectedAccountID, profile?.uuid.caseInsensitiveCompare(expected) != .orderedSame { throw UsageFailure.identityMismatch }
        if let expected = account.expectedOrganizationID, profile?.organizationUUID.caseInsensitiveCompare(expected) != .orderedSame { throw UsageFailure.identityMismatch }
        if account.expectedEmail != nil, profile?.email == nil, account.expectedAccountID == nil { throw UsageDataFailure.identityUnavailable }
        if let expected = account.expectedEmail, let email = profile?.email,
           email.caseInsensitiveCompare(expected) != .orderedSame { throw UsageFailure.identityMismatch }
    }

    private nonisolated static func validate(_ account: UsageAccount, credential: UsageCredential) throws {
        if account.expectedAccountID != nil, !credential.tokenBoundIdentity { throw UsageDataFailure.identityUnavailable }
        if let expected = account.expectedAccountID, credential.accountID?.caseInsensitiveCompare(expected) != .orderedSame { throw UsageFailure.identityMismatch }
        if let expected = account.expectedEmail, credential.email?.caseInsensitiveCompare(expected) != .orderedSame { throw UsageFailure.identityMismatch }
    }

    nonisolated static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func validMetadata(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 200 && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private func makeRequest(url: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if url.hasPrefix("https://api.anthropic.com/api/oauth/") {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-cli/2.1.294 (external, cli)", forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        }
        return request
    }


    private func credentialFile(_ path: URL) throws -> Data? {
        do {
            return try Data(contentsOf: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch { throw UsageFailure.invalidResponse }
    }

    private func credentials(for account: UsageAccount, allowPrompt: Bool, strict: Bool = false) throws -> [UsageCredential] {
        var candidates: [UsageCredential] = []
        var lastError: Error = UsageFailure.loginRequired(account.provider)
        let pinned = account.expectedAccountID != nil || account.expectedOrganizationID != nil || account.expectedEmail != nil
        let directory = try UsageAccountDiscovery.configDirectory(for: account, homeDirectory: homeDirectory, environment: environment)
        let swap = UsageAccountDiscovery.claudeSwapRoute(for: account, homeDirectory: homeDirectory)
        if account.id.hasPrefix("claude-cswap:"), swap == nil { throw UsageFailure.identityMismatch }
        if swap != nil, let defaults = try? credentials(for: .claude, allowPrompt: allowPrompt, strict: strict) {
            candidates += defaults
        }
        if account.provider == .claude {
            let defaultDirectory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
            let isDefault = directory.standardizedFileURL == defaultDirectory.standardizedFileURL
            let override = account.directory ?? environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let service = override.flatMap { $0.isEmpty ? nil : $0 }.map(Self.claudeKeychainService) ?? "Claude Code-credentials"
            guard account.keychainService == nil || account.keychainService == service else { throw UsageFailure.identityMismatch }
            do {
                let output: Data?
                if let securityReader { output = securityReader(service) }
                else { output = Self.claudeSecurityOutput(service: service) }
                let document: Data?
                if let output {
                    guard let decoded = Self.claudeCredentialData(fromSecurityOutput: output) else {
                        throw Self.sourceFailure(.loginRequired(.claude), document: output)
                    }
                    document = decoded
                } else {
                    document = try keychainCredential(service: service, account: nil, allowPrompt: allowPrompt)
                }
                if let document {
                    var credential = try Self.claudeSource(document, now: clock())
                    credential.sourceID = "keychain:" + service
                    credential.authSource = swap == nil ? "Claude Code keychain" : "Claude Swap session keychain"
                    credential.useSwapCache = isDefault
                    candidates.append(credential)
                    if !pinned { return candidates }
                }
            } catch {
                if !pinned || strict { throw error }
                lastError = error
            }
        }
        let file = directory.appendingPathComponent(account.provider == .claude ? ".credentials.json" : "auth.json")
        do {
            if let document = try credentialFile(file) {
                var credential: UsageCredential
                if account.provider == .claude {
                    credential = try Self.claudeSource(document, now: clock())
                    credential.authSource = swap == nil ? "Claude credential file" : "Claude Swap session file"
                } else {
                    credential = try Self.codexSource(document, now: clock())
                    credential.authSource = account.id.hasPrefix("codex-xswap:") ? "Codex Swap auth file" : "Codex auth file"
                }
                credential.sourceID = file.path
                candidates.append(credential)
                if !pinned { return candidates }
                if account.provider == .codex, credential.localFailure == nil {
                    do {
                        try Self.validate(account, credential: credential)
                        return candidates
                    } catch { lastError = error }
                }
            }
        } catch {
            if !pinned { throw error }
            lastError = error
        }
        if let swap {
            do {
                if let encoded = try credentialFile(swap.vaultCredentialFile) {
                    guard let text = String(data: encoded, encoding: .utf8),
                          let document = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw Self.sourceFailure(.loginRequired(.claude), document: encoded)
                    }
                    var credential = try Self.claudeSource(document, now: clock())
                    credential.sourceID = swap.vaultCredentialFile.path
                    credential.authSource = "Claude Swap vault file"
                    candidates.append(credential)
                }
            } catch { lastError = error }
            do {
                if let document = try keychainCredential(service: "claude-swap", account: swap.keychainAccount, allowPrompt: allowPrompt) {
                    var credential = try Self.claudeSource(document, now: clock())
                    credential.sourceID = "vault:" + swap.keychainAccount
                    credential.authSource = "Claude Swap vault keychain"
                    candidates.append(credential)
                }
            } catch { lastError = error }
        } else if account.provider == .codex {
            do {
                let canonical = directory.resolvingSymlinksInPath().standardizedFileURL.path
                let key = "cli|" + Self.fingerprint(Data(canonical.utf8)).prefix(16)
                if let document = try keychainCredential(service: "Codex Auth", account: key, allowPrompt: allowPrompt) {
                    var credential = try Self.codexSource(document, now: clock())
                    credential.sourceID = "keychain:" + key
                    credential.authSource = "Codex home keychain"
                    candidates.append(credential)
                }
            } catch {
                if !pinned || strict { throw error }
                lastError = error
            }
        }
        if candidates.isEmpty {
            if let failure = lastError as? CredentialSourceFailure { lastError = failure.reason }
            if account.id.hasPrefix("claude-cswap:") || account.id.hasPrefix("codex-xswap:") {
                switch lastError {
                case UsageFailure.loginRequired, UsageFailure.unauthorized: throw UsageDataFailure.savedLoginRequired(account.provider)
                default: break
                }
            }
            throw lastError
        }
        return candidates
    }

    private nonisolated static func claudeKeychainService(_ path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        return "Claude Code-credentials-" + fingerprint(Data(normalized.utf8)).prefix(8)
    }

    private nonisolated static func claudeSecurityOutput(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() }
        catch { return nil }

        // security has no no-UI flag; a locked/untrusted item must not stall automatic refresh.
        let deadline = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        defer {
            deadline.cancel()
            try? output.fileHandleForReading.close()
        }
        let data = try? output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let data, !data.isEmpty else { return nil }
        return data
    }

    nonisolated static func claudeToken(fromSecurityOutput output: Data) throws -> String? {
        guard let document = claudeCredentialData(fromSecurityOutput: output) else { return nil }
        return try parseClaudeCredential(document)
    }

    private nonisolated static func claudeCredentialData(fromSecurityOutput output: Data) -> Data? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "{" {
            return output
        }
        // security -w hex-encodes passwords containing nonprintable bytes, including JSON newlines.
        func hexDigit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var hexadecimal = trimmed.utf8.makeIterator()
        var decoded = Data(capacity: trimmed.utf8.count / 2)
        while let highByte = hexadecimal.next() {
            guard let high = hexDigit(highByte), let lowByte = hexadecimal.next(),
                  let low = hexDigit(lowByte) else { return nil }
            decoded.append(high * 16 + low)
        }
        return decoded
    }

    private nonisolated static func parseClaudeCredential(_ data: Data) throws -> String? {
        guard let credential = try parseClaudeAccess(data, now: Date()) else { return nil }
        if let failure = credential.localFailure { throw failure }
        return credential.token
    }

    private nonisolated static func parseClaudeAccess(_ data: Data, now: Date) throws -> UsageCredential? {
        let credentials: ClaudeCredentials
        do { credentials = try JSONDecoder().decode(ClaudeCredentials.self, from: data) }
        catch { throw UsageFailure.loginRequired(.claude) }
        guard let oauth = credentials.claudeAiOauth, let token = oauth.accessToken, validHeader(token) else { return nil }
        var failure: UsageFailure?
        if let expiresAt = oauth.expiresAt, !expiresAt.isFinite || expiresAt <= now.timeIntervalSince1970 * 1_000 {
            failure = .unauthorized(.claude)
        }
        return UsageCredential(token: token, sourceID: "", authSource: "", localFailure: failure)
    }

    private nonisolated static func claudeSource(_ document: Data, now: Date) throws -> UsageCredential {
        do {
            guard let credential = try parseClaudeAccess(document, now: now) else {
                throw UsageFailure.loginRequired(.claude)
            }
            return credential
        } catch let reason as UsageFailure { throw sourceFailure(reason, document: document) }
    }

    private nonisolated static func codexSource(_ document: Data, now: Date) throws -> UsageCredential {
        do {
            guard let credential = try parseCodexCredential(document, now: now) else {
                throw UsageFailure.loginRequired(.codex)
            }
            return credential
        } catch let reason as UsageFailure { throw sourceFailure(reason, document: document) }
    }

    private nonisolated static func sourceFailure(_ reason: UsageFailure, document: Data) -> CredentialSourceFailure {
        CredentialSourceFailure(reason: reason, observation: UsageIdentityBinding(fingerprint: fingerprint(document), identity: nil))
    }

    private nonisolated static func parseCodexCredential(_ data: Data, now: Date) throws -> UsageCredential? {
        let credentials: CodexCredentials
        do { credentials = try JSONDecoder().decode(CodexCredentials.self, from: data) }
        catch { throw UsageFailure.loginRequired(.codex) }
        if credentials.authMode == "apikey" { throw UsageFailure.apiKeyMode }
        if let tokens = credentials.tokens, let accessToken = tokens.accessToken, validHeader(accessToken) {
            let claims = Self.codexClaims(accessToken)
            let failure: UsageFailure?
            if let expiry = claims?.exp, !expiry.isFinite || expiry <= now.timeIntervalSince1970 { failure = .unauthorized(.codex) }
            else { failure = nil }
            let claimID = claims?.auth?.accountID ?? claims?.accountID
            if let stored = tokens.accountID, let claimID, stored.caseInsensitiveCompare(claimID) != .orderedSame { throw UsageFailure.identityMismatch }
            guard let accountID = claimID ?? tokens.accountID, validHeader(accountID) else { throw UsageFailure.loginRequired(.codex) }
            let email = claims?.profile?.email ?? claims?.email
            return UsageCredential(token: accessToken, sourceID: "", authSource: "", accountID: accountID,
                                   email: email.flatMap { validMetadata($0) ? $0 : nil }, tokenBoundIdentity: claimID != nil, localFailure: failure)
        }
        if let apiKey = credentials.openAIAPIKey, !apiKey.isEmpty { throw UsageFailure.apiKeyMode }
        return nil
    }

    private nonisolated static func codexClaims(_ token: String) -> CodexTokenClaims? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(CodexTokenClaims.self, from: data)
    }

    private static func validHeader(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }

    private func keychainCredential(service: String, account: String?, allowPrompt: Bool) throws -> Data? {
        if let keychainReader { return try keychainReader(service, account, allowPrompt) }
        // CLI credentials use legacy ACLs; LAContext alone can still wait for authorization.
        var interactionWasAllowed = DarwinBoolean(true)
        if !allowPrompt {
            guard SecKeychainGetUserInteractionAllowed(&interactionWasAllowed) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                throw UsageFailure.keychainDenied
            }
        }
        defer {
            if !allowPrompt { SecKeychainSetUserInteractionAllowed(interactionWasAllowed.boolValue) }
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if allowPrompt {
            query[kSecUseAuthenticationContext as String] = LAContext()
        } else {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw UsageFailure.keychainDenied }
        guard let data = result as? Data else { throw UsageFailure.invalidResponse }
        return data
    }

    // These usage endpoints have published observed contracts, not stable official API guarantees.
    nonisolated static func decodeClaude(_ data: Data, now: Date) throws -> UsageReading {
        let payload: ClaudeUsageResponse
        do { payload = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data) }
        catch { throw UsageFailure.invalidResponse }
        var windows: [QuotaWindow] = []
        let candidates: [(String, String, ClaudeUsageWindow?, TimeInterval)] = [
            ("5시간", "session", payload.fiveHour, 18_000), ("주간", "weekly", payload.sevenDay, 604_800),
            ("Sonnet 주간", "model:sonnet:weekly", payload.sevenDaySonnet, 604_800),
            ("Opus 주간", "model:opus:weekly", payload.sevenDayOpus, 604_800)
        ]
        for (title, id, measured, duration) in candidates {
            guard let measured, let usedPercent = measured.utilization else { continue }
            let resetsAt = try measured.resetsAt?.date()
            windows.append(try QuotaWindow(title: title, usedPercent: usedPercent, resetsAt: resetsAt, id: id, durationSeconds: duration))
        }
        for entry in payload.limits ?? [] where entry?.kind == "weekly_scoped" {
            guard let entry, let name = entry.scope?.model?.displayName, validMetadata(name), let percent = entry.percent else { continue }
            let id = "model:\(name.lowercased()):weekly"
            let reset = try entry.resetsAt?.date()
            let window = try QuotaWindow(title: "\(name) 주간", usedPercent: percent, resetsAt: reset, id: id, durationSeconds: 604_800)
            windows.removeAll { $0.id == id }
            windows.append(window)
        }
        guard !windows.isEmpty else { throw UsageFailure.invalidResponse }
        var reading = UsageReading(provider: .claude, windows: windows, fetchedAt: now)
        if let extra = payload.extraUsage, extra.isEnabled == true, let used = extra.usedCredits {
            guard used.isFinite, used >= 0, extra.monthlyLimit.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw UsageFailure.invalidResponse }
            reading.extras.append(UsageExtra(id: "extra-spend", title: "추가 사용", amount: used / 100, unit: "USD", limit: extra.monthlyLimit.flatMap { $0 > 0 ? $0 / 100 : nil }))
        }
        if let grants = payload.cedarEmber {
            reading.extras += try resetExtras(grants, now: now)
        }
        return reading
    }

    nonisolated static func decodeCodex(_ data: Data, now: Date) throws -> UsageReading {
        let payload: CodexUsageResponse
        do { payload = try JSONDecoder().decode(CodexUsageResponse.self, from: data) }
        catch { throw UsageFailure.invalidResponse }
        var windows: [QuotaWindow] = []
        if let limits = payload.rateLimit { windows += try codexWindows(limits, model: nil, now: now) }
        for additional in payload.additionalRateLimits ?? [] {
            guard let additional, let name = additional.limitName ?? additional.meteredFeature, validMetadata(name),
                  let limits = additional.rateLimit else { continue }
            windows += try codexWindows(limits, model: name, now: now)
        }
        guard !windows.isEmpty, Set(windows.map(\.id)).count == windows.count else { throw UsageFailure.invalidResponse }
        var reading = UsageReading(provider: .codex, windows: windows, fetchedAt: now)
        reading.plan = payload.planType.flatMap { validMetadata($0) ? $0 : nil }
        if let credits = payload.credits {
            let balance = credits.balance?.number ?? (credits.hasCredits == false ? 0 : nil)
            if let balance {
                guard balance.isFinite, balance >= 0 else { throw UsageFailure.invalidResponse }
                reading.extras.append(UsageExtra(id: "flex-credits", title: "추가 크레딧", amount: balance, unit: "credits"))
            }
        }
        if let count = payload.resetCredits?.availableCount {
            guard count.isFinite, count >= 0 else { throw UsageFailure.invalidResponse }
            reading.extras.append(UsageExtra(id: "reset-credits", title: "사용량 초기화", amount: count.rounded(.down), unit: "count"))
        }
        return reading
    }

    private nonisolated static func codexWindows(_ rateLimit: CodexRateLimit, model: String?, now: Date) throws -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        for (index, measured) in [rateLimit.primaryWindow, rateLimit.secondaryWindow].enumerated() {
            guard let measured, let percent = measured.usedPercent else { continue }
            let duration = measured.limitWindowSeconds
            if let duration, duration <= 0 { throw UsageFailure.invalidResponse }
            let kind = duration == 604_800 ? "weekly" : duration == 18_000 ? "session" : (index == 0 ? "session" : "weekly")
            let title: String
            if let duration {
                if duration == 604_800 { title = "주간" }
                else if duration % 86_400 == 0 { title = "\(duration / 86_400)일 한도" }
                else if duration % 3_600 == 0 { title = "\(duration / 3_600)시간" }
                else { title = "\(duration)초 한도" }
            } else { title = index == 0 ? "첫 번째 한도" : "두 번째 한도" }
            var reset: Date?
            if let timestamp = measured.resetAt {
                guard timestamp.isFinite, timestamp >= 0 else { throw UsageFailure.invalidResponse }
                reset = Date(timeIntervalSince1970: timestamp)
            } else if let seconds = measured.resetAfterSeconds {
                guard seconds.isFinite, seconds >= 0 else { throw UsageFailure.invalidResponse }
                reset = now.addingTimeInterval(seconds)
            }
            let id = model.map { "model:\($0.lowercased()):\(kind)" } ?? kind
            windows.append(try QuotaWindow(title: model.map { "\($0) \(title)" } ?? title, usedPercent: percent,
                resetsAt: reset, id: id, durationSeconds: duration.map(Double.init)))
        }
        return windows
    }

    private nonisolated static func resetExtras(_ grants: ClaudeResetGrants, now: Date) throws -> [UsageExtra] {
        guard let eligible = grants.eligible, !eligible || grants.grants != nil else { throw UsageFailure.invalidResponse }
        var count = 0.0
        for grant in grants.grants ?? [] {
            guard !grant.id.isEmpty, grant.resetsLeft.isFinite, grant.resetsLeft >= 0 else { throw UsageFailure.invalidResponse }
            let end = try grant.endsAt?.date()
            if eligible, end.map({ $0 > now }) ?? true { count += grant.resetsLeft.rounded(.down) }
        }
        guard count.isFinite else { throw UsageFailure.invalidResponse }
        return [UsageExtra(id: "reset-credits", title: "사용량 초기화", amount: count, unit: "count")]
    }

    fileprivate nonisolated static func parseReset(_ text: String?) throws -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { throw UsageFailure.invalidResponse }
        return date
    }
}

private struct UsageCredential {
    let token: String
    var sourceID: String
    var authSource: String
    var useSwapCache: Bool
    let accountID: String?
    let email: String?
    let tokenBoundIdentity: Bool
    let fingerprint: String
    let tokenFingerprint: String
    let localFailure: UsageFailure?

    init(token: String, sourceID: String, authSource: String, useSwapCache: Bool = false,
         accountID: String? = nil, email: String? = nil, tokenBoundIdentity: Bool = false, localFailure: UsageFailure? = nil) {
        self.token = token
        self.sourceID = sourceID
        self.authSource = authSource
        self.useSwapCache = useSwapCache
        self.accountID = accountID
        self.email = email
        self.tokenBoundIdentity = tokenBoundIdentity
        self.localFailure = localFailure
        let tokenFingerprint = UsageClient.fingerprint(Data(token.utf8))
        self.tokenFingerprint = tokenFingerprint
        if let accountID {
            let material = token + "\0" + accountID.lowercased()
            self.fingerprint = UsageClient.fingerprint(Data(material.utf8))
        } else {
            self.fingerprint = tokenFingerprint
        }
    }
    var generation: String { sourceID + ":" + fingerprint }
    var identityKey: String? {
        guard tokenBoundIdentity, let accountID, let email else { return nil }
        return accountID.lowercased() + "|" + email.lowercased()
    }
}

private struct VerifiedClaudeAccount {
    let uuid: String
    let email: String?
    let organizationUUID: String
    let plan: String?
    var identityKey: String { uuid.lowercased() + "|" + organizationUUID.lowercased() }
}

private struct ClaudeProfile: Decodable {
    let account: Account?
    let organization: Organization?
    struct Account: Decodable {
        let uuid: String?
        let email: String?
    }
    struct Organization: Decodable {
        let uuid: String?
        let organizationType: String?
        let rateLimitTier: String?
        enum CodingKeys: String, CodingKey {
            case uuid
            case organizationType = "organization_type"
            case rateLimitTier = "rate_limit_tier"
        }
    }
}

struct ClaudeSwapCache: Decodable {
    let schemaVersion: Int
    fileprivate let accounts: [String: Account]

    func reading(email: String?, organizationUUID: String, now: Date) -> UsageReading? {
        guard schemaVersion == 2, let email, !email.isEmpty, !organizationUUID.isEmpty else { return nil }
        var matching: Account?
        for account in accounts.values where account.email == email && account.organizationUuid == organizationUUID {
            guard matching == nil else { return nil }
            matching = account
        }
        guard let account = matching, let fetchedAt = account.fetchedAt, fetchedAt.isFinite,
              let usage = account.lastGood else { return nil }
        let measuredAt = Date(timeIntervalSince1970: fetchedAt)
        let age = now.timeIntervalSince(measuredAt)
        guard age >= 0, age <= 60 * 60 else { return nil }
        var candidates: [(String, Window?)] = [("5시간", usage.fiveHour), ("주간", usage.sevenDay)]
        for window in usage.scoped ?? [] {
            guard let name = window.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            candidates.append(("\(name) 주간", window))
        }
        var windows: [QuotaWindow] = []
        do {
            for (title, measured) in candidates {
                guard let measured else { continue }
                let reset = try UsageClient.parseReset(measured.resetsAt)
                // Even a recent sample belongs to the previous window after a reset.
                if let reset, reset <= now { return nil }
                let id = title == "5시간" ? "session" : title == "주간" ? "weekly" : "model:\((measured.name ?? title).lowercased()):weekly"
                let window = try QuotaWindow(title: title, usedPercent: measured.pct, resetsAt: reset,
                                             id: id, durationSeconds: id == "session" ? 18_000 : 604_800)
                windows.append(window)
            }
        } catch {
            return nil
        }
        guard !windows.isEmpty else { return nil }
        var reading = UsageReading(provider: .claude, windows: windows, fetchedAt: measuredAt)
        reading.source = .swapCache
        return reading
    }

    fileprivate struct Account: Decodable {
        let email: String
        let organizationUuid: String
        let fetchedAt: Double?
        let lastGood: Usage?
    }
    fileprivate struct Usage: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let scoped: [Window]?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case scoped
        }
    }
    fileprivate struct Window: Decodable {
        let pct: Double
        let resetsAt: String?
        let name: String?
        enum CodingKeys: String, CodingKey {
            case pct, name
            case resetsAt = "resets_at"
        }
    }
}

private struct ClaudeCredentials: Decodable {
    let claudeAiOauth: OAuth?
    struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: Double?
    }
}

private struct CodexCredentials: Decodable {
    let authMode: String?
    let openAIAPIKey: String?
    let tokens: Tokens?
    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
    }
    struct Tokens: Decodable {
        let accessToken: String?
        let accountID: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}


private struct ClaudeUsageResponse: Decodable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
    let sevenDaySonnet: ClaudeUsageWindow?
    let sevenDayOpus: ClaudeUsageWindow?
    let limits: [ClaudeScopedLimit?]?
    let extraUsage: ClaudeExtraUsage?
    let cedarEmber: ClaudeResetGrants?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case limits
        case extraUsage = "extra_usage"
        case cedarEmber = "cedar_ember"
    }
}

private struct ClaudeUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: ProviderDate?
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct CodexUsageResponse: Decodable {
    let rateLimit: CodexRateLimit?
    let additionalRateLimits: [CodexAdditionalLimit?]?
    let planType: String?
    let credits: CodexCredits?
    let resetCredits: CodexResetCredits?
    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case planType = "plan_type"
        case credits
        case resetCredits = "rate_limit_reset_credits"
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?
    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexUsageWindow: Decodable {
    let usedPercent: Double?
    let limitWindowSeconds: Int?
    let resetAt: Double?
    let resetAfterSeconds: Double?
    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
        case resetAfterSeconds = "reset_after_seconds"
    }
}

private struct CodexTokenClaims: Decodable {
    let exp: Double?
    let email: String?
    let accountID: String?
    let auth: Auth?
    let profile: Profile?
    struct Auth: Decodable {
        let accountID: String?
        enum CodingKeys: String, CodingKey { case accountID = "chatgpt_account_id" }
    }
    struct Profile: Decodable { let email: String? }
    enum CodingKeys: String, CodingKey {
        case exp, email
        case accountID = "chatgpt_account_id"
        case auth = "https://api.openai.com/auth"
        case profile = "https://api.openai.com/profile"
    }
}

private struct ClaudeScopedLimit: Decodable {
    let kind: String?
    let percent: Double?
    let resetsAt: ProviderDate?
    let scope: Scope?
    struct Scope: Decodable { let model: Model? }
    struct Model: Decodable {
        let displayName: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }
    enum CodingKeys: String, CodingKey {
        case kind, percent, scope
        case resetsAt = "resets_at"
    }
}

private struct ClaudeExtraUsage: Decodable {
    let isEnabled: Bool?
    let usedCredits: Double?
    let monthlyLimit: Double?
    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
    }
}

private struct CodexAdditionalLimit: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: CodexRateLimit?
    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }
}

private struct CodexCredits: Decodable {
    let balance: DecimalAmount?
    let hasCredits: Bool?
    let unlimited: Bool?
    enum CodingKeys: String, CodingKey {
        case balance, unlimited
        case hasCredits = "has_credits"
    }
}

private struct CodexResetCredits: Decodable {
    let availableCount: Double?
    enum CodingKeys: String, CodingKey { case availableCount = "available_count" }
}

private struct DecimalAmount: Decodable {
    let number: Double
    init(from decoder: Decoder) throws {
        let scalar = try decoder.singleValueContainer()
        if let numeric = try? scalar.decode(Double.self) { number = numeric }
        else {
            let text = try scalar.decode(String.self)
            guard let numeric = Double(text), numeric.isFinite else { throw UsageFailure.invalidResponse }
            number = numeric
        }
    }
}

private struct ClaudeResetGrants: Decodable {
    let eligible: Bool?
    let grants: [Grant]?
    struct Grant: Decodable {
        let id: String
        let resetsLeft: Double
        let endsAt: ProviderDate?
        enum CodingKeys: String, CodingKey {
            case id
            case resetsLeft = "resets_left"
            case endsAt = "ends_at"
        }
    }
}

private enum ProviderDate: Decodable {
    case text(String), epoch(Double)
    init(from decoder: Decoder) throws {
        let scalar = try decoder.singleValueContainer()
        if let text = try? scalar.decode(String.self) { self = .text(text) }
        else { self = .epoch(try scalar.decode(Double.self)) }
    }
    func date() throws -> Date? {
        switch self {
        case .text(let text): return try UsageClient.parseReset(text)
        case .epoch(let seconds):
            guard seconds.isFinite, seconds >= 0 else { throw UsageFailure.invalidResponse }
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
    }
}

private struct ResetGrantSample {
    let attemptedAt: Date
    let grants: ClaudeResetGrants?
}

enum UsageDataFailure: Error, LocalizedError, Sendable {
    case identityUnavailable
    case unsupportedConfigHome
    case savedLoginRequired(UsageProvider)
    var errorDescription: String? {
        switch self {
        case .identityUnavailable:
            "The selected login cannot verify its account identity. Sign in again in the account's original CLI, then refresh."
        case .unsupportedConfigHome:
            "Choose one absolute CLI configuration directory. Relative paths and Claude comma-separated configuration homes are not supported."
        case .savedLoginRequired(.claude):
            "This saved Claude login is unavailable or expired. Run cswap run <account> for this account, then refresh. The pet never renews or changes saved credentials."
        case .savedLoginRequired(.codex):
            "This saved Codex login is unavailable or expired. Run xswap login <account> or xswap run <account> for this account, then refresh. The pet never renews or changes saved credentials."
        }
    }
}

private struct UsageIdentityBinding: Sendable {
    let fingerprint: String
    let identity: String?
    func changed(from previous: UsageIdentityBinding?) -> Bool {
        guard let previous, fingerprint != previous.fingerprint else { return false }
        if let identity, let old = previous.identity { return identity != old }
        return true
    }
}

private struct CredentialSourceFailure: Error, Sendable {
    let reason: UsageFailure
    let observation: UsageIdentityBinding
}
