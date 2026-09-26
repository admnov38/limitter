import AppKit
import SwiftUI
import Combine
import LimitterCore

final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: HoverPanel!
    private var settingsWindow: NSWindow?
    private var appliedTheme: AppTheme?
    private var tracking: NSTrackingArea?
    private var pollTimer: Timer?
    private var lastInside = Date()
    private var openWork: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()
    private var monitors: [Any] = []
    let store = UsageStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = store.preferences.theme.appearance
        appliedTheme = store.preferences.theme
        store.onOpenSettings = { [weak self] in self?.showSettings() }
        configureApplicationMenu()
        store.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = menuImage()
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.target = self; button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Limitter · AI usage at a glance"
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        button.addTrackingArea(tracking!)
        panel = HoverPanel(contentRect: NSRect(x: 0, y: 0, width: DashboardLayout.width, height: DashboardLayout.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.title = "Limitter"
        panel.contentView = NSHostingView(rootView: DashboardView(store: store))
        store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateMenu() }
        }.store(in: &subscriptions)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.store.pinned else { return }
                if !self.isPointerInside() { self.hide() }
            }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53, NSApp.keyWindow === self?.panel { self?.store.pinned = false; self?.hide(); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "r" { self?.store.refresh(force: true); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," { self?.showSettings(); return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" { NSApp.terminate(nil); return nil }
            return event
        } as Any)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        updateMenu()
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.indices.contains(index + 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.renderPreview(path: CommandLine.arguments[index + 1])
            }
        } else if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.show(activate: true) }
        } else if store.preferences.showSettingsOnLaunch && !CommandLine.arguments.contains("--background") {
            DispatchQueue.main.async { self.showSettings() }
        }
        if CommandLine.arguments.contains("--verify-ui") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.verifyWindowBehavior() }
        }
    }
    @objc private func wake() { store.refresh(force: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    @objc private func clicked() {
        openWork?.cancel()
        if NSApp.currentEvent?.type == .rightMouseUp {
            showSettings()
        } else if panel.isVisible { store.pinned = false; hide() }
        else { show(activate: true) }
    }
    @objc func mouseEntered(with event: NSEvent) {
        guard store.preferences.hoverToOpen, !panel.isVisible else { return }
        openWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(activate: false) }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    @objc func mouseExited(with event: NSEvent) { openWork?.cancel() }
    private func show(activate: Bool) {
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main!
        let height = min(DashboardLayout.height, screen.visibleFrame.height - 16)
        (panel.contentView as? NSHostingView<DashboardView>)?.rootView = DashboardView(store: store, height: height)
        panel.setContentSize(NSSize(width: DashboardLayout.width, height: height))
        let x = min(max(anchor.midX - DashboardLayout.width / 2, screen.visibleFrame.minX + 10), screen.visibleFrame.maxX - DashboardLayout.width - 10)
        let y = max(screen.visibleFrame.minY + 8, anchor.minY - height - 6)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        if activate { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
        lastInside = Date()
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkPointer() }
            }
        }
        store.refresh()
    }
    private func hide() { panel.orderOut(nil); pollTimer?.invalidate(); pollTimer = nil }
    private func isPointerInside() -> Bool {
        let pointer = NSEvent.mouseLocation
        if panel.isVisible && panel.frame.insetBy(dx: -5, dy: -9).contains(pointer) { return true }
        if let button = statusItem.button, let window = button.window {
            return window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -3, dy: -3).contains(pointer)
        }
        return false
    }
    private func checkPointer() {
        guard panel.isVisible, !store.pinned else { return }
        if isPointerInside() { lastInside = Date() }
        else if Date().timeIntervalSince(lastInside) > 0.5 { hide() }
    }
    private func updateMenu() {
        if appliedTheme != store.preferences.theme {
            NSApp.appearance = store.preferences.theme.appearance
            appliedTheme = store.preferences.theme
        }
        statusItem.button?.image = store.preferences.showMenuIcon || !store.preferences.showMenuUsage ? menuImage() : nil
        statusItem.button?.title = store.menuLabel.isEmpty ? "" : " " + store.menuLabel
        statusItem.button?.toolTip = store.menuTooltip
        statusItem.button?.setAccessibilityLabel("Limitter usage")
        statusItem.button?.setAccessibilityValue(store.menuTooltip)
    }
    private func menuImage() -> NSImage {
        if store.preferences.menuMetric != .tokens {
            let readings = store.menuReadings
            let image = NSImage(size: NSSize(width: readings.count * 20 - 2, height: 18), flipped: false) { _ in
                for (index, reading) in readings.enumerated() {
                    let center = NSPoint(x: 8 + index * 20, y: 9)
                    let circle = NSBezierPath(ovalIn: NSRect(x: center.x - 6, y: 3, width: 12, height: 12))
                    NSColor.white.withAlphaComponent(0.25).setStroke(); circle.lineWidth = 2; circle.stroke()
                    NSColor.white.setStroke()
                    if let used = reading.usedPercent, used > 0 {
                        let arc = NSBezierPath(); arc.lineWidth = 2; arc.lineCapStyle = .round
                        arc.appendArc(withCenter: center, radius: 6, startAngle: 90, endAngle: 90 - CGFloat(min(100, used)) * 3.6, clockwise: true)
                        arc.stroke()
                    } else if reading.usedPercent == nil {
                        NSColor.white.withAlphaComponent(0.6).setFill()
                        NSBezierPath(ovalIn: NSRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2)).fill()
                    }
                }
                return true
            }
            image.isTemplate = true; return image
        }
        let image = NSImage(size: NSSize(width: 19, height: 18), flipped: false) { rect in
            NSColor.white.setFill()
            for (x, height) in [(2.0, 8.0), (7.5, 15.0), (13.0, 11.0)] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: 3.5, height: height), xRadius: 1.75, yRadius: 1.75).fill()
            }
            return true
        }
        image.isTemplate = true; return image
    }
    @objc private func showSettings() {
        openWork?.cancel(); store.pinned = false; hide()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Limitter Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 850, height: 640)
            window.contentView = NSHostingView(rootView: SettingsWindowView(store: store).ignoresSafeArea())
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private func configureApplicationMenu() {
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu(title: "Limitter")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem(title: "Hide Limitter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Limitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
    }
    private func renderPreview(path: String) {
        if CommandLine.arguments.contains("--preview-activity") { store.page = .activity }
        if CommandLine.arguments.contains("--preview-costs") { store.page = .costs }
        if CommandLine.arguments.contains("--preview-mixed") { store.preferences.setQuotaPeriod(.weekly, for: .codex); store.preferences.setQuotaPeriod(.session, for: .claude) }
        if CommandLine.arguments.contains("--preview-grok") { store.selectedProvider = .grok }
        if CommandLine.arguments.contains("--preview-grok-missing") {
            store.limits[.grok]?.buckets = []
            store.limits[.grok]?.quotaNote = "Grok hasn’t reported a percentage used. Resets in 3d 4h."
        }
        if CommandLine.arguments.contains("--preview-claude-partial") {
            store.preferences.setQuotaPeriod(.session, for: .claude)
            var snapshot = store.limits[.claude]!
            snapshot.buckets = [.init(id: "claude", name: "All models", windows: snapshot.windows.filter { $0.durationMinutes == 10080 })]
            store.limits[.claude] = snapshot
        }
        if CommandLine.arguments.contains("--preview-claude-cached") { store.limits[.claude]?.updatedAt = Date().addingTimeInterval(-900) }
        let settings = CommandLine.arguments.contains("--preview-settings")
        for section in UsageStore.SettingsSection.allCases where CommandLine.arguments.contains("--section=" + section.id.lowercased().replacingOccurrences(of: " ", with: "-")) { store.settingsSection = section }
        if settings { showSettings() }
        else { panel.setFrame(NSRect(x: 0, y: 0, width: DashboardLayout.width, height: DashboardLayout.height), display: true); panel.orderFrontRegardless() }
        let window = settings ? settingsWindow! : panel!
        guard let view = window.contentView else { NSApp.terminate(nil); return }
        view.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            window.displayIfNeeded()
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
            }
            print("Rendered \(settings ? "settings window" : "usage panel") · \(Int(view.bounds.width))×\(Int(view.bounds.height)) · \(self.store.preferences.theme.rawValue)")
            print("Menu bar: \(self.statusItem.button?.title ?? "")")
            NSApp.terminate(nil)
        }
    }
    private func verifyWindowBehavior() {
        func require(_ condition: Bool, _ message: String) {
            if !condition { fputs("UI verification failed: " + message + "\n", stderr); exit(1) }
        }
        require(settingsWindow?.isVisible == true, "Settings should open on launch")
        require(NSApp.activationPolicy() == .regular, "Settings must be a normal app window")
        settingsWindow?.performClose(nil)
        require(settingsWindow?.isVisible == false && NSApp.activationPolicy() == .accessory, "Closing settings should leave a menu bar app")
        require(!applicationShouldTerminateAfterLastWindowClosed(NSApp), "Closing the window must not quit")
        showSettings()
        require(settingsWindow?.isVisible == true, "Settings must reopen")
        store.preferences.theme = .light
        store.preferences.menuMetric = .used
        store.preferences.menuQuotaPeriod = .session
        store.preferences.menuProviders = .codex
        updateMenu()
        require(NSApp.appearance?.name == .aqua, "Theme must update the running app")
        require(statusItem.button?.title.contains("CX S 32%") == true, "The actual menu bar must display the selected metric")
        store.preferences.menuProviders = .both
        store.preferences.setQuotaPeriod(.weekly, for: .codex)
        store.preferences.setQuotaPeriod(.session, for: .claude)
        updateMenu()
        require(statusItem.button?.title.contains("CX W 58%") == true && statusItem.button?.title.contains("CL S 74%") == true, "Provider timeframes must be independent in the actual menu bar")
        store.preferences.menuProviders = .all
        updateMenu()
        require(statusItem.button?.title.contains("GK W 27%") == true, "Grok weekly quota must appear in the actual menu bar")
        store.preferences.setTokenPeriod(.month, for: .grok)
        require(store.preferences.tokenPeriod(for: .codex) == .today && store.preferences.quotaPeriod(for: .claude) == .session, "Grok controls must preserve other provider periods")
        store.selectedProvider = .grok
        require(store.overviewUsage.total == 165800 && store.currentSession?.provider == .grok && store.heatmap.days.count == 84, "Grok filtering must populate tokens, sessions, and heatmap")
        store.selectedProvider = nil
        require(store.currentSession?.state() == .running, "The current session should prefer a fresh running session")
        require(store.apiCost > 0 && store.history.days.count == 84, "API equivalent and 12-week activity should be populated")
        let claudePrice = store.estimate(for: .claude, days: 1)
        require(claudePrice.isComplete && claudePrice.rows.count == 4 && claudePrice.totalTokens == 301800, "Claude pricing must include both Opus and Fable versions without losing tokens")
        let fable = QuotaPresentation(provider: .claude, snapshot: store.limits[.claude], period: .weekly, bucketID: "model:fable")
        require(fable.hasValue && fable.window?.usedPercent == 100 && store.preferences.quotaPeriod(for: .claude) == .session, "Fable’s weekly cap must remain independent of Claude’s selected session quota")
        store.preferences.showMenuIcon = false
        updateMenu()
        require(statusItem.button?.image == nil, "The icon can be hidden while numbers remain visible")
        store.preferences.showMenuUsage = false
        updateMenu()
        require(statusItem.button?.image != nil, "An accessible icon must remain when numbers are hidden")
        store.selectedProvider = .codex
        store.preferences.showCodex = false
        require(store.providers == [.claude, .grok] && store.activityUsage.total == 467600, "Hiding Codex must retain Claude and Grok only")
        store.preferences.showGrok = false
        require(store.providers == [.claude] && store.activityUsage.total == 301800, "Hiding a selected provider must exclude its tokens")
        let todayTokens = store.overviewUsage.total
        let todayCost = store.overviewCost
        let todayResponses = store.overviewCounts.requests
        store.preferences.apiTokenPeriod = .week
        store.page = .costs
        require(store.apiCost > todayCost, "API Value must use its own weekly selection")
        store.page = .overview
        require(store.overviewUsage.total == todayTokens && store.overviewCost == todayCost && store.overviewCounts.requests == todayResponses, "Overview must stay on today after changing API Value")
        require(store.overviewHours.allSatisfy { Calendar.current.isDateInToday($0.date) }, "Overview chart must contain today’s hours only")
        store.preferences.tokenPeriod = .month
        store.preferences.chartPeriod = .month
        require(store.overviewUsage.total == todayTokens && store.preferences.apiTokenPeriod == .week, "Activity controls must not affect Overview or API Value")
        require(store.activityUsage.total > 301800 && store.activityDays.count == 30, "Timeframes must change totals and chart data")
        print("Native UI checks passed: launch, close, reopen, live theme, menu readout, icon fallback, hidden providers, Grok integration, independent page/provider periods, today-only Overview, current session, mixed Opus/Fable pricing, Fable weekly cap, and 84-day activity. No preferences were saved.")
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        monitors.forEach { NSEvent.removeMonitor($0) }
    }
}

@main
enum LimitterMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--capture-claude") { ClaudeConnector.capture(); return }
        if CommandLine.arguments.contains("--install-claude-connector") {
            do { try ClaudeConnector.install(executable: URL(fileURLWithPath: CommandLine.arguments[0])); print("Claude connector installed. Claude Code reloads settings automatically; usage arrives when reported.") }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--remove-claude-connector") {
            do { try ClaudeConnector.uninstall(); print("Previous Claude status line restored.") }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--diagnose-claude") {
            let snapshot = ClaudeConnector.read()
            print("Claude connector: \(ClaudeConnector.isInstalled ? "installed" : "not installed")")
            for period in QuotaPeriod.allCases {
                let status = QuotaPresentation(provider: .claude, snapshot: snapshot, period: period)
                print(period.rawValue + ": " + status.label + (status.hasValue ? " · \(Format.percent(status.window!.usedPercent))% used" : "") + " · " + status.message)
            }
            return
        }
        if CommandLine.arguments.contains("--diagnose-claude-account") {
            Task {
                do {
                    let snapshot = try await Task.detached { try ClaudeUsageConnection().fetch() }.value
                    print("Claude account: " + (snapshot.plan ?? "plan not reported"))
                    for bucket in snapshot.buckets {
                        let periods: [QuotaPeriod] = bucket.id == "claude" ? [.session, .weekly] : [.weekly]
                        for period in periods {
                            let status = QuotaPresentation(provider: .claude, snapshot: snapshot, period: period, bucketID: bucket.id)
                            print(bucket.name + " · " + period.rawValue + ": " + status.label + (status.hasValue ? " · \(Format.percent(status.window!.usedPercent))% used" : "") + " · " + status.message)
                        }
                    }
                    if let error = snapshot.error { fputs(error + "\n", stderr) }
                    exit(snapshot.error == nil ? 0 : 1)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--diagnose-claude-combined") {
            Task {
                do {
                    let status = ClaudeConnector.read()
                    let account = try await Task.detached { try ClaudeUsageConnection().fetch() }.value
                    let merged = ClaudeQuotaSources.combine(account: account, statusLine: status)
                    func dump(label: String, snapshot: ProviderLimits) {
                        print("[" + label + "] buckets=" + String(snapshot.buckets.count) + " plan=" + (snapshot.plan ?? "n/a") + " error=" + (snapshot.error ?? "nil") )
                        for bucket in snapshot.buckets {
                            let windows = bucket.windows.map { win in "\(win.id):\(win.durationMinutes ?? -1):used\(win.usedPercent)" }.joined(separator: ", ")
                            print("  bucket " + bucket.id + " name=" + bucket.name + " windows=[" + windows + "]" + (bucket.error == nil ? "" : " err=" + bucket.error!))
                        }
                        if let modelError = snapshot.modelLimitsError { print("  modelLimitsError=" + modelError) }
                    }
                    dump(label: "status", snapshot: status)
                    dump(label: "account", snapshot: account)
                    dump(label: "merged", snapshot: merged)
                    exit(0)
                } catch {
                    fputs(error.localizedDescription + "\n", stderr)
                    exit(1)
                }
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--diagnose-pricing") {
            Task {
                let now = Date(), history = await HistoryReader().read(dayCount: 84)
                if let live = try? await PriceSources.fetch() { PriceCatalog.shared.install(live) }
                else if let cached = PriceSources.loadCache() { PriceCatalog.shared.install(cached) }
                var output: [[String: Any]] = []
                for provider in Provider.allCases {
                    let estimate = PriceEstimate(usage: history.modelUsage(dayCount: 30, provider: provider, now: now), provider: provider, preferences: AppPreferences())
                    output.append(["provider": provider.rawValue, "days": 30, "total_tokens": estimate.totalTokens, "unpriced_tokens": estimate.unpricedTokens, "usd": estimate.cost.total,
                                   "models": estimate.rows.map { row -> [String: Any] in
                        ["model": row.model, "tokens": row.usage.total, "input": row.usage.input, "output": row.usage.output, "cache_read": row.usage.cached, "cache_write": row.usage.cacheWrite, "cache_write_1h": row.usage.cacheWriteHour, "usd": row.cost.map { $0.total as Any } ?? NSNull()]
                    }])
                }
                if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), let json = String(data: data, encoding: .utf8) { print(json) }
                exit(0)
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--diagnose-grok") {
            Task {
                do {
                    let snapshot = try await Task.detached { try GrokConnection().fetch() }.value
                    let status = QuotaPresentation(provider: .grok, snapshot: snapshot, period: .weekly)
                    print("Grok account: connected · " + (snapshot.plan ?? "plan not reported"))
                    print("Weekly: " + status.label + (status.hasValue ? " · \(Format.percent(status.window!.usedPercent))% used" : "") + " · " + status.message)
                    let history = await HistoryReader().read(dayCount: 84, providers: [.grok])
                    print("Grok history: \(history.records[.grok]?.count ?? 0) completed turns · \(history.total(dayCount: 84, providers: [.grok]).total) tokens · \(history.activityCounts(dayCount: 84, providers: [.grok]).requests) responses in 84 days")
                    exit(snapshot.error == nil ? 0 : 1)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--diagnose") {
            Task {
                let history = await HistoryReader().read(dayCount: 84)
                print("History: \(history.available.map(\.title).sorted().joined(separator: ", "))")
                for provider in Provider.allCases { print("\(provider.title): \(history.total(for: provider).total) tokens today, \(history.sessions[provider] ?? 0) sessions") }
                print("Activity: \(history.days.count) days, \(history.recentSessions.count) tracked sessions, \(history.recentSessions.filter { $0.state().isActive }.count) recently active")
                let result = await Task.detached { try? CodexConnection().fetch() }.value
                print("Codex limits: \(result?.buckets.count ?? 0) buckets")
                print("Claude connector: \(ClaudeConnector.isInstalled ? "installed" : "not installed")")
                let grok = await Task.detached { try? GrokConnection().fetch() }.value
                print("Grok account: " + (grok?.updatedAt != nil ? "connected" : "unavailable"))
                print("Grok history: \(history.records[.grok]?.count ?? 0) completed turns, \(history.total(dayCount: 84, providers: [.grok]).total) tokens in 84 days")
                var limits: [Provider: ProviderLimits] = result.map { [.codex: $0, .claude: ClaudeConnector.read()] } ?? [.claude: ClaudeConnector.read()]
                limits[.grok] = grok
                let defaults = AppPreferences()
                print("Default menu bar: " + MenuBarFormatter.label(preferences: defaults, readings: MenuBarFormatter.readings(preferences: defaults, limits: limits, history: history)))
                exit(result == nil ? 1 : 0)
            }
            RunLoop.main.run(); return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
