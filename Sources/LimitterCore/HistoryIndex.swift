import Foundation

public struct DayActivity: Sendable {
    public var responses = 0
    public var sessions = Set<String>()
    public init() {}
}

/// Built once with a history refresh, outside UI hover handlers.
public struct HistoryIndex: Sendable {
    public var builtAt: Date
    public var calendar: Calendar
    public var daily: [Provider: [Date: DayActivity]] = [:]
    public var dailyModels: [Provider: [Date: [String: TokenUsage]]] = [:]
    public var hourly: [Provider: [Date: TokenUsage]] = [:]
    public init(records: [Provider: [UsageRecord]], now: Date, calendar: Calendar) {
        self.builtAt = now; self.calendar = calendar
        let today = calendar.startOfDay(for: now)
        for provider in Provider.allCases {
            for record in records[provider] ?? [] where record.date <= now {
                let day = calendar.startOfDay(for: record.date)
                for (model, tokens) in record.modelUsage {
                    dailyModels[provider, default: [:]][day, default: [:]][model] = (dailyModels[provider]?[day]?[model] ?? TokenUsage()) + tokens
                }
                daily[provider, default: [:]][day, default: DayActivity()].responses += record.responses
                daily[provider, default: [:]][day, default: DayActivity()].sessions.insert(record.session)
                if day == today, let hour = calendar.dateInterval(of: .hour, for: record.date)?.start {
                    hourly[provider, default: [:]][hour] = (hourly[provider]?[hour] ?? TokenUsage()) + record.usage
                }
            }
        }
    }
    public func usable(now: Date, calendar: Calendar) -> Bool { self.calendar == calendar && builtAt <= now }
}

public struct HeatmapDay: Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let responses: Int
    public let tokens: Int
    public let accessibilityLabel: String
}

public struct HeatmapData: Sendable {
    public var days: [HeatmapDay] = []
    public var summary = ActivitySummary()
    public var peak = 1
    public init() {}
}

extension HistorySnapshot {
    public mutating func buildIndex(now: Date = Date(), calendar: Calendar = .current) {
        index = HistoryIndex(records: records, now: now, calendar: calendar)
    }
    public func heatmap(providers: [Provider], now: Date = Date(), calendar: Calendar = .current) -> HeatmapData {
        let counts = dailyResponses(providers: providers, calendar: calendar, now: now)
        var result = HeatmapData()
        result.summary = activity(providers: providers, now: now, calendar: calendar)
        result.days = days.map { day in
            let count = counts[day.date, default: 0]
            return HeatmapDay(date: day.date, responses: count, tokens: providers.reduce(0) { $0 + day.tokens(for: $1) }, accessibilityLabel: day.date.formatted(date: .complete, time: .omitted) + ", \(count) model responses")
        }
        result.peak = max(1, result.days.map(\.responses).max() ?? 1)
        return result
    }
    public func todayHours(providers: [Provider], now: Date = Date(), calendar: Calendar = .current) -> [UsageDay] {
        let source = index.flatMap { $0.usable(now: now, calendar: calendar) && calendar.isDate($0.builtAt, inSameDayAs: now) ? $0 : nil }
            ?? HistoryIndex(records: records, now: now, calendar: calendar)
        let start = calendar.startOfDay(for: now)
        var hour = start, result: [UsageDay] = []
        while hour <= now {
            var bucket = UsageDay(date: hour)
            for provider in providers { bucket.setUsage(source.hourly[provider]?[hour] ?? TokenUsage(), for: provider) }
            result.append(bucket)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour), next > hour else { break }
            hour = next
        }
        return result
    }
}
