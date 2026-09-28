import SwiftUI
import LimitterCore

@MainActor
final class UsageStore: ObservableObject {
    @Published var history = HistorySnapshot()
    @Published private(set) var heatmaps: [Int: HeatmapData] = [:]
    @Published var limits: [Provider: ProviderLimits] = [:]
    @Published var refreshing = false
    @Published var lastRefresh: Date?
    @Published var selectedProvider: Provider?
    @Published var page: Page = .overview
    @Published var pinned = false
    @Published var demo = false
    @Published var connectorInstalled = ClaudeConnector.isInstalled
    @Published var connectionMessage: String?
    @Published private(set) var prices = PriceCatalog.shared.current
    @Published private(set) var priceError: String?
    @Published private(set) var updatingPrices = false
    @Published var preferences: AppPreferences {
        didSet {
            if !isRendering, let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "preferences.v2") }
        }
    }
    @Published var settingsSection = SettingsSection.appearance
    var onOpenSettings: (() -> Void)?
    private let isRendering: Bool
    private let reader = HistoryReader()
    private var timer: Timer?
    private var claudeTimer: Timer?
    private var claudeSignature = ""
    private var claudeAccount: ProviderLimits?
    private var lastAccountRefresh = Date.distantPast
    private var nextPriceAttempt = Date.distantPast
    enum Page: String, CaseIterable { case overview = "Overview", activity = "Activity", costs = "API Value" }
    enum SettingsSection: String, CaseIterable, Identifiable {
        case appearance = "Appearance", menuBar = "Menu Bar", display = "Display", timeframes = "Timeframes", general = "General", pricing = "API Pricing", connections = "Connections"
        var id: String { rawValue }
        var symbol: String {
            switch self { case .appearance: return "paintpalette"; case .menuBar: return "menubar.rectangle"; case .display: return "rectangle.grid.1x2"; case .timeframes: return "clock"; case .general: return "slider.horizontal.3"; case .pricing: return "dollarsign.circle"; case .connections: return "point.3.connected.trianglepath.dotted" }
        }
        var subtitle: String {
            switch self {
            case .appearance: return "Set the mood for your workspace."
            case .menuBar: return "Your most useful numbers, always in sight."
            case .display: return "Choose what appears when you hover."
            case .timeframes: return "See your usage over the periods that matter."
            case .general: return "A little utility that fits your routine."
            case .connections: return "Bring your AI subscriptions together."
            case .pricing: return "What would your activity cost at API rates?"
            }
        }
    }
    init() {
        isRendering = CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--verify-ui")
        if !isRendering, let data = UserDefaults.standard.data(forKey: "preferences.v2"), let saved = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            preferences = saved
            // Introduce Grok in the existing combined readout without changing solo choices.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["showGrok"] == nil,
               saved.menuProviders == .both, GrokConnection.executable() != nil { preferences.menuProviders = .all }
        } else {
            var defaults = AppPreferences()
            if !isRendering {
                defaults.hoverToOpen = UserDefaults.standard.object(forKey: "hoverToOpen") as? Bool ?? true
                defaults.showMenuUsage = UserDefaults.standard.object(forKey: "showMenuUsage") as? Bool ?? true
            }
            if CommandLine.arguments.contains("--preview-light") { defaults.theme = .light }
            if CommandLine.arguments.contains("--preview-month") { defaults.tokenPeriod = .month; defaults.apiTokenPeriod = .month; defaults.chartPeriod = .month }
            preferences = defaults
        }
    }

    func start() {
        demo = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--verify-ui")
        if demo { loadDemo() } else {
            if let executable = Bundle.main.executableURL {
                do { try ClaudeConnector.upgradeIfNeeded(executable: executable) }
                catch { connectionMessage = "Couldn’t update the Claude connector: " + error.localizedDescription }
            }
            if let cached = PriceSources.loadCache() { installPrices(cached) }
            updatePrices()
            refreshClaude(force: true)
            refresh()
        }
        claudeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClaude() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.updatePrices() }
        }
    }
    func refresh(force: Bool = false) {
        refreshClaude(force: force)
        guard !refreshing, !demo else { return }
        refreshing = true
        let fetchAccount = force || Date().timeIntervalSince(lastAccountRefresh) >= 120
        Task {
            async let newHistory = reader.read(dayCount: 84)
            if fetchAccount {
                async let claudeResult = Task.detached(priority: .utility) { () -> Result<ProviderLimits, Error> in
                    Result { try ClaudeUsageConnection().fetch() }
                }.value
                async let grokResult = Task.detached(priority: .utility) { () -> Result<ProviderLimits, Error> in
                    Result { try GrokConnection().fetch() }
                }.value
                let result = await Task.detached(priority: .utility) { () -> Result<ProviderLimits, Error> in
                    Result { try CodexConnection().fetch() }
                }.value
                switch result {
                case .success(let value): limits[.codex] = value
                case .failure(let error):
                    var value = limits[.codex] ?? ProviderLimits(provider: .codex, source: "Codex account")
                    value.error = error.localizedDescription; limits[.codex] = value
                }
                switch await grokResult {
                case .success(let value): limits[.grok] = value
                case .failure(let error):
                    var value = limits[.grok] ?? ProviderLimits(provider: .grok, source: "Grok account")
                    value.error = error.localizedDescription; limits[.grok] = value
                }
                switch await claudeResult {
                case .success(let value): claudeAccount = ClaudeQuotaSources.retainingModelReadings(from: claudeAccount, in: value)
                case .failure(let error):
                    var value = claudeAccount ?? ProviderLimits(provider: .claude, source: "Claude account")
                    value.error = error.localizedDescription; claudeAccount = value
                }
                refreshClaude(force: true)
                lastAccountRefresh = Date()
            }
            let loaded = await newHistory
            heatmaps = await Task.detached(priority: .utility) { Self.makeHeatmaps(loaded) }.value
            history = loaded
            refreshClaude(force: true)
            lastRefresh = Date(); refreshing = false
        }
    }
    /// Pulls current model rates at most once a day unless forced; cached rates stay in use on failure.
    func updatePrices(force: Bool = false) {
        guard !demo, !updatingPrices, force || (prices.isStale() && Date() >= nextPriceAttempt) else { return }
        updatingPrices = true
        nextPriceAttempt = Date().addingTimeInterval(3_600)
        Task {
            do {
                let fetched = try await PriceSources.fetch()
                installPrices(fetched)
                try? PriceSources.saveCache(fetched)
                priceError = nil
            } catch {
                priceError = "Couldn’t update prices: " + error.localizedDescription
            }
            updatingPrices = false
        }
    }
    private func installPrices(_ snapshot: PriceSnapshot) {
        PriceCatalog.shared.install(snapshot)
        prices = snapshot
    }
    private func refreshClaude(force: Bool = false) {
        guard !demo else { return }
        let signature = ClaudeConnector.updateSignature
        guard force || signature != claudeSignature else { return }
        claudeSignature = signature
        limits[.claude] = ClaudeQuotaSources.combine(account: claudeAccount, statusLine: ClaudeConnector.read())
        connectorInstalled = ClaudeConnector.isInstalled
    }
    private nonisolated static func makeHeatmaps(_ history: HistorySnapshot) -> [Int: HeatmapData] {
        let allMask = Provider.allCases.reduce(0) { $0 | $1.mask }
        return Dictionary(uniqueKeysWithValues: (1...allMask).map { mask in
            (mask, history.heatmap(providers: Provider.allCases.filter { mask & $0.mask != 0 }))
        })
    }
    var heatmap: HeatmapData { heatmaps[providers.reduce(0) { $0 | $1.mask }] ?? HeatmapData() }
    func setDemo(_ enabled: Bool) {
        guard !refreshing else { return }
        demo = enabled
        if enabled { loadDemo() }
        else { history = HistorySnapshot(); heatmaps = [:]; limits = [:]; claudeSignature = ""; claudeAccount = nil; lastAccountRefresh = .distantPast; refresh(force: true) }
    }
    func connectClaude() {
        do {
            guard let executable = Bundle.main.executableURL else { return }
            try ClaudeConnector.install(executable: executable)
            connectorInstalled = true
            connectionMessage = "Connector ready. Claude Code reloads its settings automatically; quotas arrive when Claude reports them."
            refreshClaude(force: true)
        } catch { connectionMessage = error.localizedDescription }
    }
    func disconnectClaude() {
        do { try ClaudeConnector.uninstall(); connectorInstalled = false; connectionMessage = "Your previous Claude status line has been restored."; refreshClaude(force: true) }
        catch { connectionMessage = error.localizedDescription }
    }
    var activeProvider: Provider? { selectedProvider.flatMap { preferences.visibleProviders.contains($0) ? $0 : nil } }
    var providers: [Provider] { activeProvider.map { [$0] } ?? preferences.visibleProviders }
    var overviewUsage: TokenUsage { history.total(dayCount: 1, providers: providers) }
    var overviewCounts: (sessions: Int, requests: Int) { history.activityCounts(dayCount: 1, providers: providers) }
    var overviewCost: Double { providers.reduce(0) { $0 + cost(for: $1, days: 1).total } }
    var overviewHours: [UsageDay] { history.todayHours(providers: providers) }
    var overviewSeries: [UsageDay] { history.chartBuckets(interval: preferences.overviewInterval, dayCount: 1, providers: providers) }
    var activitySeries: [UsageDay] { history.chartBuckets(interval: preferences.activityInterval, dayCount: preferences.chartPeriod.days, providers: providers) }
    var activityUsage: TokenUsage { history.total(dayCount: preferences.tokenPeriod.days, providers: providers) }
    var activityCounts: (sessions: Int, requests: Int) { history.activityCounts(dayCount: preferences.tokenPeriod.days, providers: providers) }
    var activityDays: [UsageDay] {
        Array(history.days.suffix(preferences.chartPeriod.days)).map { original in
            var day = original
            for provider in Provider.allCases where !providers.contains(provider) { day.setUsage(TokenUsage(), for: provider) }
            return day
        }
    }
    var activity: ActivitySummary { history.activity(providers: providers) }
    var currentSession: SessionSummary? { history.currentSession(providers: providers) }
    var recentSessions: [SessionSummary] { Array(history.recentSessions.filter { providers.contains($0.provider) }.prefix(8)) }
    func estimate(for provider: Provider, days: Int? = nil) -> PriceEstimate {
        PriceEstimate(usage: history.modelUsage(dayCount: days ?? preferences.apiTokenPeriod.days, provider: provider), provider: provider, preferences: preferences)
    }
    func estimate(days: Int? = nil) -> PriceEstimate { providers.reduce(PriceEstimate()) { $0 + estimate(for: $1, days: days) } }
    func cost(for provider: Provider, days: Int? = nil) -> CostBreakdown { estimate(for: provider, days: days).cost }
    var overviewEstimate: PriceEstimate { estimate(days: 1) }
    var apiEstimate: PriceEstimate { estimate() }
    func sessionEstimate(_ session: SessionSummary) -> PriceEstimate { PriceEstimate(usage: session.modelUsage, provider: session.provider, preferences: preferences) }
    var apiCost: Double { providers.reduce(0) { $0 + cost(for: $1).total } }
    var historyAvailable: Bool { providers.contains { history.available.contains($0) } }
    var costsAvailable: Bool { historyAvailable && apiEstimate.canDisplay }
    func quotaBinding(for provider: Provider) -> Binding<QuotaPeriod> {
        Binding(get: { self.preferences.quotaPeriod(for: provider) }, set: { self.preferences.setQuotaPeriod($0, for: provider) })
    }
    func tokenBinding(for provider: Provider) -> Binding<TokenPeriod> {
        Binding(get: { self.preferences.tokenPeriod(for: provider) }, set: { self.preferences.setTokenPeriod($0, for: provider) })
    }
    var menuReadings: [MenuReading] { MenuBarFormatter.readings(preferences: preferences, limits: limits, history: history) }
    var menuLabel: String {
        let label = MenuBarFormatter.label(preferences: preferences, readings: menuReadings)
        return demo ? "DEMO " + label : label
    }
    var menuTooltip: String { (demo ? "Preview data\n" : "") + menuReadings.map(\.detail).joined(separator: "\n") }
    func openSettings() { onOpenSettings?() }
    private func loadDemo() {
        let now = Date(), calendar = Calendar.current
        var sample = HistorySnapshot()
        let codex = [245000, 410000, 295000, 530000, 380000, 715000, 482600]
        let claude = [180000, 230000, 320000, 210000, 460000, 345000, 301800]
        sample.days = (0..<84).map { index in
            var day = UsageDay(date: calendar.date(byAdding: .day, value: index - 83, to: calendar.startOfDay(for: now))!)
            func tokens(_ count: Int) -> TokenUsage { TokenUsage(input: count / 5, output: count / 10, cached: count - count / 5 - count / 10) }
            let valueIndex = (index + 5) % 7
            let quiet = index < 80 && (index % 13 == 0 || index % 13 == 1)
            let scale = 0.35 + Double((index * 7) % 11) / 10
            day.codex = tokens(quiet ? 0 : Int(Double(codex[valueIndex]) * scale))
            day.claude = tokens(quiet ? 0 : Int(Double(claude[valueIndex]) * scale))
            day.grok = tokens(quiet ? 0 : Int(Double(claude[(valueIndex + 2) % 7]) * scale * 0.65)); return day
        }
        sample.today = [.codex: TokenUsage(input: 98200, output: 42400, cached: 342000), .claude: TokenUsage(input: 55200, output: 26600, cached: 208000, cacheWrite: 12000), .grok: TokenUsage(input: 24600, output: 15200, cached: 126000)]
        sample.days[83].codex = sample.today[.codex]!
        sample.days[83].claude = sample.today[.claude]!
        sample.days[83].grok = sample.today[.grok]!
        sample.sessions = [.codex: 8, .claude: 5, .grok: 3]; sample.requests = [.codex: 142, .claude: 86, .grok: 38]; sample.available = Set(Provider.allCases)
        for provider in Provider.allCases {
            for (dayIndex, day) in sample.days.enumerated() {
                let total = day.tokens(for: provider)
                let count = dayIndex == 83 ? (sample.requests[provider] ?? 0) : total / 4000
                for index in 0..<count {
                    let id = "\(provider.rawValue)-\(dayIndex)-\(index)"
                    let session = "\(dayIndex)-\(index % (sample.sessions[provider] ?? 1))"
                    let totalUsage = day.usage(for: provider)
                    func share(_ value: Int) -> Int { value / count + (index < value % count ? 1 : 0) }
                    let usage = TokenUsage(input: share(totalUsage.input), output: share(totalUsage.output), cached: share(totalUsage.cached), cacheWrite: share(totalUsage.cacheWrite))
                    let model = provider == .codex ? "gpt-6-astra" : provider == .grok ? "grok-4.6" : ["claude-opus-5", "claude-opus-4-8", "claude-fable-5", "claude-fable-5-1"][index % 4]
                    sample.records[provider, default: []].append(UsageRecord(id: id, session: session, date: day.date.addingTimeInterval(Double(index) / Double(max(1, count)) * (dayIndex == 83 ? max(0, now.timeIntervalSince(day.date) - 10) : 80000)), usage: usage, model: model))
                }
            }
        }
        sample.recentSessions = [
            SessionSummary(provider: .codex, session: "demo-current", project: "limitter", model: "gpt-6-astra", startedAt: now.addingTimeInterval(-2700), lastActivity: now.addingTimeInterval(-12), observedState: .running, usage: .init(input: 32400, output: 18200, cached: 104000), responses: 42),
            SessionSummary(provider: .claude, session: "demo-claude", project: "design-system", model: "claude-fable-5-1", startedAt: now.addingTimeInterval(-7200), lastActivity: now.addingTimeInterval(-2400), observedState: .idle, usage: .init(input: 19400, output: 11200, cached: 97000), responses: 28),
            SessionSummary(provider: .grok, session: "demo-grok", project: "launchpad", model: "grok-4.6", startedAt: now.addingTimeInterval(-3600), lastActivity: now.addingTimeInterval(-1800), observedState: .idle, usage: .init(input: 24600, output: 15200, cached: 126000), responses: 38)
        ]
        sample.buildIndex(now: now, calendar: calendar)
        heatmaps = Self.makeHeatmaps(sample)
        history = sample
        var c = ProviderLimits(provider: .codex, source: "Preview data"); c.plan = "Pro"; c.updatedAt = now; c.resetCredits = 2
        c.buckets = [LimitBucket(id: "codex", name: "All models", windows: [LimitWindow(id: "session", usedPercent: 32, durationMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3600 + 24 * 60)), LimitWindow(id: "weekly", usedPercent: 58, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400 + 14 * 3600))])]
        var a = ProviderLimits(provider: .claude, source: "Preview data"); a.plan = "Max"; a.updatedAt = now
        c.buckets.append(.init(id: "model:spark", name: "GPT-5.3-Codex-Spark", windows: [.init(id: "session", usedPercent: 12, durationMinutes: 300, resetsAt: now.addingTimeInterval(7200)), .init(id: "weekly", usedPercent: 24, durationMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400))]))
        a.buckets = [LimitBucket(id: "claude", name: "All models", windows: [LimitWindow(id: "session", usedPercent: 74, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600 + 42 * 60)), LimitWindow(id: "weekly", usedPercent: 41, durationMinutes: 10080, resetsAt: now.addingTimeInterval(5 * 86400 + 8 * 3600))])]
        a.buckets.append(.init(id: "model:fable", name: "Fable", windows: [.init(id: "weekly", usedPercent: 100, durationMinutes: 10080, resetsAt: now.addingTimeInterval(5 * 86400 + 8 * 3600), observedAt: now)]))
        var g = ProviderLimits(provider: .grok, source: "Preview data"); g.plan = "SuperGrok"; g.updatedAt = now
        g.buckets = [.init(id: "grok", name: "Shared subscription pool", windows: [.init(id: "weekly", usedPercent: 27, durationMinutes: 10080, resetsAt: now.addingTimeInterval(2 * 86400 + 6 * 3600))])]
        limits = [.codex: c, .claude: a, .grok: g]; lastRefresh = now
    }
}
