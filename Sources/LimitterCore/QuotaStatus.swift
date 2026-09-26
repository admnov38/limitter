import Foundation

public struct QuotaPresentation: Sendable {
    public enum State: Sendable { case live, cached, expired, missing, error }
    public let state: State
    public let window: LimitWindow?
    public let message: String
    public let observedAt: Date?
    public var hasValue: Bool { state == .live || state == .cached }
    public var label: String {
        switch state { case .live: return "UPDATED"; case .cached: return "LAST KNOWN"; case .expired: return "WINDOW ENDED"; case .missing: return "NOT REPORTED"; case .error: return "SYNC ERROR" }
    }
    public init(provider: Provider, snapshot: ProviderLimits?, period: QuotaPeriod, now: Date = Date(), bucketID: String? = nil) {
        let bucket = bucketID.flatMap { id in snapshot?.buckets.first { $0.id == id } }
        window = (bucketID == nil ? snapshot?.windows : bucket?.windows)?.first(where: period.matches)
        observedAt = window?.observedAt ?? snapshot?.updatedAt
        if let error = snapshot?.error ?? bucket?.error ?? (bucketID == nil ? snapshot?.windowErrors[period.rawValue] : nil) {
            state = .error; message = error; return
        }
        guard let window else {
            state = .missing
            if let bucket { message = "Claude hasn’t reported a current \(bucket.name) allowance."; return }
            message = provider == .grok ? (snapshot?.quotaNote ?? "Grok reports a shared weekly subscription pool. Sign in with Grok Build and refresh to receive it.") : provider == .claude
                ? (period == .session ? "Claude hasn’t reported an active 5-hour window. It can disappear after reset; updates arrive from Claude Code." : "Claude hasn’t reported a weekly window yet. Updates arrive from Claude Code.")
                : "This account hasn’t reported a \(period.rawValue.lowercased()) window."
            return
        }
        if window.hasExpired(at: now) {
            state = .expired
            message = provider == .claude ? "Window ended. Waiting for Claude Code’s next quota update." : "Window ended. Refresh to fetch the new allowance."
        } else if let observedAt, now.timeIntervalSince(observedAt) >= -60, now.timeIntervalSince(observedAt) <= 600 {
            state = .live; message = "Last reported " + observedAt.formatted(date: .abbreviated, time: .shortened)
        } else if provider == .claude, let observedAt, observedAt <= now, window.resetsAt != nil {
            // Claude pushes updates during activity. Keep a dated, explicitly cached value until its window ends.
            state = .cached; message = "Last known quota from " + observedAt.formatted(date: .abbreviated, time: .shortened) + ". Awaiting a newer Claude Code update."
        } else {
            state = .missing; message = "Waiting for a fresh quota update."
        }
    }
}
