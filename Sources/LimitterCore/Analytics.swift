import Foundation

public enum SessionState: String, Sendable {
    case running = "Running", recent = "Recently active", idle = "Idle", interrupted = "Interrupted", error = "Error", unknown = "Last seen"
    public var isActive: Bool { self == .running || self == .recent }
}

public struct SessionSummary: Identifiable, Sendable {
    public var id: String { provider.rawValue + ":" + session }
    public var provider: Provider
    public var session: String
    public var project: String
    public var model: String?
    public var startedAt: Date
    public var lastActivity: Date
    public var observedState: SessionState
    public var usage: TokenUsage
    public var responses: Int
    public var modelUsage: [String: TokenUsage]
    public init(provider: Provider, session: String, project: String, model: String? = nil, startedAt: Date, lastActivity: Date, observedState: SessionState, usage: TokenUsage = .init(), responses: Int = 0, modelUsage: [String: TokenUsage]? = nil) {
        self.modelUsage = ModelPricing.partition(usage, reported: modelUsage ?? model.map { [$0: usage] } ?? [:])
        self.provider = provider; self.session = session; self.project = project; self.model = model
        self.startedAt = startedAt; self.lastActivity = lastActivity; self.observedState = observedState; self.usage = usage; self.responses = responses
    }
    public func state(at now: Date = Date()) -> SessionState {
        guard lastActivity <= now else { return .unknown }
        // A transcript is evidence of activity, not proof that a process is alive forever.
        if observedState.isActive && now.timeIntervalSince(lastActivity) > 300 { return .unknown }
        return observedState
    }
    public var stateExplanation: String {
        provider == .grok ? "Based on Grok Build’s local turn events. Tokens and responses are recorded when a turn completes; active state expires after 5 minutes without activity." : provider == .codex ? "Based on local task start, completion, and interruption events. Active state expires after 5 minutes without activity." : "Inferred from local messages and stop events. Recently active does not confirm a running process; it expires after 5 minutes."
    }
}

public struct APIRates: Codable, Equatable, Sendable {
    public var name: String
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var cacheWriteHour: Double
    public init(name: String, input: Double, output: Double, cacheRead: Double, cacheWrite: Double, cacheWriteHour: Double? = nil) {
        self.name = name; self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite; self.cacheWriteHour = cacheWriteHour ?? cacheWrite
    }
    public static let astra = APIRates(name: "GPT-6 Astra", input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)
    public static let grok46 = APIRates(name: "Grok 4.6", input: 2, output: 6, cacheRead: 0.5, cacheWrite: 2)
    public static let fable = APIRates(name: "Claude Fable 5.1", input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5, cacheWriteHour: 20)
    public static func presets(for provider: Provider) -> [APIRates] {
        if provider == .codex { return [.astra, .init(name: "GPT-5.6 Sol", input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5), .init(name: "GPT-5.6 Terra", input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2.5), .init(name: "GPT-5.6 Luna", input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25)] }
        if provider == .grok { return [.grok46, .init(name: "Grok Build 0.1", input: 1, output: 2, cacheRead: 0.2, cacheWrite: 1), .init(name: "Grok 4.5", input: 2, output: 6, cacheRead: 0.3, cacheWrite: 2), .init(name: "Grok 4.3", input: 1.25, output: 2.5, cacheRead: 0.2, cacheWrite: 1.25)] }
        return [.fable, .init(name: "Claude Fable 5", input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5, cacheWriteHour: 20),
                .init(name: "Claude Opus 5.5", input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5, cacheWriteHour: 8),
                .init(name: "Claude Opus 5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteHour: 10),
                .init(name: "Claude Opus 4.8", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteHour: 10),
                .init(name: "Claude Opus 4.7", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteHour: 10),
                .init(name: "Claude Opus 4.5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteHour: 10),
                .init(name: "Claude Opus 4.1", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75, cacheWriteHour: 30),
                .init(name: "Claude Opus 4", input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75, cacheWriteHour: 30),
                .init(name: "Claude Sonnet 4.5", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteHour: 6),
                .init(name: "Claude Sonnet 4", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteHour: 6),
                .init(name: "Claude Opus 4.6", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25, cacheWriteHour: 10), .init(name: "Claude Sonnet 5", input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, cacheWriteHour: 4), .init(name: "Claude Sonnet 4.6", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75, cacheWriteHour: 6), .init(name: "Claude Haiku 4.5", input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25, cacheWriteHour: 2)]
    }
    public var isValid: Bool { [input, output, cacheRead, cacheWrite, cacheWriteHour].allSatisfy { $0.isFinite && $0 >= 0 } }
    public func cost(_ usage: TokenUsage) -> CostBreakdown {
        guard isValid else { return .init() }
        let hour = max(0, min(usage.cacheWrite, usage.cacheWriteHour))
        return .init(input: Double(max(0, usage.input)) * input / 1e6, output: Double(max(0, usage.output)) * output / 1e6,
                     cacheRead: Double(max(0, usage.cached)) * cacheRead / 1e6,
                     cacheWrite: (Double(max(0, usage.cacheWrite - hour)) * cacheWrite + Double(hour) * cacheWriteHour) / 1e6)
    }
}

public struct CostBreakdown: Sendable {
    public var input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0
    public var totalInput: Double { input + cacheRead + cacheWrite }
    public var total: Double { totalInput + output }
    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

public struct ActivitySummary: Sendable {
    public var activeDays = 0, currentStreak = 0, bestStreak = 0, todayResponses = 0
    public var previousDailyAverage: Double = 0
    public var available = false
    public var headline: String {
        if !available { return "Ready when you are." }
        if todayResponses == 0 { return "No coding today? Fresh canvas." }
        if todayResponses >= 100 || (previousDailyAverage >= 10 && Double(todayResponses) >= previousDailyAverage * 1.6) { return "You’re going beast mode today." }
        if currentStreak >= 3 { return "\(currentStreak) days. Look at you showing up." }
        if todayResponses < 10 { return "First sparks. Big possibilities." }
        return "In the zone. Keep your flow."
    }
    public var factualHeadline: String { available ? "\(todayResponses.formatted()) model responses today." : "Waiting for local activity." }
}

extension HistorySnapshot {
    public func activity(providers: [Provider], now: Date = Date(), calendar: Calendar = .current) -> ActivitySummary {
        var result = ActivitySummary()
        result.available = providers.contains { available.contains($0) }
        let today = calendar.startOfDay(for: now)
        let counts = dailyResponses(providers: providers, calendar: calendar, now: now)
        result.todayResponses = counts[today, default: 0]
        let eligible = days.filter { $0.date <= today }.sorted { $0.date < $1.date }
        var streak = 0
        for day in eligible {
            if counts[day.date, default: 0] > 0 { result.activeDays += 1; streak += 1; result.bestStreak = max(result.bestStreak, streak) }
            else { streak = 0 }
        }
        var cursor = result.todayResponses > 0 ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while counts[cursor, default: 0] > 0 {
            result.currentStreak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        let preceding = eligible.filter { $0.date < today }.suffix(7)
        result.previousDailyAverage = preceding.isEmpty ? 0 : Double(preceding.reduce(0) { $0 + counts[$1.date, default: 0] }) / Double(preceding.count)
        return result
    }
    public func dailyResponses(providers: [Provider], calendar: Calendar = .current, now: Date = Date()) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        if let index, index.usable(now: now, calendar: calendar) {
            for provider in providers { for (day, activity) in index.daily[provider] ?? [:] where day <= now { counts[day, default: 0] += activity.responses } }
            return counts
        }
        for provider in providers {
            for record in records[provider] ?? [] where record.date <= now { counts[calendar.startOfDay(for: record.date), default: 0] += record.responses }
        }
        return counts
    }
    public func currentSession(providers: [Provider], now: Date = Date()) -> SessionSummary? {
        let sessions = recentSessions.filter { providers.contains($0.provider) && $0.lastActivity <= now }.sorted { $0.lastActivity > $1.lastActivity }
        return sessions.first(where: { $0.state(at: now).isActive }) ?? sessions.first
    }
}

extension Format {
    public static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US"))) }
}
