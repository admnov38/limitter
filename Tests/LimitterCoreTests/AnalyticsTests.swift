import XCTest
@testable import LimitterCore

final class AnalyticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_800_400)
    private func transcript(_ events: [[String: Any]], provider: Provider) throws -> ParsedTranscript {
        let lines = try events.map { try JSONSerialization.data(withJSONObject: $0) }
        return TranscriptParser.parseDetailed(lines.reduce(Data()) { $0 + $1 + Data([10]) }, provider: provider, fileID: "fixture")
    }
    private func event(_ type: String, offset: TimeInterval = 0, payload: [String: Any]) -> [String: Any] {
        ["type": type, "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)), "payload": payload]
    }
    func testIndependentProviderWindowsAndTokenPeriodsSurviveReload() throws {
        var preferences = AppPreferences(); preferences.menuProviders = .both
        preferences.setQuotaPeriod(.weekly, for: .codex); preferences.setQuotaPeriod(.session, for: .claude)
        preferences.setTokenPeriod(.month, for: .codex); preferences.setTokenPeriod(.today, for: .claude)
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        var limits: [Provider: ProviderLimits] = [:]
        for provider in Provider.allCases {
            var value = ProviderLimits(provider: provider, source: "fixture"); value.updatedAt = now
            value.buckets = [.init(id: "quota", name: "All", windows: [
                .init(id: "weekly", usedPercent: 20, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3600)),
                .init(id: "session", usedPercent: 60, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600))])]
            limits[provider] = value
        }
        let readings = MenuBarFormatter.readings(preferences: restored, limits: limits, history: .init(), now: now)
        XCTAssertEqual(MenuBarFormatter.label(preferences: restored, readings: readings), "CX W 80%  ·  CL S 40%")
        XCTAssertTrue(readings[1].detail.contains("Session"))
        preferences.menuMetric = .tokens
        var history = HistorySnapshot(); history.available = Set(Provider.allCases)
        for offset in 0..<30 {
            var day = UsageDay(date: Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: now))!)
            day.codex = .init(input: 10); day.claude = .init(input: 20); history.days.append(day)
        }
        let tokens = MenuBarFormatter.readings(preferences: preferences, limits: [:], history: history, now: now)
        XCTAssertEqual(MenuBarFormatter.label(preferences: preferences, readings: tokens), "CX 30d 300  ·  CL 1d 20")
    }
    func testOldPreferencesMigrateWithoutResettingUserChoices() throws {
        let data = Data(#"{"theme":"Light","showCodex":false,"showChart":false,"menuQuotaPeriod":"Session","menuTokenPeriod":"Last 30 days","hoverToOpen":false}"#.utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertEqual(preferences.theme, .light); XCTAssertFalse(preferences.showCodex); XCTAssertFalse(preferences.showChart)
        XCTAssertFalse(preferences.hoverToOpen)
        XCTAssertEqual(preferences.quotaPeriod(for: .claude), .session)
        XCTAssertEqual(preferences.tokenPeriod(for: .codex), .month)
        XCTAssertTrue(preferences.showCurrentSession); XCTAssertTrue(preferences.showHeatmap)
    }
    func testCostAccountsForCacheWritesAndHourTTLWithoutDoubleCounting() {
        let claude = TokenUsage.claude(["input_tokens": 1_000_000, "output_tokens": 100_000, "cache_read_input_tokens": 2_000_000, "cache_creation_input_tokens": 1_000_000, "cache_creation": ["ephemeral_1h_input_tokens": 400_000]])
        XCTAssertEqual(claude.total, 4_100_000)
        let cost = APIRates.fable.cost(claude)
        XCTAssertEqual(cost.input, 10); XCTAssertEqual(cost.output, 5); XCTAssertEqual(cost.cacheRead, 0.5)
        XCTAssertEqual(cost.cacheWrite, 15.5); XCTAssertEqual(cost.total, 31)
        XCTAssertEqual((claude + claude).cacheWriteHour, 800_000)
        let codex = TokenUsage.codex(["input_tokens": 1_000_000, "cached_input_tokens": 600_000, "cache_write_input_tokens": 100_000, "output_tokens": 100_000])
        XCTAssertEqual(codex.input, 300_000); XCTAssertEqual(codex.total, 1_100_000)
        XCTAssertEqual(APIRates.astra.cost(codex).total, 9.85, accuracy: 0.00001)
        var invalid = APIRates.astra; invalid.input = .nan
        XCTAssertFalse(invalid.isValid); XCTAssertEqual(invalid.cost(codex).total, 0)
    }
    func testSessionEventsStateAndStaleness() throws {
        let start = event("session_meta", offset: -120, payload: ["id": "s1", "cwd": "/workspace/limitter"])
        let turn = event("turn_context", offset: -110, payload: ["model": "gpt-6-astra"])
        let running = event("event_msg", offset: -60, payload: ["type": "task_started"])
        let usage = event("token_usage_record", offset: -30, payload: ["session_id": "s1", "response_id": "r1", "usage": ["input_tokens": 100, "output_tokens": 20]])
        let parsed = try transcript([start, turn, running, usage], provider: .codex)
        let session = try XCTUnwrap(parsed.session)
        XCTAssertEqual(session.state(at: now), .running); XCTAssertEqual(session.state(at: now.addingTimeInterval(301)), .unknown)
        XCTAssertEqual(session.project, "limitter"); XCTAssertEqual(session.model, "gpt-6-astra")
        XCTAssertEqual(session.responses, 1); XCTAssertEqual(session.usage.total, 120)
        let completed = try transcript([start, turn, running, usage, event("event_msg", payload: ["type": "task_complete"])], provider: .codex)
        XCTAssertEqual(completed.session?.state(at: now), .idle)
        let interrupted = try transcript([start, running, event("event_msg", payload: ["type": "turn_aborted"])], provider: .codex)
        XCTAssertEqual(interrupted.session?.state(at: now), .interrupted)
    }
    func testClaudeActivityIsInferredAndCompletedTurnsAreIdle() throws {
        var message: [String: Any] = ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: now), "sessionId": "claude-session", "cwd": "/work/site", "message": ["id": "r1", "model": "claude-fable-5-1", "stop_reason": "tool_use", "usage": ["input_tokens": 5, "output_tokens": 5]]]
        XCTAssertEqual(try transcript([message], provider: .claude).session?.state(at: now), .recent)
        var body = message["message"] as! [String: Any]; body["stop_reason"] = "end_turn"; message["message"] = body
        XCTAssertEqual(try transcript([message], provider: .claude).session?.state(at: now), .idle)
        message["isApiErrorMessage"] = true
        let failed = try transcript([message], provider: .claude)
        XCTAssertEqual(failed.session?.state(at: now), .error); XCTAssertTrue(failed.records.isEmpty)
    }
    func testCurrentSessionPrefersFreshActiveThenLatestAndRespectsFilters() {
        var history = HistorySnapshot()
        let active = SessionSummary(provider: .codex, session: "a", project: "a", startedAt: now, lastActivity: now.addingTimeInterval(-20), observedState: .running)
        let idle = SessionSummary(provider: .claude, session: "b", project: "b", startedAt: now, lastActivity: now.addingTimeInterval(-5), observedState: .idle)
        history.recentSessions = [idle, active]
        XCTAssertEqual(history.currentSession(providers: Provider.allCases, now: now)?.id, active.id)
        XCTAssertEqual(history.currentSession(providers: [.claude], now: now)?.id, idle.id)
        XCTAssertEqual(history.currentSession(providers: Provider.allCases, now: now.addingTimeInterval(600))?.id, idle.id)
        XCTAssertNil(history.currentSession(providers: [], now: now))
    }
    func testCadenceUsesCalendarDaysAndDoesNotBreakStreakBeforeTodayStarts() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        let today = calendar.startOfDay(for: now)
        var history = HistorySnapshot(); history.available = [.codex]
        for offset in -5...0 {
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            history.days.append(UsageDay(date: date))
            if [-4, -3, -2, -1].contains(offset) { history.records[.codex, default: []].append(UsageRecord(id: "\(offset)", session: "s", date: date, usage: .init(input: 1))) }
        }
        let stats = history.activity(providers: [.codex], now: now, calendar: calendar)
        XCTAssertEqual(stats.currentStreak, 4); XCTAssertEqual(stats.bestStreak, 4); XCTAssertEqual(stats.activeDays, 4)
        XCTAssertEqual(stats.todayResponses, 0); XCTAssertTrue(stats.headline.contains("No coding today"))
        XCTAssertEqual(history.activity(providers: [.claude], now: now).headline, "Ready when you are.")
        for index in 0..<100 { history.records[.codex, default: []].append(UsageRecord(id: "today\(index)", session: "s", date: now, usage: .init(input: 1))) }
        XCTAssertEqual(history.activity(providers: [.codex], now: now, calendar: calendar).headline, "You’re going beast mode today.")
    }
    func testReaderExpandsTo84DaysWithoutDuplicatingSessionUsage() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex/sessions")
        let archive = home.appendingPathComponent(".codex/archived_sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let events = [
            event("session_meta", offset: -60 * 86400, payload: ["id": "old", "cwd": "/work/old-project"]),
            event("token_usage_record", offset: -60 * 86400, payload: ["session_id": "old", "response_id": "response", "usage": ["input_tokens": 100, "output_tokens": 20]]),
            event("event_msg", offset: -60 * 86400, payload: ["type": "task_complete"])
        ]
        let data = try events.map { try JSONSerialization.data(withJSONObject: $0) }.reduce(Data()) { $0 + $1 + Data([10]) }
        try data.write(to: root.appendingPathComponent("old.jsonl"))
        try data.write(to: archive.appendingPathComponent("copy.jsonl"))
        let reader = HistoryReader(home: home)
        let month = await reader.read(now: now, dayCount: 30)
        let quarter = await reader.read(now: now, dayCount: 84)
        XCTAssertEqual(month.total(dayCount: 84, providers: [.codex], now: now).total, 0)
        XCTAssertEqual(quarter.days.count, 84)
        XCTAssertEqual(quarter.total(dayCount: 84, providers: [.codex], now: now).total, 120)
        XCTAssertEqual(quarter.recentSessions.count, 1)
        XCTAssertEqual(quarter.recentSessions.first?.usage.total, 120)
        XCTAssertEqual(quarter.recentSessions.first?.responses, 1)
    }

}
