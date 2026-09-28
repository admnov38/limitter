import XCTest
@testable import LimitterCore

final class ChartBucketTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_800_400) // 2026-09-07 17:00:00 UTC
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testOptionsMatchTheVisibleRange() {
        XCTAssertEqual(ChartInterval.options(dayCount: 1), [.minutes15, .minutes30, .hour, .hours3, .hours6, .hours12])
        XCTAssertEqual(ChartInterval.options(dayCount: 7), [.hour, .hours3, .hours6, .hours12, .day])
        XCTAssertEqual(ChartInterval.options(dayCount: 14), [.hours3, .hours6, .hours12, .day])
        XCTAssertEqual(ChartInterval.options(dayCount: 30), [.hours6, .hours12, .day])
        XCTAssertEqual(ChartInterval.hour.resolved(for: 7), .hour)
        XCTAssertEqual(ChartInterval.hour.resolved(for: 14), .hours3)
        XCTAssertEqual(ChartInterval.hour.resolved(for: 30), .hours6)
        XCTAssertEqual(ChartInterval.day.resolved(for: 1), .hours12)
        XCTAssertEqual(ChartInterval.minutes15.resolved(for: 1), .minutes15)
    }

    func testBucketsConserveTokensAndRespectBoundaries() {
        let calendar = calendar
        let today = calendar.startOfDay(for: now)
        func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
            calendar.date(byAdding: .minute, value: ((dayOffset * 24) + hour) * 60 + minute, to: today)!
        }
        var history = HistorySnapshot()
        history.records[.codex] = [
            .init(id: "a", session: "s", date: at(10, 20), usage: .init(input: 100, output: 1, cached: 2, cacheWrite: 3, cacheWriteHour: 1)),
            .init(id: "b", session: "s", date: at(10, 50), usage: .init(input: 40)),
            .init(id: "c", session: "s", date: at(11, 0), usage: .init(input: 7)),
            .init(id: "d", session: "s", date: at(8, 0, dayOffset: -2), usage: .init(input: 5)),
            .init(id: "future", session: "s", date: at(18, 0), usage: .init(input: 999))
        ]
        history.records[.claude] = [.init(id: "f", session: "s", date: at(10, 20), usage: .init(input: 3))]
        history.buildIndex(now: now, calendar: calendar)

        let quarters = history.chartBuckets(interval: .minutes15, dayCount: 1, providers: [.codex], now: now, calendar: calendar)
        XCTAssertEqual(quarters.first { $0.date == at(10, 15) }?.codex.input, 100)
        XCTAssertEqual(quarters.first { $0.date == at(10, 45) }?.codex.input, 40)
        XCTAssertEqual(quarters.first { $0.date == at(11, 0) }?.codex.input, 7)
        XCTAssertEqual(quarters.first { $0.date == at(10, 15) }?.codex, .init(input: 100, output: 1, cached: 2, cacheWrite: 3, cacheWriteHour: 1))
        XCTAssertTrue(quarters.allSatisfy { calendar.isDate($0.date, inSameDayAs: now) })
        XCTAssertEqual(quarters.reduce(0) { $0 + $1.codex.input }, 147)

        let hours = history.chartBuckets(interval: .hour, dayCount: 1, providers: [.codex], now: now, calendar: calendar)
        XCTAssertEqual(hours.first { $0.date == at(10, 0) }?.codex.input, 140)
        XCTAssertEqual(hours.first { $0.date == at(11, 0) }?.codex.input, 7)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.codex.input }, quarters.reduce(0) { $0 + $1.codex.input })
        XCTAssertEqual(history.todayHours(providers: [.codex], now: now, calendar: calendar).map(\.date), hours.map(\.date))

        let weekDaily = history.chartBuckets(interval: .day, dayCount: 7, providers: [.codex, .claude], now: now, calendar: calendar)
        let weekHourly = history.chartBuckets(interval: .hour, dayCount: 7, providers: [.codex, .claude], now: now, calendar: calendar)
        XCTAssertEqual(weekDaily.count, 7)
        XCTAssertGreaterThan(weekHourly.count, 24)
        XCTAssertLessThanOrEqual(weekHourly.count, 7 * 24)
        XCTAssertEqual(weekDaily.reduce(0) { $0 + $1.tokens(for: nil) }, weekHourly.reduce(0) { $0 + $1.tokens(for: nil) })
        XCTAssertEqual(weekDaily.reduce(0) { $0 + $1.codex.input }, 152)
        XCTAssertEqual(weekDaily.reduce(0) { $0 + $1.claude.input }, 3)
        XCTAssertEqual(history.chartBuckets(interval: .hour, dayCount: 7, providers: [.claude], now: now, calendar: calendar).reduce(0) { $0 + $1.tokens(for: nil) }, 3)

        let month = history.chartBuckets(interval: .hour, dayCount: 30, providers: [.codex], now: now, calendar: calendar)
        XCTAssertEqual(month.reduce(0) { $0 + $1.codex.input }, 152)
        XCTAssertLessThanOrEqual(month.count, 7 * 24)
        XCTAssertGreaterThan(month.count, 30)
    }

    func testDailyFallbackWhenOnlyDayTotalsExist() {
        var history = HistorySnapshot()
        var day = UsageDay(date: calendar.startOfDay(for: now))
        day.codex = .init(input: 12)
        history.days = [day]
        // A one-day window resolves Daily to 12 hours, so the day-total fallback is the activity chart.
        let buckets = history.chartBuckets(interval: .day, dayCount: 7, providers: [.codex], now: now, calendar: calendar)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.codex.input }, 12)
        let hours = history.chartBuckets(interval: .hour, dayCount: 1, providers: [.codex], now: now, calendar: calendar)
        XCTAssertEqual(hours.reduce(0) { $0 + $1.codex.input }, 0)
        XCTAssertFalse(hours.isEmpty)
    }

    func testChartPreferencesDefaultAndRoundTrip() throws {
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs.chartStyle, .line)
        XCTAssertEqual(prefs.overviewInterval, .hour)
        XCTAssertEqual(prefs.activityInterval, .day)
        XCTAssertEqual(prefs.modelOrder, .apiValue)
        var edited = prefs
        edited.chartStyle = .histogram
        edited.overviewInterval = .minutes15
        edited.activityInterval = .hour
        edited.modelOrder = .tokens
        let saved = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(saved, edited)
    }
}
