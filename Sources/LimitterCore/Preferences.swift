import Foundation

public enum AppTheme: String, CaseIterable, Codable, Sendable { case dark = "Dark", light = "Light", system = "System" }
public enum MenuProviders: String, CaseIterable, Codable, Sendable {
    case all = "All providers", both = "Both providers", codex = "Codex", claude = "Claude", grok = "Grok", codexGrok = "Codex + Grok", claudeGrok = "Claude + Grok"
    public var providers: [Provider] {
        switch self {
        case .all: return Provider.allCases
        case .both: return [.codex, .claude]
        case .codex: return [.codex]
        case .claude: return [.claude]
        case .grok: return [.grok]
        case .codexGrok: return [.codex, .grok]
        case .claudeGrok: return [.claude, .grok]
        }
    }
    public var title: String { self == .both ? "Codex + Claude" : rawValue }
}
public enum MenuMetric: String, CaseIterable, Codable, Sendable {
    case remaining = "Limit remaining", used = "Limit used", tokens = "Tokens"
}
public enum QuotaPeriod: String, CaseIterable, Codable, Sendable {
    case session = "Session", weekly = "Weekly"
    public func matches(_ window: LimitWindow) -> Bool {
        guard let minutes = window.durationMinutes else { return false }
        return self == .weekly ? minutes >= 10080 : minutes < 1440
    }
}
public enum TokenPeriod: String, CaseIterable, Codable, Sendable {
    case today = "Today", week = "Last 7 days", month = "Last 30 days"
    public var days: Int { self == .today ? 1 : self == .week ? 7 : 30 }
    public var shortLabel: String { self == .today ? "1d" : self == .week ? "7d" : "30d" }
}
public enum ChartPeriod: String, CaseIterable, Codable, Sendable {
    case week = "7 days", fortnight = "14 days", month = "30 days"
    public var days: Int { self == .week ? 7 : self == .fortnight ? 14 : 30 }
}
public enum VisibleWindows: String, CaseIterable, Codable, Sendable {
    case all = "All windows", session = "Session only", weekly = "Weekly only"
    public func matches(_ window: LimitWindow) -> Bool {
        self == .all || (self == .session ? QuotaPeriod.session : QuotaPeriod.weekly).matches(window)
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var theme = AppTheme.dark
    public var showSettingsOnLaunch = true
    public var hoverToOpen = true
    public var showMenuUsage = true
    public var showMenuIcon = true
    public var showProviderLabels = true
    public var menuProviders = MenuProviders.all
    public var menuMetric = MenuMetric.remaining
    public var menuQuotaPeriod = QuotaPeriod.weekly
    public var menuTokenPeriod = TokenPeriod.today
    public var showCodex = true
    public var showClaude = true
    public var showGrok = true
    public var showLimits = true
    public var showTokenSummary = true
    public var showChart = true
    public var showBreakdown = true
    public var showResetTimes = true
    public var showAdditionalLimits = true
    public var visibleWindows = VisibleWindows.all
    public var tokenPeriod = TokenPeriod.today
    public var apiTokenPeriod = TokenPeriod.today
    public var chartPeriod = ChartPeriod.week
    public var pricingMode = PricingMode.recordedModels
    public var showCosts = true
    public var showHeatmap = true
    public var showCurrentSession = true
    public var playfulCadence = true
    public var codexRates = APIRates.astra
    public var claudeRates = APIRates.fable
    public var grokRates = APIRates.grok46
    public var codexQuotaPeriod: QuotaPeriod?
    public var claudeQuotaPeriod: QuotaPeriod?
    public var codexTokenPeriod: TokenPeriod?
    public var claudeTokenPeriod: TokenPeriod?
    public var grokTokenPeriod: TokenPeriod?
    public init() {}
    public func quotaPeriod(for provider: Provider) -> QuotaPeriod {
        switch provider { case .codex: return codexQuotaPeriod ?? menuQuotaPeriod; case .claude: return claudeQuotaPeriod ?? menuQuotaPeriod; case .grok: return .weekly }
    }
    public func tokenPeriod(for provider: Provider) -> TokenPeriod {
        switch provider { case .codex: return codexTokenPeriod ?? menuTokenPeriod; case .claude: return claudeTokenPeriod ?? menuTokenPeriod; case .grok: return grokTokenPeriod ?? menuTokenPeriod }
    }
    public mutating func setQuotaPeriod(_ period: QuotaPeriod, for provider: Provider) {
        switch provider { case .codex: codexQuotaPeriod = period; case .claude: claudeQuotaPeriod = period; case .grok: break }
    }
    public mutating func setTokenPeriod(_ period: TokenPeriod, for provider: Provider) {
        switch provider { case .codex: codexTokenPeriod = period; case .claude: claudeTokenPeriod = period; case .grok: grokTokenPeriod = period }
    }
    public func rates(for provider: Provider) -> APIRates {
        switch provider { case .codex: return codexRates; case .claude: return claudeRates; case .grok: return grokRates }
    }
    private enum CodingKeys: String, CodingKey { case pricingMode, showGrok, grokRates, grokTokenPeriod, theme, showSettingsOnLaunch, hoverToOpen, showMenuUsage, showMenuIcon, showProviderLabels, menuProviders, menuMetric, menuQuotaPeriod, menuTokenPeriod, showCodex, showClaude, showLimits, showTokenSummary, showChart, showBreakdown, showResetTimes, showAdditionalLimits, visibleWindows, tokenPeriod, apiTokenPeriod, chartPeriod, showCosts, showHeatmap, showCurrentSession, playfulCadence, codexRates, claudeRates, codexQuotaPeriod, claudeQuotaPeriod, codexTokenPeriod, claudeTokenPeriod }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pricingMode = try values.decodeIfPresent(PricingMode.self, forKey: .pricingMode) ?? .recordedModels
        theme = try values.decodeIfPresent(type(of: theme), forKey: .theme) ?? theme
        showSettingsOnLaunch = try values.decodeIfPresent(type(of: showSettingsOnLaunch), forKey: .showSettingsOnLaunch) ?? showSettingsOnLaunch
        hoverToOpen = try values.decodeIfPresent(type(of: hoverToOpen), forKey: .hoverToOpen) ?? hoverToOpen
        showMenuUsage = try values.decodeIfPresent(type(of: showMenuUsage), forKey: .showMenuUsage) ?? showMenuUsage
        showMenuIcon = try values.decodeIfPresent(type(of: showMenuIcon), forKey: .showMenuIcon) ?? showMenuIcon
        showProviderLabels = try values.decodeIfPresent(type(of: showProviderLabels), forKey: .showProviderLabels) ?? showProviderLabels
        menuProviders = try values.decodeIfPresent(type(of: menuProviders), forKey: .menuProviders) ?? menuProviders
        menuMetric = try values.decodeIfPresent(type(of: menuMetric), forKey: .menuMetric) ?? menuMetric
        menuQuotaPeriod = try values.decodeIfPresent(type(of: menuQuotaPeriod), forKey: .menuQuotaPeriod) ?? menuQuotaPeriod
        menuTokenPeriod = try values.decodeIfPresent(type(of: menuTokenPeriod), forKey: .menuTokenPeriod) ?? menuTokenPeriod
        showCodex = try values.decodeIfPresent(type(of: showCodex), forKey: .showCodex) ?? showCodex
        showClaude = try values.decodeIfPresent(type(of: showClaude), forKey: .showClaude) ?? showClaude
        showLimits = try values.decodeIfPresent(type(of: showLimits), forKey: .showLimits) ?? showLimits
        showTokenSummary = try values.decodeIfPresent(type(of: showTokenSummary), forKey: .showTokenSummary) ?? showTokenSummary
        showChart = try values.decodeIfPresent(type(of: showChart), forKey: .showChart) ?? showChart
        showBreakdown = try values.decodeIfPresent(type(of: showBreakdown), forKey: .showBreakdown) ?? showBreakdown
        showResetTimes = try values.decodeIfPresent(type(of: showResetTimes), forKey: .showResetTimes) ?? showResetTimes
        showAdditionalLimits = try values.decodeIfPresent(type(of: showAdditionalLimits), forKey: .showAdditionalLimits) ?? showAdditionalLimits
        visibleWindows = try values.decodeIfPresent(type(of: visibleWindows), forKey: .visibleWindows) ?? visibleWindows
        tokenPeriod = try values.decodeIfPresent(type(of: tokenPeriod), forKey: .tokenPeriod) ?? tokenPeriod
        apiTokenPeriod = try values.decodeIfPresent(TokenPeriod.self, forKey: .apiTokenPeriod) ?? tokenPeriod
        chartPeriod = try values.decodeIfPresent(type(of: chartPeriod), forKey: .chartPeriod) ?? chartPeriod
        showCosts = try values.decodeIfPresent(type(of: showCosts), forKey: .showCosts) ?? showCosts
        showHeatmap = try values.decodeIfPresent(type(of: showHeatmap), forKey: .showHeatmap) ?? showHeatmap
        showCurrentSession = try values.decodeIfPresent(type(of: showCurrentSession), forKey: .showCurrentSession) ?? showCurrentSession
        playfulCadence = try values.decodeIfPresent(type(of: playfulCadence), forKey: .playfulCadence) ?? playfulCadence
        codexRates = try values.decodeIfPresent(type(of: codexRates), forKey: .codexRates) ?? codexRates
        claudeRates = try values.decodeIfPresent(type(of: claudeRates), forKey: .claudeRates) ?? claudeRates
        codexQuotaPeriod = try values.decodeIfPresent(QuotaPeriod.self, forKey: .codexQuotaPeriod)
        claudeQuotaPeriod = try values.decodeIfPresent(QuotaPeriod.self, forKey: .claudeQuotaPeriod)
        codexTokenPeriod = try values.decodeIfPresent(TokenPeriod.self, forKey: .codexTokenPeriod)
        claudeTokenPeriod = try values.decodeIfPresent(TokenPeriod.self, forKey: .claudeTokenPeriod)
        grokTokenPeriod = try values.decodeIfPresent(TokenPeriod.self, forKey: .grokTokenPeriod)
        grokRates = try values.decodeIfPresent(APIRates.self, forKey: .grokRates) ?? grokRates
        showGrok = try values.decodeIfPresent(Bool.self, forKey: .showGrok) ?? showGrok
    }
    public var visibleProviders: [Provider] {
        Provider.allCases.filter { switch $0 { case .codex: return showCodex; case .claude: return showClaude; case .grok: return showGrok } }
    }
}

public struct MenuReading: Sendable {
    public let provider: Provider
    public let value: String
    public let usedPercent: Double?
    public let detail: String
    public init(provider: Provider, value: String, usedPercent: Double?, detail: String) {
        self.provider = provider; self.value = value; self.usedPercent = usedPercent; self.detail = detail
    }
}

public enum MenuBarFormatter {
    public static func readings(preferences: AppPreferences, limits: [Provider: ProviderLimits], history: HistorySnapshot, now: Date = Date()) -> [MenuReading] {
        preferences.menuProviders.providers.map { provider in
            if preferences.menuMetric == .tokens {
                let value = history.available.contains(provider) ? Format.compact(history.total(dayCount: preferences.tokenPeriod(for: provider).days, providers: [provider], now: now).total) : "—"
                return MenuReading(provider: provider, value: value, usedPercent: nil,
                    detail: "\(provider.title) · \(preferences.tokenPeriod(for: provider).rawValue) · \(value) local tokens")
            }
            let presentation = QuotaPresentation(provider: provider, snapshot: limits[provider], period: preferences.quotaPeriod(for: provider), now: now)
            let showExpiredSession = provider == .claude && preferences.quotaPeriod(for: provider) == .session && presentation.window != nil
            guard presentation.hasValue || showExpiredSession, let window = presentation.window else {
                return MenuReading(provider: provider, value: "—", usedPercent: nil, detail: provider.title + " · " + preferences.quotaPeriod(for: provider).rawValue + " · " + presentation.message)
            }
            let percentage = preferences.menuMetric == .remaining ? window.remaining : window.usedPercent
            let value = (presentation.state == .cached ? "~" : "") + "\(Format.percent(percentage))%"
            return MenuReading(provider: provider, value: value, usedPercent: window.usedPercent,
                detail: "\(provider.title) · \(window.title) · \(value) \(preferences.menuMetric == .remaining ? "remaining" : "used") · \(presentation.message) · \(Format.reset(window.resetsAt, now: now))")
        }
    }
    public static func label(preferences: AppPreferences, readings: [MenuReading]) -> String {
        guard preferences.showMenuUsage else { return "" }
        return readings.map { reading in
            let period = preferences.menuMetric == .tokens ? preferences.tokenPeriod(for: reading.provider).shortLabel : preferences.quotaPeriod(for: reading.provider) == .weekly ? "W" : "S"
            let name = preferences.showProviderLabels ? (reading.provider.abbreviation + " ") : ""
            return "\(name)\(period) \(reading.value)"
        }.joined(separator: "  ·  ")
    }
}
