import SwiftUI
import Charts
import LimitterCore

enum DashboardLayout {
    static let width: CGFloat = 840
    static let height: CGFloat = 800
    static let providerCardHeight: CGFloat = 300
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    var height: CGFloat = DashboardLayout.height
    var body: some View {
        VStack(spacing: 0) {
            header
            if store.demo {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles"); Text("PREVIEW MODE · SAMPLE DATA").tracking(1)
                    Spacer(); Button("Exit preview") { store.setDemo(false) }.disabled(store.refreshing)
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.mint).padding(.horizontal, 24).padding(.vertical, 7).background(Theme.mint.opacity(0.055))
            }
            navigation.padding(.horizontal, 24)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: store.page == .overview ? 10 : 12) {
                    if store.providers.isEmpty {
                        emptyState("Your dashboard, your rules.", detail: "Enable a provider in Display settings to see your activity.")
                    } else {
                        if store.page == .overview { overview }
                        else if store.page == .activity { activity }
                        else { CostsDashboard(store: store) }
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "internaldrive")
                            Text(store.history.unreadableFiles > 0 ? "Some history couldn’t be read. Totals may be incomplete." : (store.providers.contains(.grok) ? "Local coding activity · Grok updates after each turn · Account-wide limits" : "Activity from this Mac · Account-wide subscription limits"))
                            Spacer()
                        }.font(.system(size: 9)).foregroundStyle(Theme.muted)
                    }
                }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 14)
            }
            footer
        }.frame(width: DashboardLayout.width, height: height)
            .background(Theme.background).foregroundStyle(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(Theme.text.opacity(0.1)))
            .preferredColorScheme(store.preferences.theme.colorScheme).buttonStyle(.plain)
    }
    private var header: some View {
        HStack(spacing: 10) {
            BrandMark().frame(width: 29, height: 29)
            Text("limitter").font(.system(size: 22, weight: .semibold, design: .rounded)).tracking(-0.7)
            Text("YOUR AI, IN VIEW").font(.system(size: 8, weight: .medium)).tracking(1.3).foregroundStyle(Theme.muted).padding(.leading, 6)
            Spacer()
            iconButton(store.pinned ? "pin.fill" : "pin", label: "Pin dashboard", active: store.pinned) { store.pinned.toggle() }
            iconButton("gearshape", label: "Open settings", active: false) { store.openSettings() }
        }.padding(.horizontal, 24).padding(.vertical, 15)
    }
    private var navigation: some View {
        HStack(spacing: 25) {
            ForEach(UsageStore.Page.allCases, id: \.self) { page in
                Button { withAnimation(.easeInOut(duration: 0.15)) { store.page = page } } label: {
                    VStack(spacing: 10) {
                        Text(page.rawValue).font(.system(size: 12, weight: .semibold)).foregroundStyle(store.page == page ? Theme.text : Theme.muted)
                        Capsule().fill(store.page == page ? Theme.mint : .clear).frame(height: 2)
                    }.fixedSize(horizontal: true, vertical: false)
                }
            }
            Spacer()
            if store.preferences.visibleProviders.count > 1 {
                Menu {
                    Button("All providers") { store.selectedProvider = nil }
                    ForEach(store.preferences.visibleProviders) { provider in Button(provider.title) { store.selectedProvider = provider } }
                } label: {
                    HStack(spacing: 6) { Text(store.activeProvider?.title ?? "All providers"); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.bottom, 10).accessibilityLabel("Filter dashboard by provider")
            }
        }.overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
    private var greeting: some View {
        let message = WelcomeMessage(activity: store.activity, providers: store.providers, limits: store.limits, playful: store.preferences.playfulCadence)
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(message.title).font(.system(size: 24, weight: .semibold, design: .rounded)).tracking(-0.7)
                Text(message.detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if store.activity.currentStreak > 0 {
                HStack(spacing: 6) { Image(systemName: "flame.fill"); Text("\(store.activity.currentStreak) day streak") }
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.orange).padding(.horizontal, 11).padding(.vertical, 8)
                    .background(Theme.orange.opacity(0.075), in: Capsule()).help("Consecutive days with recorded AI responses; today or yesterday can anchor the streak.")
            }
        }.padding(.bottom, 2)
    }
    @ViewBuilder private var overview: some View {
        greeting
        if store.preferences.showTokenSummary { metrics }
        if store.preferences.showLimits {
            HStack(alignment: .top, spacing: 12) {
                ForEach(store.providers) { provider in
                    ProviderCard(provider: provider, snapshot: store.limits[provider], store: store)
                        .frame(width: (DashboardLayout.width - 48 - CGFloat(max(0, store.providers.count - 1)) * 12) / CGFloat(max(1, store.providers.count)), alignment: .topLeading)
                }
            }
        }
        if store.preferences.showChart { todayActivityCard }
        if store.preferences.showCurrentSession {
            if let session = store.currentSession {
                SessionCard(session: session, title: session.state().isActive ? "IN THE FLOW" : "LAST SESSION", showCost: store.preferences.showCosts, estimate: store.sessionEstimate(session))
            } else {
                emptyState("Your next session starts here.", detail: "Once Codex, Claude, or Grok Build writes local activity, its project, state, and quick stats appear here.")
            }
        }
    }
    private var metrics: some View {
        HStack(spacing: 10) {
            MetricTile(title: TokenPeriod.today.rawValue.uppercased() + " · TOKENS", value: store.historyAvailable ? Format.compact(store.overviewUsage.total) : "—", detail: "Including cached tokens", symbol: "sparkle", color: Theme.mint)
            if store.preferences.showCosts {
                Button { store.page = .costs } label: { MetricTile(title: "API EQUIVALENT", value: store.historyAvailable ? store.overviewEstimate.formatted : "—", detail: store.overviewEstimate.isComplete ? (store.preferences.pricingMode == .recordedModels ? "By model used ↗" : "At benchmark rates ↗") : "Some tokens unpriced ↗", symbol: "dollarsign", color: Color(red: 0.70, green: 0.65, blue: 0.97)) }
                    .help("Hypothetical token cost for " + TokenPeriod.today.rawValue.lowercased() + ". Open API Value for assumptions.")
            }
            MetricTile(title: "SESSIONS", value: store.historyAvailable ? store.overviewCounts.sessions.formatted() : "—", detail: TokenPeriod.today.rawValue, symbol: "rectangle.stack", color: Theme.orange)
            MetricTile(title: "RESPONSES", value: store.historyAvailable ? Format.compact(store.overviewCounts.requests) : "—", detail: TokenPeriod.today.rawValue, symbol: "arrow.triangle.branch", color: Theme.mint)
        }
    }
    private var todayActivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                eyebrow("TODAY’S TOKEN FLOW")
                ForEach(store.providers) { provider in
                    HStack(spacing: 4) { Circle().fill(Theme.accent(provider)).frame(width: 5, height: 5); Text(provider.title) }.font(.system(size: 9)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text("HOURLY · TODAY").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.muted)
            }
            TokenChart(days: store.overviewHours, providers: store.providers, intraday: true).frame(height: 100)
        }.padding(14).card()
    }
    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                eyebrow("TOKEN FLOW")
                ForEach(store.providers) { provider in
                    HStack(spacing: 4) { Circle().fill(Theme.accent(provider)).frame(width: 5, height: 5); Text(provider.title) }.font(.system(size: 9)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Menu {
                    ForEach(ChartPeriod.allCases, id: \.self) { period in Button(period.rawValue) { store.preferences.chartPeriod = period } }
                } label: { HStack(spacing: 5) { Text(store.preferences.chartPeriod.rawValue); Image(systemName: "chevron.down").font(.system(size: 7)) }.font(.system(size: 10)).foregroundStyle(Theme.muted) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            TokenChart(days: store.activityDays, providers: store.providers).frame(height: 110)
        }.padding(16).card()
    }
    @ViewBuilder private var activity: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) { Text("A little every day adds up.").font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.6); Text("Your rhythm, measured in AI activity.").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            Spacer()
            Menu {
                ForEach(TokenPeriod.allCases, id: \.self) { period in Button(period.rawValue) { store.preferences.tokenPeriod = period } }
            } label: { Label(store.preferences.tokenPeriod.rawValue, systemImage: "calendar").font(.system(size: 10)).foregroundStyle(Theme.muted) }.menuStyle(.borderlessButton).fixedSize()
        }
        if store.preferences.showHeatmap { ActivityHeatmap(data: store.heatmap) }
        if store.preferences.showChart { activityCard }
        if store.preferences.showBreakdown {
            HStack(spacing: 10) {
                MetricTile(title: "UNCACHED INPUT", value: Format.compact(store.activityUsage.input), detail: "Excludes cache reads / writes", symbol: "arrow.up", color: Theme.mint)
                MetricTile(title: "OUTPUT", value: Format.compact(store.activityUsage.output), detail: store.preferences.tokenPeriod.rawValue, symbol: "arrow.down", color: Theme.orange)
                MetricTile(title: "CACHE READ", value: Format.compact(store.activityUsage.cached), detail: "Reused context", symbol: "bolt", color: Theme.mint)
                MetricTile(title: "CACHE WRITE", value: Format.compact(store.activityUsage.cacheWrite), detail: "New cached context", symbol: "tray.and.arrow.down", color: Theme.orange)
            }
        }
        if store.preferences.showBreakdown {
            HStack {
                Label("Cache read share", systemImage: "bolt")
                Text(store.activityUsage.total > 0 ? "\(Int(Double(store.activityUsage.cached) / Double(store.activityUsage.total) * 100))%" : "—").foregroundStyle(Theme.mint)
                Spacer()
                Text("\(store.activityCounts.sessions) sessions · \(store.activityCounts.requests.formatted()) responses · " + store.preferences.tokenPeriod.rawValue.lowercased())
            }.font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.horizontal, 3)
        }
        if store.preferences.showBreakdown, store.providers.contains(.codex), let lifetime = store.limits[.codex]?.lifetimeTokens {
            HStack { Label("Codex lifetime tokens", systemImage: "sparkles"); Spacer(); Text(Format.compact(lifetime)).foregroundStyle(Theme.mint) }.font(.system(size: 11)).foregroundStyle(Theme.muted).padding(14).card()
        }
        if store.preferences.showCurrentSession {
            HStack { eyebrow("RECENT SESSIONS"); Spacer(); Text("Local history · up to 84 days").font(.system(size: 9)).foregroundStyle(Theme.muted) }
            ForEach(store.recentSessions) { session in SessionCard(session: session, showCost: store.preferences.showCosts, estimate: store.sessionEstimate(session)) }
        }
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(store.refreshing ? Theme.orange : store.lastRefresh == nil ? Theme.muted : Theme.mint).frame(width: 5, height: 5)
            Text(store.refreshing ? "Syncing activity…" : store.demo ? "Exploring with sample data" : "Auto sync · every 30s").font(.system(size: 9)).foregroundStyle(Theme.muted)
            Spacer()
            Button { store.refresh(force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 10)) }.foregroundStyle(Theme.muted).disabled(store.refreshing || store.demo)
            Rectangle().fill(Theme.line).frame(width: 1, height: 12).padding(.horizontal, 7)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 11)) }.foregroundStyle(Theme.muted).help("Quit Limitter")
        }.padding(.horizontal, 24).padding(.vertical, 13).background(Theme.surface.opacity(0.45))
    }
    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 13, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(3) }.frame(maxWidth: .infinity, alignment: .leading).padding(18).card()
    }
    private func iconButton(_ symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(active ? Theme.mint : Theme.muted).frame(width: 28, height: 28).background(active ? Theme.mint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7)) }.help(label).accessibilityLabel(label)
    }
}

struct ProviderCard: View {
    let provider: Provider
    let snapshot: ProviderLimits?
    @ObservedObject var store: UsageStore
    @State private var expanded: Bool
    private var accent: Color { Theme.accent(provider) }

    init(provider: Provider, snapshot: ProviderLimits?, store: UsageStore) {
        self.provider = provider
        self.snapshot = snapshot
        self.store = store
        _expanded = State(initialValue: provider == .codex || provider == .claude)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let preferred = store.preferences.quotaPeriod(for: provider)
            let status = QuotaPresentation(provider: provider, snapshot: snapshot, period: preferred, now: context.date)
            let todayCounts = store.history.activityCounts(dayCount: 1, providers: [provider])
            let grokUsage = store.history.today[provider] ?? TokenUsage()
            ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    ProviderMark(provider: provider).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider == .claude ? "Claude Code" : provider.title).font(.system(size: 14, weight: .semibold))
                        if let plan = snapshot?.plan { Text(plan.capitalized).font(.system(size: 8, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Circle().fill(status.state == .live ? accent : status.state == .error ? Theme.orange : Theme.muted).frame(width: 4, height: 4)
                        Text(status.label)
                    }.font(.system(size: 7, weight: .medium)).tracking(0.5).foregroundStyle(Theme.muted).help(status.message)
                }
                HStack {
                    Text("MENU BAR WINDOW").font(.system(size: 8, weight: .medium)).tracking(0.7).foregroundStyle(Theme.muted)
                    Spacer()
                    Menu {
                        ForEach(provider.quotaPeriods, id: \.self) { period in Button(period.rawValue) { store.preferences.setQuotaPeriod(period, for: provider) } }
                    } label: { HStack(spacing: 5) { Text(preferred.rawValue); Image(systemName: "chevron.down").font(.system(size: 7)) }.font(.system(size: 10, weight: .medium)).foregroundStyle(accent) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(provider.title + " menu bar timeframe")
                }
                if let window = status.window {
                    LimitMeter(window: window, accent: accent, showReset: store.preferences.showResetTimes, stale: !status.hasValue, cached: status.state == .cached)
                } else {
                    HStack { Text(preferred.rawValue + (preferred == .session ? " · 5h" : "")); Spacer(); Text("—").foregroundStyle(Theme.muted) }.font(.system(size: 11, weight: .medium))
                }
                if status.state != .live {
                    Text(status.message).font(.system(size: 9)).foregroundStyle(status.state == .error ? Theme.orange : Theme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                // Visibility controls apply to secondary details, never hide the selected primary window.
                ForEach((snapshot?.windows ?? []).filter { !preferred.matches($0) && store.preferences.visibleWindows.matches($0) }) { window in
                    let secondary = QuotaPresentation(provider: provider, snapshot: snapshot, period: window.durationMinutes ?? 0 >= 10080 ? .weekly : .session, now: context.date)
                    if let secondaryWindow = secondary.window {
                        LimitMeter(window: secondaryWindow, accent: accent, showReset: store.preferences.showResetTimes, stale: !secondary.hasValue, cached: secondary.state == .cached, title: window.title)
                            .help(secondary.message)
                    } else {
                        HStack(spacing: 6) {
                            Text(window.title)
                            Text("—").foregroundStyle(Theme.muted)
                            Spacer(minLength: 0)
                            if store.preferences.showResetTimes { Text(Format.reset(window.resetsAt, now: context.date)) }
                }.font(.system(size: 9)).foregroundStyle(Theme.muted).help(secondary.message)
                    }
                }
                if provider == .grok {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    Text("BUILD ACTIVITY · TODAY").font(.system(size: 8, weight: .medium)).tracking(0.7).foregroundStyle(Theme.muted)
                    grokStat("Tokens", value: Format.compact(grokUsage.total))
                    HStack {
                        grokStat("Sessions", value: todayCounts.sessions.formatted())
                        Spacer(minLength: 14)
                        grokStat("Responses", value: Format.compact(todayCounts.requests))
                    }
                    Rectangle().fill(Theme.line).frame(height: 1)
                    Text("LAST 7 DAYS").font(.system(size: 8, weight: .medium)).tracking(0.7).foregroundStyle(Theme.muted)
                    grokStat("Tokens", value: Format.compact(store.history.total(dayCount: 7, providers: [.grok]).total))
                    grokStat("Responses", value: Format.compact(store.history.activityCounts(dayCount: 7, providers: [.grok]).requests))
                    Text("Local Grok Build activity; other Grok products count toward the shared quota above.")
                        .font(.system(size: 9)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                if provider == .claude && store.preferences.showAdditionalLimits {
                    ForEach(Array((snapshot?.buckets ?? []).dropFirst())) { bucket in
                        let modelStatus = QuotaPresentation(provider: provider, snapshot: snapshot, period: .weekly, now: context.date, bucketID: bucket.id)
                        Rectangle().fill(Theme.line).frame(height: 1)
                        if let window = modelStatus.window {
                            LimitMeter(window: window, accent: accent, showReset: store.preferences.showResetTimes, stale: !modelStatus.hasValue, cached: modelStatus.state == .cached, title: bucket.name + " · weekly")
                                .help(modelStatus.message)
                        } else {
                            HStack { Text(bucket.name + " · weekly"); Spacer(); Text("—") }.font(.system(size: 11, weight: .medium))
                        }
                        if !modelStatus.hasValue { Text(modelStatus.message).font(.system(size: 9)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
                    }
                    if let error = snapshot?.modelLimitsError { Text(error).font(.system(size: 9)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
                }
                if provider != .claude, let snapshot, snapshot.buckets.count > 1 && store.preferences.showAdditionalLimits {
                    Button { withAnimation { expanded.toggle() } } label: {
                        HStack { Text("\(snapshot.buckets.count - 1) additional model limit\(snapshot.buckets.count > 2 ? "s" : "")"); Spacer(); Image(systemName: expanded ? "chevron.up" : "chevron.down") }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    if expanded {
                        ForEach(Array(snapshot.buckets.dropFirst())) { bucket in
                            Text(bucket.name).font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                            ForEach(bucket.windows.filter(store.preferences.visibleWindows.matches)) { window in LimitMeter(window: window, accent: accent, showReset: store.preferences.showResetTimes, stale: snapshot.isStale || snapshot.error != nil) }
                        }
                    }
                }
                if provider == .grok {
                    if status.state == .error {
                        Button("Connection settings ↗") { store.settingsSection = .connections; store.openSettings() }.font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                    }
                }
                if provider == .claude, !store.demo, status.state == .error {
                    Button { store.connectClaude() } label: { Label(store.connectorInstalled ? "Repair Claude connection" : "Connect Claude limits", systemImage: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent) }
                }
            }.frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }.frame(height: DashboardLayout.providerCardHeight).card()
        }
    }
    private func grokStat(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer(minLength: 4)
            Text(store.history.available.contains(.grok) ? value : "—").fontWeight(.medium).foregroundStyle(accent)
        }.font(.system(size: 10)).help("Activity recorded by Grok Build on this Mac.")
    }
}

struct LimitMeter: View {
    let window: LimitWindow
    let accent: Color
    var showReset = true
    var stale = false
    var cached = false
    var title: String? = nil
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let expired = stale || window.hasExpired(at: context.date)
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title ?? window.title).font(.system(size: 11, weight: .medium))
                    Text(window.durationMinutes == 300 ? "5h" : "").font(.system(size: 9)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text((cached ? "~" : "") + "\(Format.percent(window.usedPercent))%").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(expired ? Theme.muted : accent)
                    Text("used").font(.system(size: 9)).foregroundStyle(Theme.muted)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.text.opacity(0.065))
                        Capsule().fill(expired ? Theme.muted : window.usedPercent >= 90 ? Color(red: 0.96, green: 0.43, blue: 0.42) : accent)
                            .frame(width: max(0, geometry.size.width * (expired ? 0 : window.progress)))
                        HStack(spacing: 0) { ForEach(0..<30) { _ in Spacer(minLength: 0); Rectangle().fill(Theme.surface).frame(width: 2) } }.padding(.horizontal, 1)
                    }
                }.frame(height: 6)
                HStack {
                    if showReset { Text(Format.reset(window.resetsAt, now: context.date)) }
                    Spacer()
                    Text(expired ? "Ended" : "\(Int(window.remaining))% left")
                }.font(.system(size: 9)).foregroundStyle(Theme.muted)
            }.accessibilityElement(children: .ignore).accessibilityLabel("\(title ?? window.title), \(Format.percent(window.usedPercent)) percent used, \(Format.reset(window.resetsAt, now: context.date))")
        }
    }
}

struct BrandMark: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            Capsule().frame(width: 5, height: 13)
            Capsule().frame(width: 5, height: 23)
            Capsule().frame(width: 5, height: 17)
        }.foregroundStyle(Theme.mint).rotationEffect(.degrees(18))
    }
}
struct ProviderMark: View {
    let provider: Provider
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Theme.accent(provider).opacity(0.09))
            if provider == .codex { Text(">_").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.mint) }
            else if provider == .grok { Image(systemName: "sparkle").font(.system(size: 19, weight: .medium)).foregroundStyle(Theme.blue).rotationEffect(.degrees(-20)) }
            else { Image(systemName: "sun.max.fill").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.orange) }
        }
    }
}
func eyebrow(_ text: String) -> some View { Text(text).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.muted) }
extension View {
    func card() -> some View { background(Theme.surface, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.line)) }
}
