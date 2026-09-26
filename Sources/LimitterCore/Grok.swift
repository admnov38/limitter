import Foundation
import CoreFoundation

/// Uses Grok's own read-only billing extension. The CLI owns authentication;
/// Limitter never opens auth.json or creates a coding session.
public final class GrokConnection: @unchecked Sendable {
    public init() {}
    public static var home: URL {
        ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }
    public static func executable() -> URL? {
        let candidates = [home.appendingPathComponent("bin/grok").path, "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/grok" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    public func fetch() throws -> ProviderLimits {
        guard let executable = Self.executable() else { throw ConnectionError.unavailable("Install Grok Build and run grok login in Terminal to connect your subscription.") }
        let rpc = RPCProcess(executable: executable, arguments: ["agent", "--no-leader", "stdio"], provider: "Grok", jsonRPC: true)
        try rpc.start()
        defer { rpc.stop() }
        _ = try rpc.request(id: 0, method: "initialize", params: ["protocolVersion": 1, "clientCapabilities": [:], "clientInfo": ["name": "limitter", "version": "1.3.0"]])
        return GrokBillingParser.parse(try rpc.request(id: 1, method: "_x.ai/billing"))
    }
}

public enum GrokBillingParser {
    public static func parse(_ result: [String: Any], now: Date = Date()) -> ProviderLimits {
        var snapshot = ProviderLimits(provider: .grok, source: "Grok account · shared subscription pool")
        snapshot.plan = result["subscription_tier"] as? String
        guard let config = result["config"] as? [String: Any] else {
            snapshot.error = "Grok returned an unreadable billing response. Update Grok Build and try refreshing."
            return snapshot
        }
        snapshot.updatedAt = now; snapshot.receivedAt = now
        let period = config["currentPeriod"] as? [String: Any] ?? [:]
        let start = parseDate(period["start"] ?? config["billingPeriodStart"])
        let end = parseDate(period["end"] ?? config["billingPeriodEnd"])
        let weekly = (period["type"] as? String == "USAGE_PERIOD_TYPE_WEEKLY")
            || (start != nil && end != nil && abs(end!.timeIntervalSince(start!) - 7 * 86400) < 60)
        guard weekly else {
            snapshot.windowErrors["Weekly"] = "Grok hasn’t reported a weekly subscription pool for this account."
            return snapshot
        }
        guard let raw = config["creditUsagePercent"], !(raw is NSNull) else {
            snapshot.quotaNote = "Grok hasn’t reported a percentage used." + (end.map { " " + Format.reset($0, now: now) + "." } ?? "")
            return snapshot
        }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue >= 0 else {
            snapshot.windowErrors["Weekly"] = "Grok returned an unreadable usage percentage. Try refreshing."
            return snapshot
        }
        snapshot.buckets = [.init(id: "grok", name: "Shared subscription pool", windows: [.init(id: "weekly", usedPercent: value.doubleValue, durationMinutes: 10080, resetsAt: end, observedAt: now)])]
        return snapshot
    }
}

/// Grok's ACP turn ledger includes cached input, reasoning within output, and
/// completed subagents. Read it once per prompt, never its repeated text chunks.
public enum GrokTranscriptParser {
    public static func parse(_ data: Data, fileID: String, metadata: [String: Any] = [:]) -> ParsedTranscript {
        let info = metadata["info"] as? [String: Any] ?? [:]
        var sessionID = info["id"] as? String ?? URL(fileURLWithPath: fileID).deletingLastPathComponent().lastPathComponent
        let cwd = info["cwd"] as? String
            ?? URL(fileURLWithPath: fileID).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.removingPercentEncoding
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Local session"
        var model = metadata["current_model_id"] as? String
        var summary: SessionSummary?
        var records: [String: UsageRecord] = [:]
        var children: [String: Set<String>] = [:]
        var covered = Set<String>()
        for (index, line) in data.split(separator: 10).enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  ["session/update", "_x.ai/session/update"].contains(object["method"] as? String ?? ""),
                  let params = object["params"] as? [String: Any], let update = params["update"] as? [String: Any] else { continue }
            let meta = params["_meta"] as? [String: Any] ?? [:]
            let date = (meta["agentTimestampMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                ?? (object["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                ?? parseDate(object["timestamp"])
            guard let date else { continue }
            sessionID = params["sessionId"] as? String ?? sessionID
            if let value = (update["_meta"] as? [String: Any])?["modelId"] as? String { model = value }
            if summary == nil {
                summary = .init(provider: .grok, session: sessionID, project: project, model: model, startedAt: parseDate(metadata["created_at"]) ?? date, lastActivity: date, observedState: .unknown)
            }
            summary?.session = sessionID; summary?.model = model
            let type = update["sessionUpdate"] as? String ?? ""
            if type == "subagent_spawned", let child = update["child_session_id"] as? String, let prompt = update["parent_prompt_id"] as? String {
                children[prompt, default: []].insert(child)
            }
            var state: SessionState?
            switch type {
            case "user_message_chunk": state = .recent
            case "agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update": state = .running
            case "turn_completed":
                switch update["stop_reason"] as? String {
                case "cancelled", "canceled": state = .interrupted
                case "error": state = .error
                default: state = .idle
                }
            default: break
            }
            if let state, date >= (summary?.lastActivity ?? .distantPast) { summary?.observedState = state; summary?.lastActivity = date }
            guard type == "turn_completed", let raw = update["usage"] as? [String: Any] else { continue }
            let input = max(0, number(raw["inputTokens"]))
            let cached = min(input, max(0, number(raw["cachedReadTokens"])))
            let writes = min(input - cached, max(0, number(raw["cacheCreationTokens"])))
            let usage = TokenUsage(input: input - cached - writes, output: max(0, number(raw["outputTokens"])), cached: cached, cacheWrite: writes)
            guard usage.total > 0 else { continue }
            var models: [String: TokenUsage] = [:]
            for (id, entry) in raw["modelUsage"] as? [String: [String: Any]] ?? [:] {
                models[id] = TokenUsage.codex(["input_tokens": entry["inputTokens"] ?? 0, "cached_input_tokens": entry["cachedReadTokens"] ?? 0, "cache_write_input_tokens": entry["cacheCreationTokens"] ?? 0, "output_tokens": entry["outputTokens"] ?? 0])
            }
            let prompt = update["prompt_id"] as? String ?? "\(sessionID):\(index)"
            if usage.total >= (records[prompt]?.usage.total ?? 0) {
                records[prompt] = .init(id: prompt, session: sessionID, date: date, usage: usage, responses: max(0, number(raw["modelCalls"])), model: model, modelUsage: models.isEmpty ? nil : models)
            }
            covered.formUnion(children[prompt] ?? [])
        }
        let values = Array(records.values)
        summary?.usage = values.reduce(TokenUsage()) { $0 + $1.usage }
        summary?.responses = values.reduce(0) { $0 + $1.responses }
        summary?.modelUsage = TranscriptParser.modelTotals(values)
        return ParsedTranscript(records: values, session: summary, coveredSessions: covered)
    }
}
