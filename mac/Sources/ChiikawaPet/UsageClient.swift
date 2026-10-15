import CryptoKit
import Foundation
import LocalAuthentication
import Security

actor UsageClient: UsageFetching {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func fetch(_ provider: UsageProvider, allowKeychainPrompt: Bool) async throws -> UsageReading {
        let request: URLRequest
        var claudeOrganization: String?
        switch provider {
        case .claude:
            let access = try claudeAccess(allowKeychainPrompt: allowKeychainPrompt)
            // claude-swap polls this endpoint for every account and spends the same hourly budget,
            // so a direct request mostly gets 429 while it runs. Reuse its recent reading instead.
            if let organization = access.organizationUUID {
                if let cached = swapCachedReading(organizationUUID: organization, maxAge: Self.swapFreshAge) { return cached }
                claudeOrganization = organization
            }
            request = makeRequest(url: "https://api.anthropic.com/api/oauth/usage", token: access.token)
        case .codex:
            let tokens = try codexTokens(allowKeychainPrompt: allowKeychainPrompt)
            var codexRequest = makeRequest(url: "https://chatgpt.com/backend-api/wham/usage", token: tokens.accessToken)
            codexRequest.setValue(tokens.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            codexRequest.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
            codexRequest.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
            request = codexRequest
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageFailure.invalidResponse }
        switch response.statusCode {
        case 200...299: break
        case 401, 403: throw UsageFailure.unauthorized(provider)
        case 429:
            if let claudeOrganization,
               let cached = swapCachedReading(organizationUUID: claudeOrganization, maxAge: Self.swapStaleAge) { return cached }
            throw UsageFailure.http(response.statusCode)
        default: throw UsageFailure.http(response.statusCode)
        }
        let now = Date()
        switch provider {
        case .claude: return try Self.decodeClaude(data, now: now)
        case .codex: return try Self.decodeCodex(data, now: now)
        }
    }

    private func makeRequest(url: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if url == "https://api.anthropic.com/api/oauth/usage" {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code", forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    private func configDirectory(variable: String, defaultName: String) -> URL {
        if let configured = ProcessInfo.processInfo.environment[variable], !configured.isEmpty {
            let expanded = NSString(string: configured).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(defaultName, isDirectory: true)
    }

    private func credentialFile(_ path: URL) throws -> Data? {
        do {
            return try Data(contentsOf: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func claudeAccess(allowKeychainPrompt: Bool) throws -> ClaudeAccess {
        let directory = configDirectory(variable: "CLAUDE_CONFIG_DIR", defaultName: ".claude")
        let path = directory.appendingPathComponent(".credentials.json")
        if let data = try credentialFile(path), let access = try Self.parseClaudeCredential(data) {
            return access
        }
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        guard directory.resolvingSymlinksInPath().standardizedFileURL == defaultDirectory.resolvingSymlinksInPath().standardizedFileURL else {
            throw UsageFailure.loginRequired(.claude)
        }
        // Claude Code writes this item through /usr/bin/security, so only that tool is on its ACL.
        // Reading through the same tool avoids the prompt, and keeps working after the item is rewritten.
        if let data = Self.securityToolCredential(service: "Claude Code-credentials"),
           let access = try Self.parseClaudeCredential(data) {
            return access
        }
        let data = try keychainCredential(service: "Claude Code-credentials", account: nil, allowPrompt: allowKeychainPrompt)
        if let data, let access = try Self.parseClaudeCredential(data) { return access }
        throw UsageFailure.loginRequired(.claude)
    }

    private static func parseClaudeCredential(_ data: Data) throws -> ClaudeAccess? {
        let credentials: ClaudeCredentials
        do { credentials = try JSONDecoder().decode(ClaudeCredentials.self, from: data) }
        catch { throw UsageFailure.loginRequired(.claude) }
        guard let oauth = credentials.claudeAiOauth, let token = oauth.accessToken, validHeader(token) else { return nil }
        if let expiresAt = oauth.expiresAt, (!expiresAt.isFinite || expiresAt <= Date().timeIntervalSince1970 * 1_000) {
            throw UsageFailure.unauthorized(.claude)
        }
        return ClaudeAccess(token: token, organizationUUID: credentials.organizationUuid)
    }

    static let swapFreshAge: TimeInterval = 15 * 60
    static let swapStaleAge: TimeInterval = 60 * 60

    private func swapCachedReading(organizationUUID: String, maxAge: TimeInterval) -> UsageReading? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-swap-backup/cache/usage.json")
        guard let data = try? credentialFile(path) else { return nil }
        return Self.decodeSwapCache(data, organizationUUID: organizationUUID, now: Date(), maxAge: maxAge)
    }

    // claude-swap's cache/usage.json (schemaVersion 2) keeps the last good reading per account.
    nonisolated static func decodeSwapCache(_ data: Data, organizationUUID: String, now: Date, maxAge: TimeInterval) -> UsageReading? {
        guard let cache = try? JSONDecoder().decode(SwapUsageCache.self, from: data), cache.schemaVersion == 2 else { return nil }
        let candidates = cache.accounts.values.filter { $0.organizationUuid == organizationUUID && $0.lastGood != nil }
        guard let account = candidates.max(by: { ($0.fetchedAt ?? 0) < ($1.fetchedAt ?? 0) }),
              let fetchedAt = account.fetchedAt, let usage = account.lastGood else { return nil }
        let fetchedDate = Date(timeIntervalSince1970: fetchedAt)
        let age = now.timeIntervalSince(fetchedDate)
        guard age >= -60, age <= maxAge else { return nil }
        var measured: [(String, SwapUsageWindow?)] = [("5시간", usage.fiveHour), ("주간", usage.sevenDay)]
        for scoped in usage.scoped ?? [] {
            if let name = scoped.name, !name.isEmpty { measured.append(("\(name) 주간", scoped)) }
        }
        var windows: [QuotaWindow] = []
        for (title, window) in measured {
            guard let window, let used = window.pct,
                  let quota = try? QuotaWindow(title: title, usedPercent: used, resetsAt: try? parseReset(window.resetsAt)) else { continue }
            windows.append(quota)
        }
        guard !windows.isEmpty else { return nil }
        return UsageReading(provider: .claude, windows: windows, fetchedAt: fetchedDate)
    }

    private func codexTokens(allowKeychainPrompt: Bool) throws -> CodexAccess {
        let directory = configDirectory(variable: "CODEX_HOME", defaultName: ".codex")
        let path = directory.appendingPathComponent("auth.json")
        if let data = try credentialFile(path), let tokens = try Self.parseCodexCredential(data) {
            return tokens
        }
        // Codex scopes the keychain account to the canonical home path, not the macOS username.
        // Contract: github.com/openai/codex/blob/main/codex-rs/login/src/auth/storage.rs
        let canonicalPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let pathData = Data(canonicalPath.utf8)
        let digest = SHA256.hash(data: pathData)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let account = "cli|\(hex.prefix(16))"
        let data = try keychainCredential(service: "Codex Auth", account: account, allowPrompt: allowKeychainPrompt)
        if let data, let tokens = try Self.parseCodexCredential(data) { return tokens }
        throw UsageFailure.loginRequired(.codex)
    }

    private static func parseCodexCredential(_ data: Data) throws -> CodexAccess? {
        let credentials: CodexCredentials
        do { credentials = try JSONDecoder().decode(CodexCredentials.self, from: data) }
        catch { throw UsageFailure.loginRequired(.codex) }
        if credentials.authMode == "apikey" { throw UsageFailure.apiKeyMode }
        if let tokens = credentials.tokens, let accessToken = tokens.accessToken, let accountID = tokens.accountID,
           validHeader(accessToken), validHeader(accountID) {
            return CodexAccess(accessToken: accessToken, accountID: accountID)
        }
        if let apiKey = credentials.openAIAPIKey, !apiKey.isEmpty { throw UsageFailure.apiKeyMode }
        return nil
    }

    private static func validHeader(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }

    private static func securityToolCredential(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }

    private func keychainCredential(service: String, account: String?, allowPrompt: Bool) throws -> Data? {
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
        let candidates: [(String, ClaudeUsageWindow?)] = [
            ("5시간", payload.fiveHour), ("주간", payload.sevenDay),
            ("Sonnet 주간", payload.sevenDaySonnet), ("Opus 주간", payload.sevenDayOpus)
        ]
        for (title, measured) in candidates {
            guard let measured, let usedPercent = measured.utilization else { continue }
            let resetsAt = try parseReset(measured.resetsAt)
            let window = try QuotaWindow(title: title, usedPercent: usedPercent, resetsAt: resetsAt)
            windows.append(window)
        }
        guard !windows.isEmpty else { throw UsageFailure.invalidResponse }
        return UsageReading(provider: .claude, windows: windows, fetchedAt: now)
    }

    nonisolated static func decodeCodex(_ data: Data, now: Date) throws -> UsageReading {
        let payload: CodexUsageResponse
        do { payload = try JSONDecoder().decode(CodexUsageResponse.self, from: data) }
        catch { throw UsageFailure.invalidResponse }
        guard let rateLimit = payload.rateLimit else { throw UsageFailure.invalidResponse }
        var windows: [QuotaWindow] = []
        let candidates = [rateLimit.primaryWindow, rateLimit.secondaryWindow]
        for (index, measured) in candidates.enumerated() {
            guard let measured, let usedPercent = measured.usedPercent else { continue }
            let title: String
            if let seconds = measured.limitWindowSeconds {
                guard seconds > 0 else { throw UsageFailure.invalidResponse }
                if seconds == 604_800 { title = "주간" }
                else if seconds % 86_400 == 0 { title = "\(seconds / 86_400)일 한도" }
                else if seconds % 3_600 == 0 { title = "\(seconds / 3_600)시간" }
                else { title = "\(seconds)초 한도" }
            } else {
                title = index == 0 ? "첫 번째 한도" : "두 번째 한도"
            }
            var resetsAt: Date?
            if let reset = measured.resetAt {
                guard reset.isFinite, reset >= 0 else { throw UsageFailure.invalidResponse }
                resetsAt = Date(timeIntervalSince1970: reset)
            }
            let window = try QuotaWindow(title: title, usedPercent: usedPercent, resetsAt: resetsAt)
            windows.append(window)
        }
        guard !windows.isEmpty else { throw UsageFailure.invalidResponse }
        return UsageReading(provider: .codex, windows: windows, fetchedAt: now)
    }

    private nonisolated static func parseReset(_ text: String?) throws -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { throw UsageFailure.invalidResponse }
        return date
    }
}

private struct ClaudeCredentials: Decodable {
    let claudeAiOauth: OAuth?
    let organizationUuid: String?
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

private struct ClaudeAccess {
    let token: String
    let organizationUUID: String?
}

private struct SwapUsageCache: Decodable {
    let schemaVersion: Int?
    let accounts: [String: SwapAccount]
}

private struct SwapAccount: Decodable {
    let organizationUuid: String?
    let fetchedAt: Double?
    let lastGood: SwapUsage?
}

private struct SwapUsage: Decodable {
    let fiveHour: SwapUsageWindow?
    let sevenDay: SwapUsageWindow?
    let scoped: [SwapUsageWindow]?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case scoped
    }
}

private struct SwapUsageWindow: Decodable {
    let name: String?
    let pct: Double?
    let resetsAt: String?
    enum CodingKeys: String, CodingKey {
        case name, pct
        case resetsAt = "resets_at"
    }
}

private struct CodexAccess {
    let accessToken: String
    let accountID: String
}

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
    let sevenDaySonnet: ClaudeUsageWindow?
    let sevenDayOpus: ClaudeUsageWindow?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
    }
}

private struct ClaudeUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct CodexUsageResponse: Decodable {
    let rateLimit: CodexRateLimit?
    enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
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
    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}
