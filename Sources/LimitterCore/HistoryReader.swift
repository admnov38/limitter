import Foundation

public struct ParsedTranscript: Sendable {
    public var records: [UsageRecord]
    public var session: SessionSummary?
    public var coveredSessions: Set<String> = []
}

public enum TranscriptParser {
    public static func parse(_ data: Data, provider: Provider, fileID: String) -> [UsageRecord] {
        parseDetailed(data, provider: provider, fileID: fileID).records
    }
    public static func parseDetailed(_ data: Data, provider: Provider, fileID: String) -> ParsedTranscript {
        if provider == .grok { return GrokTranscriptParser.parse(data, fileID: fileID) }
        var summary: SessionSummary?
        var records: [String: UsageRecord] = [:]
        var legacy: [UsageRecord] = []
        var previousTotal = TokenUsage()
        var hasModernCodexRecords = false
        var session = fileID
        for (lineIndex, line) in data.split(separator: 0x0A).enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let date = parseDate(object["timestamp"]) else { continue }
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any] ?? [:]
            if provider == .codex {
                if type == "session_meta" { session = payload["id"] as? String ?? session }
                if type == "token_usage_record" { session = payload["session_id"] as? String ?? session }
            } else { session = object["sessionId"] as? String ?? object["session_id"] as? String ?? session }
            if summary == nil {
                summary = SessionSummary(provider: provider, session: session, project: "Local session", startedAt: date, lastActivity: date, observedState: .unknown)
            }
            summary?.session = session
            if let cwd = (provider == .codex ? payload["cwd"] : object["cwd"]) as? String, !cwd.isEmpty {
                summary?.project = URL(fileURLWithPath: cwd).lastPathComponent
            }
            let message = object["message"] as? [String: Any] ?? [:]
            if let model = (provider == .codex ? payload["model"] : message["model"]) as? String, model != "<synthetic>" { summary?.model = model }
            var observed: SessionState?
            var activity = false
            if provider == .codex {
                let event = payload["type"] as? String
                if type == "event_msg" {
                    switch event {
                    case "task_started": observed = .running
                    case "task_complete": observed = .idle
                    case "turn_aborted": observed = .interrupted
                    case "error": observed = .error
                    default: break
                    }
                    activity = observed != nil || event == "token_count" || event == "item_completed"
                }
                activity = activity || type == "token_usage_record"
            } else {
                activity = type == "user" || type == "assistant"
                if object["isApiErrorMessage"] as? Bool == true { observed = .error }
                else if type == "assistant", ["end_turn", "stop_sequence"].contains(message["stop_reason"] as? String ?? "") { observed = .idle }
                else if type == "system", ["turn_duration", "stop_hook_summary"].contains(object["subtype"] as? String ?? "") { observed = .idle; activity = true }
                else if activity { observed = .recent }
            }
            if activity, date >= (summary?.lastActivity ?? .distantPast) {
                summary?.lastActivity = date
                if let observed { summary?.observedState = observed }
            }
            if provider == .codex {
                let payload = object["payload"] as? [String: Any] ?? [:]
                if type == "session_meta", let id = payload["id"] as? String { session = id }
                if type == "token_usage_record", let usage = payload["usage"] as? [String: Any] {
                    hasModernCodexRecords = true
                    let id = payload["response_id"] as? String ?? "\(fileID):\(lineIndex)"
                    records[id] = UsageRecord(id: id, session: payload["session_id"] as? String ?? session, date: date, usage: .codex(usage), model: summary?.model)
                } else if type == "event_msg", payload["type"] as? String == "token_count",
                          let info = payload["info"] as? [String: Any], let cumulative = info["total_token_usage"] as? [String: Any] {
                    let total = TokenUsage.codex(cumulative)
                    // Repeated token_count events carry the same cumulative counters.
                    if total != previousTotal {
                        let delta: TokenUsage
                        if total.total < previousTotal.total {
                            delta = TokenUsage.codex(info["last_token_usage"] as? [String: Any] ?? [:])
                        } else {
                            delta = TokenUsage(input: max(0, total.input - previousTotal.input), output: max(0, total.output - previousTotal.output), cached: max(0, total.cached - previousTotal.cached), cacheWrite: max(0, total.cacheWrite - previousTotal.cacheWrite))
                        }
                        let id = "\(session):\(date.timeIntervalSince1970):\(total.total)"
                        if delta.total > 0 { legacy.append(UsageRecord(id: id, session: session, date: date, usage: delta, model: summary?.model)) }
                        previousTotal = total
                    }
                }
            } else if type == "assistant", object["isApiErrorMessage"] as? Bool != true,
                      let message = object["message"] as? [String: Any], message["model"] as? String != "<synthetic>",
                      let usage = message["usage"] as? [String: Any] {
                let id = message["id"] as? String ?? object["uuid"] as? String ?? "\(fileID):\(lineIndex)"
                let parsed = TokenUsage.claude(usage)
                guard parsed.total > 0 else { continue }
                // Streaming blocks repeat a message ID. Retain the most complete usage.
                if parsed.total >= (records[id]?.usage.total ?? 0) {
                    records[id] = UsageRecord(id: id, session: object["sessionId"] as? String ?? object["session_id"] as? String ?? fileID, date: date, usage: parsed, model: message["model"] as? String)
                }
            }
        }
        let finalRecords = provider == .codex && !hasModernCodexRecords ? legacy : Array(records.values)
        summary?.usage = finalRecords.reduce(TokenUsage()) { $0 + $1.usage }
        summary?.responses = finalRecords.count
        summary?.modelUsage = Self.modelTotals(finalRecords)
        return ParsedTranscript(records: finalRecords, session: summary)
    }
    public static func modelTotals(_ records: [UsageRecord]) -> [String: TokenUsage] {
        records.reduce(into: [:]) { totals, record in
            for (model, tokens) in record.modelUsage { totals[model] = (totals[model] ?? TokenUsage()) + tokens }
        }
    }
}

public actor HistoryReader {
    private struct CachedFile { let size: Int; let modified: Date; let transcript: ParsedTranscript }
    private var cache: [String: CachedFile] = [:]
    private let roots: [Provider: [URL]]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let env = home == FileManager.default.homeDirectoryForCurrentUser ? ProcessInfo.processInfo.environment : [:]
        let codex = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let claude = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let grok = env["GROK_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".grok")
        roots = [.grok: [grok.appendingPathComponent("sessions")], .codex: [codex.appendingPathComponent("sessions"), codex.appendingPathComponent("archived_sessions")], .claude: [claude.appendingPathComponent("projects")]]
    }
    public func read(now: Date = Date(), calendar: Calendar = .current, dayCount: Int = 7, providers: [Provider] = Provider.allCases) -> HistorySnapshot {
        var result = HistorySnapshot()
        let today = calendar.startOfDay(for: now)
        let count = max(1, min(84, dayCount))
        let start = calendar.date(byAdding: .day, value: 1 - count, to: today)!
        result.days = (0..<count).map { UsageDay(date: calendar.date(byAdding: .day, value: $0, to: start)!) }
        var visited: Set<String> = []
        for provider in providers {
            var records: [String: UsageRecord] = [:]
            var sessionsByID: [String: SessionSummary] = [:]
            var coveredSessions = Set<String>()
            for root in roots[provider] ?? [] {
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                result.available.insert(provider)
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in enumerator where url.pathExtension == "jsonl" && (provider != .grok || url.lastPathComponent == "updates.jsonl") {
                    guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                          let modified = attrs.contentModificationDate, modified >= start else { continue }
                    visited.insert(url.path)
                    let parsed: ParsedTranscript
                    if let entry = cache[url.path], entry.size == attrs.fileSize, entry.modified == modified { parsed = entry.transcript }
                    else {
                        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { result.unreadableFiles += 1; continue }
                        if provider == .grok {
                            let metadataURL = url.deletingLastPathComponent().appendingPathComponent("summary.json")
                            let metadata = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                            parsed = GrokTranscriptParser.parse(data, fileID: url.path, metadata: metadata)
                        } else { parsed = TranscriptParser.parseDetailed(data, provider: provider, fileID: url.path) }
                        cache[url.path] = CachedFile(size: attrs.fileSize ?? 0, modified: modified, transcript: parsed)
                    }
                    coveredSessions.formUnion(parsed.coveredSessions)
                    if let session = parsed.session, session.lastActivity >= start, session.lastActivity <= now {
                        if session.lastActivity >= (sessionsByID[session.session]?.lastActivity ?? .distantPast) { sessionsByID[session.session] = session }
                    }
                    for record in parsed.records where record.date >= start && record.date <= now {
                        if record.usage.total >= (records[record.id]?.usage.total ?? 0) { records[record.id] = record }
                    }
                }
            }
            // Parent Grok turn ledgers already include these child sessions.
            records = records.filter { !coveredSessions.contains($0.value.session) }
            var sessions = Set<String>()
            for record in records.values {
                let day = calendar.startOfDay(for: record.date)
                if let index = result.days.firstIndex(where: { $0.date == day }) {
                    result.days[index].setUsage(result.days[index].usage(for: provider) + record.usage, for: provider)
                }
                if day == today {
                    result.today[provider] = (result.today[provider] ?? TokenUsage()) + record.usage
                    result.requests[provider, default: 0] += record.responses
                    sessions.insert(record.session)
                }
            }
            let grouped = Dictionary(grouping: records.values, by: \.session)
            for var session in sessionsByID.values where !coveredSessions.contains(session.session) {
                let usage = grouped[session.session] ?? []
                session.usage = usage.reduce(TokenUsage()) { $0 + $1.usage }
                session.responses = usage.reduce(0) { $0 + $1.responses }
                session.modelUsage = TranscriptParser.modelTotals(usage)
                result.recentSessions.append(session)
            }
            result.sessions[provider] = sessions.count
            result.records[provider] = Array(records.values)
        }
        result.buildIndex(now: now, calendar: calendar)
        result.recentSessions.sort { $0.lastActivity > $1.lastActivity }
        cache = cache.filter { visited.contains($0.key) }
        return result
    }
}
