import XCTest
@testable import LimitterCore

final class GrokTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_800_400)
    private func billing(_ percentage: Any? = 42) -> [String: Any] {
        var config: [String: Any] = ["currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "start": ISO8601DateFormatter().string(from: now.addingTimeInterval(-86400)), "end": ISO8601DateFormatter().string(from: now.addingTimeInterval(6 * 86400))]]
        if let percentage { config["creditUsagePercent"] = percentage }
        return ["config": config, "subscription_tier": "SuperGrok"]
    }
    func testLiveWeeklyPoolPreservesZeroAndOverLimit() {
        for percentage in [0.0, 42, 106] {
            let snapshot = GrokBillingParser.parse(billing(percentage), now: now)
            let status = QuotaPresentation(provider: .grok, snapshot: snapshot, period: .weekly, now: now)
            XCTAssertEqual(status.state, .live)
            XCTAssertEqual(status.window?.usedPercent, percentage)
            XCTAssertEqual(status.window?.durationMinutes, 10080)
            XCTAssertEqual(snapshot.plan, "SuperGrok")
            XCTAssertLessThanOrEqual(status.window!.progress, 1)
            XCTAssertGreaterThanOrEqual(status.window!.remaining, 0)
            XCTAssertEqual(QuotaPresentation(provider: .grok, snapshot: snapshot, period: .session, now: now).state, .missing)
        }
    }
    func testMissingPercentageDoesNotBecomeZeroAndKeepsResetInformation() {
        for value in [billing(nil), billing(NSNull())] {
            let snapshot = GrokBillingParser.parse(value, now: now)
            let status = QuotaPresentation(provider: .grok, snapshot: snapshot, period: .weekly, now: now)
            XCTAssertEqual(status.state, .missing)
            XCTAssertTrue(status.message.contains("hasn’t reported"))
            XCTAssertTrue(status.message.contains("Resets"))
            XCTAssertEqual(snapshot.updatedAt, now)
            XCTAssertNil(status.window)
        }
    }
    func testMalformedFailedStaleAndExpiredGrokQuotasAreUnavailable() {
        for value: Any in ["42", -1, true, Double.infinity] {
            let snapshot = GrokBillingParser.parse(billing(value), now: now)
            XCTAssertEqual(QuotaPresentation(provider: .grok, snapshot: snapshot, period: .weekly, now: now).state, .error)
        }
        let invalid = GrokBillingParser.parse([:], now: now)
        XCTAssertNotNil(invalid.error)
        let valid = GrokBillingParser.parse(billing(), now: now)
        XCTAssertFalse(QuotaPresentation(provider: .grok, snapshot: valid, period: .weekly, now: now.addingTimeInterval(601)).hasValue)
        XCTAssertEqual(QuotaPresentation(provider: .grok, snapshot: valid, period: .weekly, now: now.addingTimeInterval(7 * 86400)).state, .expired)
        var failed = valid; failed.error = "Offline"
        XCTAssertFalse(QuotaPresentation(provider: .grok, snapshot: failed, period: .weekly, now: now).hasValue)
        let monthly = GrokBillingParser.parse(["config": ["currentPeriod": ["type": "USAGE_PERIOD_TYPE_MONTHLY"], "creditUsagePercent": 50]], now: now)
        XCTAssertTrue(monthly.windows.isEmpty)
    }
    private func update(_ fields: [String: Any], session: String = "parent", date: Date? = nil) -> [String: Any] {
        let stamp = date ?? now
        return ["timestamp": stamp.timeIntervalSince1970, "method": ["turn_completed", "subagent_spawned"].contains(fields["sessionUpdate"] as? String ?? "") ? "_x.ai/session/update" : "session/update", "params": ["sessionId": session, "update": fields, "_meta": ["agentTimestampMs": stamp.timeIntervalSince1970 * 1000]]]
    }
    private func turn(_ prompt: String, session: String = "parent", input: Int = 1000, calls: Int = 4, date: Date? = nil) -> [String: Any] {
        update(["sessionUpdate": "turn_completed", "prompt_id": prompt, "stop_reason": "end_turn", "usage": ["inputTokens": input, "cachedReadTokens": 600, "cacheCreationTokens": 100, "outputTokens": 200, "reasoningTokens": 150, "modelCalls": calls]], session: session, date: date)
    }
    private func jsonl(_ values: [[String: Any]]) throws -> Data {
        try values.reduce(Data()) { try $0 + JSONSerialization.data(withJSONObject: $1) + Data([10]) }
    }
    func testTurnLedgerDeduplicatesStreamingAndDoesNotDoubleCountCacheOrReasoning() throws {
        let values = [update(["sessionUpdate": "user_message_chunk", "_meta": ["modelId": "grok-4.6"]]), update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "ignored"]]), turn("p1"), turn("p1"), turn("p2", input: 2000, calls: 6)]
        let parsed = GrokTranscriptParser.parse(try jsonl(values), fileID: "/tmp/%2Fwork%2Fapp/parent/updates.jsonl")
        XCTAssertEqual(parsed.records.count, 2)
        XCTAssertEqual(parsed.records.reduce(0) { $0 + $1.usage.total }, 3400)
        XCTAssertEqual(parsed.records.reduce(0) { $0 + $1.responses }, 10)
        let first = parsed.records.first { $0.id == "p1" }!.usage
        XCTAssertEqual(first, TokenUsage(input: 300, output: 200, cached: 600, cacheWrite: 100))
        XCTAssertEqual(parsed.session?.project, "app")
        XCTAssertEqual(parsed.session?.model, "grok-4.6")
        XCTAssertEqual(parsed.session?.state(at: now), .idle)
        XCTAssertEqual(parsed.session?.responses, 10)
        XCTAssertEqual(APIRates.grok46.cost(first).total, 0.0023, accuracy: 0.0000001)
    }
    func testSessionActivityDoesNotInventSpendBeforeCompletion() throws {
        let active = GrokTranscriptParser.parse(try jsonl([update(["sessionUpdate": "agent_thought_chunk"])]), fileID: "/tmp/session/updates.jsonl")
        XCTAssertTrue(active.records.isEmpty)
        XCTAssertEqual(active.session?.state(at: now), .running)
        XCTAssertEqual(active.session?.state(at: now.addingTimeInterval(301)), .unknown)
        let cancelled = GrokTranscriptParser.parse(try jsonl([update(["sessionUpdate": "turn_completed", "stop_reason": "cancelled"])]), fileID: "/tmp/session/updates.jsonl")
        XCTAssertEqual(cancelled.session?.observedState, .interrupted)
        XCTAssertTrue(cancelled.records.isEmpty)
    }
    func testReaderAvoidsChildAndMirrorLogDoubleCountingAndUsesCompletionDay() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".grok/sessions/%2Fwork%2Fapp")
        let start = Calendar.current.startOfDay(for: now)
        let old = start.addingTimeInterval(-1)
        let parent = [update(["sessionUpdate": "subagent_spawned", "child_session_id": "child", "parent_prompt_id": "p1"], date: old), turn("p1"), turn("older", date: old)]
        for (session, events) in [("parent", parent), ("child", [turn("child-prompt", session: "child")])] {
            let dir = root.appendingPathComponent(session)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try jsonl(events)
            try data.write(to: dir.appendingPathComponent("updates.jsonl"))
            try data.write(to: dir.appendingPathComponent("chat_history.jsonl"))
            try data.write(to: dir.appendingPathComponent("events.jsonl"))
        }
        let reader = HistoryReader(home: home)
        let history = await reader.read(now: now, dayCount: 7)
        XCTAssertEqual(history.available, [.grok])
        XCTAssertEqual(history.total(dayCount: 7, providers: [.grok], now: now).total, 2400)
        XCTAssertEqual(history.total(dayCount: 1, providers: [.grok], now: now).total, 1200)
        XCTAssertEqual(history.requests[.grok], 4)
        XCTAssertEqual(history.sessions[.grok], 1)
        XCTAssertEqual(history.recentSessions.count, 1)
        XCTAssertEqual(history.heatmap(providers: [.grok], now: now).summary.todayResponses, 4)
        XCTAssertEqual(history.todayHours(providers: [.grok], now: now).reduce(0) { $0 + $1.grok.total }, 1200)
        let cached = await reader.read(now: now, dayCount: 7)
        XCTAssertEqual(cached.total(for: .grok), history.total(for: .grok))
    }
    func testAllProviderAggregationAndIndependentPeriodsSurviveMigration() throws {
        let legacy = Data(#"{"menuProviders":"Both providers","theme":"Light","claudeQuotaPeriod":"Session","codexTokenPeriod":"Last 30 days","tokenPeriod":"Last 7 days"}"#.utf8)
        var preferences = try JSONDecoder().decode(AppPreferences.self, from: legacy)
        XCTAssertEqual(preferences.menuProviders.providers, [.codex, .claude])
        XCTAssertEqual(preferences.visibleProviders, Provider.allCases)
        XCTAssertEqual(preferences.grokRates, .grok46)
        preferences.menuProviders = .all
        preferences.setTokenPeriod(.week, for: .grok)
        preferences.setQuotaPeriod(.session, for: .grok)
        let saved = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(saved.tokenPeriod(for: .grok), .week)
        XCTAssertEqual(saved.tokenPeriod(for: .codex), .month)
        XCTAssertEqual(saved.quotaPeriod(for: .claude), .session)
        XCTAssertEqual(saved.quotaPeriod(for: .grok), .weekly)
        XCTAssertEqual(saved.theme, .light)
        XCTAssertEqual(Provider.grok.quotaPeriods, [.weekly])
        var history = HistorySnapshot()
        var day = UsageDay(date: Calendar.current.startOfDay(for: now))
        day.codex = .init(input: 10); day.claude = .init(input: 20); day.grok = .init(input: 30)
        history.days = [day]; history.today = [.codex: day.codex, .claude: day.claude, .grok: day.grok]
        XCTAssertEqual(history.total(for: nil).total, 60)
        XCTAssertEqual(history.total(dayCount: 1, providers: [.codex, .grok], now: now).total, 40)
        XCTAssertEqual(day.tokens(for: nil), 60)
        var onlyGrok = saved; onlyGrok.menuProviders = .grok
        let readings = MenuBarFormatter.readings(preferences: onlyGrok, limits: [.grok: GrokBillingParser.parse(billing(), now: now)], history: history, now: now)
        XCTAssertEqual(MenuBarFormatter.label(preferences: onlyGrok, readings: readings), "GK W 58%")
    }
}
