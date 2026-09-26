import Foundation

public struct WelcomeMessage: Sendable {
    public let title: String
    public let detail: String

    public init(activity: ActivitySummary, providers: [Provider], limits: [Provider: ProviderLimits], playful: Bool = true, now: Date = Date()) {
        let windows = providers.map { provider in
            provider.quotaPeriods.compactMap { period -> LimitWindow? in
                let status = QuotaPresentation(provider: provider, snapshot: limits[provider], period: period, now: now)
                return status.state == .live ? status.window : nil
            }
        }
        let known = !providers.isEmpty && windows.allSatisfy { !$0.isEmpty }
        let blocked = windows.filter { $0.contains { $0.usedPercent >= 100 } }.count
        let allFree = known && windows.flatMap { $0 }.allSatisfy { $0.usedPercent == 0 }
            && providers.allSatisfy { provider in
                guard let snapshot = limits[provider], snapshot.modelLimitsError == nil else { return false }
                return snapshot.buckets.dropFirst().allSatisfy { bucket in
                    let status = QuotaPresentation(provider: provider, snapshot: snapshot, period: .weekly, now: now, bucketID: bucket.id)
                    return status.state == .live && status.window?.usedPercent == 0
                }
            }
        let cappedModel = providers.lazy.compactMap { provider -> String? in
            limits[provider]?.buckets.dropFirst().first { bucket in
                let status = QuotaPresentation(provider: provider, snapshot: limits[provider], period: .weekly, now: now, bucketID: bucket.id)
                return status.state == .live && (status.window?.usedPercent ?? 0) >= 100
            }?.name
        }.first
        let fast = activity.available && activity.previousDailyAverage >= 10
            && Double(activity.todayResponses) >= activity.previousDailyAverage * 1.6
        let title: String
        let detail: String
        if known && blocked == providers.count {
            title = playful ? "Touch some grass." : "All providers have reached a limit."
            detail = "Your quotas need a breather. You’ve earned one, too."
        } else if fast {
            title = playful ? "You’re a machine today." : "Activity is above your usual pace."
            detail = String(format: "%.1f× your recent daily average · %@ responses today.", Double(activity.todayResponses) / activity.previousDailyAverage, activity.todayResponses.formatted())
        } else if let model = cappedModel {
            title = playful ? "Time for a change of engines." : "A model allowance is exhausted."
            detail = "\(model)’s weekly limit is full. Check another model’s allowance."
        } else if blocked > 0 {
            title = playful ? "One engine down. Keep building." : "A provider has reached a limit."
            detail = "Check the other providers for room to continue."
        } else if allFree {
            title = playful ? "Let’s build something great." : "Your reported allowances are unused."
            detail = "Fresh quotas. A blank canvas. What’s the first move?"
        } else if windows.flatMap({ $0 }).contains(where: { $0.usedPercent >= 90 }) {
            title = playful ? "Make the next prompt count." : "An allowance is nearly exhausted."
            detail = "At least one quota is over 90% used. A little planning goes a long way."
        } else if activity.available && activity.todayResponses >= 100 {
            title = playful ? "The keyboard is on fire." : "A busy day of model activity."
            detail = "\(activity.todayResponses.formatted()) responses today. That’s a lot of ideas in motion."
        } else if activity.available && activity.todayResponses == 0 {
            title = playful ? "Your next idea starts here." : "No recorded responses today."
            detail = activity.currentStreak >= 3 ? "A \(activity.currentStreak)-day streak. Ready for the next chapter?" : "Pick a small problem. Make something useful."
        } else if activity.currentStreak >= 3 {
            title = playful ? "Look at you showing up." : "Your activity streak continues."
            detail = "\(activity.currentStreak) days in a row · \(activity.todayResponses.formatted()) responses today."
        } else {
            title = playful ? (activity.todayResponses > 0 ? "Ideas are turning into things." : "Ready when inspiration hits.") : "Your usage at a glance."
            detail = activity.factualHeadline
        }
        self.title = title
        self.detail = playful ? detail : (fast || cappedModel != nil ? detail : activity.factualHeadline)
    }
}
