import Foundation

public enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex, claude, grok
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var abbreviation: String { switch self { case .codex: return "CX"; case .claude: return "CL"; case .grok: return "GK" } }
    public var mask: Int { switch self { case .codex: return 1; case .claude: return 2; case .grok: return 4 } }
    public var quotaPeriods: [QuotaPeriod] { self == .grok ? [.weekly] : QuotaPeriod.allCases }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var input: Int = 0
    public var output: Int = 0
    public var cached: Int = 0
    public var cacheWrite: Int = 0
    // A subset of cacheWrite, never added to total a second time.
    public var cacheWriteHour: Int = 0
    public var totalInput: Int { input + cached + cacheWrite }
    public var total: Int { totalInput + output }
    public init(input: Int = 0, output: Int = 0, cached: Int = 0, cacheWrite: Int = 0, cacheWriteHour: Int = 0) {
        self.input = input; self.output = output; self.cached = cached; self.cacheWrite = cacheWrite
        self.cacheWriteHour = max(0, min(cacheWrite, cacheWriteHour))
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
              cached: lhs.cached + rhs.cached, cacheWrite: lhs.cacheWrite + rhs.cacheWrite, cacheWriteHour: lhs.cacheWriteHour + rhs.cacheWriteHour)
    }
    public static func codex(_ value: [String: Any]) -> Self {
        let input = max(0, number(value["input_tokens"]))
        let cached = min(input, max(0, number(value["cached_input_tokens"])))
        let writes = min(input - cached, max(0, number(value["cache_write_input_tokens"])))
        // Codex input includes cached input; reasoning is already part of output.
        return .init(input: input - cached - writes, output: max(0, number(value["output_tokens"])), cached: cached, cacheWrite: writes)
    }
    public static func claude(_ value: [String: Any]) -> Self {
        .init(input: max(0, number(value["input_tokens"])), output: max(0, number(value["output_tokens"])),
              cached: max(0, number(value["cache_read_input_tokens"])), cacheWrite: max(0, number(value["cache_creation_input_tokens"])),
              cacheWriteHour: number((value["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]))
    }
}

public struct UsageRecord: Sendable {
    public let id: String
    public let session: String
    public let date: Date
    public let usage: TokenUsage
    public let responses: Int
    public let modelUsage: [String: TokenUsage]
    public init(id: String, session: String, date: Date, usage: TokenUsage, responses: Int = 1, model: String? = nil, modelUsage: [String: TokenUsage]? = nil) {
        self.modelUsage = ModelPricing.partition(usage, reported: modelUsage ?? model.map { [$0: usage] } ?? [:])
        self.responses = max(0, responses)
        self.id = id; self.session = session; self.date = date; self.usage = usage
    }
}

public struct UsageDay: Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public var codex = TokenUsage()
    public var claude = TokenUsage()
    public var grok = TokenUsage()
    public init(date: Date) { self.date = date }
    public func tokens(for provider: Provider?) -> Int {
        if let provider { return usage(for: provider).total }
        return Provider.allCases.reduce(0) { $0 + usage(for: $1).total }
    }
    public func usage(for provider: Provider) -> TokenUsage {
        switch provider { case .codex: return codex; case .claude: return claude; case .grok: return grok }
    }
    public mutating func setUsage(_ value: TokenUsage, for provider: Provider) {
        switch provider { case .codex: codex = value; case .claude: claude = value; case .grok: grok = value }
    }
}

public struct HistorySnapshot: Sendable {
    public var days: [UsageDay] = []
    public var today: [Provider: TokenUsage] = [:]
    public var sessions: [Provider: Int] = [:]
    public var requests: [Provider: Int] = [:]
    public var records: [Provider: [UsageRecord]] = [:]
    public var recentSessions: [SessionSummary] = []
    public var index: HistoryIndex?
    public var available: Set<Provider> = []
    public var unreadableFiles: Int = 0
    public init() {}
    public func total(for provider: Provider?) -> TokenUsage {
        if let provider { return today[provider] ?? TokenUsage() }
        return today.values.reduce(TokenUsage(), +)
    }
    public func count(_ values: [Provider: Int], provider: Provider?) -> Int {
        if let provider { return values[provider] ?? 0 }; return values.values.reduce(0, +)
    }
    public func total(dayCount: Int, providers: [Provider], now: Date = Date(), calendar: Calendar = .current) -> TokenUsage {
        let start = calendar.date(byAdding: .day, value: 1 - max(1, dayCount), to: calendar.startOfDay(for: now))!
        return days.filter { $0.date >= start && $0.date <= now }.reduce(TokenUsage()) { sum, day in
            providers.reduce(sum) { $0 + day.usage(for: $1) }
        }
    }
    public func activityCounts(dayCount: Int, providers: [Provider], now: Date = Date(), calendar: Calendar = .current) -> (sessions: Int, requests: Int) {
        let start = calendar.date(byAdding: .day, value: 1 - max(1, dayCount), to: calendar.startOfDay(for: now))!
        var sessions = Set<String>(), requests = 0
        if let index, index.usable(now: now, calendar: calendar) {
            for provider in providers {
                for (day, activity) in index.daily[provider] ?? [:] where day >= start && day <= now {
                    requests += activity.responses
                    sessions.formUnion(activity.sessions.map { provider.rawValue + ":" + $0 })
                }
            }
            return (sessions.count, requests)
        }
        for provider in providers {
            for record in records[provider] ?? [] where record.date >= start && record.date <= now {
                sessions.insert(provider.rawValue + ":" + record.session); requests += record.responses
            }
        }
        return (sessions.count, requests)
    }
}

public struct LimitWindow: Identifiable, Sendable {
    public let id: String
    public let usedPercent: Double
    public let durationMinutes: Int?
    public let resetsAt: Date?
    public let observedAt: Date?
    public var title: String {
        guard let minutes = durationMinutes else { return id.capitalized }
        if minutes >= 10080 { return "Weekly" }
        if minutes == 300 { return "Session" }
        if minutes == 1440 { return "Daily" }
        return minutes >= 60 ? "\(minutes / 60) hour" : "\(minutes) min"
    }
    public var remaining: Double { max(0, 100 - usedPercent) }
    public var progress: Double { min(1, usedPercent / 100) }
    public func hasExpired(at now: Date = Date()) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public init(id: String, usedPercent: Double, durationMinutes: Int?, resetsAt: Date?, observedAt: Date? = nil) {
        self.id = id; self.usedPercent = usedPercent.isFinite ? max(0, usedPercent) : 0; self.durationMinutes = durationMinutes; self.resetsAt = resetsAt; self.observedAt = observedAt
    }
}

public struct LimitBucket: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let windows: [LimitWindow]
    public var error: String?
    public init(id: String, name: String, windows: [LimitWindow], error: String? = nil) { self.id = id; self.name = name; self.windows = windows; self.error = error }
}

public struct ProviderLimits: Sendable {
    public var provider: Provider
    public var plan: String?
    public var buckets: [LimitBucket] = []
    public var updatedAt: Date?
    public var receivedAt: Date?
    public var windowErrors: [String: String] = [:]
    public var error: String?
    public var quotaNote: String?
    public var modelLimitsError: String?
    public var source: String
    public var resetCredits: Int?
    public var lifetimeTokens: Int?
    public var streakDays: Int?
    public var windows: [LimitWindow] { buckets.first?.windows ?? [] }
    public init(provider: Provider, source: String) { self.provider = provider; self.source = source }
    public var isStale: Bool { updatedAt.map { Date().timeIntervalSince($0) > 600 } ?? true }
}

public func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
public func parseDate(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    return fractionalISO.date(from: string) ?? plainISO.date(from: string)
}
private let fractionalISO: ISO8601DateFormatter = {
    let result = ISO8601DateFormatter(); result.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return result
}()
private let plainISO = ISO8601DateFormatter()

public enum Format {
    public static func percent(_ value: Double) -> String { value.isFinite ? String(format: "%.0f", value.rounded(.towardZero)) : "—" }
    public static func compact(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1e9) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1e6) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1e3) }
        return String(value)
    }
    public static func reset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Reset unavailable" }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "Awaiting new window" }
        let minutes = max(1, seconds / 60), hours = minutes / 60
        if hours >= 24 { return "Resets in \(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}
