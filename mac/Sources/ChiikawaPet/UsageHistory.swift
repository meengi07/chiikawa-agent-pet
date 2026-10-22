import Foundation

struct UsageHistorySummary: Sendable {
    let days: [UsageHistoryDay]
    let warning: String?
}

struct UsageHistoryDay: Identifiable, Sendable {
    var id: String { day }
    let day: String
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cachedTokens: Int64 = 0
    var estimatedCost: Double?
    var unpricedTokens: Int64 = 0
    var totalTokens: Int64 { inputTokens + outputTokens + cachedTokens }
}

// Event contracts: openai/codex codex-rs/protocol/src/protocol.rs; OpenUsage commit
// 26132ff48dd78eb2c4a9498e40424e6365f99fec ClaudeLogUsageScanner / CodexLogFileParser.
// Callers must opt in before invoking this reader; history belongs to a home, not its current login.
enum LocalUsageHistory {
    static func scan(provider: UsageProvider, directory: URL, pricingFile: URL? = nil) async throws -> UsageHistorySummary {
        try Task.checkCancellation()
        let scan = Task.detached(priority: .utility) {
            try HistoryScan().run(provider: provider, directory: directory, pricingFile: pricingFile)
        }
        return try await withTaskCancellationHandler {
            let summary = try await scan.value
            try Task.checkCancellation()
            return summary
        } onCancel: {
            scan.cancel()
        }
    }
}

private enum HistoryError: Error, LocalizedError {
    case pricing
    var errorDescription: String? { "Cannot read pricing JSON. Use version 1 and finite, nonnegative per-million-token model rates." }
}

private struct HistoryRates: Decodable {
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cachedInputPerMillion: Double
    let cacheWritePerMillion: Double
    let cacheWriteOneHourPerMillion: Double?

    var valid: Bool {
        let rates = [inputPerMillion, outputPerMillion, cachedInputPerMillion, cacheWritePerMillion]
        return rates.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1e12 }
            && (cacheWriteOneHourPerMillion.map { $0.isFinite && $0 >= 0 && $0 <= 1e12 } ?? true)
    }
}

private struct HistoryPrices: Decodable {
    let version: Int
    let models: [String: HistoryRates]
}

private struct HistoryEnvelope: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let isSidechain: Bool?
    let message: HistoryMessage?
    let payload: HistoryPayload?
}

private struct HistoryMessage: Decodable {
    let id: String?
    let model: String?
    let usage: HistoryUsage?
}

private struct HistoryPayload: Decodable {
    let type: String?
    let id: String?
    let model: String?
    let model_name: String?
    let metadata: HistoryModelMetadata?
    let info: HistoryTokenInfo?
    let forked_from_id: String?
    let parent_thread_id: String?
    let thread_source: String?
    let source: HistorySessionSource?
    let started_at: Double?
    let thread_settings: HistoryThreadSettings?
    let service_tier: String?
}

private struct HistoryModelMetadata: Decodable { let model: String? }
private struct HistoryThreadSettings: Decodable { let service_tier: String? }
private enum HistorySessionSource: Decodable, Equatable {
    case root, child
    private enum CodingKeys: String, CodingKey { case subagent }
    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = text == "subagent" ? .child : .root
        } else {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            if fields.contains(.subagent) {
                let absent = try fields.decodeNil(forKey: .subagent)
                self = absent ? .root : .child
            } else { self = .root }
        }
    }
}
private struct HistoryTokenInfo: Decodable {
    let total_token_usage: HistoryUsage?
    let last_token_usage: HistoryUsage?
    let model: String?
    let model_name: String?
}

private struct HistoryCacheCreation: Decodable {
    let ephemeral_5m_input_tokens: Int64?
    let ephemeral_1h_input_tokens: Int64?
}

private struct HistoryUsage: Decodable {
    let type: String?
    let model: String?
    let input_tokens: Int64?
    let output_tokens: Int64?
    let cached_input_tokens: Int64?
    let cache_read_input_tokens: Int64?
    let cache_creation_input_tokens: Int64?
    let cache_write_input_tokens: Int64?
    let cache_creation: HistoryCacheCreation?
    let speed: String?
    let service_tier: String?
    let iterations: [HistoryUsage?]?
    var specialRate: Bool {
        (speed != nil && speed != "standard") || (service_tier != nil && service_tier != "standard")
    }

    func tokens(claude: Bool) throws -> HistoryTokens {
        guard let input = input_tokens, let output = output_tokens else { throw HistoryParseError.invalid }
        guard Self.validCount(input), Self.validCount(output), Self.validCount(cached_input_tokens ?? 0),
              Self.validCount(cache_read_input_tokens ?? 0), Self.validCount(cache_creation_input_tokens ?? 0),
              Self.validCount(cache_write_input_tokens ?? 0), Self.validCount(cache_creation?.ephemeral_5m_input_tokens ?? 0),
              Self.validCount(cache_creation?.ephemeral_1h_input_tokens ?? 0) else { throw HistoryParseError.invalid }
        let cached = claude ? cache_read_input_tokens ?? 0 : cached_input_tokens ?? 0
        let oneHour = cache_creation?.ephemeral_1h_input_tokens ?? 0
        let splitWrites = (cache_creation?.ephemeral_5m_input_tokens ?? 0) + oneHour
        let writes = claude ? cache_creation_input_tokens ?? splitWrites : cache_write_input_tokens ?? 0
        let fiveMinute = cache_creation == nil ? writes : cache_creation?.ephemeral_5m_input_tokens ?? 0
        guard Self.validCount(writes),
              claude || cached + writes <= input,
              cache_creation == nil || fiveMinute + oneHour == writes
        else { throw HistoryParseError.invalid }
        return HistoryTokens(input: claude ? input : input - cached - writes,
                             output: output, cached: cached, writes: fiveMinute, oneHour: oneHour)
    }
    private static func validCount(_ count: Int64) -> Bool { count >= 0 && count <= 1_000_000_000_000 }
}


private enum HistoryParseError: Error { case invalid }
private struct HistoryTokens: Equatable, Hashable {
    var input: Int64
    var output: Int64
    var cached: Int64
    var writes: Int64
    var oneHour: Int64
    var total: Int64 { input + output + cached + writes + oneHour }

    func delta(from previous: HistoryTokens?) throws -> HistoryTokens {
        let before = previous ?? HistoryTokens(input: 0, output: 0, cached: 0, writes: 0, oneHour: 0)
        guard input >= before.input, output >= before.output, cached >= before.cached,
              writes >= before.writes, oneHour >= before.oneHour else { throw HistoryParseError.invalid }
        return HistoryTokens(input: input - before.input, output: output - before.output,
                             cached: cached - before.cached, writes: writes - before.writes,
                             oneHour: oneHour - before.oneHour)
    }
}

private struct HistoryEvent {
    let date: Date
    let model: String?
    let tokens: HistoryTokens
    let request: String
    let sidechain: Bool
    let specialRate: Bool
}

private struct HistoryCodexKey: Hashable {
    let sessionID: String?
    let date: Date
    let model: String?
    let tokens: HistoryTokens
    let specialRate: Bool
}

private final class HistoryScan {
    private let decoder = JSONDecoder()
    private let fractionalDates = ISO8601DateFormatter()
    private let wholeDates = ISO8601DateFormatter()
    private var claudeMessages: [String: [HistoryEvent]] = [:]
    private var codexEvents: [HistoryCodexKey: HistoryEvent] = [:]
    private var eventCount = 0
    private var incomplete = false
    private var limited = false
    private var readBytes: Int64 = 0
    private var files = 0
    private let maxEvents = 250_000

    init() {
        fractionalDates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func run(provider: UsageProvider, directory: URL, pricingFile: URL?) throws -> UsageHistorySummary {
        try Task.checkCancellation()
        let prices = try loadPrices(pricingFile)
        let roots = provider == .claude ? ["projects"] : ["sessions", "archived_sessions"]
        let home = directory.standardizedFileURL.resolvingSymlinksInPath()
        var activeRelativePaths: Set<String> = []
        for name in roots {
            let root = home.appendingPathComponent(name).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let entries = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in self.incomplete = true; return true }
            ) else { incomplete = true; continue }
            for case let file as URL in entries {
                try Task.checkCancellation()
                if limited { break }
                guard file.pathExtension == "jsonl" else { continue }
                let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes?.isRegularFile == true, attributes?.isSymbolicLink != true else { continue }
                if provider == .codex {
                    let relative = String(file.path.dropFirst(root.path.count))
                    if name == "archived_sessions", activeRelativePaths.contains(relative) { continue }
                    if name == "sessions" { activeRelativePaths.insert(relative) }
                }
                files += 1
                if files > 20_000 { limited = true; break }
                try parseFile(file, claude: provider == .claude)
            }
        }
        let dayFormat = DateFormatter()
        dayFormat.calendar = Calendar(identifier: .gregorian)
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.timeZone = .current
        dayFormat.dateFormat = "yyyy-MM-dd"
        var days: [String: UsageHistoryDay] = [:]
        for events in claudeMessages.values {
            for event in events {
                try Task.checkCancellation()
                aggregate(event, prices: prices, format: dayFormat, days: &days)
            }
        }
        for event in codexEvents.values {
            try Task.checkCancellation()
            aggregate(event, prices: prices, format: dayFormat, days: &days)
        }
        var warnings: [String] = []
        if files == 0 { warnings.append("No local session history found.") }
        if incomplete { warnings.append("History is incomplete: unreadable, corrupt, unsupported or ambiguous records were skipped.") }
        if limited { warnings.append("History is incomplete: local scan safety limit reached.") }
        if days.values.contains(where: { $0.unpricedTokens > 0 }) {
            warnings.append("Some measured tokens are unpriced. Estimates use only exact user-supplied model rates; API-rate estimates are not subscription bills.")
        }
        return UsageHistorySummary(days: days.values.sorted { $0.day < $1.day },
                                   warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    private func loadPrices(_ file: URL?) throws -> [String: HistoryRates] {
        guard let file else { return [:] }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 262_145) ?? Data()
            guard data.count <= 262_144 else { throw HistoryError.pricing }
            let prices = try decoder.decode(HistoryPrices.self, from: data)
            guard prices.version == 1, prices.models.count <= 1000,
                  prices.models.allSatisfy({ validID($0.key) && $0.value.valid }) else { throw HistoryError.pricing }
            return prices.models
        } catch { throw HistoryError.pricing }
    }

    private func parseFile(_ file: URL, claude: Bool) throws {
        var previous: HistoryTokens?
        var model: String?
        var sawMeta = false
        var replaying = false
        var created: Date?
        var specialRate = false
        var sessionID: String?
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var line = Data()
            var oversized = false
            while !limited {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 65_536) ?? Data()
                if chunk.isEmpty { break }
                readBytes += Int64(chunk.count)
                if readBytes > 2_147_483_648 { limited = true; break }
                for byte in chunk {
                    if byte == 10 { try Task.checkCancellation() }
                    if byte == 10 {
                        if !oversized && !line.isEmpty {
                            parseLine(line, claude: claude, previous: &previous, model: &model,
                                      sawMeta: &sawMeta, replaying: &replaying, created: &created, specialRate: &specialRate,
                                      sessionID: &sessionID)
                        }
                        line.removeAll(keepingCapacity: true)
                        oversized = false
                    } else if !oversized {
                        if line.count >= 4_194_304 { oversized = true; incomplete = true; line.removeAll(keepingCapacity: true) }
                        else { line.append(byte) }
                    }
                }
            }
            if !oversized && !line.isEmpty && !limited {
                parseLine(line, claude: claude, previous: &previous, model: &model,
                          sawMeta: &sawMeta, replaying: &replaying, created: &created, specialRate: &specialRate,
                          sessionID: &sessionID)
            }
            if replaying { incomplete = true }
        } catch is CancellationError { throw CancellationError() }
        catch { incomplete = true }
    }

    private func parseLine(_ line: Data, claude: Bool, previous: inout HistoryTokens?, model: inout String?,
                           sawMeta: inout Bool, replaying: inout Bool, created: inout Date?, specialRate: inout Bool,
                           sessionID: inout String?) {
        do {
            let envelope = try decoder.decode(HistoryEnvelope.self, from: line)
            if claude {
                guard let message = envelope.message, let usage = message.usage else { return }
                guard let date = date(envelope.timestamp), let id = message.id, validID(id),
                      message.model.map(validID) ?? true, envelope.requestId.map(validID) ?? true else { throw HistoryParseError.invalid }
                let tokens = try usage.tokens(claude: true)
                let event = HistoryEvent(date: date, model: message.model, tokens: tokens, request: envelope.requestId ?? "",
                                         sidechain: envelope.isSidechain ?? false, specialRate: usage.specialRate)
                addClaude(event, id: id)
                var advisorIndex = 0
                for candidate in usage.iterations ?? [] {
                    guard let iteration = candidate else { incomplete = true; continue }
                    guard iteration.type == "advisor_message" else { continue }
                    guard let advisorModel = iteration.model, validID(advisorModel),
                          let advisorTokens = try? iteration.tokens(claude: true) else { incomplete = true; continue }
                    let specialRate = event.specialRate || iteration.specialRate
                    let advisor = HistoryEvent(date: date, model: advisorModel, tokens: advisorTokens,
                                               request: event.request, sidechain: event.sidechain, specialRate: specialRate)
                    addClaude(advisor, id: "\(id):advisor:\(advisorIndex)")
                    advisorIndex += 1
                }
                return
            }
            guard let payload = envelope.payload else { return }
            if envelope.type == "session_meta", !sawMeta {
                sawMeta = true
                if let id = payload.id, validID(id) { sessionID = id }
                else { incomplete = true }
                replaying = (payload.forked_from_id.map { !$0.isEmpty } ?? false)
                    || (payload.parent_thread_id.map { !$0.isEmpty } ?? false)
                    || payload.thread_source == "subagent" || payload.source == .child
                created = date(envelope.timestamp)
                return
            }
            if envelope.type == "turn_context" {
                if let name = modelName(payload), validID(name) { model = name }
                return
            }
            guard envelope.type == "event_msg" else { return }
            if payload.type == "thread_settings_applied" {
                if let tier = payload.thread_settings?.service_tier ?? payload.service_tier { specialRate = tier != "default" && tier != "standard" }
                return
            }
            if payload.type == "task_started", replaying, let started = payload.started_at, started.isFinite {
                let boundary = created ?? date(envelope.timestamp)
                if let boundary, started >= floor(boundary.timeIntervalSince1970) { replaying = false }
                return
            }
            guard payload.type == "token_count", let info = payload.info else { return }
            let totals = try info.total_token_usage?.tokens(claude: false)
            if replaying { if let totals { previous = totals }; return }
            if let totals, totals == previous { return }
            let tokens: HistoryTokens
            if let last = info.last_token_usage { tokens = try last.tokens(claude: false) }
            else if let totals {
                do { tokens = try totals.delta(from: previous) }
                catch { previous = totals; throw error }
            } else { throw HistoryParseError.invalid }
            if let totals { previous = totals }
            guard let date = date(envelope.timestamp) else { throw HistoryParseError.invalid }
            if let name = modelName(payload) ?? info.model ?? info.model_name, validID(name) { model = name }
            guard tokens.total > 0 else { return }
            if sessionID == nil { incomplete = true }
            let key = HistoryCodexKey(sessionID: sessionID, date: date, model: model, tokens: tokens, specialRate: specialRate)
            guard codexEvents[key] == nil else { return }
            guard eventCount < maxEvents else { limited = true; return }
            codexEvents[key] = HistoryEvent(date: date, model: model, tokens: tokens, request: "", sidechain: false, specialRate: specialRate)
            eventCount += 1
        } catch { incomplete = true }
    }

    private func addClaude(_ event: HistoryEvent, id: String) {
        if let index = claudeMessages[id]?.firstIndex(where: { $0.request == event.request || $0.sidechain || event.sidechain }),
           let old = claudeMessages[id]?[index] {
            let larger = event.tokens.total > old.tokens.total
            let richer = event.tokens.total == old.tokens.total && event.specialRate && !old.specialRate
            if (old.sidechain && !event.sidechain) || (old.sidechain == event.sidechain && (larger || richer)) {
                claudeMessages[id]?[index] = event
            }
        } else if eventCount < maxEvents && (claudeMessages[id]?.count ?? 0) < 256 {
            claudeMessages[id, default: []].append(event)
            eventCount += 1
        } else { limited = true }
    }

    private func aggregate(_ event: HistoryEvent, prices: [String: HistoryRates], format: DateFormatter,
                           days: inout [String: UsageHistoryDay]) {
        let day = format.string(from: event.date)
        var summary = days[day] ?? UsageHistoryDay(day: day)
        let tokens = event.tokens
        summary.inputTokens += tokens.input + tokens.writes + tokens.oneHour
        summary.outputTokens += tokens.output
        summary.cachedTokens += tokens.cached
        if !event.specialRate, let model = event.model, let rates = prices[model], tokens.oneHour == 0 || rates.cacheWriteOneHourPerMillion != nil {
            let cost = (Double(tokens.input) * rates.inputPerMillion + Double(tokens.output) * rates.outputPerMillion
                        + Double(tokens.cached) * rates.cachedInputPerMillion + Double(tokens.writes) * rates.cacheWritePerMillion
                        + Double(tokens.oneHour) * (rates.cacheWriteOneHourPerMillion ?? 0)) / 1_000_000
            summary.estimatedCost = (summary.estimatedCost ?? 0) + cost
        } else { summary.unpricedTokens += tokens.total }
        days[day] = summary
    }

    private func validID(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 256
            && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private func date(_ text: String?) -> Date? {
        guard let text, text.utf8.count <= 64 else { return nil }
        return fractionalDates.date(from: text) ?? wholeDates.date(from: text)
    }
    private func modelName(_ payload: HistoryPayload) -> String? { payload.model ?? payload.model_name ?? payload.metadata?.model }
}
