import Foundation

enum UsageProvider: String, CaseIterable, Codable, Sendable {
    case claude = "Claude"
    case codex = "Codex"
}

struct UsageAccount: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let provider: UsageProvider
    var label: String
    var directory: String? = nil
    var expectedEmail: String? = nil
    var expectedOrganizationID: String? = nil
    var expectedAccountID: String? = nil
    var keychainService: String? = nil

    static let claude = UsageAccount(id: "claude-default", provider: .claude, label: "Claude")
    static let codex = UsageAccount(id: "codex-default", provider: .codex, label: "Codex")
    static let defaults = [claude, codex]
}

enum UsageOrigin: String, Codable, Sendable {
    case live, swapCache, diskCache
}

struct UsageExtra: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let amount: Double
    let unit: String
    var limit: Double? = nil
}

struct QuotaWindow: Codable, Sendable, Equatable {
    let title: String
    let remainingPercent: Double
    let resetsAt: Date?
    let id: String
    let durationSeconds: TimeInterval?

    init(title: String, usedPercent: Double, resetsAt: Date?, id: String? = nil, durationSeconds: TimeInterval? = nil) throws {
        guard usedPercent.isFinite, usedPercent >= 0 else {
            throw UsageFailure.invalidResponse
        }
        if let durationSeconds, (!durationSeconds.isFinite || durationSeconds <= 0) {
            throw UsageFailure.invalidResponse
        }
        self.title = title
        self.remainingPercent = max(0, 100 - usedPercent)
        self.resetsAt = resetsAt
        self.id = id ?? title
        self.durationSeconds = durationSeconds
    }
}

struct UsageReading: Codable, Sendable {
    let provider: UsageProvider
    let windows: [QuotaWindow]
    let fetchedAt: Date
    var source: UsageOrigin = .live
    var accountID: String? = nil
    var accountIdentity: String? = nil
    var accountLabel: String? = nil
    var plan: String? = nil
    var authSource: String? = nil
    var credentialFingerprint: String? = nil
    var retryAt: Date? = nil
    var extras: [UsageExtra] = []

    func isCurrent(at now: Date) -> Bool {
        guard source != .diskCache, !windows.isEmpty else { return false }
        let age = now.timeIntervalSince(fetchedAt)
        guard age >= 0, age <= 15 * 60 else { return false }
        for window in windows {
            guard window.remainingPercent.isFinite, (0...100).contains(window.remainingPercent) else { return false }
            if let duration = window.durationSeconds, (!duration.isFinite || duration <= 0) { return false }
            if let reset = window.resetsAt, (!reset.timeIntervalSince1970.isFinite || reset <= now) { return false }
        }
        return true
    }
    var remainingPercent: Double? { windows.map(\.remainingPercent).min() }
}

enum UsageFailure: Error, LocalizedError, Sendable {
    case loginRequired(UsageProvider)
    case keychainDenied
    case apiKeyMode
    case unauthorized(UsageProvider)
    case http(Int)
    case invalidResponse
    case cooldown(Date)
    case identityMismatch
    case accountChanged(Date?)

    var errorDescription: String? {
        switch self {
        case .loginRequired(.claude): "Claude Code에서 /login 후 새로고침하세요."
        case .loginRequired(.codex): "터미널에서 codex login 후 새로고침하세요."
        case .keychainDenied: "로그인 키체인 접근이 필요합니다. 새로고침 버튼을 눌러 허용하세요."
        case .apiKeyMode: "API 키는 구독 잔여량이 없습니다. codex login으로 ChatGPT 계정을 연결하세요."
        case .unauthorized(.claude): "Claude 인증이 만료되었거나 사용량 권한이 없습니다. Claude Code에서 /login 후 다시 시도하세요."
        case .unauthorized(.codex): "Codex 인증이 만료되었습니다. Codex를 실행하거나 codex login 후 다시 시도하세요."
        case .http(let status): "사용량 서버 오류 (HTTP \(status)). 나중에 새로고침하세요."
        case .invalidResponse: "사용량 응답에 유효한 한도가 없습니다."
        case .cooldown(let until): "조회 제한으로 \(until.formatted(date: .omitted, time: .shortened)) 이후 다시 시도합니다."
        case .identityMismatch: "로그인 계정이 선택한 계정과 다릅니다. 원래 CLI에서 계정을 확인하세요."
        case .accountChanged: "로그인 계정이 변경되어 이전 사용량을 숨겼습니다. 다시 조회하세요."
        }
    }
}

protocol UsageFetching: Sendable {
    func fetch(_ account: UsageAccount, allowKeychainPrompt: Bool) async throws -> UsageReading
    func cached(_ account: UsageAccount) async -> UsageReading?
}

enum PetMood: String, Sendable {
    case delighted, happy, uneasy, sad, crying, unknown
    static func forRemaining(_ percent: Double?) -> PetMood {
        guard let percent else { return .unknown }
        if percent <= 10 { return .crying }
        if percent < 30 { return .sad }
        if percent < 60 { return .uneasy }
        if percent < 95 { return .happy }
        return .delighted
    }
    var caption: String {
        switch self {
        case .delighted: T("와아! 아직 한가득!")
        case .happy: T("오늘도 같이 힘내자")
        case .uneasy: T("조금씩 아껴 쓰자…")
        case .sad: T("이제 얼마 안 남았어…")
        case .crying: T("울먹… 잠깐 쉬었다 가자")
        case .unknown: T("연결하면 기분을 알려줄게")
        }
    }
}
