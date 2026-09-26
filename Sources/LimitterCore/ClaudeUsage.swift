import Foundation

/// Requests structured /usage over Claude Code's control protocol. No prompts,
/// tools, hooks, MCP servers, or persisted coding sessions are started.
public final class ClaudeUsageConnection: @unchecked Sendable {
    public init() {}
    public static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    public func fetch() throws -> ProviderLimits {
        guard let executable = Self.executable() else { throw ConnectionError.unavailable("Install Claude Code and sign in to receive model limits.") }
        let rpc = RPCProcess(executable: executable, arguments: ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", "", "--settings", "{\"disableAllHooks\":true}", "--setting-sources", "user"], provider: "Claude", claudeControl: true)
        try rpc.start()
        defer { rpc.stop() }
        _ = try rpc.request(id: 0, method: "initialize", params: ["hooks": [:]])
        return ClaudeUsageParser.parse(try rpc.request(id: 1, method: "get_usage", params: ["skip_behaviors": true]))
    }
}

public enum ClaudeUsageParser {
    public static func parse(_ value: [String: Any], now: Date = Date()) -> ProviderLimits {
        var result = ProviderLimits(provider: .claude, source: "Claude account")
        result.plan = value["subscription_type"] as? String
        guard value["rate_limits_available"] as? Bool != false, let limits = value["rate_limits"] as? [String: Any] else {
            result.error = "Claude couldn’t return subscription limits. Check your sign-in and refresh."
            return result
        }
        result.updatedAt = now; result.receivedAt = now
        func window(_ data: [String: Any], id: String, duration: Int) -> LimitWindow? {
            guard let used = ClaudeQuotaCache.percentage(data["utilization"] ?? data["percent"]) else { return nil }
            let reset = parseDate(data["resets_at"]) ?? ClaudeQuotaCache.timestamp(data["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            return .init(id: id, usedPercent: used, durationMinutes: duration, resetsAt: reset, observedAt: now)
        }
        let primary = [("five_hour", 300, "Session"), ("seven_day", 10080, "Weekly")].compactMap { key, duration, title -> LimitWindow? in
            guard let raw = limits[key], !(raw is NSNull) else { return nil }
            guard let data = raw as? [String: Any] else { result.windowErrors[title] = "Claude returned an unreadable \(title.lowercased()) quota."; return nil }
            if data["utilization"] == nil || data["utilization"] is NSNull { return nil }
            let parsed = window(data, id: key, duration: duration)
            if parsed == nil { result.windowErrors[title] = "Claude returned an unreadable \(title.lowercased()) percentage." }
            return parsed
        }
        result.buckets = [.init(id: "claude", name: "All models", windows: primary)]
        var scoped: [String: (name: String, data: [String: Any])] = [:]
        func add(_ name: String, data: [String: Any]) {
            let label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !label.isEmpty else { return }
            // The named and raw projections can disagree during a partial update.
            // An empty projection must not erase a numeric reading in this response.
            if let existing = scoped[label.lowercased()],
               window(existing.data, id: "weekly", duration: 10080) != nil,
               window(data, id: "weekly", duration: 10080) == nil { return }
            scoped[label.lowercased()] = (label, data)
        }
        // Legacy model buckets are superseded by the server's current named projection.
        for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            if let data = limits[key] as? [String: Any] { add(name, data: data) }
        }
        for row in limits["limits"] as? [[String: Any]] ?? [] where row["kind"] as? String == "weekly_scoped" {
            if let scope = row["scope"] as? [String: Any], let model = scope["model"] as? [String: Any], let name = model["display_name"] as? String { add(name, data: row) }
        }
        for row in limits["model_scoped"] as? [[String: Any]] ?? [] {
            if let name = row["display_name"] as? String { add(name, data: row) }
        }
        for key in scoped.keys.sorted(by: { a, b in a == "fable" ? b != "fable" : b == "fable" ? false : a < b }) {
            guard let row = scoped[key] else { continue }
            let parsed = window(row.data, id: "weekly", duration: 10080)
            let raw = row.data["utilization"] ?? row.data["percent"]
            let error = parsed == nil && raw != nil && !(raw is NSNull) ? "Claude returned an unreadable \(row.name) quota." : nil
            result.buckets.append(.init(id: "model:" + key, name: row.name, windows: parsed.map { [$0] } ?? [], error: error))
        }
        return result
    }
}

public enum ClaudeQuotaSources {
    public static func retainingModelReadings(from previous: ProviderLimits?, in incoming: ProviderLimits, now: Date = Date()) -> ProviderLimits {
        var result = incoming
        guard let previous else { return result }
        if let error = incoming.error {
            result = previous
            result.error = error
            return result
        }
        for bucket in previous.buckets.dropFirst() {
            let retained = bucket.windows.filter { $0.resetsAt != nil && !$0.hasExpired(at: now) }
                .map { window -> LimitWindow in
                    LimitWindow(id: window.id, usedPercent: window.usedPercent, durationMinutes: window.durationMinutes,
                                resetsAt: window.resetsAt, observedAt: window.observedAt ?? previous.updatedAt)
                }
            guard !retained.isEmpty else { continue }
            if let index = result.buckets.firstIndex(where: { $0.id == bucket.id }) {
                if result.buckets[index].windows.isEmpty && result.buckets[index].error == nil {
                    result.buckets[index] = .init(id: bucket.id, name: bucket.name, windows: retained)
                }
            } else if !result.buckets.isEmpty {
                result.buckets.append(.init(id: bucket.id, name: bucket.name, windows: retained))
            }
        }
        return result
    }

    public static func combine(account: ProviderLimits?, statusLine: ProviderLimits, now: Date = Date()) -> ProviderLimits {
        var result = statusLine
        if result.buckets.isEmpty { result.buckets = [.init(id: "claude", name: "All models", windows: [])] }
        if let account {
            let fresh = account.error == nil && (account.updatedAt.map { now.timeIntervalSince($0) <= 600 && $0 <= now } ?? false)
            let statusWindows = result.buckets.first?.windows ?? []
            let accountWindows = account.buckets.first?.windows ?? []
            let statusByID = Dictionary(uniqueKeysWithValues: statusWindows.map { ($0.id, $0) })
            let accountByID = Dictionary(uniqueKeysWithValues: accountWindows.map { ($0.id, $0) })
            if !accountWindows.isEmpty || !statusWindows.isEmpty {
                let merged = Set(statusByID.keys).union(accountByID.keys).compactMap { id -> LimitWindow? in
                    guard let status = statusByID[id] else { return accountByID[id] }
                    guard let accountWindow = accountByID[id] else { return status }
                    // Every open CLI session re-renders its status line with the last quota it
                    // saw, so idle sessions keep rewriting stale readings with fresh timestamps.
                    // A fresh account poll is authoritative; the status line is only a fallback.
                    let statusLive = !status.hasExpired(at: now), accountLive = !accountWindow.hasExpired(at: now)
                    if fresh && accountLive { return accountWindow }
                    if statusLive != accountLive { return statusLive ? status : accountWindow }
                    let statusSeen = status.observedAt ?? statusLine.updatedAt ?? .distantPast
                    let accountSeen = accountWindow.observedAt ?? account.updatedAt ?? .distantPast
                    return statusSeen > accountSeen ? status : accountWindow
                }
                .sorted { (left, right) in
                    let leftDuration = left.durationMinutes ?? Int.max
                    let rightDuration = right.durationMinutes ?? Int.max
                    return leftDuration == rightDuration ? left.id < right.id : leftDuration < rightDuration
                }
                if result.buckets.isEmpty { result.buckets = [LimitBucket(id: "claude", name: "All models", windows: merged)] }
                else { result.buckets[0] = LimitBucket(id: account.buckets.first?.id ?? "claude", name: account.buckets.first?.name ?? "All models", windows: merged) }
            } else if fresh {
                result.buckets = statusLine.buckets.isEmpty ? [LimitBucket(id: "claude", name: "All models", windows: statusWindows)] : result.buckets
            }
            result.plan = account.plan ?? result.plan
            let fallbackError = account.error ?? "Waiting for a fresh Claude account update."
            let models = account.buckets.dropFirst().map { source in
                var value = source
                if value.error == nil && value.windows.isEmpty { value.error = fallbackError }
                return value
            }
            if result.buckets.isEmpty { result.buckets = [.init(id: "claude", name: "All models", windows: [])] }
            if models.isEmpty {
                result.modelLimitsError = fallbackError
            } else {
                if result.buckets.count > 1 { result.buckets.replaceSubrange(1..., with: models) }
                else { result.buckets.append(contentsOf: models) }
                result.modelLimitsError = nil
            }
        } else {
            result.modelLimitsError = "Model limits are syncing from Claude Code."
        }
        return result
    }
}
