import SwiftUI
import LimitterCore

enum Theme {
    private static func adaptive(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
    static let background = adaptive(dark: (0.055, 0.065, 0.078), light: (0.955, 0.965, 0.965))
    static let surface = adaptive(dark: (0.088, 0.100, 0.114), light: (1, 1, 1))
    static let text = adaptive(dark: (0.91, 0.93, 0.94), light: (0.11, 0.15, 0.17))
    static let muted = adaptive(dark: (0.49, 0.53, 0.57), light: (0.39, 0.44, 0.47))
    static let mint = adaptive(dark: (0.65, 0.94, 0.77), light: (0.12, 0.47, 0.32))
    static let orange = adaptive(dark: (0.89, 0.65, 0.49), light: (0.65, 0.34, 0.17))
    static let blue = adaptive(dark: (0.59, 0.74, 0.99), light: (0.20, 0.39, 0.72))
    static let line = text.opacity(0.08)
    static func accent(_ provider: Provider) -> Color { switch provider { case .codex: return mint; case .claude: return orange; case .grok: return blue } }
}

extension AppTheme {
    var colorScheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
    var appearance: NSAppearance? { self == .system ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
}

struct MenuBarPreview: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { eyebrow("YOUR MENU BAR"); Spacer(); Text(store.demo ? "SAMPLE DATA" : "LIVE PREVIEW").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(Theme.muted) }
            HStack(spacing: 10) {
                if store.preferences.showMenuIcon || !store.preferences.showMenuUsage {
                    if store.preferences.menuMetric == .tokens { Image(systemName: "chart.bar.fill").font(.system(size: 14)) }
                    else { MenuGauge(readings: store.menuReadings).frame(height: 17) }
                }
                if !store.menuLabel.isEmpty { Text(store.menuLabel).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7) }
                Spacer(minLength: 12)
                Image(systemName: "wifi").font(.system(size: 12))
                Image(systemName: "battery.100percent").font(.system(size: 18))
                Text("9:41").font(.system(size: 12, weight: .medium))
            }.foregroundStyle(Theme.text).padding(.horizontal, 16).padding(.vertical, 14)
                .background(Theme.text.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            Text(store.preferences.menuMetric == .tokens ? "CX = Codex · CL = Claude · GK = Grok. Token totals are local to this Mac." : "CX = Codex · CL = Claude · GK = Grok. S = session · W = weekly. A dash means current data is unavailable.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }.padding(18).card()
    }
}

struct MenuGauge: View {
    let readings: [MenuReading]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                ZStack {
                    Circle().stroke(Theme.text.opacity(0.16), lineWidth: 2)
                    if let used = reading.usedPercent {
                        Circle().trim(from: 0, to: min(100, used) / 100).stroke(Theme.text, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                    } else { Circle().fill(Theme.muted).frame(width: 3, height: 3) }
                }.frame(width: 14, height: 14)
            }
        }.help("Rings show quota consumed")
    }
}
