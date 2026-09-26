import Foundation

/// Live model rates, keyed by provider and normalized model ID. Built-in presets remain the offline fallback.
public struct PriceSnapshot: Codable, Equatable, Sendable {
    public var fetchedAt: Date?
    public var sources: [String] = []
    public var rates: [Provider: [String: APIRates]] = [:]
    public init(fetchedAt: Date? = nil, sources: [String] = [], rates: [Provider: [String: APIRates]] = [:]) {
        self.fetchedAt = fetchedAt; self.sources = sources; self.rates = rates
    }
    public var modelCount: Int { rates.values.reduce(0) { $0 + $1.count } }
    public func isStale(now: Date = Date(), maxAge: TimeInterval = 86_400) -> Bool {
        fetchedAt.map { now.timeIntervalSince($0) >= maxAge } ?? true
    }
    /// Later sources win for models both define.
    public func merging(_ other: PriceSnapshot) -> PriceSnapshot {
        var result = self
        for (provider, models) in other.rates { result.rates[provider, default: [:]].merge(models) { _, new in new } }
        result.sources += other.sources.filter { !result.sources.contains($0) }
        result.fetchedAt = [fetchedAt, other.fetchedAt].compactMap { $0 }.max()
        return result
    }
}

public final class PriceCatalog: @unchecked Sendable {
    public static let shared = PriceCatalog()
    private let lock = NSLock()
    private var snapshot = PriceSnapshot()
    public init() {}
    public var current: PriceSnapshot { lock.withLock { snapshot } }
    public func install(_ value: PriceSnapshot) { lock.withLock { snapshot = value } }
    func rates(provider: Provider, key: String) -> APIRates? { lock.withLock { snapshot.rates[provider]?[key] } }
}

public enum PriceSources {
    public static let anthropic = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing.md")!
    public static let litellm = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    public static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Limitter/pricing.json")
    }

    /// Parses the "Model pricing" table from Anthropic's pricing page (Markdown).
    public static func parseAnthropic(_ markdown: String) -> [String: APIRates] {
        var columns: [String: Int] = [:]
        var result: [String: APIRates] = [:]
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else {
                if !columns.isEmpty && !result.isEmpty { break }
                continue
            }
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            let lower = cells.map { $0.lowercased() }
            if columns.isEmpty {
                guard lower.first == "model", lower.contains(where: { $0.contains("5m cache") }) else { continue }
                func column(_ needle: String) -> Int? { lower.firstIndex { $0.contains(needle) } }
                guard let input = column("base input"), let write = column("5m cache"), let hour = column("1h cache"),
                      let read = column("cache hits"), let output = column("output") else { continue }
                columns = ["input": input, "write": write, "hour": hour, "read": read, "output": output]
                continue
            }
            guard let name = modelName(cells.first ?? ""), name.lowercased().hasPrefix("claude ") else { continue }
            func price(_ key: String) -> Double? { columns[key].flatMap { $0 < cells.count ? dollars(cells[$0]) : nil } }
            guard let input = price("input"), let output = price("output"), let read = price("read"), let write = price("write") else { continue }
            let rates = APIRates(name: name, input: input, output: output, cacheRead: read, cacheWrite: write, cacheWriteHour: price("hour"))
            result[ModelPricing.key(for: name, provider: .claude)] = rates
        }
        return result
    }

    /// Parses LiteLLM's community-maintained price list for first-party provider entries.
    public static func parseLiteLLM(_ data: Data) -> [Provider: [String: APIRates]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let owners: [String: Provider] = ["openai": .codex, "anthropic": .claude, "xai": .grok]
        var result: [Provider: [String: APIRates]] = [:]
        for (rawKey, value) in object {
            guard let entry = value as? [String: Any], let owner = entry["litellm_provider"] as? String, let provider = owners[owner],
                  let input = number(entry["input_cost_per_token"]), let output = number(entry["output_cost_per_token"]) else { continue }
            var model = rawKey
            if let slash = model.lastIndex(of: "/") {
                // Only the provider's own namespace, never resellers or regional mirrors.
                guard model[..<slash] == owner else { continue }
                model = String(model[model.index(after: slash)...])
            }
            let write = number(entry["cache_creation_input_token_cost"]) ?? input
            let rates = APIRates(name: model, input: input * 1e6, output: output * 1e6,
                                 cacheRead: (number(entry["cache_read_input_token_cost"]) ?? input) * 1e6, cacheWrite: write * 1e6,
                                 cacheWriteHour: number(entry["cache_creation_input_token_cost_above_1hr"]).map { $0 * 1e6 })
            guard rates.isValid else { continue }
            result[provider, default: [:]][ModelPricing.key(for: model, provider: provider)] = rates
        }
        return result
    }

    /// Downloads both sources. Anthropic's own table takes precedence for Claude.
    public static func fetch(session: URLSession = .shared, now: Date = Date()) async throws -> PriceSnapshot {
        async let anthropicData = try? session.data(from: anthropic)
        async let litellmData = try? session.data(from: litellm)
        var snapshot = PriceSnapshot()
        if let (data, response) = await litellmData, (response as? HTTPURLResponse)?.statusCode == 200 {
            let rates = parseLiteLLM(data)
            if !rates.isEmpty { snapshot = snapshot.merging(.init(fetchedAt: now, sources: ["LiteLLM"], rates: rates)) }
        }
        if let (data, response) = await anthropicData, (response as? HTTPURLResponse)?.statusCode == 200 {
            let rates = parseAnthropic(String(decoding: data, as: UTF8.self))
            if !rates.isEmpty { snapshot = snapshot.merging(.init(fetchedAt: now, sources: ["Anthropic"], rates: [.claude: rates])) }
        }
        guard snapshot.modelCount > 0 else { throw URLError(.cannotParseResponse) }
        return snapshot
    }

    public static func loadCache(from url: URL = cacheURL) -> PriceSnapshot? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PriceSnapshot.self, from: $0) }
    }
    public static func saveCache(_ snapshot: PriceSnapshot, to url: URL = cacheURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    private static func modelName(_ cell: String) -> String? {
        var name = cell.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        if let cut = name.range(of: #"\s*[\(\[]"#, options: .regularExpression) { name = String(name[..<cut.lowerBound]) }
        name = name.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    private static func dollars(_ cell: String) -> Double? {
        guard let match = cell.range(of: #"\$\s*[0-9][0-9,]*(\.[0-9]+)?"#, options: .regularExpression) else { return nil }
        return Double(cell[match].dropFirst().replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let double = value.doubleValue
        return double.isFinite && double >= 0 ? double : nil
    }
}
