import Foundation
import Testing
@testable import ChiikawaPet

struct UsageHistoryTests {
    // Shapes verified against OpenUsage 26132ff48dd78eb2c4a9498e40424e6365f99fec history parser fixtures.
    @Test func claudeStreamingCopiesAndSidechainReplayCountOnce() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let partial = claude("message", input: 100, output: 2, cached: 30, writes: 10)
        let complete = claude("message", input: 100, output: 20, cached: 30, writes: 10)
        let replay = claude("message", request: "replayed-request", input: 100, output: 999, cached: 30, writes: 10, sidechain: true)
        let worker = claude("worker-message", input: 5, output: 3)
        try corpus(home, path: "projects/main.jsonl", lines: [partial, complete])
        try corpus(home, path: "projects/copied.jsonl", lines: [complete])
        try corpus(home, path: "projects/session/subagents/agent.jsonl", lines: [replay, worker])
        let result = try await LocalUsageHistory.scan(provider: .claude, directory: home)
        #expect(result.days.count == 1)
        let day = try #require(result.days.first)
        #expect(day.inputTokens == 115)
        #expect(day.cachedTokens == 30)
        #expect(day.outputTokens == 23)
        #expect(day.totalTokens == 168)
        #expect(day.estimatedCost == nil)
        #expect(day.unpricedTokens == 168)
        #expect(result.warning?.contains("unpriced") == true)
    }

    @Test func codexTotalsDeltasLastUsageAndArchiveCopies() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = codex("2026-10-20T12:00:00Z", totals: usage(100, 30, 20))
        let second = codex("2026-10-21T12:00:00Z", totals: usage(150, 40, 30))
        let third = codex("2026-10-21T12:01:00Z", totals: usage(500, 80, 100), last: usage(20, 5, 4))
        let repeated = codex("2026-10-21T12:02:00Z", totals: usage(500, 80, 100), last: usage(20, 5, 4))
        let lines = [sessionMeta("session-a"), context("fixture"), first, second, third, repeated]
        try corpus(home, path: "sessions/2026/rollout.jsonl", lines: lines)
        try corpus(home, path: "archived_sessions/copied.jsonl", lines: lines)
        let result = try await LocalUsageHistory.scan(provider: .codex, directory: home)
        #expect(result.days.count == 2)
        #expect(result.days.reduce(0) { $0 + $1.inputTokens } == 125)
        #expect(result.days.reduce(0) { $0 + $1.cachedTokens } == 45)
        #expect(result.days.reduce(0) { $0 + $1.outputTokens } == 34)
        #expect(result.days.reduce(0) { $0 + $1.totalTokens } == 204)
    }

    @Test func childForkReplaysSeedBaselineUntilLiveTaskStarts() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let creation = "2026-10-21T12:00:00Z"
        let epoch = try #require(ISO8601DateFormatter().date(from: creation)).timeIntervalSince1970
        let meta = "{\"type\":\"session_meta\",\"timestamp\":\"\(creation)\",\"payload\":{\"id\":\"child\",\"forked_from_id\":\"parent\",\"source\":{\"subagent\":{\"thread_spawn\":{}}}}}"
        let oldTask = taskStarted(creation, epoch: epoch - 300)
        let liveTask = taskStarted("2026-10-21T12:00:03Z", epoch: epoch + 3)
        let replay = codex("2026-10-21T12:00:01Z", totals: usage(1000, 100, 200))
        let replayMore = codex("2026-10-21T12:00:02Z", totals: usage(1500, 150, 300))
        let live = codex("2026-10-21T12:01:00Z", totals: usage(1600, 160, 320))
        try corpus(home, path: "sessions/fork.jsonl", lines: [meta, context("fixture"), oldTask, replay, replayMore, liveTask, live])
        let result = try await LocalUsageHistory.scan(provider: .codex, directory: home)
        let day = try #require(result.days.first)
        #expect(day.inputTokens == 90)
        #expect(day.cachedTokens == 10)
        #expect(day.outputTokens == 20)
        #expect(day.totalTokens == 120)
    }

    @Test func childWithoutLiveBoundaryNeverInventsUsage() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let meta = #"{"type":"session_meta","payload":{"parent_thread_id":"parent"}}"#
        try corpus(home, path: "sessions/fork.jsonl", lines: [meta, codex("2026-10-21T12:00:00Z", totals: usage(1000, 100, 200))])
        let result = try await LocalUsageHistory.scan(provider: .codex, directory: home)
        #expect(result.days.isEmpty)
        #expect(result.warning?.contains("incomplete") == true)
    }

    @Test func explicitRatesPriceCacheBucketsAndUnknownModelsStayUnpriced() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let prices = home.appendingPathComponent("prices.json")
        try Data(#"{"version":1,"models":{"fixture":{"inputPerMillion":2,"outputPerMillion":8,"cachedInputPerMillion":0.5,"cacheWritePerMillion":3}}}"#.utf8).write(to: prices)
        let known = claude("known", input: 100, output: 20, cached: 30, writes: 10)
        let unknown = claude("unknown", input: 7, output: 3, model: "unknown-model")
        try corpus(home, path: "projects/one.jsonl", lines: [known, unknown])
        let result = try await LocalUsageHistory.scan(provider: .claude, directory: home, pricingFile: prices)
        let day = try #require(result.days.first)
        let cost = try #require(day.estimatedCost)
        #expect(abs(cost - 0.000405) < 0.000000001)
        #expect(day.unpricedTokens == 10)
        #expect(day.totalTokens == 170)
        #expect(result.warning?.contains("subscription") == true)
    }

    @Test func oneHourCacheRequiresExplicitRateAndFastNeverUsesStandardRate() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let prices = home.appendingPathComponent("prices.json")
        let rates = #"{"version":1,"models":{"fixture":{"inputPerMillion":2,"outputPerMillion":8,"cachedInputPerMillion":0.5,"cacheWritePerMillion":3,"cacheWriteOneHourPerMillion":4}}}"#
        try Data(rates.utf8).write(to: prices)
        let oneHour = #"{"timestamp":"2026-10-21T12:00:00Z","message":{"id":"cache","model":"fixture","usage":{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}"#
        let fast = #"{"timestamp":"2026-10-21T12:00:00Z","message":{"id":"fast","model":"fixture","usage":{"input_tokens":10,"output_tokens":5,"speed":"fast"}}}"#
        try corpus(home, path: "projects/one.jsonl", lines: [oneHour, fast])
        let result = try await LocalUsageHistory.scan(provider: .claude, directory: home, pricingFile: prices)
        let day = try #require(result.days.first)
        let cost = try #require(day.estimatedCost)
        #expect(abs(cost - 0.00047) < 0.000000001)
        #expect(day.unpricedTokens == 15)
        try Data(rates.replacingOccurrences(of: ",\"cacheWriteOneHourPerMillion\":4", with: "").utf8).write(to: prices)
        let missingRate = try await LocalUsageHistory.scan(provider: .claude, directory: home, pricingFile: prices)
        #expect(missingRate.days.first?.estimatedCost == nil)
        #expect(missingRate.days.first?.unpricedTokens == 165)
    }

    @Test(arguments: [
        #"{"version":2,"models":{}}"#,
        #"{"version":1,"models":{"fixture":{"inputPerMillion":-1,"outputPerMillion":8,"cachedInputPerMillion":0,"cacheWritePerMillion":3}}}"#,
        #"{"version":1,"models":{"fixture":{"inputPerMillion":2,"outputPerMillion":8,"cacheWritePerMillion":3}}}"#,
        #"{"version":1,"models":{"fixture":{"inputPerMillion":1e999,"outputPerMillion":8,"cachedInputPerMillion":0,"cacheWritePerMillion":3}}}"#
    ])
    func invalidCustomRatesAreRejectedWithoutLeakingPath(json: String) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let prices = home.appendingPathComponent("private-secret-prices.json")
        try Data(json.utf8).write(to: prices)
        do {
            _ = try await LocalUsageHistory.scan(provider: .claude, directory: home, pricingFile: prices)
            Issue.record("Invalid pricing unexpectedly accepted")
        } catch {
            #expect(!error.localizedDescription.contains("private-secret"))
            #expect(error.localizedDescription.contains("pricing JSON"))
        }
    }

    @Test func corruptOversizedAndOverflowRecordsAreSkippedWithoutTextLeakage() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let oversized = "{\"private-prompt\":\"" + String(repeating: "x", count: 4_194_305) + "\"}"
        let overflow = #"{"timestamp":"2026-10-21T12:00:00Z","message":{"id":"overflow","usage":{"input_tokens":1,"output_tokens":1,"cache_creation":{"ephemeral_5m_input_tokens":9223372036854775807,"ephemeral_1h_input_tokens":9223372036854775807}}}}"#
        try corpus(home, path: "projects/one.jsonl", lines: ["{secret-prompt", oversized, overflow, claude("good", input: 4, output: 2)])
        let result = try await LocalUsageHistory.scan(provider: .claude, directory: home)
        #expect(result.days.first?.totalTokens == 6)
        #expect(result.warning?.contains("incomplete") == true)
        #expect(result.warning?.contains("secret-prompt") == false)
        #expect(result.warning?.contains(home.path) == false)
    }

    @Test func datesUseLocalCalendarAndCRLFTailIsRead() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stamp = "2026-10-21T23:30:00-07:00"
        let line = claude("date", input: 2, output: 1, timestamp: stamp)
        try corpus(home, path: "projects/one.jsonl", lines: [line + "\r", claude("next", input: 3, output: 1, timestamp: stamp)], trailingNewline: false)
        let result = try await LocalUsageHistory.scan(provider: .claude, directory: home)
        let date = try #require(ISO8601DateFormatter().date(from: stamp))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        #expect(result.days.first?.day == formatter.string(from: date))
        #expect(result.days.first?.totalTokens == 7)
    }

    @Test func decreasingTotalsReseedWithoutInventingFullHistoricalTokens() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try corpus(home, path: "sessions/one.jsonl", lines: [
            codex("2026-10-21T12:00:00Z", totals: usage(1000, 100, 200)),
            codex("2026-10-21T12:01:00Z", totals: usage(100, 10, 20)),
            codex("2026-10-21T12:02:00Z", totals: usage(150, 15, 30))
        ])
        let result = try await LocalUsageHistory.scan(provider: .codex, directory: home)
        #expect(result.days.first?.totalTokens == 1260)
        #expect(result.warning?.contains("incomplete") == true)
    }

    @Test func activeRolloutWinsSameRelativeArchivedPathAndCacheIsNotDoubleCounted() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let prices = home.appendingPathComponent("prices.json")
        try Data(#"{"version":1,"models":{"fixture":{"inputPerMillion":2,"outputPerMillion":8,"cachedInputPerMillion":0.5,"cacheWritePerMillion":3}}}"#.utf8).write(to: prices)
        try corpus(home, path: "sessions/day/one.jsonl", lines: [
            context("fixture"), codex("2026-10-21T12:00:00Z", totals: usage(100, 30, 20))
        ])
        try corpus(home, path: "archived_sessions/day/one.jsonl", lines: [
            context("fixture"), codex("2026-10-21T12:00:00Z", totals: usage(999, 30, 99))
        ])
        let result = try await LocalUsageHistory.scan(provider: .codex, directory: home, pricingFile: prices)
        let day = try #require(result.days.first)
        #expect(day.inputTokens == 70)
        #expect(day.cachedTokens == 30)
        #expect(day.totalTokens == 120)
        let cost = try #require(day.estimatedCost)
        #expect(abs(cost - 0.000315) < 0.000000001)
        #expect(day.unpricedTokens == 0)
    }

    @Test func advisorWorkIsDistinctButOrdinaryIterationsAreNotRecounted() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let line = #"{"timestamp":"2026-10-21T12:00:00Z","message":{"id":"parent","model":"fixture","usage":{"input_tokens":100,"output_tokens":20,"iterations":[{"type":"message","model":null,"input_tokens":100,"output_tokens":20},{"type":"advisor_message","model":"advisor-model","input_tokens":10,"output_tokens":3,"cache_read_input_tokens":5,"cache_creation":{"ephemeral_1h_input_tokens":7}}]}}}"#
        try corpus(home, path: "projects/one.jsonl", lines: [line, line])
        let result = try await LocalUsageHistory.scan(provider: .claude, directory: home)
        let day = try #require(result.days.first)
        #expect(day.inputTokens == 117)
        #expect(day.outputTokens == 23)
        #expect(day.cachedTokens == 5)
        #expect(day.totalTokens == 145)
    }

    @Test func nullAdvisorIsSkippedWithoutLosingValidParentUsage() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let line = #"{"timestamp":"2026-10-21T12:00:00Z","message":{"id":"parent","model":"fixture","usage":{"input_tokens":10,"output_tokens":3,"iterations":[null]}}}"#
        try corpus(home, path: "projects/one.jsonl", lines: [line])
        let result = try await LocalUsageHistory.scan(provider: .claude, directory: home)
        #expect(result.days.first?.totalTokens == 13)
        #expect(result.warning?.contains("incomplete") == true)
    }

    @Test(arguments: ["priority", "batch"])
    func claudeServiceTiersNeverUseStandardParentOrAdvisorRates(tier: String) async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let prices = home.appendingPathComponent("prices.json")
        try Data(#"{"version":1,"models":{"fixture":{"inputPerMillion":2,"outputPerMillion":8,"cachedInputPerMillion":0.5,"cacheWritePerMillion":3}}}"#.utf8).write(to: prices)
        let parent = "{\"timestamp\":\"2026-10-21T12:00:00Z\",\"message\":{\"id\":\"parent\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":10,\"output_tokens\":3,\"speed\":\"standard\",\"service_tier\":\"\(tier)\"}}}"
        try corpus(home, path: "projects/parent.jsonl", lines: [parent])
        let parentResult = try await LocalUsageHistory.scan(provider: .claude, directory: home, pricingFile: prices)
        #expect(parentResult.days.first?.totalTokens == 13)
        #expect(parentResult.days.first?.unpricedTokens == 13)
        #expect(parentResult.days.first?.estimatedCost == nil)
        let advisor = "{\"timestamp\":\"2026-10-21T12:00:00Z\",\"message\":{\"id\":\"with-advisor\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":20,\"output_tokens\":4,\"service_tier\":\"standard\",\"iterations\":[{\"type\":\"advisor_message\",\"model\":\"fixture\",\"input_tokens\":5,\"output_tokens\":2,\"speed\":\"standard\",\"service_tier\":\"\(tier)\"}]}}}"
        try corpus(home, path: "projects/advisor.jsonl", lines: [advisor])
        let advisorResult = try await LocalUsageHistory.scan(provider: .claude, directory: home, pricingFile: prices)
        let day = try #require(advisorResult.days.first)
        #expect(day.totalTokens == 44)
        #expect(day.unpricedTokens == 20)
        let cost = try #require(day.estimatedCost)
        #expect(abs(cost - 0.000072) < 0.000000001)
    }

    @Test func distinctCodexSessionsRemainDistinctWhileCopiedSessionCountsOnce() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let event = codex("2026-10-21T12:00:00Z", totals: usage(100, 30, 20))
        let first = [sessionMeta("session-a"), context("fixture"), event]
        let second = [sessionMeta("session-b"), context("fixture"), event]
        try corpus(home, path: "sessions/first.jsonl", lines: first)
        try corpus(home, path: "sessions/second.jsonl", lines: second)
        try corpus(home, path: "archived_sessions/copy.jsonl", lines: first)
        let result = try await LocalUsageHistory.scan(provider: .codex, directory: home)
        #expect(result.days.first?.inputTokens == 140)
        #expect(result.days.first?.cachedTokens == 60)
        #expect(result.days.first?.outputTokens == 40)
        #expect(result.days.first?.totalTokens == 240)
        #expect(result.warning?.contains("incomplete") == false)
    }

    @Test func cancelledCallerDoesNotReadOrReturnHistory() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalUsageHistory.scan(provider: .claude, directory: home)
        }
        do {
            _ = try await request.value
            Issue.record("Cancelled scan unexpectedly returned history")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected cancellation, not a history or pricing error")
        }
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func corpus(_ home: URL, path: String, lines: [String], trailingNewline: Bool = true) throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try Data(text.utf8).write(to: file)
    }

    private func claude(_ id: String, request: String = "request", input: Int, output: Int, cached: Int = 0,
                        writes: Int = 0, sidechain: Bool = false, model: String = "fixture", timestamp: String = "2026-10-21T12:00:00Z") -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"requestId\":\"\(request)\",\"isSidechain\":\(sidechain),\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cached),\"cache_creation_input_tokens\":\(writes)}}}"
    }

    private func usage(_ input: Int, _ cached: Int, _ output: Int) -> String {
        "{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"output_tokens\":\(output),\"reasoning_output_tokens\":0,\"total_tokens\":\(input + output)}"
    }

    private func codex(_ timestamp: String, totals: String, last: String? = nil) -> String {
        let lastField = last.map { ",\"last_token_usage\":\($0)" } ?? ""
        return "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(totals)\(lastField)}}}"
    }

    private func sessionMeta(_ id: String) -> String {
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-10-21T12:00:00Z\",\"payload\":{\"id\":\"\(id)\",\"source\":\"cli\"}}"
    }

    private func context(_ model: String) -> String {
        "{\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\"}}"
    }

    private func taskStarted(_ timestamp: String, epoch: Double) -> String {
        "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"task_started\",\"started_at\":\(epoch)}}"
    }
}
