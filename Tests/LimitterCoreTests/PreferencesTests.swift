import XCTest
@testable import LimitterCore

final class PreferencesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_800_400)
    private func quota(_ provider: Provider, session: Double? = nil, weekly: Double? = nil) -> ProviderLimits {
        var result = ProviderLimits(provider: provider, source: "test")
        result.updatedAt = now
        var windows: [LimitWindow] = []
        if let session { windows.append(LimitWindow(id: "s", usedPercent: session, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600))) }
        if let weekly { windows.append(LimitWindow(id: "w", usedPercent: weekly, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))) }
        result.buckets = [LimitBucket(id: provider.id, name: "All models", windows: windows)]
        return result
    }
    func testMenuUsesSelectedWindowForBothProviders() {
        var settings = AppPreferences(); settings.menuProviders = .both
        let limits: [Provider: ProviderLimits] = [.codex: quota(.codex, session: 20, weekly: 2), .claude: quota(.claude, session: 80, weekly: 41)]
        let readings = MenuBarFormatter.readings(preferences: settings, limits: limits, history: HistorySnapshot(), now: now)
        XCTAssertEqual(MenuBarFormatter.label(preferences: settings, readings: readings), "CX W 98%  ·  CL W 59%")
        XCTAssertEqual(readings.map(\.usedPercent), [2, 41])
        settings.menuQuotaPeriod = .session; settings.menuMetric = .used; settings.menuProviders = .claude
        let updated = MenuBarFormatter.readings(preferences: settings, limits: limits, history: HistorySnapshot(), now: now)
        XCTAssertEqual(MenuBarFormatter.label(preferences: settings, readings: updated), "CL S 80%")
    }
    func testSessionSelectionNeverSilentlyFallsBackToWeekly() {
        var settings = AppPreferences(); settings.menuProviders = .both; settings.menuQuotaPeriod = .session; settings.menuProviders = .codex
        let readings = MenuBarFormatter.readings(preferences: settings, limits: [.codex: quota(.codex, weekly: 2)], history: HistorySnapshot(), now: now)
        XCTAssertEqual(readings.first?.value, "—")
        XCTAssertNil(readings.first?.usedPercent)
    }
    func testStaleFailedAndExpiredQuotasDoNotShowCurrentNumbers() {
        var settings = AppPreferences(); settings.menuProviders = .both; settings.menuProviders = .codex
        var stale = quota(.codex, weekly: 5); stale.updatedAt = now.addingTimeInterval(-601)
        var failed = quota(.codex, weekly: 5); failed.error = "offline"
        var expired = quota(.codex, weekly: 5)
        expired.buckets = [LimitBucket(id: "codex", name: "All models", windows: [LimitWindow(id: "w", usedPercent: 5, durationMinutes: 10080, resetsAt: now.addingTimeInterval(-1))])]
        for value in [stale, failed, expired] {
            let reading = MenuBarFormatter.readings(preferences: settings, limits: [.codex: value], history: HistorySnapshot(), now: now)
            XCTAssertEqual(reading.first?.value, "—")
        }
    }
    func testTokenTimeframesAndProviderFilteringChangeActualTotals() {
        var history = HistorySnapshot()
        let calendar = Calendar.current, today = calendar.startOfDay(for: now)
        for offset in 0..<30 {
            var day = UsageDay(date: calendar.date(byAdding: .day, value: -offset, to: today)!)
            day.codex = TokenUsage(input: 100); day.claude = TokenUsage(input: 200)
            history.days.append(day)
        }
        XCTAssertEqual(history.total(dayCount: 1, providers: [.codex, .claude], now: now).total, 300)
        XCTAssertEqual(history.total(dayCount: 7, providers: [.codex], now: now).total, 700)
        XCTAssertEqual(history.total(dayCount: 30, providers: [.claude], now: now).total, 6000)
        XCTAssertEqual(history.total(dayCount: 30, providers: [], now: now).total, 0)
        history.available = [.claude]
        var settings = AppPreferences(); settings.menuProviders = .both; settings.menuMetric = .tokens; settings.menuTokenPeriod = .month
        let readings = MenuBarFormatter.readings(preferences: settings, limits: [:], history: history, now: now)
        XCTAssertEqual(readings.map(\.value), ["—", "6.0K"])
    }
    func testPeriodCountsDeduplicateSessionsAndExcludeOlderRecords() {
        var history = HistorySnapshot()
        history.records[.codex] = [
            UsageRecord(id: "a", session: "one", date: now, usage: TokenUsage()),
            UsageRecord(id: "b", session: "one", date: now, usage: TokenUsage()),
            UsageRecord(id: "c", session: "two", date: now.addingTimeInterval(-10 * 86400), usage: TokenUsage())
        ]
        let week = history.activityCounts(dayCount: 7, providers: [.codex], now: now)
        let month = history.activityCounts(dayCount: 30, providers: [.codex], now: now)
        XCTAssertEqual(week.sessions, 1); XCTAssertEqual(week.requests, 2)
        XCTAssertEqual(month.sessions, 2); XCTAssertEqual(month.requests, 3)
    }
    func testPreferencesRoundTripAndHiddenProviders() throws {
        var settings = AppPreferences(); settings.menuProviders = .both
        settings.theme = .light; settings.showCodex = false; settings.showGrok = false; settings.showChart = false
        settings.menuMetric = .tokens; settings.menuTokenPeriod = .month; settings.chartPeriod = .fortnight
        settings.showSettingsOnLaunch = false; settings.showResetTimes = false
        let copy = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(copy, settings)
        XCTAssertEqual(copy.visibleProviders, [.claude])
        XCTAssertEqual(copy.menuProviders.providers, [.codex, .claude]) // Menu bar remains independently configurable.
    }
    func testReaderCanExpandFromSevenToThirtyDays() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".claude/projects/example")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let event: [String: Any] = ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-20 * 86400)), "sessionId": "s", "message": ["id": "m", "usage": ["input_tokens": 100, "output_tokens": 20]]]
        try JSONSerialization.data(withJSONObject: event).write(to: root.appendingPathComponent("history.jsonl"))
        let reader = HistoryReader(home: home)
        let week = await reader.read(now: now)
        let month = await reader.read(now: now, dayCount: 30)
        XCTAssertEqual(week.days.count, 7); XCTAssertEqual(month.days.count, 30)
        XCTAssertEqual(week.total(dayCount: 7, providers: [.claude], now: now).total, 0)
        XCTAssertEqual(month.total(dayCount: 30, providers: [.claude], now: now).total, 120)
    }
}
