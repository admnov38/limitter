import XCTest
@testable import LimitterCore

final class WelcomeMessageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_800_400)
    private func limits(_ used: Double) -> [Provider: ProviderLimits] {
        Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
            var snapshot = ProviderLimits(provider: provider, source: "test")
            snapshot.updatedAt = now
            snapshot.buckets = [.init(id: provider.rawValue, name: "All models", windows: [.init(id: "weekly", usedPercent: used, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))])]
            return (provider, snapshot)
        })
    }
    private func message(_ quotas: [Provider: ProviderLimits], activity: ActivitySummary = .init(), providers: [Provider] = Provider.allCases, playful: Bool = true) -> WelcomeMessage {
        WelcomeMessage(activity: activity, providers: providers, limits: quotas, playful: playful, now: now)
    }
    func testFreshAndExhaustedQuotas() {
        XCTAssertEqual(WelcomeMessage.classify(activity: .init(), providers: Provider.allCases, limits: limits(0), now: now), .fresh)
        XCTAssertTrue(WelcomeMessage.titles(for: .fresh).contains(message(limits(0)).title))
        XCTAssertEqual(WelcomeMessage.classify(activity: .init(), providers: Provider.allCases, limits: limits(100), now: now), .blocked)
        XCTAssertTrue(WelcomeMessage.titles(for: .blocked).contains(message(limits(100)).title))
        XCTAssertEqual(WelcomeMessage.classify(activity: .init(), providers: Provider.allCases, limits: limits(95), now: now), .nearly)
        XCTAssertTrue(WelcomeMessage.titles(for: .nearly).contains(message(limits(95)).title))
        XCTAssertEqual(message(limits(100), playful: false).title, "All providers have reached a limit.")
        XCTAssertEqual(message(limits(100), playful: false).detail, ActivitySummary().factualHeadline)
    }
    func testUnknownAndExpiredAreNeverFreeOrExhausted() {
        XCTAssertEqual(WelcomeMessage.classify(activity: .init(), providers: Provider.allCases, limits: [:], now: now), .everyday)
        XCTAssertTrue(WelcomeMessage.titles(for: .everyday).contains(message([:]).title))
        XCTAssertEqual(message([:], playful: false).title, "Your usage at a glance.")
        var quotas = limits(0); quotas[.claude] = nil
        XCTAssertNotEqual(message(quotas).title, "Let’s build something great.")
        quotas = limits(100); quotas[.grok]?.error = "Offline"
        XCTAssertNotEqual(message(quotas).title, "Touch some grass.")
        quotas = limits(0); quotas[.grok]?.updatedAt = now.addingTimeInterval(-700)
        XCTAssertNotEqual(message(quotas).title, "Let’s build something great.")
        let expired = WelcomeMessage(activity: .init(), providers: Provider.allCases, limits: limits(100), now: now.addingTimeInterval(86401))
        XCTAssertNotEqual(expired.title, "Touch some grass.")
    }
    func testVelocityRequiresBaselineAndExhaustionTakesPriority() {
        var activity = ActivitySummary(); activity.available = true; activity.todayResponses = 80; activity.previousDailyAverage = 40
        XCTAssertEqual(WelcomeMessage.classify(activity: activity, providers: Provider.allCases, limits: limits(20), now: now), .fast)
        XCTAssertTrue(WelcomeMessage.titles(for: .fast, activity: activity).contains(message(limits(20), activity: activity).title))
        XCTAssertTrue(message(limits(20), activity: activity).detail.contains("2.0×"))
        XCTAssertTrue(WelcomeMessage.details(for: .fast, activity: activity).allSatisfy { $0.contains("2.0×") })
        XCTAssertEqual(message(limits(20), activity: activity, playful: false).title, "Activity is above your usual pace.")
        XCTAssertTrue(WelcomeMessage.titles(for: .blocked).contains(message(limits(100), activity: activity).title))
        activity.previousDailyAverage = 0
        XCTAssertNotEqual(WelcomeMessage.classify(activity: activity, providers: Provider.allCases, limits: limits(20), now: now), .fast)
    }
    func testModelCapAndProviderFilter() {
        var quotas = limits(0)
        quotas[.claude]?.buckets.append(.init(id: "model:fable", name: "Fable", windows: [.init(id: "weekly", usedPercent: 100, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))]))
        XCTAssertEqual(WelcomeMessage.classify(activity: .init(), providers: Provider.allCases, limits: quotas, now: now), .modelCap)
        XCTAssertTrue(WelcomeMessage.titles(for: .modelCap).contains(message(quotas).title))
        XCTAssertTrue(message(quotas).detail.contains("Fable"))
        XCTAssertTrue(WelcomeMessage.details(for: .modelCap, activity: .init(), model: "Fable").allSatisfy { $0.contains("Fable") })
        XCTAssertEqual(WelcomeMessage.classify(activity: .init(), providers: [.codex], limits: quotas, now: now), .fresh)
        XCTAssertTrue(WelcomeMessage.titles(for: .fresh).contains(message(quotas, providers: [.codex]).title))
    }
    func testCopyFollowsTheDayAndStaysStableUntilThePatternChanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var seen = Set<String>()
        var day = now
        for _ in 0..<8 {
            let quotas = freshLimits(at: day)
            let first = WelcomeMessage(activity: .init(), providers: Provider.allCases, limits: quotas, now: day, calendar: calendar)
            let second = WelcomeMessage(activity: .init(), providers: Provider.allCases, limits: quotas, now: day, calendar: calendar)
            XCTAssertEqual(first.title, second.title)
            XCTAssertEqual(first.detail, second.detail)
            seen.insert(first.title)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        XCTAssertGreaterThan(seen.count, 1)
        var light = ActivitySummary(); light.available = true; light.todayResponses = 4
        var steady = light; steady.todayResponses = 40
        XCTAssertEqual(WelcomeMessage.classify(activity: light, providers: Provider.allCases, limits: limits(20), now: now), .everyday)
        XCTAssertNotEqual(message(limits(20), activity: light).title, message(limits(20), activity: steady).title)
        var quiet = ActivitySummary(); quiet.available = true; quiet.todayResponses = 0; quiet.currentStreak = 5
        XCTAssertEqual(WelcomeMessage.classify(activity: quiet, providers: Provider.allCases, limits: limits(20), now: now), .quiet)
        XCTAssertTrue(WelcomeMessage.details(for: .quiet, activity: quiet).allSatisfy { $0.contains("5") })
        var busy = ActivitySummary(); busy.available = true; busy.todayResponses = 120
        XCTAssertEqual(WelcomeMessage.classify(activity: busy, providers: Provider.allCases, limits: limits(20), now: now), .busy)
        XCTAssertTrue(WelcomeMessage.details(for: .busy, activity: busy).allSatisfy { $0.contains("120") })
        var coasting = ActivitySummary(); coasting.available = true; coasting.todayResponses = 4; coasting.currentStreak = 10; coasting.previousDailyAverage = 40
        XCTAssertEqual(WelcomeMessage.classify(activity: coasting, providers: Provider.allCases, limits: limits(20), now: now), .coasting)
        var kept = coasting; kept.todayResponses = 40
        XCTAssertEqual(WelcomeMessage.classify(activity: kept, providers: Provider.allCases, limits: limits(20), now: now), .streak)
        for situation in [WelcomeMessage.Situation.blocked, .fast, .modelCap, .partial, .fresh, .nearly, .busy, .coasting, .streak, .everyday] {
            XCTAssertGreaterThanOrEqual(WelcomeMessage.titles(for: situation).count, 6)
        }
    }
    private func freshLimits(at day: Date) -> [Provider: ProviderLimits] {
        Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
            var snapshot = ProviderLimits(provider: provider, source: "test")
            snapshot.updatedAt = day
            snapshot.buckets = [.init(id: provider.rawValue, name: "All models", windows: [.init(id: "weekly", usedPercent: 0, durationMinutes: 10080, resetsAt: day.addingTimeInterval(10 * 86400))])]
            return (provider, snapshot)
        })
    }
}
