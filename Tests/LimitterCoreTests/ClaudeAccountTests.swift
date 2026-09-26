import XCTest
@testable import LimitterCore

final class ClaudeAccountTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_800_400)
    private func window(_ percent: Any) -> [String: Any] { ["utilization": percent, "resets_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(86400))] }
    private func fixture(_ models: [[String: Any]]) -> [String: Any] {
        ["subscription_type": "max", "rate_limits_available": true, "rate_limits": ["five_hour": window(15), "seven_day": window(57), "model_scoped": models]]
    }
    func testFableQuotaIsSeparateFromAllModelsAndNotCountedTwice() {
        var fable = window(100); fable["display_name"] = "Fable"
        var value = fixture([fable]); var limits = value["rate_limits"] as! [String: Any]
        limits["limits"] = [["kind": "weekly_scoped", "percent": 100, "resets_at": fable["resets_at"]!, "scope": ["model": ["display_name": "Fable"]]]]
        value["rate_limits"] = limits
        let snapshot = ClaudeUsageParser.parse(value, now: now)
        XCTAssertEqual(snapshot.plan, "max")
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .weekly, now: now).window?.usedPercent, 57)
        let model = QuotaPresentation(provider: .claude, snapshot: snapshot, period: .weekly, now: now, bucketID: "model:fable")
        XCTAssertEqual(model.window?.usedPercent, 100)
        XCTAssertEqual(model.state, .live)
        XCTAssertEqual(model.window?.remaining, 0)
    }
    func testScopedRawServerProjectionWorksWithoutModelScopedField() {
        let snapshot = ClaudeUsageParser.parse(["rate_limits": ["limits": [["kind": "weekly_scoped", "percent": 28, "scope": ["model": ["display_name": "Fable"]]], ["kind": "weekly_all", "percent": 40]]]], now: now)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets.last?.name, "Fable")
        XCTAssertEqual(snapshot.buckets.last?.windows.first?.usedPercent, 28)
    }
    func testMissingAndMalformedFableNeverBecomeZeroOrBreakOtherWindows() {
        for percent: Any in [NSNull(), "50", true, -1] {
            var fable = window(percent); fable["display_name"] = "Fable"
            let snapshot = ClaudeUsageParser.parse(fixture([fable]), now: now)
            let model = QuotaPresentation(provider: .claude, snapshot: snapshot, period: .weekly, now: now, bucketID: "model:fable")
            XCTAssertFalse(model.hasValue)
            XCTAssertEqual(model.state, percent is NSNull ? .missing : .error)
            XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .session, now: now).state, .live)
        }
        XCTAssertNotNil(ClaudeUsageParser.parse(["rate_limits": NSNull()], now: now).error)
    }
    func testFreshAccountSurvivesStatusLineReplaysAndUnavailableAccountKeepsExplicitModelErrors() {
        var fable = window(100); fable["display_name"] = "Fable"
        let account = ClaudeUsageParser.parse(fixture([fable]), now: now)
        let line = LimitsParser.claude(["rate_limits": ["five_hour": ["used_percentage": 6, "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970]]], updatedAt: now.addingTimeInterval(1))
        let combined = ClaudeQuotaSources.combine(account: account, statusLine: line, now: now.addingTimeInterval(2))
        XCTAssertEqual(combined.windows.first?.usedPercent, 15)
        XCTAssertEqual(combined.buckets.last?.windows.first?.usedPercent, 100)
        var failed = account; failed.error = "Offline"
        let fallback = ClaudeQuotaSources.combine(account: failed, statusLine: line, now: now.addingTimeInterval(2))
        XCTAssertEqual(fallback.windows.first?.usedPercent, 6)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: fallback, period: .session, now: now.addingTimeInterval(2)).state, .live)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: fallback, period: .weekly, now: now.addingTimeInterval(2), bucketID: "model:fable").state, .live)
    }
    func testFreshAccountPollOverridesStaleStatusLineRewrites() {
        // Idle CLI sessions re-render their last-seen quota with a newer timestamp.
        let account = ClaudeUsageParser.parse(fixture([]), now: now)
        let line = LimitsParser.claude(["rate_limits": ["five_hour": ["used_percentage": 6, "resets_at": now.addingTimeInterval(3600).timeIntervalSince1970]]], updatedAt: now.addingTimeInterval(60))
        XCTAssertEqual(ClaudeQuotaSources.combine(account: account, statusLine: line, now: now.addingTimeInterval(61)).windows.first?.usedPercent, 15)
        let stale = ClaudeQuotaSources.combine(account: account, statusLine: line, now: now.addingTimeInterval(700))
        XCTAssertEqual(stale.windows.first?.usedPercent, 6)
    }
    func testEmptyNamedProjectionDoesNotEraseRawFableReading() {
        let snapshot = ClaudeUsageParser.parse(["rate_limits": [
            "limits": [["kind": "weekly_scoped", "percent": 100, "scope": ["model": ["display_name": "Fable"]]]],
            "model_scoped": [["display_name": "Fable", "utilization": NSNull()]]
        ]], now: now)
        XCTAssertEqual(snapshot.buckets.last?.windows.first?.usedPercent, 100)
    }
    func testPartialAccountRefreshRetainsModelUntilResetWithoutRefreshingTimestamp() {
        var fable = window(100); fable["display_name"] = "Fable"
        let previous = ClaudeUsageParser.parse(fixture([fable]), now: now)
        let later = now.addingTimeInterval(700)
        for models: [[String: Any]] in [[], [["display_name": "Fable", "utilization": NSNull()]]] {
            let incoming = ClaudeUsageParser.parse(fixture(models), now: later)
            let retained = ClaudeQuotaSources.retainingModelReadings(from: previous, in: incoming, now: later)
            let combined = ClaudeQuotaSources.combine(account: retained, statusLine: ProviderLimits(provider: .claude, source: "test"), now: later)
            let status = QuotaPresentation(provider: .claude, snapshot: combined, period: .weekly, now: later, bucketID: "model:fable")
            XCTAssertEqual(status.window?.usedPercent, 100)
            XCTAssertEqual(status.observedAt, now)
            XCTAssertEqual(status.state, .cached)
        }
        let expired = ClaudeQuotaSources.retainingModelReadings(from: previous, in: ClaudeUsageParser.parse(fixture([]), now: later), now: now.addingTimeInterval(86401))
        XCTAssertEqual(expired.buckets.count, 1)
        fable["utilization"] = 5
        let fresh = ClaudeQuotaSources.retainingModelReadings(from: previous, in: ClaudeUsageParser.parse(fixture([fable]), now: later), now: later)
        XCTAssertEqual(fresh.buckets.last?.windows.first?.usedPercent, 5)
        let unavailable = ClaudeQuotaSources.retainingModelReadings(from: previous, in: ClaudeUsageParser.parse(["rate_limits": NSNull()], now: later), now: later)
        XCTAssertNotNil(unavailable.error)
        XCTAssertEqual(unavailable.buckets.last?.windows.first?.usedPercent, 100)
        XCTAssertEqual(unavailable.updatedAt, now)
    }
    func testModelFreshnessUsesItsOwnTimestampAndReset() {
        var fable = window(100); fable["display_name"] = "Fable"
        let snapshot = ClaudeUsageParser.parse(fixture([fable]), now: now)
        let old = QuotaPresentation(provider: .claude, snapshot: snapshot, period: .weekly, now: now.addingTimeInterval(601), bucketID: "model:fable")
        XCTAssertEqual(old.state, .cached)
        XCTAssertEqual(QuotaPresentation(provider: .claude, snapshot: snapshot, period: .weekly, now: now.addingTimeInterval(86401), bucketID: "model:fable").state, .expired)
    }
}
