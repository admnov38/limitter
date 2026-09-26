import XCTest
@testable import LimitterCore

final class ModelPricingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_800_400)
    private func transcript(_ rows: [[String: Any]], provider: Provider = .claude) throws -> ParsedTranscript {
        let data = try rows.reduce(Data()) { try $0 + JSONSerialization.data(withJSONObject: $1) + Data([10]) }
        return TranscriptParser.parseDetailed(data, provider: provider, fileID: "session.jsonl")
    }
    private func message(_ id: String, model: String?, output: Int = 100_000) -> [String: Any] {
        var body: [String: Any] = ["id": id, "usage": ["input_tokens": 1_000_000, "output_tokens": output, "cache_read_input_tokens": 2_000_000, "cache_creation_input_tokens": 1_000_000, "cache_creation": ["ephemeral_1h_input_tokens": 400_000]]]
        body["model"] = model
        return ["type": "assistant", "sessionId": "mixed", "timestamp": ISO8601DateFormatter().string(from: now), "message": body]
    }
    func testClaudeSwitchesModelsAndKeepsFableVersionsAtDifferentCachePrices() throws {
        let rows = [message("opus", model: "claude-opus-5", output: 10), message("opus", model: "claude-opus-5"), message("opus48", model: "claude-opus-4-8"), message("fable", model: "claude-fable-5"), message("fable51", model: "claude-fable-5-1")]
        let parsed = try transcript(rows)
        XCTAssertEqual(parsed.records.count, 4)
        let estimate = PriceEstimate(usage: parsed.session!.modelUsage, provider: .claude, preferences: .init())
        XCTAssertEqual(estimate.rows.count, 4)
        XCTAssertTrue(estimate.isComplete)
        XCTAssertEqual(estimate.rows.first { $0.model == "claude-opus-5" }?.cost?.total ?? 0, 16.25, accuracy: 0.00001)
        XCTAssertEqual(estimate.rows.first { $0.model == "claude-opus-4-8" }?.cost?.total ?? 0, 16.25, accuracy: 0.00001)
        XCTAssertEqual(estimate.rows.first { $0.model == "claude-fable-5" }?.cost?.total ?? 0, 32.5, accuracy: 0.00001)
        XCTAssertEqual(estimate.rows.first { $0.model == "claude-fable-5-1" }?.cost?.total ?? 0, 31, accuracy: 0.00001)
        XCTAssertEqual(estimate.cost.total, 96, accuracy: 0.00001)
        XCTAssertEqual(estimate.totalTokens, parsed.session?.usage.total)
    }
    func testMissingModelNeverInheritsPreviousClaudeModelAndUnknownRatesRemainUnpriced() throws {
        let parsed = try transcript([message("one", model: "claude-opus-5"), message("unknown", model: nil), message("future", model: "claude-opus-99")])
        let estimate = PriceEstimate(usage: parsed.session!.modelUsage, provider: .claude, preferences: .init())
        XCTAssertFalse(estimate.isComplete)
        XCTAssertEqual(estimate.unpricedTokens, 8_200_000)
        XCTAssertEqual(estimate.cost.total, 16.25, accuracy: 0.00001)
        XCTAssertTrue(estimate.formatted.hasPrefix("≥ "))
        XCTAssertEqual(ModelPricing.rates(for: "claude-haiku-4-5-20251001", provider: .claude)?.input, 1)
        XCTAssertNil(ModelPricing.rates(for: "claude-fable-5-99", provider: .claude))
        let entirelyUnknown = PriceEstimate(usage: ["mystery": .init(input: 500)], provider: .claude, preferences: .init())
        XCTAssertEqual(entirelyUnknown.formatted, "—")
    }
    func testBenchmarkRemainsOptionalAndPreferencesDefaultToRecordedModelsOnUpgrade() throws {
        var prefs = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"apiTokenPeriod":"Last 7 days","claudeQuotaPeriod":"Session"}"#.utf8))
        XCTAssertEqual(prefs.pricingMode, .recordedModels)
        XCTAssertEqual(prefs.apiTokenPeriod, .week)
        XCTAssertEqual(prefs.quotaPeriod(for: .claude), .session)
        prefs.pricingMode = .benchmark
        let parsed = try transcript([message("a", model: "claude-opus-5")])
        let estimate = PriceEstimate(usage: parsed.session!.modelUsage, provider: .claude, preferences: prefs)
        XCTAssertEqual(estimate.cost.total, 31, accuracy: 0.00001)
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(restored.pricingMode, .benchmark)
    }
    func testCodexAndGrokRecordModelAttributionWithoutDuplicatingUsage() throws {
        let date = ISO8601DateFormatter().string(from: now)
        let codex = try transcript([
            ["timestamp": date, "type": "turn_context", "payload": ["model": "gpt-6-astra"]],
            ["timestamp": date, "type": "token_usage_record", "payload": ["response_id": "a", "usage": ["input_tokens": 100]]],
            ["timestamp": date, "type": "turn_context", "payload": ["model": "gpt-5.6-sol"]],
            ["timestamp": date, "type": "token_usage_record", "payload": ["response_id": "b", "usage": ["input_tokens": 200]]]
        ], provider: .codex)
        XCTAssertEqual(codex.session?.modelUsage["gpt-6-astra"]?.total, 100)
        XCTAssertEqual(codex.session?.modelUsage["gpt-5.6-sol"]?.total, 200)
        let grok = try transcript([["timestamp": now.timeIntervalSince1970, "method": "_x.ai/session/update", "params": ["sessionId": "g", "update": ["sessionUpdate": "turn_completed", "prompt_id": "p", "usage": ["inputTokens": 1000, "cachedReadTokens": 600, "outputTokens": 200, "modelCalls": 2, "modelUsage": ["grok-4.6-build": ["inputTokens": 500, "cachedReadTokens": 300, "outputTokens": 100], "grok-4.5": ["inputTokens": 500, "cachedReadTokens": 300, "outputTokens": 100]]]]]]], provider: .grok)
        XCTAssertEqual(grok.session?.modelUsage.count, 2)
        XCTAssertEqual(grok.session?.modelUsage.values.reduce(0) { $0 + $1.total }, 1200)
        XCTAssertTrue(PriceEstimate(usage: grok.session!.modelUsage, provider: .grok, preferences: .init()).isComplete)
    }
    func testIndexedModelTotalsRespectTodayPeriodProviderAndTimezone() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 7200)!
        let today = calendar.startOfDay(for: now)
        var history = HistorySnapshot()
        history.records[.claude] = [
            .init(id: "old", session: "s", date: today.addingTimeInterval(-1), usage: .init(input: 1000), model: "claude-opus-5"),
            .init(id: "now", session: "s", date: today, usage: .init(input: 2000), model: "claude-fable-5"),
            .init(id: "future", session: "s", date: now.addingTimeInterval(10), usage: .init(input: 5000), model: "claude-fable-5")]
        history.records[.codex] = [.init(id: "other", session: "s", date: now, usage: .init(input: 7000), model: "gpt-6-astra")]
        let raw = history.modelUsage(dayCount: 1, provider: .claude, now: now, calendar: calendar)
        history.buildIndex(now: now, calendar: calendar)
        XCTAssertEqual(history.modelUsage(dayCount: 1, provider: .claude, now: now, calendar: calendar), raw)
        XCTAssertEqual(raw, ["claude-fable-5": .init(input: 2000)])
        XCTAssertEqual(history.modelUsage(dayCount: 7, provider: .claude, now: now, calendar: calendar).values.reduce(0) { $0 + $1.total }, 3000)
    }
    func testPartialModelMapsPreserveUnattributedTokensAndCacheDuration() {
        let partition = ModelPricing.partition(.init(input: 1000, output: 200), reported: ["grok-4.6": .init(input: 400, output: 100)])
        XCTAssertEqual(partition[ModelPricing.unknown], .init(input: 600, output: 100))
        let invalidTTL = ModelPricing.partition(.init(cacheWrite: 100, cacheWriteHour: 100), reported: ["claude-opus-5": .init(cacheWrite: 100)])
        XCTAssertEqual(invalidTTL[ModelPricing.unknown], .init(cacheWrite: 100, cacheWriteHour: 100))
    }
    func testClaudeTotalInputIncludesBothCacheCategoriesWithoutDoubleCountingHourWrites() {
        let usage = TokenUsage.claude(["input_tokens": 50, "cache_read_input_tokens": 100_000, "cache_creation_input_tokens": 10_000,
                                      "cache_creation": ["ephemeral_1h_input_tokens": 4_000], "output_tokens": 1_000])
        let cost = ModelPricing.rates(for: "claude-opus-5", provider: .claude)!.cost(usage)
        XCTAssertEqual(usage.input, 50)
        XCTAssertEqual(usage.totalInput, 110_050)
        XCTAssertEqual(usage.total, 111_050)
        XCTAssertEqual(cost.input, 0.00025, accuracy: 0.0000001)
        XCTAssertEqual(cost.totalInput, 0.12775, accuracy: 0.0000001)
        XCTAssertEqual(cost.total, 0.15275, accuracy: 0.0000001)
    }
}
