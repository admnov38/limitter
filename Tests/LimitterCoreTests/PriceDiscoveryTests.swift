import XCTest
@testable import LimitterCore

final class PriceDiscoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNewModelBypassesFreshDailyCacheButRetriesAreBounded() {
        var policy = PriceRefreshPolicy()
        let fresh = PriceSnapshot(fetchedAt: now)
        let sonnet: Set<String> = ["claude:claude-sonnet-5-5"]
        XCTAssertFalse(policy.begin(snapshot: fresh, missingModels: [], now: now))
        XCTAssertTrue(policy.begin(snapshot: fresh, missingModels: sonnet, now: now))
        policy.finish(succeeded: true)
        XCTAssertFalse(policy.begin(snapshot: fresh, missingModels: sonnet, now: now.addingTimeInterval(30)))
        XCTAssertFalse(policy.begin(snapshot: fresh, missingModels: sonnet, now: now.addingTimeInterval(899)))
        XCTAssertTrue(policy.begin(snapshot: fresh, missingModels: sonnet, now: now.addingTimeInterval(900)))
        XCTAssertFalse(policy.begin(snapshot: fresh, missingModels: [], now: now.addingTimeInterval(1_800)), "Finding a rate stops missing-model retries")
    }

    func testAnotherNewModelCanRefreshAfterOneMinuteAndManualRefreshBypassesCooldown() {
        var policy = PriceRefreshPolicy()
        let fresh = PriceSnapshot(fetchedAt: now)
        XCTAssertTrue(policy.begin(snapshot: fresh, missingModels: ["claude:first"], now: now))
        XCTAssertFalse(policy.begin(snapshot: fresh, missingModels: ["claude:second"], now: now.addingTimeInterval(59)))
        XCTAssertTrue(policy.begin(snapshot: fresh, missingModels: ["claude:second"], now: now.addingTimeInterval(60)))
        XCTAssertTrue(policy.begin(snapshot: fresh, missingModels: [], now: now.addingTimeInterval(61), force: true))
    }

    func testDailyAndFailedSourceRetries() {
        var policy = PriceRefreshPolicy()
        let fresh = PriceSnapshot(fetchedAt: now)
        XCTAssertTrue(policy.begin(snapshot: fresh, missingModels: [], now: now, force: true))
        policy.finish(succeeded: false)
        XCTAssertFalse(policy.begin(snapshot: fresh, missingModels: [], now: now.addingTimeInterval(899)))
        XCTAssertTrue(policy.begin(snapshot: fresh, missingModels: [], now: now.addingTimeInterval(900)))
        policy.finish(succeeded: true)
        XCTAssertFalse(policy.begin(snapshot: fresh, missingModels: [], now: now.addingTimeInterval(1_800)))
        XCTAssertTrue(policy.begin(snapshot: fresh, missingModels: [], now: now.addingTimeInterval(86_400)))
        var partial = PriceSnapshot(fetchedAt: now.addingTimeInterval(86_400))
        partial.failedSources = ["Anthropic"]
        XCTAssertTrue(policy.begin(snapshot: partial, missingModels: [], now: now.addingTimeInterval(87_300)))
    }

    func testDiscoveryIgnoresMissingModelNamesAndAlreadyPricedModels() {
        let catalog = PriceCatalog()
        var history = HistorySnapshot()
        history.records[.claude] = ["claude-sonnet-5-5", "anthropic/claude-sonnet-5.5-20260928", ModelPricing.unknown, "claude-opus-5"].enumerated().map {
            UsageRecord(id: "\($0.offset)", session: "test", date: now, usage: TokenUsage(input: 100), model: $0.element)
        }
        XCTAssertEqual(history.unpricedModels(catalog: catalog, now: now), ["claude:claude-sonnet-5-5"])
        catalog.install(PriceSnapshot(rates: [.claude: ["claude-sonnet-5-5": .init(name: "Claude Sonnet 5.5", input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, cacheWriteHour: 4)]]))
        XCTAssertTrue(history.unpricedModels(catalog: catalog, now: now).isEmpty)
        XCTAssertNil(ModelPricing.rates(for: "reseller/claude-sonnet-5-5", provider: .claude, catalog: catalog))
    }

    func testFreshSourcePricesNewModelWithoutPresetAndAnthropicWins() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let fetched = try await PriceSources.fetch(session: session, now: now)
        XCTAssertEqual(fetched.failedSources, [])
        let catalog = PriceCatalog()
        catalog.install(fetched)
        let rates = try XCTUnwrap(ModelPricing.rates(for: "anthropic/claude-sonnet-5.5-20260928", provider: .claude, catalog: catalog))
        XCTAssertEqual(rates, APIRates(name: "Claude Sonnet 5.5", input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, cacheWriteHour: 4))
        XCTAssertEqual(rates.cost(TokenUsage(input: 1_000_000, output: 1_000_000, cached: 1_000_000, cacheWrite: 2_000_000, cacheWriteHour: 1_000_000)).total, 18.7, accuracy: 1e-9)
    }

    func testPartialFetchKeepsCachedModelsAndFlagsSourceForRetry() async throws {
        let session = makeSession(failAnthropic: true)
        defer { session.invalidateAndCancel() }
        let fetched = try await PriceSources.fetch(session: session, now: now)
        XCTAssertEqual(fetched.failedSources, ["Anthropic"])
        let old = APIRates(name: "Old published model", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
        let cached = PriceSnapshot(fetchedAt: now.addingTimeInterval(-100), sources: ["Anthropic"], rates: [.claude: ["claude-older-model": old]])
        XCTAssertEqual(cached.merging(fetched).rates[.claude]?["claude-older-model"], old)
        XCTAssertEqual(cached.merging(fetched).failedSources, ["Anthropic"])
    }

    private func makeSession(failAnthropic: Bool = false) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PricingFixtureProtocol.self]
        if failAnthropic { configuration.httpAdditionalHeaders = ["X-Test-Fail-Anthropic": "1"] }
        return URLSession(configuration: configuration)
    }
}

private final class PricingFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
        let anthropic = request.url == PriceSources.anthropic
        let failed = anthropic && request.value(forHTTPHeaderField: "X-Test-Fail-Anthropic") == "1"
        let body = anthropic ? """
        | Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |
        | --- | --- | --- | --- | --- | --- |
        | **[Claude Sonnet 5.5](https://example.com/sonnet)** | $2 / MTok | $2.50 / MTok | $4 / MTok | $0.20 / MTok | $10 / MTok |
        """ : """
        {"claude-sonnet-5-5":{"litellm_provider":"anthropic","input_cost_per_token":0.000003,"output_cost_per_token":0.000015}}
        """
        let response = HTTPURLResponse(url: request.url!, statusCode: failed ? 503 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
