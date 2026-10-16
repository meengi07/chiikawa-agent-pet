import Foundation

enum UsageProvider: String, CaseIterable, Sendable {
    case claude = "Claude"
    case codex = "Codex"
}

struct QuotaWindow: Sendable, Equatable {
    let title: String
    let remainingPercent: Double
    let resetsAt: Date?

    init(title: String, usedPercent: Double, resetsAt: Date?) throws {
        guard usedPercent.isFinite, usedPercent >= 0 else {
            throw UsageFailure.invalidResponse
        }
        self.title = title
        self.remainingPercent = max(0, 100 - usedPercent)
        self.resetsAt = resetsAt
    }
}

struct UsageReading: Sendable {
    let provider: UsageProvider
    let windows: [QuotaWindow]
    let fetchedAt: Date
    var remainingPercent: Double? { windows.map(\.remainingPercent).min() }
}

enum UsageFailure: Error, LocalizedError, Sendable {
    case loginRequired(UsageProvider)
    case keychainDenied
    case apiKeyMode
    case unauthorized(UsageProvider)
    case http(Int)
    case invalidResponse

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
        }
    }
}

protocol UsageFetching: Sendable {
    func fetch(_ provider: UsageProvider, allowKeychainPrompt: Bool) async throws -> UsageReading
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
