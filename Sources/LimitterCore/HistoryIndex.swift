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
    /// Quarter-hour starts. Charts sum these into the selected bucket.
    public var quarterHours: [Provider: [Date: TokenUsage]] = [:]
    public init(records: [Provider: [UsageRecord]], now: Date, calendar: Calendar) {
        self.builtAt = now; self.calendar = calendar
        for provider in Provider.allCases {
            for record in records[provider] ?? [] where record.date <= now {
                let day = calendar.startOfDay(for: record.date)
                for (model, tokens) in record.modelUsage {
                    dailyModels[provider, default: [:]][day, default: [:]][model] = (dailyModels[provider]?[day]?[model] ?? TokenUsage()) + tokens
                }
                daily[provider, default: [:]][day, default: DayActivity()].responses += record.responses
                daily[provider, default: [:]][day, default: DayActivity()].sessions.insert(record.session)
                let quarter = ChartInterval.floor(record.date, minutes: ChartInterval.minutes15.minutes, calendar: calendar)
                quarterHours[provider, default: [:]][quarter] = (quarterHours[provider]?[quarter] ?? TokenUsage()) + record.usage
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
        chartBuckets(interval: .hour, dayCount: 1, providers: providers, now: now, calendar: calendar)
    }
    /// One bucket per interval from the start of the window through now. Daily charts with no indexed records fall back to day totals.
    public func chartBuckets(interval: ChartInterval, dayCount: Int, providers: [Provider], now: Date = Date(), calendar: Calendar = .current) -> [UsageDay] {
        let dayCount = max(1, dayCount)
        let interval = interval.resolved(for: dayCount)
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: 1 - dayCount, to: today) else { return [] }
        let source = chartIndex(now: now, calendar: calendar)
        let hasQuarters = providers.contains { source.quarterHours[$0]?.isEmpty == false }
        if interval == .day, !hasQuarters {
            return days.compactMap { original in
                guard original.date >= start, original.date <= now else { return nil }
                var day = UsageDay(date: original.date)
                for provider in providers { day.setUsage(original.usage(for: provider), for: provider) }
                return day
            }
        }
        var slots = Self.chartSlots(from: start, through: now, interval: interval, calendar: calendar)
        for provider in providers {
            for (time, usage) in source.quarterHours[provider] ?? [:] where time >= start && time <= now {
                let slot = interval == .day ? calendar.startOfDay(for: time) : ChartInterval.floor(time, minutes: interval.minutes, calendar: calendar)
                guard slot >= start, slot <= now else { continue }
                var bucket = slots[slot] ?? UsageDay(date: slot)
                bucket.setUsage(bucket.usage(for: provider) + usage, for: provider)
                slots[slot] = bucket
            }
        }
        return slots.keys.sorted().compactMap { slots[$0] }
    }
    private func chartIndex(now: Date, calendar: Calendar) -> HistoryIndex {
        if let index, index.usable(now: now, calendar: calendar), calendar.isDate(index.builtAt, inSameDayAs: now) { return index }
        return HistoryIndex(records: records, now: now, calendar: calendar)
    }
    private static func chartSlots(from start: Date, through now: Date, interval: ChartInterval, calendar: Calendar) -> [Date: UsageDay] {
        var slots: [Date: UsageDay] = [:]
        if interval == .day {
            var day = start
            while day <= now {
                slots[day] = UsageDay(date: day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
            return slots
        }
        var day = start
        while day <= now {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else { break }
            var minute = 0
            var finished = false
            while minute < 1_560 {
                guard let slot = calendar.date(byAdding: .minute, value: minute, to: day) else { break }
                if slot >= nextDay { break }
                if slot > now { finished = true; break }
                let aligned = ChartInterval.floor(slot, minutes: interval.minutes, calendar: calendar)
                if slots[aligned] == nil, aligned >= start, aligned <= now { slots[aligned] = UsageDay(date: aligned) }
                minute += interval.minutes
            }
            if finished { break }
            day = nextDay
        }
        return slots
    }
}
