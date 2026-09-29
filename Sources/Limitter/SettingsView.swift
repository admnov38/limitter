import SwiftUI
import ServiceManagement
import LimitterCore

struct SettingsWindowView: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    BrandMark().frame(width: 29, height: 30)
                    Text("limitter").font(.system(size: 22, weight: .semibold, design: .rounded)).tracking(-0.6)
                }.padding(.horizontal, 23).padding(.top, 46).padding(.bottom, 32)
                Text("PREFERENCES").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted).padding(.horizontal, 24).padding(.bottom, 13)
                ForEach(UsageStore.SettingsSection.allCases) { section in
                    Button { store.settingsSection = section } label: {
                        HStack(spacing: 11) {
                            Image(systemName: section.symbol).font(.system(size: 14)).frame(width: 18)
                            Text(section.rawValue).font(.system(size: 12, weight: .medium))
                            Spacer()
                        }.foregroundStyle(store.settingsSection == section ? Theme.mint : Theme.muted)
                            .padding(.horizontal, 12).padding(.vertical, 12)
                            .background(store.settingsSection == section ? Theme.mint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.padding(.horizontal, 13).padding(.bottom, 3)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) { Circle().fill(store.refreshing ? Theme.orange : Theme.mint).frame(width: 5, height: 5); Text(store.refreshing ? "Syncing your usage" : "Running in your menu bar") }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                    HStack { Text("LIMITTER / \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")").font(.system(size: 9, design: .monospaced)).tracking(0.8); Spacer(); Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Limitter") }.foregroundStyle(Theme.muted.opacity(0.75))
                }.padding(23)
            }.frame(width: 204).background(Theme.surface.opacity(0.55))
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(store.settingsSection.rawValue).font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(-0.8)
                        Text(store.settingsSection.subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text("SAVED AUTOMATICALLY").font(.system(size: 8, weight: .medium)).tracking(1).foregroundStyle(Theme.muted).padding(.top, 12)
                }.padding(.horizontal, 32).padding(.top, 43).padding(.bottom, 27)
                ScrollView {
                    SettingsContent(store: store).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 32).padding(.bottom, 28)
                }
            }
        }.frame(minWidth: 850, minHeight: 640)
            .background(Theme.background).foregroundStyle(Theme.text).buttonStyle(.plain)
            .preferredColorScheme(store.preferences.theme.colorScheme)
    }
}

struct SettingsContent: View {
    @ObservedObject var store: UsageStore
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch store.settingsSection {
            case .appearance: appearance
            case .menuBar: menuBar
            case .display: display
            case .timeframes: timeframes
            case .general: general
            case .connections: connections
            case .pricing: pricing
            }
        }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 22) {
            eyebrow("CHOOSE YOUR THEME")
            HStack(spacing: 14) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Button { store.preferences.theme = theme } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            ThemeSwatch(theme: theme).frame(height: 111).clipShape(RoundedRectangle(cornerRadius: 9))
                            HStack { Text(theme.rawValue).font(.system(size: 12, weight: .medium)); Spacer(); Image(systemName: store.preferences.theme == theme ? "checkmark.circle.fill" : "circle").foregroundStyle(store.preferences.theme == theme ? Theme.mint : Theme.muted.opacity(0.4)) }
                        }.padding(11).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(store.preferences.theme == theme ? Theme.mint : Theme.line, lineWidth: store.preferences.theme == theme ? 1.5 : 1))
                    }.frame(maxWidth: .infinity)
                }
            }
            Text("Your choice applies to the settings window and hover panel. System follows your Mac’s appearance.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(3)
            MenuBarPreview(store: store)
            note("The menu bar always follows macOS for contrast. Its rings and numbers reflect your selected live usage.", icon: "menubar.rectangle")
        }
    }
    private var menuBar: some View {
        VStack(spacing: 22) {
            MenuBarPreview(store: store)
            section("LIVE READOUT") {
                option("Providers", subtitle: "Choose any provider or a combination.", selection: $store.preferences.menuProviders)
                Divider().overlay(Theme.line)
                option("Metric", subtitle: "Choose what the numbers represent.", selection: $store.preferences.menuMetric)
                if store.preferences.menuMetric == .tokens {
                    ForEach(store.preferences.menuProviders.providers) { provider in
                        option(provider.title + " token period", subtitle: "Count activity on this Mac.", selection: store.tokenBinding(for: provider))
                    }
                } else {
                    ForEach(store.preferences.menuProviders.providers) { provider in
                        option(provider.title + " limit window", subtitle: "Independent timeframe for " + provider.title + ".", selection: store.quotaBinding(for: provider), choices: provider.quotaPeriods)
                    }
                }
            }
            section("APPEARANCE") {
                settingToggle("Show numbers", subtitle: "Display the selected metric beside the icon.", binding: $store.preferences.showMenuUsage)
                settingToggle("Show usage icon", subtitle: "Quota rings, or the Limitter icon for token totals.", binding: $store.preferences.showMenuIcon)
                settingToggle("Show provider labels", subtitle: "CX for Codex, CL for Claude, GK for Grok.", binding: $store.preferences.showProviderLabels)
            }
            note("If both icon and numbers are disabled, an icon remains so you can always reach Limitter.", icon: "cursorarrow")
        }
    }
    private var display: some View {
        VStack(spacing: 22) {
            section("PROVIDERS IN THE HOVER PANEL") {
                settingToggle("Codex", subtitle: "Account limits and local Codex activity.", binding: $store.preferences.showCodex)
                settingToggle("Claude", subtitle: "Account limits and local Claude activity.", binding: $store.preferences.showClaude)
                settingToggle("Grok", subtitle: "Shared subscription pool and local Grok Build activity.", binding: $store.preferences.showGrok)
            }
            section("VISIBLE STATS") {
                settingToggle("Subscription limits", subtitle: "Usage meters for your account’s quota windows.", binding: $store.preferences.showLimits)
                settingToggle("Token summary", subtitle: "Total, input, output, and cached tokens.", binding: $store.preferences.showTokenSummary)
                settingToggle("Activity chart", subtitle: "Compare provider activity over time.", binding: $store.preferences.showChart)
                settingToggle("Current or last session", subtitle: "Project, model, state, tokens, and responses.", binding: $store.preferences.showCurrentSession)
                settingToggle("API equivalent", subtitle: "Optional token cost estimate and API Value tab.", binding: $store.preferences.showCosts)
                settingToggle("Daily activity grid", subtitle: "Twelve weeks of AI activity and your streaks.", binding: $store.preferences.showHeatmap)
                settingToggle("Playful daily message", subtitle: "Funny, blunt, or encouraging. It follows today’s pace, streak, and quotas.", binding: $store.preferences.playfulCadence)
                settingToggle("Detailed statistics", subtitle: "Sessions, responses, cache share, and lifetime usage.", binding: $store.preferences.showBreakdown)
            }
            section("LIMIT DETAILS") {
                settingToggle("Reset countdowns", subtitle: "See when the current allowance resets.", binding: $store.preferences.showResetTimes)
                settingToggle("Additional model limits", subtitle: "Show separate model buckets when available.", binding: $store.preferences.showAdditionalLimits)
            }
            note("These controls change the hover panel. Menu bar providers and metrics are configured separately.", icon: "rectangle.on.rectangle")
        }
    }
    private var timeframes: some View {
        VStack(spacing: 22) {
            section("HOVER PANEL") {
                HStack { Text("Overview").font(.system(size: 12, weight: .medium)); Spacer(); Text("Always today").font(.system(size: 11)).foregroundStyle(Theme.mint) }
                option("Activity totals", subtitle: "Only changes statistics on the Activity tab.", selection: $store.preferences.tokenPeriod)
                option("API Value totals", subtitle: "Only changes the API cost estimate tab.", selection: $store.preferences.apiTokenPeriod)
                option("Activity chart", subtitle: "Days on the Activity chart. Line, histogram, and bucket size are chosen on the chart.", selection: $store.preferences.chartPeriod)
                option("Other quota windows", subtitle: "Primary cards always show each provider’s chosen window.", selection: $store.preferences.visibleWindows)
            }
            section("MENU BAR") {
                ForEach(Provider.allCases) { provider in
                    option(provider.title + " limit window", subtitle: "Used for this provider’s menu bar percentage.", selection: store.quotaBinding(for: provider), choices: provider.quotaPeriods)
                    option(provider.title + " token period", subtitle: "Used for this provider’s menu bar token count.", selection: store.tokenBinding(for: provider))
                }
            }
            note("The activity grid covers up to 84 days; totals and charts cover up to 30. Overview is always today. Charts switch between a line and a histogram, with buckets such as 15 minutes, hourly, or daily. Today and date boundaries use your Mac’s time zone. Subscription windows are defined by each provider.", icon: "calendar")
            MenuBarPreview(store: store)
        }
    }
    private var priceStatus: String {
        if let error = store.priceError { return error + (store.prices.fetchedAt == nil ? " Using built-in rates." : " Previously known rates remain available.") }
        guard let fetched = store.prices.fetchedAt else { return "Using built-in rates. Live prices download automatically." }
        return "Live rates for \(store.prices.modelCount) models from \(store.prices.sources.joined(separator: " and ")), updated \(fetched.formatted(.relative(presentation: .named))). Checked daily and when an unpriced model appears. Missing prices retry every 15 minutes."
    }
    private var pricing: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("CALCULATION") {
                option("Pricing method", subtitle: "Use each response’s model or choose a benchmark.", selection: $store.preferences.pricingMode)
                Text("Recorded models keeps Opus, Fable, and other models at their own rates, even within a single session. Missing model rates stay unpriced.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
            }
            if store.preferences.pricingMode == .benchmark {
                RateEditor(provider: .codex, rates: $store.preferences.codexRates)
                RateEditor(provider: .claude, rates: $store.preferences.claudeRates)
                RateEditor(provider: .grok, rates: $store.preferences.grokRates)
            } else {
                ForEach(Provider.allCases) { provider in RecordedRateCard(provider: provider, models: store.estimate(for: provider, days: 84).rows) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                note(priceStatus, icon: store.priceError == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                Spacer()
                Button(store.updatingPrices ? "Updating…" : "Update now") { store.updatePrices(force: true) }.disabled(store.updatingPrices || store.demo)
            }
            note("USD per 1 million tokens. Claude rates come from Anthropic’s pricing page; OpenAI and xAI rates from the LiteLLM price list. Built-in rates (checked September 2026) apply offline. Tools, tiers, regional pricing, long-context premiums, and tax are excluded.", icon: "info.circle")
            HStack(spacing: 22) {
                Link("OpenAI pricing ↗", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
                Link("Anthropic pricing ↗", destination: URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!)
                Link("xAI pricing ↗", destination: URL(string: "https://docs.x.ai/developers/pricing")!)
            }.font(.system(size: 11)).foregroundStyle(Theme.mint)
        }
    }
    private var general: some View {
        VStack(spacing: 22) {
            section("STARTUP & BEHAVIOR") {
                settingToggle("Open settings on launch", subtitle: "Show this window when Limitter starts.", binding: $store.preferences.showSettingsOnLaunch)
                settingToggle("Open panel on hover", subtitle: "Move over the menu bar readout to see details.", binding: $store.preferences.hoverToOpen)
                settingToggle("Launch at login", subtitle: "Start Limitter when you sign in to your Mac.", binding: Binding(get: { loginEnabled }, set: setLogin))
                if let loginError { Text(loginError).font(.system(size: 11)).foregroundStyle(Theme.orange) }
            }
            section("PREVIEW") {
                settingToggle("Use sample data", subtitle: "Explore the interface. The menu bar will say DEMO.", binding: Binding(get: { store.demo }, set: { store.setDemo($0) })).disabled(store.refreshing)
            }
            section("REFRESH") {
                HStack { VStack(alignment: .leading, spacing: 5) { Text("Always up to date").font(.system(size: 12, weight: .medium)); Text("Local history: 30s · Claude updates: 2s · All provider accounts: 2m").font(.system(size: 11)).foregroundStyle(Theme.muted) }; Spacer(); Button("Refresh now") { store.refresh(force: true) }.font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mint).disabled(store.refreshing || store.demo) }
            }
            note("Close this window to keep Limitter running in the menu bar. Right-click its icon or press ⌘, to open settings again.", icon: "menubar.rectangle")
        }
    }
    private var connections: some View {
        VStack(spacing: 22) {
            section("YOUR SUBSCRIPTIONS") {
                HStack(spacing: 12) {
                    ProviderMark(provider: .codex).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 5) { Text("Codex").font(.system(size: 13, weight: .medium)); Text(CodexConnection.executable() != nil ? "Uses your existing Codex sign-in" : "Install Codex, then sign in").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                    Spacer()
                    Text(store.limits[.codex]?.updatedAt != nil ? "Connected" : "Waiting").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.mint)
                }
                Divider().overlay(Theme.line)
                HStack(spacing: 12) {
                    ProviderMark(provider: .claude).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 5) { Text("Claude Code").font(.system(size: 13, weight: .medium)); Text(ClaudeUsageConnection.executable() != nil ? "Account usage includes Fable and model limits" : "Install Claude Code and sign in").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                    Spacer()
                    Button(store.connectorInstalled ? "Disconnect" : "Connect") { if store.connectorInstalled { store.disconnectClaude() } else { store.connectClaude() } }.font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.orange)
                }
                Text("Account limits refresh every two minutes through Claude Code, including model-specific weekly allowances. The status-line connector provides a fallback for session and weekly windows when account reads are unavailable.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
                if store.connectorInstalled {
                    HStack {
                        if let date = store.limits[.claude]?.receivedAt { Text("Last quota update: " + date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(Theme.muted) }
                        Spacer()
                        Button("Repair connection") { store.connectClaude() }.font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.orange)
                    }
                }
                Divider().overlay(Theme.line)
                HStack(spacing: 12) {
                    ProviderMark(provider: .grok).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Grok Build").font(.system(size: 13, weight: .medium))
                        Text(GrokConnection.executable() != nil ? "Uses your existing Grok sign-in" : "Install Grok Build, then run grok login in Terminal").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(store.limits[.grok]?.error != nil ? "Needs attention" : store.limits[.grok]?.updatedAt != nil ? "Connected" : "Waiting").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.blue)
                }
                Text("Grok’s weekly pool is shared across its products. Local tokens, sessions, and activity come from Grok Build only; usage is recorded at turn completion. Missing percentages stay unavailable.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
                if let error = store.limits[.grok]?.error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.orange) }
                HStack {
                    Link("Grok Build setup ↗", destination: URL(string: "https://docs.x.ai/build/overview")!).foregroundStyle(Theme.blue)
                    Spacer()
                    Button("Refresh Grok") { store.refresh(force: true) }.foregroundStyle(Theme.blue).disabled(store.refreshing || store.demo)
                }.font(.system(size: 11, weight: .medium))
                if let message = store.connectionMessage { Text(message).font(.system(size: 11)).foregroundStyle(Theme.mint) }
            }
            HStack(spacing: 22) {
                Link("Open Codex usage ↗", destination: URL(string: "https://chatgpt.com/codex/settings/usage")!)
                Link("Open Claude usage ↗", destination: URL(string: "https://claude.ai/settings/usage")!)
                Link("Open Grok ↗", destination: URL(string: "https://grok.com")!)
                Spacer()
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
            note("On your Mac. No analytics. No API keys. Old or unavailable quota snapshots display a dash in the menu bar.", icon: "lock.shield")
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) { eyebrow(title); content() }.frame(maxWidth: .infinity, alignment: .leading).padding(22).card()
    }
    private func option<T: RawRepresentable & CaseIterable & Hashable>(_ title: String, subtitle: String, selection: Binding<T>, choices: [T]? = nil) -> some View where T.RawValue == String {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12, weight: .medium)); Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.muted) }
            Spacer(minLength: 12)
            Menu {
                ForEach(choices ?? Array(T.allCases), id: \.self) { value in
                    Button { selection.wrappedValue = value } label: {
                        if selection.wrappedValue == value { Label((value as? MenuProviders)?.title ?? value.rawValue, systemImage: "checkmark") }
                        else { Text((value as? MenuProviders)?.title ?? value.rawValue) }
                    }
                }
            } label: {
                HStack { Text((selection.wrappedValue as? MenuProviders)?.title ?? selection.wrappedValue.rawValue); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted) }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text).padding(.horizontal, 11).padding(.vertical, 9)
                    .background(Theme.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 170).accessibilityLabel(title)
        }
    }
    private func settingToggle(_ title: String, subtitle: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12, weight: .medium)); Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 12)
            Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.mint)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func note(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 9) { Image(systemName: icon); Text(text).lineSpacing(4).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 0) }.font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.horizontal, 3)
    }
    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginError = SMAppService.mainApp.status == .requiresApproval ? "Allow Limitter in System Settings → General → Login Items." : nil
        } catch { loginError = "Move Limitter to Applications, then try again. \(error.localizedDescription)"; loginEnabled = SMAppService.mainApp.status == .enabled }
    }
}

private struct ThemeSwatch: View {
    let theme: AppTheme
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if theme == .system { HStack(spacing: 0) { swatch(dark: false); swatch(dark: true) } }
                else { swatch(dark: theme == .dark) }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
    private func swatch(dark: Bool) -> some View {
        let bg = dark ? Color(red: 0.09, green: 0.10, blue: 0.12) : Color(red: 0.93, green: 0.95, blue: 0.95)
        let accent = dark ? Color(red: 0.65, green: 0.94, blue: 0.77) : Color(red: 0.17, green: 0.52, blue: 0.36)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 3) { ForEach(0..<3) { _ in Circle().fill(dark ? Color.white.opacity(0.25) : Color.black.opacity(0.15)).frame(width: 4, height: 4) }; Spacer() }.padding(.bottom, 5)
            RoundedRectangle(cornerRadius: 2).fill(dark ? Color.white.opacity(0.8) : Color.black.opacity(0.55)).frame(width: 35, height: 5)
            Capsule().fill(accent).frame(height: 5).padding(.trailing, 24)
            Capsule().fill(accent.opacity(0.3)).frame(height: 5)
            Spacer(minLength: 0)
        }.padding(15).background(bg)
    }
}

private struct RateEditor: View {
    let provider: Provider
    @Binding var rates: APIRates
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                ProviderMark(provider: provider).frame(width: 28, height: 28)
                Text(provider.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    ForEach(APIRates.presets(for: provider), id: \.name) { preset in Button(preset.name) { rates = preset } }
                } label: { HStack(spacing: 6) { Text(rates.name); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.system(size: 11)).foregroundStyle(Theme.accent(provider)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(provider.title + " API rate preset")
            }
            HStack(alignment: .top, spacing: 12) {
                rateField("Input", key: \.input)
                rateField("Output", key: \.output)
                rateField("Cache read", key: \.cacheRead)
            }
            if provider != .grok {
                HStack(alignment: .top, spacing: 12) {
                    rateField(provider == .claude ? "Cache write · 5 min" : "Cache write", key: \.cacheWrite)
                    if provider == .claude { rateField("Cache write · 1 hour", key: \.cacheWriteHour) }
                    Spacer(minLength: 0)
                }
            }
            Text("$ / 1M tokens · Edit any value to use custom rates.").font(.system(size: 10)).foregroundStyle(Theme.muted)
        }.padding(22).card()
    }
    private func rateField(_ title: String, key: WritableKeyPath<APIRates, Double>) -> some View {
        RateField(title: title, value: Binding(get: { rates[keyPath: key] }, set: { rates[keyPath: key] = $0; rates.name = "Custom " + provider.title
            if provider == .grok && key == \.input { rates.cacheWrite = $0; rates.cacheWriteHour = $0 } }))
    }
}

private struct RateField: View {
    let title: String
    @Binding var value: Double
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.muted)
            HStack(spacing: 5) {
                Text("$").foregroundStyle(Theme.muted)
                TextField(title, text: $draft).textFieldStyle(.plain).focused($focused).accessibilityLabel(title + " USD per million tokens")
            }.font(.system(size: 12, design: .monospaced)).padding(9).background(Theme.text.opacity(0.035), in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(invalid ? Theme.orange : Theme.line))
            if invalid { Text("Enter a nonnegative number.").font(.system(size: 8)).foregroundStyle(Theme.orange) }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { draft = String(value) }
        .onChange(of: value) { _, new in if !focused { draft = String(new); invalid = false } }
        .onChange(of: draft) { _, new in
            guard let parsed = Double(new), parsed.isFinite, parsed >= 0 else { invalid = true; return }
            invalid = false
            if value != parsed { value = parsed }
        }
        .onChange(of: focused) { _, new in if !new && invalid { draft = String(value); invalid = false } }
    }
}


private struct RecordedRateCard: View {
    let provider: Provider
    let models: [ModelCost]
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 9) { ProviderMark(provider: provider).frame(width: 26, height: 26); Text(provider.title).font(.system(size: 13, weight: .semibold)); Spacer(); Text("$ / 1M TOKENS").font(.system(size: 9)).foregroundStyle(Theme.muted) }
            if models.isEmpty { Text("No local model usage in the last 84 days.").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            else {
                HStack { Text("RECORDED MODEL"); Spacer(); Text("INPUT").frame(width: 55, alignment: .trailing); Text("OUTPUT").frame(width: 55, alignment: .trailing); Text("CACHE READ").frame(width: 75, alignment: .trailing) }.font(.system(size: 8, weight: .medium)).foregroundStyle(Theme.muted)
                ForEach(models) { row in
                    HStack {
                        Text(row.title).lineLimit(1); Spacer()
                        Text(row.rates.map { Format.money($0.input) } ?? "—").frame(width: 55, alignment: .trailing)
                        Text(row.rates.map { Format.money($0.output) } ?? "—").frame(width: 55, alignment: .trailing)
                        Text(row.rates.map { Format.money($0.cacheRead) } ?? "—").frame(width: 75, alignment: .trailing)
                    }.font(.system(size: 10)).help(row.rates.map { "Cache writes: \(Format.money($0.cacheWrite)) / 1M; 1-hour writes: \(Format.money($0.cacheWriteHour)) / 1M." } ?? "No known rate for " + row.model)
                }
            }
        }.padding(22).card()
    }
}
