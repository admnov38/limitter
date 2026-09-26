import XCTest
@testable import LimitterCore

final class PriceCatalogTests: XCTestCase {
    private let table = """
    ## Model pricing

    | Model                | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |
    | :------------------- | :---------------- | :-------------- | :-------------- | :----------------------- | :------------ |
    | Claude Fable 5.1     | $10 / MTok        | $12.50 / MTok   | $20 / MTok      | $0.25 / MTok<sup>1</sup> | $50 / MTok    |
    | Claude Opus 5.5      | $4 / MTok         | $5 / MTok       | $8 / MTok       | $0.20 / MTok<sup>2</sup> | $20 / MTok    |
    | Claude Opus 4.1 ([retired, except on Bedrock](https://example.com)) | $15 / MTok | $18.75 / MTok | $30 / MTok | $1.50 / MTok | $75 / MTok |

    ## Batch processing

    | Model           | Batch input | Batch output |
    | Claude Opus 5.5 | $2 / MTok   | $10 / MTok   |
    """

    func testParsesAnthropicModelTableOnly() {
        let rates = PriceSources.parseAnthropic(table)
        XCTAssertEqual(Set(rates.keys), ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-4-1"])
        XCTAssertEqual(rates["claude-opus-5-5"], APIRates(name: "Claude Opus 5.5", input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5, cacheWriteHour: 8))
        XCTAssertEqual(rates["claude-opus-4-1"]?.name, "Claude Opus 4.1")
        XCTAssertEqual(rates["claude-opus-4-1"]?.cacheRead, 1.5)
    }

    func testParsesLiteLLMFirstPartyEntriesOnly() throws {
        let json: [String: Any] = [
            "gpt-6-astra": ["litellm_provider": "openai", "input_cost_per_token": 1e-5, "output_cost_per_token": 5e-5, "cache_read_input_token_cost": 1e-6],
            "azure/gpt-6-astra": ["litellm_provider": "azure", "input_cost_per_token": 9, "output_cost_per_token": 9],
            "xai/grok-4.6": ["litellm_provider": "xai", "input_cost_per_token": 2e-6, "output_cost_per_token": 6e-6, "cache_read_input_token_cost": 5e-7],
            "vertex_ai/xai/grok-4.6": ["litellm_provider": "xai", "input_cost_per_token": 9, "output_cost_per_token": 9],
            "claude-opus-5-5": ["litellm_provider": "anthropic", "input_cost_per_token": 4e-6, "output_cost_per_token": 2e-5, "cache_read_input_token_cost": 2e-7,
                                "cache_creation_input_token_cost": 5e-6, "cache_creation_input_token_cost_above_1hr": 8e-6],
            "sample_spec": ["litellm_provider": "openai", "input_cost_per_token": "0"]
        ]
        let rates = PriceSources.parseLiteLLM(try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(rates[.codex]?.keys.sorted(), ["gpt-6-astra"])
        XCTAssertEqual(rates[.codex]?["gpt-6-astra"]?.cacheRead ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(rates[.codex]?["gpt-6-astra"]?.cacheWrite ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(rates[.grok]?.keys.sorted(), ["grok-4.6"])
        XCTAssertEqual(rates[.claude]?["claude-opus-5-5"]?.cacheWriteHour ?? 0, 8, accuracy: 1e-9)
    }

    func testLiveRatesPriceNewModelsAndOverridePresets() {
        let catalog = PriceCatalog()
        XCTAssertNil(ModelPricing.rates(for: "claude-opus-6", provider: .claude, catalog: catalog))
        catalog.install(PriceSnapshot(fetchedAt: Date(), sources: ["Anthropic"], rates: [.claude: [
            "claude-opus-6": APIRates(name: "Claude Opus 6", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            "claude-opus-5": APIRates(name: "claude-opus-5", input: 1, output: 2, cacheRead: 0.1, cacheWrite: 1.25)
        ]]))
        XCTAssertEqual(ModelPricing.rates(for: "claude-opus-6-20270101", provider: .claude, catalog: catalog)?.input, 3)
        let opus5 = ModelPricing.rates(for: "claude-opus-5", provider: .claude, catalog: catalog)
        XCTAssertEqual(opus5?.input, 1)
        XCTAssertEqual(opus5?.name, "Claude Opus 5", "preset display names are kept")
        XCTAssertNil(ModelPricing.rates(for: "claude-opus-99", provider: .claude, catalog: catalog))
    }

    func testBuiltInOpus55IsPricedOffline() {
        let rates = ModelPricing.rates(for: "claude-opus-5-5", provider: .claude, catalog: PriceCatalog())
        XCTAssertEqual(rates, APIRates(name: "Claude Opus 5.5", input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5, cacheWriteHour: 8))
    }

    func testRetiredCodexSparkIsQuotedAtLunaRates() {
        let catalog = PriceCatalog()
        let luna = ModelPricing.rates(for: "gpt-5.6-luna", provider: .codex, catalog: catalog)
        let spark = ModelPricing.rates(for: "gpt-5.3-codex-spark", provider: .codex, catalog: catalog)
        XCTAssertEqual(spark?.input, luna?.input)
        XCTAssertEqual(spark?.output, luna?.output)
        XCTAssertEqual(spark?.name, "GPT-5.3 Codex Spark (at Luna rates)")
        catalog.install(PriceSnapshot(fetchedAt: Date(), rates: [.codex: ["gpt-5.6-luna": .init(name: "gpt-5.6-luna", input: 0.3, output: 1.5, cacheRead: 0.03, cacheWrite: 0.3)]]))
        XCTAssertEqual(ModelPricing.rates(for: "gpt-5.3-codex-spark", provider: .codex, catalog: catalog)?.input, 0.3, "follows live Luna rates")
    }

    func testSnapshotRoundTripsAndMergesWithLaterSourceWinning() throws {
        let a = PriceSnapshot(fetchedAt: Date(timeIntervalSince1970: 1), sources: ["LiteLLM"], rates: [.claude: ["x": .init(name: "x", input: 1, output: 1, cacheRead: 1, cacheWrite: 1)]])
        let b = PriceSnapshot(fetchedAt: Date(timeIntervalSince1970: 2), sources: ["Anthropic"], rates: [.claude: ["x": .init(name: "x", input: 2, output: 2, cacheRead: 2, cacheWrite: 2)]])
        let merged = a.merging(b)
        XCTAssertEqual(merged.rates[.claude]?["x"]?.input, 2)
        XCTAssertEqual(merged.sources, ["LiteLLM", "Anthropic"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pricing.json")
        try PriceSources.saveCache(merged, to: url)
        XCTAssertEqual(PriceSources.loadCache(from: url), merged)
        XCTAssertTrue(merged.isStale(now: Date(timeIntervalSince1970: 2 + 86_400)))
        XCTAssertFalse(merged.isStale(now: Date(timeIntervalSince1970: 3)))
    }
}
