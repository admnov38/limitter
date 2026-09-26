import XCTest
@testable import LimitterCore

final class SyncRegressionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_788_800_400)
    func payload(session: Any? = nil, weekly: Any? = nil) -> [String: Any] {
        var limits: [String: Any] = [:]
        limits["five_hour"] = session; limits["seven_day"] = weekly
        return ["rate_limits": limits]
    }
    func window(_ used: Double, reset: TimeInterval = 3600) -> [String: Any] {
        ["used_percentage": used, "resets_at": now.addingTimeInterval(reset).timeIntervalSince1970]
    }
    func testMissingOrNullSessionDoesNotDiscardWeeklyQuota() throws {
        let snapshot = LimitsParser.claude(payload(session: NSNull(), weekly: window(17)), updatedAt: now)
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 17)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .session, now: now).state, .missing)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .weekly, now: now).state, .live)
    }
    func testPartialAndStartupCapturesPreserveWindowObservationTimes() throws {
        let first = ClaudeQuotaCache.merge(payload(session: window(23), weekly: window(17, reset: 86400)), previous: [:], now: now)
        let later = now.addingTimeInterval(900)
        let partial = ClaudeQuotaCache.merge(payload(session: NSNull(), weekly: window(19, reset: 86400)), previous: first, now: later)
        let empty = ClaudeQuotaCache.merge(["cwd": "/private", "rate_limits": NSNull()], previous: partial, now: later.addingTimeInterval(50))
        let snapshot = LimitsParser.claude(empty, updatedAt: later)
        XCTAssertEqual(snapshot.windows.first(where: { $0.title == "Session" })?.observedAt, now)
        XCTAssertEqual(snapshot.windows.first(where: { $0.title == "Weekly" })?.observedAt, later)
        let session = QuotaPresentation(provider: .claude, snapshot: snapshot, period: .session, now: later)
        XCTAssertEqual(session.state, .cached); XCTAssertEqual(session.window?.usedPercent, 23)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .weekly, now: later).state, .live)
        var preferences = AppPreferences(); preferences.menuProviders = .claude; preferences.setQuotaPeriod(.session, for: .claude)
        let readings = MenuBarFormatter.readings(preferences: preferences, limits: [.claude: snapshot], history: .init(), now: later)
        XCTAssertEqual(readings.first?.value, "~77%")
        XCTAssertNil(empty["cwd"])
    }
    func testExpiredCachedSessionIsNeverPresentedAsFreshOrZero() {
        let captured = ClaudeQuotaCache.merge(payload(session: window(90, reset: 10), weekly: window(17)), previous: [:], now: now)
        let later = now.addingTimeInterval(900)
        let absent = ClaudeQuotaCache.merge([:], previous: captured, now: later)
        let snapshot = LimitsParser.claude(absent, updatedAt: later)
        let session = QuotaPresentation(provider: .claude, snapshot: snapshot, period: .session, now: later)
        XCTAssertEqual(session.state, .expired); XCTAssertFalse(session.hasValue)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .weekly, now: later).state, .cached)
    }
    func testMalformedSessionReportsSpecificErrorWithoutBreakingWeekly() {
        for invalid: Any in [true, -1, "42"] {
            let value = ClaudeQuotaCache.merge(payload(session: ["used_percentage": invalid, "resets_at": now.addingTimeInterval(3600).timeIntervalSince1970], weekly: window(17)), previous: [:], now: now)
            let snapshot = LimitsParser.claude(value, updatedAt: now)
            XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .session, now: now).state, .error)
            XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .weekly, now: now).state, .live)
        }
        let value = ClaudeQuotaCache.merge(payload(session: window(0), weekly: window(17.5)), previous: [:], now: now)
        let snapshot = LimitsParser.claude(value, updatedAt: now)
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0, 17.5])
    }
    func testClaudeOverLimitUsageIsPreservedAndOnlyTheVisualMeterIsCapped() throws {
        let value = ClaudeQuotaCache.merge(payload(session: window(106), weekly: window(52)), previous: [:], now: now)
        let snapshot = LimitsParser.claude(value, updatedAt: now)
        let session = QuotaPresentation(provider: .claude, snapshot: snapshot, period: .session, now: now)
        XCTAssertEqual(session.state, .live)
        let window = try XCTUnwrap(session.window)
        XCTAssertEqual(window.usedPercent, 106); XCTAssertEqual(window.remaining, 0); XCTAssertEqual(window.progress, 1)
        var preferences = AppPreferences(); preferences.menuProviders = .claude; preferences.setQuotaPeriod(.session, for: .claude)
        preferences.menuMetric = .used
        XCTAssertEqual(MenuBarFormatter.readings(preferences: preferences, limits: [.claude: snapshot], history: .init(), now: now).first?.value, "106%")
        preferences.menuMetric = .remaining
        XCTAssertEqual(MenuBarFormatter.readings(preferences: preferences, limits: [.claude: snapshot], history: .init(), now: now).first?.value, "0%")
    }
    func testNullSessionPercentageMeansNotReported() {
        let value = ClaudeQuotaCache.merge(payload(session: ["used_percentage": NSNull(), "resets_at": NSNull()], weekly: window(52)), previous: [:], now: now)
        let snapshot = LimitsParser.claude(value, updatedAt: now)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .session, now: now).state, .missing)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .weekly, now: now).state, .live)
        let broken = ClaudeQuotaCache.merge(payload(session: ["used_percentage": "bad"]), previous: [:], now: now)
        let cleared = ClaudeQuotaCache.merge(payload(session: NSNull()), previous: broken, now: now)
        XCTAssertNil((cleared["window_errors"] as? [String: String])?["Session"])
    }
    func testSessionQuotaCanArriveBeforeAResetTimestamp() {
        let value = ClaudeQuotaCache.merge(payload(session: ["used_percentage": 0, "resets_at": NSNull()], weekly: window(52)), previous: [:], now: now)
        let snapshot = LimitsParser.claude(value, updatedAt: now)
        let session = QuotaPresentation(provider: .claude, snapshot: snapshot, period: .session, now: now)
        XCTAssertEqual(session.state, .live); XCTAssertEqual(session.window?.usedPercent, 0)
        XCTAssertNil(session.window?.resetsAt); XCTAssertEqual(Format.reset(session.window?.resetsAt), "Reset unavailable")
        XCTAssertFalse(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .session, now: now.addingTimeInterval(601)).hasValue)
    }
    func testValidUpdateClearsOnlyItsOwnError() {
        let broken = ClaudeQuotaCache.merge(payload(session: ["used_percentage": "bad"], weekly: ["used_percentage": "bad"]), previous: [:], now: now)
        let repaired = ClaudeQuotaCache.merge(payload(session: window(12)), previous: broken, now: now)
        let snapshot = LimitsParser.claude(repaired, updatedAt: now)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .session, now: now).state, .live)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .weekly, now: now).state, .error)
    }
    func testIndexedCountsMatchRawCountsAndTodayHourlyTokens() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        let start = calendar.startOfDay(for: now)
        var history = HistorySnapshot()
        for provider in Provider.allCases {
            history.records[provider] = [
                UsageRecord(id: provider.id + "1", session: "same-id", date: start.addingTimeInterval(-1), usage: .init(input: 900)),
                UsageRecord(id: provider.id + "2", session: "same-id", date: start, usage: .init(input: 10, output: 5)),
                UsageRecord(id: provider.id + "3", session: "same-id", date: now, usage: .init(input: 20, output: 10)),
                UsageRecord(id: provider.id + "future", session: "later", date: now.addingTimeInterval(100), usage: .init(input: 500))
            ]
        }
        let daily = history.dailyResponses(providers: Provider.allCases, calendar: calendar, now: now)
        let counts = history.activityCounts(dayCount: 1, providers: Provider.allCases, now: now, calendar: calendar)
        history.buildIndex(now: now, calendar: calendar)
        XCTAssertEqual(history.dailyResponses(providers: Provider.allCases, calendar: calendar, now: now), daily)
        let indexed = history.activityCounts(dayCount: 1, providers: Provider.allCases, now: now, calendar: calendar)
        XCTAssertEqual(indexed.sessions, counts.sessions); XCTAssertEqual(indexed.sessions, Provider.allCases.count); XCTAssertEqual(indexed.requests, counts.requests)
        let hours = history.todayHours(providers: Provider.allCases, now: now, calendar: calendar)
        XCTAssertTrue(hours.allSatisfy { calendar.isDate($0.date, inSameDayAs: now) })
        XCTAssertEqual(hours.reduce(0) { $0 + $1.tokens(for: nil) }, 45 * Provider.allCases.count)
        XCTAssertEqual(history.todayHours(providers: [.claude], now: now, calendar: calendar).reduce(0) { $0 + $1.tokens(for: nil) }, 45)
    }
    func testAPISelectionMigratesAndPersistsIndependentlyFromActivity() throws {
        var settings = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"tokenPeriod":"Last 7 days"}"#.utf8))
        XCTAssertEqual(settings.apiTokenPeriod, .week)
        settings.apiTokenPeriod = .month
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.tokenPeriod, .week); XCTAssertEqual(restored.apiTokenPeriod, .month)
    }
    func testHeatmapIsDetachedFromTranscriptSize() {
        var history = HistorySnapshot()
        let day = Calendar.current.startOfDay(for: now)
        history.days = [UsageDay(date: day)]
        history.available = [.codex]
        history.records[.codex] = (0..<100_000).map { UsageRecord(id: "\($0)", session: "\($0 % 100)", date: now, usage: .init(input: 1)) }
        history.buildIndex(now: now)
        let heatmap = history.heatmap(providers: [.codex], now: now)
        XCTAssertEqual(heatmap.days.first?.responses, 100_000)
        XCTAssertEqual(heatmap.summary.todayResponses, 100_000)
        // The hover view receives only this 84-day-or-smaller value; no transcripts or store reference.
        XCTAssertEqual(heatmap.days.count, 1)
        XCTAssertEqual(history.activityCounts(dayCount: 1, providers: [.codex], now: now).sessions, 100)
    }
}
