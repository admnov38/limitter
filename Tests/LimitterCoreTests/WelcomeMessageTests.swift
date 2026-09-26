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
        XCTAssertEqual(message(limits(0)).title, "Let’s build something great.")
        XCTAssertEqual(message(limits(100)).title, "Touch some grass.")
        XCTAssertEqual(message(limits(95)).title, "Make the next prompt count.")
        XCTAssertEqual(message(limits(100), playful: false).title, "All providers have reached a limit.")
    }
    func testUnknownAndExpiredAreNeverFreeOrExhausted() {
        XCTAssertEqual(message([:]).title, "Ready when inspiration hits.")
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
        XCTAssertEqual(message(limits(20), activity: activity).title, "You’re a machine today.")
        XCTAssertTrue(message(limits(20), activity: activity).detail.contains("2.0×"))
        XCTAssertEqual(message(limits(100), activity: activity).title, "Touch some grass.")
        activity.previousDailyAverage = 0
        XCTAssertNotEqual(message(limits(20), activity: activity).title, "You’re a machine today.")
    }
    func testModelCapAndProviderFilter() {
        var quotas = limits(0)
        quotas[.claude]?.buckets.append(.init(id: "model:fable", name: "Fable", windows: [.init(id: "weekly", usedPercent: 100, durationMinutes: 10080, resetsAt: now.addingTimeInterval(86400))]))
        XCTAssertEqual(message(quotas).title, "Time for a change of engines.")
        XCTAssertTrue(message(quotas).detail.contains("Fable"))
        XCTAssertEqual(message(quotas, providers: [.codex]).title, "Let’s build something great.")
    }
}
