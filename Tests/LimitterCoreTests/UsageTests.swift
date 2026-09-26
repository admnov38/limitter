import XCTest
@testable import LimitterCore

final class UsageTests: XCTestCase {
    private func jsonl(_ values: [[String: Any]]) throws -> Data {
        try values.reduce(into: Data()) { result, value in result.append(try JSONSerialization.data(withJSONObject: value)); result.append(10) }
    }
    private let timestamp = "2026-09-07T10:30:00.000Z"

    func testCodexCacheAndReasoningAreNotDoubleCounted() {
        let usage = TokenUsage.codex(["input_tokens": 1000, "cached_input_tokens": 750, "output_tokens": 200, "reasoning_output_tokens": 150])
        XCTAssertEqual(usage.total, 1200)
        XCTAssertEqual(usage.input, 250)
        XCTAssertEqual(usage.cached, 750)
    }
    func testClaudeCacheIsAdditive() {
        let usage = TokenUsage.claude(["input_tokens": 100, "cache_read_input_tokens": 800, "cache_creation_input_tokens": 50, "output_tokens": 200])
        XCTAssertEqual(usage.total, 1150)
    }
    func testModernCodexRecordsDeduplicateResponsesAndIgnoreLegacyMirrors() throws {
        let usage: [String: Any] = ["input_tokens": 1000, "cached_input_tokens": 500, "output_tokens": 50]
        let modern: [String: Any] = ["type": "token_usage_record", "timestamp": timestamp, "payload": ["response_id": "r1", "session_id": "s1", "usage": usage]]
        let legacy: [String: Any] = ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "token_count", "info": ["total_token_usage": usage]]]
        let result = TranscriptParser.parse(try jsonl([modern, modern, legacy]), provider: .codex, fileID: "test")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.usage.total, 1050)
    }
    func testLegacyCodexUsesDeltasAndSkipsRepeatedCounters() throws {
        func event(_ input: Int, _ output: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "output_tokens": output]]]]
        }
        let result = TranscriptParser.parse(try jsonl([event(100, 10), event(100, 10), event(250, 30)]), provider: .codex, fileID: "test")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.reduce(0) { $0 + $1.usage.total }, 280)
    }
    func testClaudeStreamingKeepsLargestUsageAndIgnoresErrors() throws {
        func event(_ output: Int, error: Bool = false) -> [String: Any] {
            ["type": "assistant", "timestamp": timestamp, "sessionId": "s1", "isApiErrorMessage": error,
             "message": ["id": "m1", "model": "claude", "usage": ["input_tokens": 100, "output_tokens": output]]]
        }
        var data = try jsonl([event(1), event(150), event(1), event(900, error: true)])
        data.append(Data("{incomplete".utf8))
        let result = TranscriptParser.parse(data, provider: .claude, fileID: "test")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.usage.total, 250)
    }
    func testWeeklyPrimaryIsLabeledWeeklyAndMissingLimitsStayMissing() {
        let snapshot = LimitsParser.codex(["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 2, "windowDurationMins": 10080], "secondary": NSNull()]]])
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.title, "Weekly")
        XCTAssertEqual(snapshot.windows.first?.remaining, 98)
        XCTAssertNil(snapshot.windows.first?.resetsAt)
        XCTAssertTrue(LimitsParser.claude(["rate_limits": ["five_hour": ["resets_at": 12]]], updatedAt: Date()).windows.isEmpty)
    }
    func testExpiredWindowDoesNotImplyFreshAllowance() {
        let now = Date()
        let window = LimitWindow(id: "a", usedPercent: 105, durationMinutes: 300, resetsAt: now.addingTimeInterval(-1))
        XCTAssertTrue(window.hasExpired(at: now))
        XCTAssertEqual(window.remaining, 0)
        XCTAssertEqual(Format.reset(window.resetsAt, now: now), "Awaiting new window")
    }
    func testReaderBucketsLocalDaysAndDeduplicatesCopiedTranscripts() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 7200)!
        let now = parseDate("2026-09-07T01:00:00Z")!
        func event(_ id: String, date: String) -> [String: Any] {
            ["type": "assistant", "timestamp": date, "sessionId": "s1", "message": ["id": id, "usage": ["input_tokens": 100, "output_tokens": 20]]]
        }
        let data = try jsonl([event("a", date: "2026-09-06T23:00:00Z"), event("b", date: "2026-09-06T21:00:00Z")])
        try data.write(to: root.appendingPathComponent("a.jsonl"))
        try data.write(to: root.appendingPathComponent("copy.jsonl"))
        let reader = HistoryReader(home: home)
        let result = await reader.read(now: now, calendar: calendar)
        XCTAssertEqual(result.today[.claude]?.total, 120)
        XCTAssertEqual(result.days.suffix(2).map { $0.claude.total }, [120, 120])
        XCTAssertEqual(result.sessions[.claude], 1)
        XCTAssertEqual(result.requests[.claude], 1)
        let again = await reader.read(now: now, calendar: calendar)
        XCTAssertEqual(again.today[.claude]?.total, 120)
    }
}
