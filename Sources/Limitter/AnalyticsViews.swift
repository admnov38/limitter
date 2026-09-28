import SwiftUI
import Charts
import LimitterCore

struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) { Text(title).font(.system(size: 8, weight: .semibold)).tracking(0.7).lineLimit(1).minimumScaleFactor(0.8); Spacer(minLength: 0); Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color) }.foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 24, weight: .medium, design: .rounded)).tracking(-0.8).lineLimit(1).minimumScaleFactor(0.7).contentTransition(.numericText())
            Text(detail).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
            .background(LinearGradient(colors: [Theme.surface, color.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }
}

struct SessionCard: View {
    let session: SessionSummary
    var title: String? = nil
    let showCost: Bool
    let estimate: PriceEstimate
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let state = session.state(at: context.date)
            let accent = Theme.accent(session.provider)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    ProviderMark(provider: session.provider).frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        if let title { eyebrow(title) }
                        HStack(spacing: 6) {
                            Text(session.project).font(.system(size: 13, weight: .semibold))
                            Text("/ " + session.provider.title).font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                    HStack(spacing: 5) { Circle().fill(state.isActive ? accent : Theme.muted).frame(width: 5, height: 5); Text(state.rawValue) }
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(state.isActive ? accent : Theme.muted)
                        .padding(.horizontal, 9).padding(.vertical, 5).background(accent.opacity(state.isActive ? 0.09 : 0.035), in: Capsule()).help(session.stateExplanation)
                }
                HStack(spacing: 15) {
                    Label(Format.compact(session.usage.total) + " tokens", systemImage: "sparkle")
                    Label("\(session.responses) responses", systemImage: "arrow.triangle.branch")
                    if showCost { Text((estimate.isComplete ? "≈ " : "") + estimate.formatted).help(estimate.isComplete ? "API equivalent by recorded model, or your selected benchmark." : "Some tokens have no known model rate; the value is a subtotal.") }
                    Spacer(minLength: 4)
                    Text(session.lastActivity, style: .relative).monospacedDigit()
                    Text("ago").padding(.leading, -12)
                }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                if let model = session.model {
                    Text((session.modelUsage.count > 1 ? "\(session.modelUsage.count) models · latest " : "") + model).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted.opacity(0.8)).lineLimit(1)
                }
            }.padding(13).card()
        }
    }
}

struct TokenChart: View {
    let days: [UsageDay]
    let providers: [Provider]
    var style = ChartStyle.line
    var interval = ChartInterval.day
    @State private var selectedDate: Date?
    private var calendar: Calendar { .current }
    private var selectedDay: UsageDay? {
        guard let selectedDate else { return nil }
        if style == .histogram { return days.last(where: { $0.date <= selectedDate }) ?? days.first }
        return days.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }
    private var singleDay: Bool {
        guard let first = days.first?.date, let last = days.last?.date else { return true }
        return calendar.isDate(first, inSameDayAs: last)
    }
    private var yPeak: Double {
        let peak = style == .histogram
            ? days.map { day in providers.reduce(0) { $0 + day.tokens(for: $1) } }.max() ?? 0
            : days.map { day in providers.map { day.tokens(for: $0) }.max() ?? 0 }.max() ?? 0
        return max(1, Double(peak) * 1.2)
    }
    private var xDomain: ClosedRange<Date> {
        let first = days.first?.date ?? Date()
        let last = days.last?.date ?? first
        if interval.minutes < 1_440, singleDay {
            let start = calendar.startOfDay(for: first)
            return start...(calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
        }
        if style == .histogram {
            let end = calendar.date(byAdding: .minute, value: interval.minutes, to: last) ?? last.addingTimeInterval(1)
            return first...(end > first ? end : first.addingTimeInterval(1))
        }
        return first...(last > first ? last : first.addingTimeInterval(1))
    }
    private var axisStride: (component: Calendar.Component, count: Int) {
        if interval == .day { return (.day, max(1, days.count / 7)) }
        let span = (days.last?.date ?? Date()).timeIntervalSince(days.first?.date ?? Date())
        if span > 26 * 3_600 { return (.day, max(1, Int(span / 86_400) / 7)) }
        return (.hour, 4)
    }
    var body: some View {
        let stride = axisStride
        Chart {
            if style == .histogram {
                ForEach(barSegments) { segment in
                    barMark(segment)
                }
            } else {
                ForEach(providers) { provider in
                    ForEach(days) { day in
                        AreaMark(x: .value("Time", day.date), y: .value("Tokens", day.tokens(for: provider)), stacking: .unstacked)
                            .foregroundStyle(by: .value("Provider", provider.title)).opacity(0.10).interpolationMethod(.monotone)
                        LineMark(x: .value("Time", day.date), y: .value("Tokens", day.tokens(for: provider)), series: .value("Provider", provider.title))
                            .foregroundStyle(by: .value("Provider", provider.title)).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                        if day.id == days.last?.id {
                            PointMark(x: .value("Time", day.date), y: .value("Tokens", day.tokens(for: provider)))
                                .foregroundStyle(by: .value("Provider", provider.title)).symbolSize(22)
                        }
                    }
                }
            }
            if let day = selectedDay {
                RuleMark(x: .value("Time", day.date)).foregroundStyle(Theme.text.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        HStack(spacing: 8) {
                            Text(day.date, format: tooltipFormat).foregroundStyle(Theme.muted)
                            ForEach(providers) { provider in Text(provider.title + " " + Format.compact(day.tokens(for: provider))).foregroundStyle(Theme.accent(provider)) }
                        }.font(.system(size: 9, weight: .medium)).padding(6).background(Theme.surface, in: RoundedRectangle(cornerRadius: 5))
                    }
            }
        }
        .chartForegroundStyleScale(["Codex": Theme.mint, "Claude": Theme.orange, "Grok": Theme.blue]).chartLegend(.hidden)
        .chartYScale(domain: 0...yPeak)
        .chartXAxis { AxisMarks(values: .stride(by: stride.component, count: max(1, stride.count))) { value in
            AxisValueLabel { if let date = value.as(Date.self) { Text(date, format: axisFormat).font(.system(size: 9)).foregroundStyle(Theme.muted) } }
        } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Theme.line)
            AxisValueLabel { if let value = value.as(Double.self) { Text(Format.compact(Int(value))).font(.system(size: 8)).foregroundStyle(Theme.muted) } }
        } }
        .chartXScale(domain: xDomain)
        .chartXSelection(value: $selectedDate)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if let plot = proxy.plotFrame {
                            let frame = geometry[plot]
                            selectedDate = frame.contains(location) ? proxy.value(atX: location.x - frame.minX) : nil
                        }
                    case .ended: selectedDate = nil
                    }
                }
            }
        }.accessibilityLabel((style == .histogram ? "Histogram" : "Line chart") + " of " + interval.rawValue.lowercased() + " token buckets for " + providers.map(\.title).joined(separator: " and "))
    }
    private func barMark(_ segment: StackSegment) -> some ChartContent {
        BarMark(
            x: PlottableValue.value("Time", segment.start..<segment.end),
            yStart: PlottableValue.value("Tokens", segment.y0),
            yEnd: PlottableValue.value("Tokens", segment.y1)
        )
        .foregroundStyle(Theme.accent(segment.provider))
    }
    private struct StackSegment: Identifiable {
        var id: String
        var start: Date
        var end: Date
        var provider: Provider
        var y0: Double
        var y1: Double
    }
    private var barSegments: [StackSegment] {
        let gap = days.count > 48 ? 0.08 : 0.2
        return days.flatMap { day in
            let bounds = barBounds(day.date, gap: gap)
            var base = 0.0
            var segments: [StackSegment] = []
            for provider in providers {
                let value = Double(day.tokens(for: provider))
                if value > 0 {
                    segments.append(StackSegment(id: provider.rawValue + "-" + String(day.date.timeIntervalSinceReferenceDate), start: bounds.start, end: bounds.end, provider: provider, y0: base, y1: base + value))
                }
                base += value
            }
            return segments
        }
    }
    private func barBounds(_ start: Date, gap: Double) -> (start: Date, end: Date) {
        let next = calendar.date(byAdding: .minute, value: interval.minutes, to: start) ?? start.addingTimeInterval(Double(interval.minutes) * 60)
        let span = max(1, next.timeIntervalSince(start))
        let inset = span * gap / 2
        return (start.addingTimeInterval(inset), start.addingTimeInterval(span - inset))
    }
    private var axisFormat: Date.FormatStyle {
        let span = (days.last?.date ?? Date()).timeIntervalSince(days.first?.date ?? Date())
        if interval == .day { return days.count <= 7 ? .dateTime.weekday(.abbreviated) : .dateTime.day() }
        if span > 26 * 3_600 { return span <= 8 * 86_400 ? .dateTime.weekday(.abbreviated) : .dateTime.day() }
        return .dateTime.hour()
    }
    private var tooltipFormat: Date.FormatStyle {
        if interval == .day { return .dateTime.month(.abbreviated).day() }
        return singleDay ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute()
    }
}

enum HeatmapLayout {
    static let tile: CGFloat = 22
    static let minGap: CGFloat = 5
    static let labelWidth: CGFloat = 12
    static let labelGap: CGFloat = 6
    static let bandSpacing: CGFloat = 24
    static let statsWidth: CGFloat = 108
    /// Card interior on the fixed dashboard: window padding, then the card’s own padding.
    static var columnWidth: CGFloat { DashboardLayout.width - 48 - 36 - labelWidth - labelGap - bandSpacing - 1 - bandSpacing - statsWidth }
    static var weeks: Int { max(1, Int((columnWidth + minGap) / (tile + minGap))) }
    static var columnGap: CGFloat {
        let weeks = weeks
        guard weeks > 1 else { return minGap }
        return (columnWidth - CGFloat(weeks) * tile) / CGFloat(weeks - 1)
    }
    /// Days from the Monday of the first visible week through today.
    static func historyDayCount(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: now)
        let sinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
        return (weeks - 1) * 7 + sinceMonday + 1
    }
}

struct ActivityHeatmap: View {
    let data: HeatmapData
    @State private var selectedDay: Date?
    @State private var hoveredDay: Date?
    private let calendar = Calendar.current
    private var dates: [Date?] {
        let weeks = HeatmapLayout.weeks
        let today = calendar.startOfDay(for: Date())
        let sinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -sinceMonday, to: today),
              let start = calendar.date(byAdding: .day, value: -(weeks - 1) * 7, to: monday) else { return [] }
        return (0..<(weeks * 7)).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start), date <= today else { return nil }
            return date
        }
    }
    var body: some View {
        let lookup = Dictionary(uniqueKeysWithValues: data.days.map { ($0.date, $0) })
        let values = dates
        let peak = data.peak
        let focus = hoveredDay ?? selectedDay ?? calendar.startOfDay(for: Date())
        return VStack(alignment: .leading, spacing: 17) {
            HStack {
                eyebrow("THE DAILY COMMITMENT")
                Spacer()
                Text("\(HeatmapLayout.weeks) WEEKS OF AI ACTIVITY").font(.system(size: 8, weight: .medium)).tracking(0.7).foregroundStyle(Theme.muted)
            }
            HStack(alignment: .center, spacing: HeatmapLayout.bandSpacing) {
              HStack(alignment: .top, spacing: HeatmapLayout.labelGap) {
                VStack(spacing: 5) {
                    Color.clear.frame(height: 14)
                    ForEach(0..<7) { index in Text(["M", "", "W", "", "F", "", ""][index]).font(.system(size: 8)).foregroundStyle(Theme.muted).frame(width: HeatmapLayout.labelWidth, height: HeatmapLayout.tile) }
                }
                HStack(alignment: .top, spacing: HeatmapLayout.columnGap) {
                    ForEach(0..<(values.count / 7), id: \.self) { week in
                        VStack(spacing: 5) {
                            Text(monthLabel(week: week, dates: values)).font(.system(size: 8)).foregroundStyle(Theme.muted).frame(height: 14)
                            ForEach(0..<7) { weekday in
                                let date = values[week * 7 + weekday]
                                let count = date.map { lookup[$0]?.responses ?? 0 } ?? 0
                                Button { selectedDay = date } label: {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(date == nil ? .clear : count == 0 ? Theme.text.opacity(0.055) : Theme.mint.opacity(0.22 + 0.78 * sqrt(Double(count) / Double(peak))))
                                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(date != nil && date == focus ? Theme.mint : .clear, lineWidth: 1.5))
                                        .frame(width: HeatmapLayout.tile, height: HeatmapLayout.tile)
                                }.disabled(date == nil).onHover { hovered in
                                    if hovered { if hoveredDay != date { hoveredDay = date } }
                                    else if hoveredDay == date { hoveredDay = nil }
                                }.accessibilityLabel(date.flatMap { lookup[$0]?.accessibilityLabel } ?? "Outside history")
                            }
                        }.frame(width: HeatmapLayout.tile)
                    }
                }
            }
              Rectangle().fill(Theme.line).frame(width: 1, height: 170)
              VStack(alignment: .leading, spacing: 19) {
                  cadenceMetric("CURRENT STREAK", value: data.summary.currentStreak, unit: "days")
                  cadenceMetric("BEST STREAK", value: data.summary.bestStreak, unit: "days")
                  cadenceMetric("ACTIVE DAYS", value: data.summary.activeDays, unit: "of \(data.days.count)")
              }.frame(width: HeatmapLayout.statsWidth, alignment: .leading)
            }
            HStack(spacing: 5) {
                Text(focus, format: .dateTime.month(.abbreviated).day()).foregroundStyle(Theme.text)
                Text("· \(lookup[focus]?.responses ?? 0) responses").foregroundStyle(Theme.muted)
                if let day = data.days.first(where: { $0.date == focus }) {
                    Text("· " + Format.compact(day.tokens) + " tokens").foregroundStyle(Theme.muted)
                }
                Spacer()
                Text("Less").foregroundStyle(Theme.muted)
                ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 2).fill(index == 0 ? Theme.text.opacity(0.055) : Theme.mint.opacity(Double(index) / 4)).frame(width: 9, height: 9) }
                Text("More").foregroundStyle(Theme.muted)
            }.font(.system(size: 9))
        }.padding(18).card()
    }
    private func monthLabel(week: Int, dates: [Date?]) -> String {
        let slice = dates[(week * 7)..<(week * 7 + 7)].compactMap { $0 }
        guard let first = slice.first else { return "" }
        if week == 0 || slice.contains(where: { calendar.component(.day, from: $0) == 1 }) { return (slice.first(where: { calendar.component(.day, from: $0) == 1 }) ?? first).formatted(.dateTime.month(.abbreviated)) }
        return ""
    }
    private func cadenceMetric(_ title: String, value: Int, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 8, weight: .medium)).tracking(0.7).foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 5) { Text("\(value)").font(.system(size: 22, weight: .medium, design: .rounded)); Text(unit).font(.system(size: 10)).foregroundStyle(Theme.muted) }
        }
    }
}

struct CostsDashboard: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        if !store.preferences.showCosts {
            VStack(alignment: .leading, spacing: 12) {
                Text("A price tag for your curiosity.").font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Enable API equivalent to estimate your local token activity at selected API rates.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Button("Show API equivalent") { store.preferences.showCosts = true }.foregroundStyle(Theme.mint)
            }.padding(20).card()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack { eyebrow("IF THIS RAN ON THE API"); Spacer(); periodPicker }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(store.historyAvailable ? store.apiEstimate.formatted : "—").font(.system(size: 44, weight: .medium, design: .rounded)).tracking(-1.7)
                        Text("USD equivalent").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Spacer()
                        Image(systemName: "sparkles").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.mint)
                    }
                    Text(store.preferences.pricingMode == .recordedModels ? "Each recorded model, priced at its own API rates." : "All activity priced at your selected benchmark rates.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }.padding(22).background(LinearGradient(colors: [Theme.mint.opacity(0.08), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.line))
                HStack(alignment: .top, spacing: 12) {
                    ForEach(store.providers) { provider in providerCost(provider) }
                }
                ModelCostTable(estimate: store.apiEstimate, order: $store.preferences.modelOrder)
                VStack(alignment: .leading, spacing: 14) {
                    HStack { eyebrow("THE ASSUMPTIONS"); Spacer(); Button("Edit rates ↗") { store.settingsSection = .pricing; store.openSettings() }.font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.mint) }
                    Text("Recorded models uses the model on each response, including switches within a session. Single benchmark applies your selected rates to all tokens. Unknown models remain unpriced in recorded mode. Estimates use standard short-context rates and exclude tools, long-context premiums, service tiers, regional multipliers, and tax.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
                    Text("Cache reads and writes are priced separately. Claude’s 1-hour cache writes use their own rate when the log reports their duration; otherwise the 5-minute rate applies.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
                    HStack(spacing: 20) {
                        Link("OpenAI rates ↗", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
                        Link("Anthropic rates ↗", destination: URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!)
                        Link("xAI rates ↗", destination: URL(string: "https://docs.x.ai/developers/pricing")!)
                        Spacer()
                        Text("Presets · Sep 7–8, 2026").foregroundStyle(Theme.muted)
                    }.font(.system(size: 10)).foregroundStyle(Theme.mint)
                }.padding(18).card()
            }
        }
    }
    private var periodPicker: some View {
        Menu {
            ForEach(TokenPeriod.allCases, id: \.self) { period in Button(period.rawValue) { store.preferences.apiTokenPeriod = period } }
        } label: { Label(store.preferences.apiTokenPeriod.rawValue, systemImage: "calendar").font(.system(size: 11)).foregroundStyle(Theme.muted) }.menuStyle(.borderlessButton).fixedSize()
    }
    private func providerCost(_ provider: Provider) -> some View {
        let estimate = store.estimate(for: provider)
        let cost = estimate.cost
        let usage = estimate.rows.reduce(TokenUsage()) { $0 + $1.usage }
        let available = store.history.available.contains(provider) && estimate.canDisplay
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) { ProviderMark(provider: provider).frame(width: 27, height: 27); Text(provider.title).font(.system(size: 13, weight: .semibold)); Spacer(); Text(available ? estimate.formatted : "—").font(.system(size: 19, weight: .medium, design: .rounded)).foregroundStyle(Theme.accent(provider)) }
            Text(store.preferences.pricingMode == .recordedModels ? "\(estimate.rows.count) recorded model\(estimate.rows.count == 1 ? "" : "s")" : store.preferences.rates(for: provider).name + " benchmark").font(.system(size: 10)).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 5) {
                costRow("Input · total", value: cost.totalInput, available: available)
                Text(Format.compact(usage.totalInput) + " tokens, including cache").font(.system(size: 9)).foregroundStyle(Theme.muted)
            }.help("All input: uncached tokens, new cache writes, and reused cache reads. Each component uses its own rate.")
            VStack(spacing: 9) {
                costRow("Uncached", value: cost.input, available: available, tokens: usage.input)
                    .help("Input that was neither read from cache nor written to cache. Claude reports only this portion as input_tokens.")
                costRow("Cache writes", value: cost.cacheWrite, available: available, tokens: usage.cacheWrite)
                    .help("New input stored in cache. Includes newly added prompts and context placed before the cache breakpoint.")
                costRow("Cache reads", value: cost.cacheRead, available: available, tokens: usage.cached)
                    .help("Input reused from cache across requests, charged at each model’s cache-read rate.")
            }.padding(.leading, 8).overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
            Rectangle().fill(Theme.line).frame(height: 1)
            costRow("Output", value: cost.output, available: available, tokens: usage.output)
        }.frame(maxWidth: .infinity).padding(18).card()
    }
    private func costRow(_ title: String, value: Double, available: Bool, tokens: Int? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Theme.muted).lineLimit(1)
            if let tokens { Text("· " + Format.compact(tokens)).font(.system(size: 8)).foregroundStyle(Theme.muted.opacity(0.8)).lineLimit(1).help("\(tokens.formatted()) tokens") }
            Spacer(minLength: 2)
            Text(available ? Format.money(value) : "—").monospacedDigit().fixedSize()
        }.font(.system(size: 10))
    }
}


struct ModelCostTable: View {
    let estimate: PriceEstimate
    @Binding var order: ModelOrder
    private var rows: [ModelCost] { estimate.ordered(by: order) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                eyebrow("MODEL BREAKDOWN")
                Spacer()
                Menu {
                    Picker("Order", selection: $order) {
                        ForEach(ModelOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) { Text("Order"); Text(order.rawValue).foregroundStyle(Theme.text); Image(systemName: "chevron.down").font(.system(size: 7)) }
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Order models by tokens used or by API value.").accessibilityLabel("Model order")
                Text("TOKENS").frame(width: 90, alignment: .trailing).foregroundStyle(order == .tokens ? Theme.text : Theme.muted)
                Text("API VALUE").frame(width: 90, alignment: .trailing).foregroundStyle(order == .apiValue ? Theme.text : Theme.muted)
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.muted)
            if rows.isEmpty { Text("Model usage appears here as local responses are recorded.").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            ForEach(rows) { row in
                HStack(spacing: 9) {
                    ProviderMark(provider: row.provider).frame(width: 23, height: 23)
                    Text(row.title).font(.system(size: 11, weight: .medium)).lineLimit(1).help(row.model)
                    Spacer()
                    Text(Format.compact(row.usage.total)).foregroundStyle(Theme.muted).frame(width: 90, alignment: .trailing)
                    Text(row.cost.map { Format.money($0.total) } ?? "Not priced").foregroundStyle(row.cost == nil ? Theme.orange : Theme.accent(row.provider)).frame(width: 90, alignment: .trailing)
                }.font(.system(size: 11)).help(row.rates.map { "Per 1M tokens: input \(Format.money($0.input)), output \(Format.money($0.output)), cache read \(Format.money($0.cacheRead)), cache write \(Format.money($0.cacheWrite)), 1-hour write \(Format.money($0.cacheWriteHour))." } ?? "No rate found for this model. Its tokens are excluded from the subtotal.")
            }
            if !estimate.isComplete {
                Text("Subtotal only · \(Format.compact(estimate.unpricedTokens)) tokens have no known rate.").font(.system(size: 10)).foregroundStyle(Theme.orange)
            }
        }.padding(18).card()
    }
}
