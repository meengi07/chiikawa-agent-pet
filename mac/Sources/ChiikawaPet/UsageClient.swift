import CryptoKit
import Darwin
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
        switch provider {
        case .claude:
            let token = try claudeToken(allowKeychainPrompt: allowKeychainPrompt)
            request = makeRequest(url: "https://api.anthropic.com/api/oauth/usage", token: token)
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

    private func claudeToken(allowKeychainPrompt: Bool) throws -> String {
        let directory = configDirectory(variable: "CLAUDE_CONFIG_DIR", defaultName: ".claude")
        let path = directory.appendingPathComponent(".credentials.json")
        if let data = try credentialFile(path), let token = try Self.parseClaudeCredential(data) {
            return token
        }
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        guard directory.resolvingSymlinksInPath().standardizedFileURL == defaultDirectory.resolvingSymlinksInPath().standardizedFileURL else {
            throw UsageFailure.loginRequired(.claude)
        }
        if let output = Self.claudeSecurityOutput(), let token = try Self.claudeToken(fromSecurityOutput: output) {
            return token
        }
        let data = try keychainCredential(service: "Claude Code-credentials", account: nil, allowPrompt: allowKeychainPrompt)
        if let data, let token = try Self.parseClaudeCredential(data) { return token }
        throw UsageFailure.loginRequired(.claude)
    }

    private nonisolated static func claudeSecurityOutput() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
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
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "{" {
            return try parseClaudeCredential(output)
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
        return try parseClaudeCredential(decoded)
    }

    private nonisolated static func parseClaudeCredential(_ data: Data) throws -> String? {
        let credentials: ClaudeCredentials
        do { credentials = try JSONDecoder().decode(ClaudeCredentials.self, from: data) }
        catch { throw UsageFailure.loginRequired(.claude) }
        guard let oauth = credentials.claudeAiOauth, let token = oauth.accessToken, validHeader(token) else { return nil }
        if let expiresAt = oauth.expiresAt, (!expiresAt.isFinite || expiresAt <= Date().timeIntervalSince1970 * 1_000) {
            throw UsageFailure.unauthorized(.claude)
        }
        return token
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
