import Foundation

public enum PricingMode: String, CaseIterable, Codable, Sendable {
    case recordedModels = "Recorded models", benchmark = "Single benchmark"
}

public enum ModelPricing {
    public static let unknown = "Unknown model"
    public static func normalizedID(_ id: String) -> String {
        id.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
    /// Lookup key shared by transcript model IDs, preset names, and fetched price lists.
    public static func key(for model: String, provider: Provider) -> String {
        var id = normalizedID(model).replacingOccurrences(of: " ", with: "-")
        let namespace: String
        switch provider { case .codex: namespace = "openai/"; case .claude: namespace = "anthropic/"; case .grok: namespace = "xai/" }
        if id.hasPrefix(namespace) { id = String(id.dropFirst(namespace.count)) }
        if provider == .claude { id = id.replacingOccurrences(of: ".", with: "-") }
        if provider == .grok && id.hasSuffix("-build") { id = String(id.dropLast(6)) }
        return id
    }
    /// Retired models without a published rate, quoted at an explicitly chosen stand-in.
    static let aliases: [Provider: [String: (target: String, name: String)]] = [
        .codex: ["gpt-5.3-codex-spark": ("gpt-5.6-luna", "GPT-5.3 Codex Spark (at Luna rates)")]
    ]
    /// Live rates first, then built-in presets. Unknown models stay unpriced.
    public static func rates(for model: String, provider: Provider, catalog: PriceCatalog = .shared) -> APIRates? {
        let id = key(for: model, provider: provider)
        if let alias = aliases[provider]?[id] {
            return rates(for: alias.target, provider: provider, catalog: catalog).map { var rates = $0; rates.name = alias.name; return rates }
        }
        let preset = APIRates.presets(for: provider).first { key(for: $0.name, provider: provider) == id }
        guard var live = catalog.rates(provider: provider, key: id) else { return preset }
        if let preset { live.name = preset.name }
        return live
    }
    /// Keep every token represented. Partial model maps leave an explicit unknown remainder.
    public static func partition(_ usage: TokenUsage, reported: [String: TokenUsage]) -> [String: TokenUsage] {
        var result: [String: TokenUsage] = [:]
        for (id, tokens) in reported {
            let key = id.isEmpty || id == unknown ? unknown : normalizedID(id)
            result[key] = (result[key] ?? TokenUsage()) + tokens
        }
        let sum = result.values.reduce(TokenUsage(), +)
        guard sum.input <= usage.input, sum.output <= usage.output, sum.cached <= usage.cached, sum.cacheWrite <= usage.cacheWrite,
              sum.cacheWriteHour <= usage.cacheWriteHour, sum.cacheWrite - sum.cacheWriteHour <= usage.cacheWrite - usage.cacheWriteHour else { return [unknown: usage] }
        let remainder = TokenUsage(input: usage.input - sum.input, output: usage.output - sum.output, cached: usage.cached - sum.cached,
                                   cacheWrite: usage.cacheWrite - sum.cacheWrite, cacheWriteHour: usage.cacheWriteHour - sum.cacheWriteHour)
        if remainder.total > 0 { result[unknown] = (result[unknown] ?? TokenUsage()) + remainder }
        return result
    }
}

public struct ModelCost: Identifiable, Sendable {
    public var id: String { provider.id + ":" + model }
    public let provider: Provider
    public let model: String
    public let usage: TokenUsage
    public let rates: APIRates?
    public var title: String { ModelPricing.rates(for: model, provider: provider)?.name ?? model }
    public var cost: CostBreakdown? { rates.map { $0.cost(usage) } }
}

public struct PriceEstimate: Sendable {
    public var rows: [ModelCost] = []
    public var cost = CostBreakdown()
    public var unpricedTokens = 0
    public var totalTokens = 0
    public var isComplete: Bool { unpricedTokens == 0 }
    public var canDisplay: Bool { totalTokens == 0 || totalTokens > unpricedTokens }
    public var formatted: String { canDisplay ? (isComplete ? "" : "≥ ") + Format.money(cost.total) : "—" }
    public init() {}
    public init(usage: [String: TokenUsage], provider: Provider, preferences: AppPreferences) {
        for (model, tokens) in usage where tokens.total > 0 {
            let rates = preferences.pricingMode == .benchmark ? preferences.rates(for: provider) : ModelPricing.rates(for: model, provider: provider)
            let row = ModelCost(provider: provider, model: model, usage: tokens, rates: rates.flatMap { $0.isValid ? $0 : nil })
            rows.append(row); totalTokens += tokens.total
            if let value = row.cost { cost = cost + value } else { unpricedTokens += tokens.total }
        }
        rows.sort(by: ModelOrder.apiValue.precedes)
    }
    public func ordered(by order: ModelOrder) -> [ModelCost] { rows.sorted(by: order.precedes) }
    public static func + (lhs: Self, rhs: Self) -> Self {
        var result = Self(); result.rows = lhs.rows + rhs.rows; result.cost = lhs.cost + rhs.cost
        result.totalTokens = lhs.totalTokens + rhs.totalTokens; result.unpricedTokens = lhs.unpricedTokens + rhs.unpricedTokens
        return result
    }
}

extension ModelOrder {
    public func precedes(_ lhs: ModelCost, _ rhs: ModelCost) -> Bool {
        switch self {
        case .tokens:
            if lhs.usage.total != rhs.usage.total { return lhs.usage.total > rhs.usage.total }
        case .apiValue:
            let left = lhs.cost?.total ?? -1, right = rhs.cost?.total ?? -1
            if left != right { return left > right }
            if lhs.usage.total != rhs.usage.total { return lhs.usage.total > rhs.usage.total }
        }
        if lhs.model != rhs.model { return lhs.model < rhs.model }
        return lhs.provider.rawValue < rhs.provider.rawValue
    }
}

extension CostBreakdown {
    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }
}

extension HistorySnapshot {
    /// Model identifiers only; no transcripts or usage data are sent to pricing sources.
    public func unpricedModels(catalog: PriceCatalog = .shared, now: Date = Date(), calendar: Calendar = .current) -> Set<String> {
        var result = Set<String>()
        for provider in Provider.allCases {
            for (model, usage) in modelUsage(dayCount: 30, provider: provider, now: now, calendar: calendar) where usage.total > 0 {
                guard !model.isEmpty, model != ModelPricing.unknown,
                      ModelPricing.rates(for: model, provider: provider, catalog: catalog) == nil else { continue }
                result.insert(provider.rawValue + ":" + ModelPricing.key(for: model, provider: provider))
            }
        }
        return result
    }

    public func modelUsage(dayCount: Int, provider: Provider, now: Date = Date(), calendar: Calendar = .current) -> [String: TokenUsage] {
        let start = calendar.date(byAdding: .day, value: 1 - max(1, dayCount), to: calendar.startOfDay(for: now))!
        var result: [String: TokenUsage] = [:]
        if let index, index.usable(now: now, calendar: calendar) {
            for (day, models) in index.dailyModels[provider] ?? [:] where day >= start && day <= now {
                for (model, usage) in models { result[model] = (result[model] ?? TokenUsage()) + usage }
            }
        } else {
            for record in records[provider] ?? [] where record.date >= start && record.date <= now {
                for (model, usage) in record.modelUsage { result[model] = (result[model] ?? TokenUsage()) + usage }
            }
        }
        return result
    }
}
