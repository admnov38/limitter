import Foundation

public struct WelcomeMessage: Sendable {
    public let title: String
    public let detail: String

    public init(activity: ActivitySummary, providers: [Provider], limits: [Provider: ProviderLimits], playful: Bool = true, tokens: Int = 0, now: Date = Date(), calendar: Calendar = .current) {
        let reading = Self.read(activity: activity, providers: providers, limits: limits, now: now)
        let facts = Facts(activity: activity, model: reading.model, tokens: max(0, tokens))
        if !playful {
            let factual = Self.factual(reading.situation, facts)
            title = factual.title
            detail = factual.detail
            return
        }
        let pool = Self.lines(for: reading.situation, facts: facts)
        let line = pool[Self.pickIndex(count: pool.count, now: now, situation: reading.situation, activity: activity, calendar: calendar)]
        title = line.title
        detail = line.detail(facts)
    }

    enum Situation: Int {
        case blocked, fast, modelCap, partial, fresh, nearly, busy, quiet, coasting, streak, everyday
    }

    static func classify(activity: ActivitySummary, providers: [Provider], limits: [Provider: ProviderLimits], now: Date = Date()) -> Situation {
        read(activity: activity, providers: providers, limits: limits, now: now).situation
    }

    static func titles(for situation: Situation, activity: ActivitySummary = .init(), model: String? = nil) -> [String] {
        lines(for: situation, facts: Facts(activity: activity, model: model, tokens: 0)).map(\.title)
    }

    static func details(for situation: Situation, activity: ActivitySummary, model: String? = nil, tokens: Int = 0) -> [String] {
        let facts = Facts(activity: activity, model: model, tokens: tokens)
        return lines(for: situation, facts: facts).map { $0.detail(facts) }
    }

    private struct Facts {
        var activity: ActivitySummary
        var model: String?
        var tokens: Int
        var responseText: String { activity.todayResponses.formatted() }
        var streakText: String { activity.currentStreak.formatted() }
        var modelName: String { model ?? "That model" }
        var multiplier: String {
            guard activity.previousDailyAverage > 0 else { return "0×" }
            return String(format: "%.1f×", Double(activity.todayResponses) / activity.previousDailyAverage)
        }
        var traffic: String {
            tokens > 0 ? "\(responseText) responses · \(Format.compact(tokens)) tokens" : "\(responseText) responses"
        }
    }

    private struct Banter {
        var title: String
        var detail: (Facts) -> String
    }

    private struct Reading {
        var situation: Situation
        var model: String?
    }

    private static func read(activity: ActivitySummary, providers: [Provider], limits: [Provider: ProviderLimits], now: Date) -> Reading {
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
        let fast = activity.available && activity.previousDailyAverage >= 10 && Double(activity.todayResponses) >= activity.previousDailyAverage * 1.6
        let situation: Situation
        if known && blocked == providers.count { situation = .blocked }
        else if fast { situation = .fast }
        else if cappedModel != nil { situation = .modelCap }
        else if blocked > 0 { situation = .partial }
        else if allFree { situation = .fresh }
        else if windows.flatMap({ $0 }).contains(where: { $0.usedPercent >= 90 }) { situation = .nearly }
        else if activity.available && activity.todayResponses >= 100 { situation = .busy }
        else if activity.available && activity.todayResponses == 0 { situation = .quiet }
        else if coasting(activity) { situation = .coasting }
        else if activity.currentStreak >= 3 { situation = .streak }
        else { situation = .everyday }
        return Reading(situation: situation, model: cappedModel)
    }

    private static func coasting(_ activity: ActivitySummary) -> Bool {
        activity.available && activity.todayResponses > 0 && activity.currentStreak >= 3 && activity.previousDailyAverage >= 10
            && Double(activity.todayResponses) < activity.previousDailyAverage * 0.5
    }

    private static func factual(_ situation: Situation, _ facts: Facts) -> (title: String, detail: String) {
        let pace = "\(facts.multiplier) your recent daily average · \(facts.responseText) responses today."
        let modelDetail = "\(facts.modelName)’s weekly limit is full. Check another model’s allowance."
        switch situation {
        case .blocked: return ("All providers have reached a limit.", facts.activity.factualHeadline)
        case .fast: return ("Activity is above your usual pace.", pace)
        case .modelCap: return ("A model allowance is exhausted.", modelDetail)
        case .partial: return ("A provider has reached a limit.", facts.activity.factualHeadline)
        case .fresh: return ("Your reported allowances are unused.", facts.activity.factualHeadline)
        case .nearly: return ("An allowance is nearly exhausted.", facts.activity.factualHeadline)
        case .busy: return ("A busy day of model activity.", facts.activity.factualHeadline)
        case .quiet: return ("No recorded responses today.", facts.activity.factualHeadline)
        case .coasting, .streak: return ("Your activity streak continues.", facts.activity.factualHeadline)
        case .everyday: return ("Your usage at a glance.", facts.activity.factualHeadline)
        }
    }

    private static func lines(for situation: Situation, facts: Facts) -> [Banter] {
        switch situation {
        case .blocked: return blockedLines()
        case .fast: return fastLines()
        case .modelCap: return modelLines()
        case .partial: return partialLines()
        case .fresh: return freshLines()
        case .nearly: return nearlyLines()
        case .busy: return busyLines()
        case .coasting: return coastingLines()
        case .quiet:
            if facts.activity.currentStreak >= 7 { return quietWeekLines() }
            if facts.activity.currentStreak >= 3 { return quietStreakLines() }
            return quietLines()
        case .streak:
            if facts.activity.currentStreak >= 14 { return streakLongLines() }
            if facts.activity.currentStreak >= 7 { return streakWeekLines() }
            return streakLines()
        case .everyday:
            if !facts.activity.available { return waitingLines() }
            if facts.activity.todayResponses < 10 { return lightLines() }
            if facts.activity.previousDailyAverage >= 10, Double(facts.activity.todayResponses) < facts.activity.previousDailyAverage * 0.5 { return slowLines() }
            return steadyLines()
        }
    }

    private static func pickIndex(count: Int, now: Date, situation: Situation, activity: ActivitySummary, calendar: Calendar) -> Int {
        guard count > 0 else { return 0 }
        let day = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        let mixed = day &* 1_048_583 &+ situation.rawValue &* 97 &+ responseBand(activity.todayResponses) &* 13 &+ streakBand(activity.currentStreak)
        let positive = mixed == Int.min ? 0 : abs(mixed)
        return positive % count
    }

    private static func responseBand(_ count: Int) -> Int {
        switch count {
        case ..<1: return 0
        case 1..<5: return 1
        case 5..<20: return 2
        case 20..<50: return 3
        case 50..<100: return 4
        case 100..<200: return 5
        default: return 6
        }
    }

    private static func streakBand(_ count: Int) -> Int {
        switch count {
        case ..<1: return 0
        case 1..<3: return 1
        case 3..<7: return 2
        case 7..<14: return 3
        case 14..<30: return 4
        default: return 5
        }
    }

    private static func blockedLines() -> [Banter] {
        [
            .init(title: "Touch some grass.") { _ in "Your quotas need a breather. You’ve earned one, too." },
            .init(title: "The tank is empty.") { _ in "Every allowance is full. The code will survive an hour without you." },
            .init(title: "Quota said absolutely not.") { _ in "All providers are tapped. Hydrate. Blink. Maybe eat." },
            .init(title: "You maxed every meter.") { _ in "Impressive, and also stop. Nothing left to spend." },
            .init(title: "The models need a nap.") { _ in "You used the entire quota. Somewhere a GPU just sighed." },
            .init(title: "That’s the whole budget.") { _ in "Limits are maxed. Go argue with a human for a bit." },
            .init(title: "Access denied, champion.") { _ in "No provider has room. Even the streak can wait." },
            .init(title: "Go outside. I’m serious.") { _ in "Every window is at the cap. Sunlight is still free." }
        ]
    }

    private static func fastLines() -> [Banter] {
        [
            .init(title: "You’re a machine today.") { "\($0.multiplier) your recent daily average · \($0.responseText) responses today." },
            .init(title: "Beast mode. Unfortunate.") { "\($0.multiplier) a normal day. \($0.traffic), and the keyboard would like a word." },
            .init(title: "Slow down. Or don’t.") { "\($0.multiplier) your usual pace. \($0.responseText) responses, and nobody asked you to stop." },
            .init(title: "The models are winded.") { "\($0.multiplier) your recent average. They did not agree to a marathon." },
            .init(title: "This is a lot, even for you.") { "\($0.responseText) responses, \($0.multiplier) your recent daily average." },
            .init(title: "Someone’s on a tear.") { "\($0.multiplier) pace. \($0.traffic). Bold of you to call this a side quest." },
            .init(title: "Pace like you mean it.") { "\($0.multiplier) the recent daily average. Try to land the plane." },
            .init(title: "Okay, sprinter.") { "\($0.multiplier) your usual day. \($0.responseText) responses. Hydrate between prompts." }
        ]
    }

    private static func modelLines() -> [Banter] {
        [
            .init(title: "Time for a change of engines.") { "\($0.modelName)’s weekly limit is full. Check another model’s allowance." },
            .init(title: "That model clocked out.") { "\($0.modelName) hit the weekly cap. It had a good run. Pick a colleague." },
            .init(title: "One model is done with you.") { "\($0.modelName) is at the weekly limit. The others are still taking appointments." },
            .init(title: "Swap the brain.") { "\($0.modelName) is spent for the week. Point the next prompt somewhere with room." },
            .init(title: "Weekly cap, meet reality.") { "\($0.modelName) has nothing left. This is a roster, not a monologue." },
            .init(title: "That engine is parked.") { "\($0.modelName)’s allowance is full. Try a different model before you start bargaining." }
        ]
    }

    private static func partialLines() -> [Banter] {
        [
            .init(title: "One engine down. Keep building.") { _ in "Check the other providers for room to continue." },
            .init(title: "We lost a provider.") { _ in "One limit is gone. Embarrassing, but you packed backups." },
            .init(title: "Not a total outage.") { _ in "A provider hit the wall. The others are still in the group chat." },
            .init(title: "Swap horses.") { _ in "One meter is maxed. Point the next prompt at someone with room." },
            .init(title: "One meter hit the wall.") { _ in "Not every allowance is gone. Use the ones still awake." },
            .init(title: "The bench is still warm.") { _ in "A provider is done. The rest of the roster showed up." }
        ]
    }

    private static func freshLines() -> [Banter] {
        [
            .init(title: "Let’s build something great.") { facts in
                facts.activity.todayResponses > 0 ? "Fresh quotas, and \(facts.traffic) already in the local logs." : "Fresh quotas. A blank canvas. What’s the first move?"
            },
            .init(title: "Full tanks. No excuses.") { _ in "Every allowance is untouched. The hard part is starting." },
            .init(title: "The quota is bored.") { _ in "Nothing spent yet. Give it a problem worth the tokens." },
            .init(title: "Clean slate. Don’t panic.") { _ in "Fresh limits across the board. Ship something small before the day gets loud." },
            .init(title: "All dressed up.") { _ in "Allowances are full and waiting. Rude to leave them standing there." },
            .init(title: "Zero spent. Suspicious.") { _ in "Not a single percent used. Your future self is already taking notes." },
            .init(title: "Fresh limits. Your move.") { _ in "The meters read empty. Spend the first prompt on something you’d show a person." },
            .init(title: "Unspent, and watching.") { _ in "Full quotas. A quiet log. The day is still willing to be interesting." }
        ]
    }

    private static func nearlyLines() -> [Banter] {
        [
            .init(title: "Make the next prompt count.") { facts in
                facts.activity.todayResponses >= 50 ? "Over 90% on a quota, with \(facts.traffic) today. Precision over volume." : "At least one quota is over 90% used. A little planning goes a long way."
            },
            .init(title: "The meter is squinting.") { _ in "Past 90% on a quota. Maybe don’t paste the whole repo this time." },
            .init(title: "Running on fumes.") { _ in "A limit is nearly gone. Spend the rest like it costs money, because it kind of does." },
            .init(title: "Last calls.") { _ in "Something is past 90%. Finish the thought, then get out." },
            .init(title: "Spend the rest carefully.") { _ in "One allowance is almost empty. Short prompts. Real questions." },
            .init(title: "Ninety percent is a warning.") { _ in "The meter is not being subtle. Make the next one good." },
            .init(title: "This is the expensive part.") { _ in "A quota is nearly spent. Volume was the morning. Aim is the rest." },
            .init(title: "Almost out. Act like it.") { _ in "Over 90% used. The models can tell when you’re stalling." }
        ]
    }

    private static func busyLines() -> [Banter] {
        [
            .init(title: "The keyboard is on fire.") { "\($0.responseText) responses today. That’s a lot of ideas in motion." },
            .init(title: "Do you live here now?") { "\($0.traffic). The models know your typing rhythm." },
            .init(title: "A hundred, casually.") { "\($0.responseText) model responses today. Touch grass later. Maybe." },
            .init(title: "The tab is your office.") { "\($0.responseText) responses. Somewhere a diff is begging to exist." },
            .init(title: "Okay, show-off.") { "\($0.traffic). Impressive. Slightly concerning." },
            .init(title: "Responses in bulk.") { "\($0.responseText) today. At least commit before you ask for another." },
            .init(title: "The models know your name.") { "\($0.responseText) responses. They stopped introducing themselves." },
            .init(title: "Busy day. Good problem.") { "\($0.traffic). Keep the last hour for the thing you actually meant to ship." }
        ]
    }

    private static func quietLines() -> [Banter] {
        [
            .init(title: "Your next idea starts here.") { _ in "Pick a small problem. Make something useful." },
            .init(title: "Zero. Interesting choice.") { _ in "No responses yet. The day is unclaimed, which is either peace or avoidance." },
            .init(title: "The models miss you.") { _ in "Local logs are quiet. One small prompt ends the silence." },
            .init(title: "Today is undecided.") { _ in "Nothing recorded yet. The blank page is not a personality." },
            .init(title: "No responses. Suspicious.") { _ in "Either you’re thinking, or you’re pretending to think." },
            .init(title: "The cursor is blinking.") { _ in "Zero responses. It can keep blinking. Or you can give it a job." },
            .init(title: "Silence. Bold strategy.") { _ in "No model replies today. Ambiguous. Slightly rude to the quota." },
            .init(title: "Blank page. Your move.") { _ in "Pick something small enough to finish and annoying enough to matter." }
        ]
    }

    private static func quietStreakLines() -> [Banter] {
        [
            .init(title: "Streak’s on the clock.") { "A \($0.streakText)-day streak, and today is still a zero. One response keeps it honest." },
            .init(title: "Don’t get cute today.") { "\($0.streakText) days in a row. Today hasn’t contributed a single response." },
            .init(title: "One response. That’s the toll.") { "The \($0.streakText)-day streak is alive. It would like proof you are too." },
            .init(title: "The streak believes in you.") { "\($0.streakText) days so far. Don’t make today the plot twist." },
            .init(title: "Absent, with a streak.") { "\($0.streakText) days of showing up, then a zero. Comedy, if you fix it." },
            .init(title: "Today still counts if you start.") { "A \($0.streakText)-day streak is waiting on one response. Cheap heroism." }
        ]
    }

    private static func quietWeekLines() -> [Banter] {
        [
            .init(title: "The streak is waiting.") { "\($0.streakText) days, and today is empty. Don’t get philosophical about it." },
            .init(title: "Don’t drop it now.") { "A \($0.streakText)-day streak. One reply is the whole assignment." },
            .init(title: "One reply saves the streak.") { "\($0.streakText) days in a row. Today is the one trying to be special." },
            .init(title: "A week of this, then nothing?") { "\($0.streakText) days deep and the log is blank. Suspicious timing." },
            .init(title: "The streak can hear you.") { "\($0.streakText) days. It does not accept “I thought about code” as a response." },
            .init(title: "Show up. It’s cheaper.") { "A \($0.streakText)-day run is on the line. The models are not even tired yet." }
        ]
    }

    private static func coastingLines() -> [Banter] {
        [
            .init(title: "The streak is carrying you.") { "\($0.streakText) days in a row, \( $0.responseText) responses. The habit is doing the heavy lifting." },
            .init(title: "Half speed, full history.") { "A \($0.streakText)-day streak and \( $0.traffic). Under your recent pace, and you know it." },
            .init(title: "Your average is concerned.") { "\($0.responseText) responses against a heavier usual day. The \($0.streakText)-day streak is unimpressed." },
            .init(title: "A light day on a long run.") { "\($0.streakText) days of showing up. Today’s \( $0.responseText) responses are the modest chapter." },
            .init(title: "Coasting. The streak noticed.") { "\($0.streakText) days, \( $0.responseText) responses. Presence without pace. Cute." },
            .init(title: "Under pace. Still here.") { "The \($0.streakText)-day streak survives. \( $0.traffic) is a lighter day than you’ve been living." }
        ]
    }

    private static func streakLines() -> [Banter] {
        [
            .init(title: "Look at you showing up.") { "\($0.streakText) days in a row · \($0.traffic) today." },
            .init(title: "Three days. Don’t fumble.") { "A \($0.streakText)-day streak. \($0.responseText) responses today. Keep the chain boring." },
            .init(title: "The streak is young.") { "\($0.streakText) days. \($0.traffic). This is the part where people get cocky." },
            .init(title: "Showing up is the trick.") { "\($0.streakText) days straight and \($0.responseText) responses today. That’s the whole craft." },
            .init(title: "Back again. Noted.") { "Day \($0.streakText). \($0.traffic). The log is starting to expect you." },
            .init(title: "Small streak, real one.") { "\($0.streakText) days in a row. \($0.responseText) responses. Don’t narrate it. Continue it." }
        ]
    }

    private static func streakWeekLines() -> [Banter] {
        [
            .init(title: "A week of this. Respect.") { "\($0.streakText) days in a row · \($0.traffic) today." },
            .init(title: "Seven days, still here.") { "A \($0.streakText)-day streak. \($0.responseText) responses. The bit is working." },
            .init(title: "The streak has a streak.") { "\($0.streakText) days. \($0.traffic). At this point it’s a habit, not a mood." },
            .init(title: "Weekly regular.") { "\($0.streakText) days straight. \($0.responseText) responses today. The models kept your seat." },
            .init(title: "You again. Good.") { "Day \($0.streakText). \($0.traffic). Consistency is the only flex that compounds." },
            .init(title: "Habit detected.") { "\($0.streakText) days and \($0.responseText) responses today. Annoying. Effective." }
        ]
    }

    private static func streakLongLines() -> [Banter] {
        [
            .init(title: "Two weeks of showing up.") { "\($0.streakText) days in a row · \($0.traffic) today." },
            .init(title: "The habit is the product.") { "A \($0.streakText)-day streak. \($0.responseText) responses. You kept the promise boring enough to last." },
            .init(title: "Streak’s getting smug.") { "\($0.streakText) days. \($0.traffic). Don’t let it write your personality." },
            .init(title: "You keep coming back.") { "Day \($0.streakText). \($0.responseText) responses. The impressive part is that it isn’t dramatic." },
            .init(title: "Consistency, the rare flex.") { "\($0.streakText) days straight. \($0.traffic). Most people negotiate with themselves by now." },
            .init(title: "At this point it’s a bit.") { "\($0.streakText) days. \($0.responseText) responses today. Commit to the bit. Also commit the code." }
        ]
    }

    private static func lightLines() -> [Banter] {
        [
            .init(title: "First sparks.") { "\($0.traffic). The day has a pulse. Don’t waste it on a tab you’ll forget." },
            .init(title: "A polite amount of work.") { "\($0.responseText) responses. Respectable start. The hard part is the second one." },
            .init(title: "We’ve confirmed you exist.") { "\($0.traffic). Hello. Now do the thing you opened the laptop for." },
            .init(title: "Started. That’s the miracle.") { "\($0.responseText) responses today. Starting was the expensive step." },
            .init(title: "Small day. Still counts.") { "\($0.traffic). Small is fine. Invisible is not." },
            .init(title: "Restraint. How novel.") { "Only \($0.responseText) responses. Either focus, or you’re warming up the excuse." },
            .init(title: "A few replies. A start.") { "\($0.traffic). Enough to prove the tools work. Not enough to hide in them." },
            .init(title: "The day has a pulse.") { "\($0.responseText) responses. Keep this one aimed at a real problem." }
        ]
    }

    private static func slowLines() -> [Banter] {
        [
            .init(title: "Today is half-speed.") { "\($0.traffic). Your recent days were louder than this." },
            .init(title: "Your average wants answers.") { "\($0.responseText) responses. Below the pace you’ve been keeping. Recovery, or hiding?" },
            .init(title: "Uncharacteristic chill.") { "\($0.traffic). You usually have more to say to the models." },
            .init(title: "Leaving runs on the table.") { "\($0.responseText) responses. The recent average remembers a busier version of this." },
            .init(title: "Recovery day, or hiding?") { "\($0.traffic). Both are allowed. Only one of them ships." },
            .init(title: "The pace fell off.") { "\($0.responseText) responses today. Not a crisis. Also not the story you’ve been telling." },
            .init(title: "Below your own bar.") { "\($0.traffic). You set that bar. It’s looking down." },
            .init(title: "Quiet, by your standards.") { "\($0.responseText) responses. A light day, measured against the ones you just had." }
        ]
    }

    private static func steadyLines() -> [Banter] {
        [
            .init(title: "Ideas are turning into things.") { "\($0.traffic) today. Ordinary, which is how the work actually gets done." },
            .init(title: "A normal day. Menace.") { "\($0.responseText) responses. Not famous. Still useful." },
            .init(title: "The work is happening.") { "\($0.traffic). Keep going. The diff will not write itself out of politeness." },
            .init(title: "Not famous. Still useful.") { "\($0.responseText) responses today. This is the unglamorous middle, which is the job." },
            .init(title: "Medium effort, full send.") { "\($0.traffic). A regular day. Dangerous words, because regular is how streaks sneak up." },
            .init(title: "You and the models, again.") { "\($0.responseText) responses. Same dance. Try to leave with something merged." },
            .init(title: "Respectable. Don’t stop.") { "\($0.traffic). Enough motion to matter. Don’t spend the rest of it renaming things." },
            .init(title: "This is what building looks like.") { "\($0.responseText) responses today. Unspectacular on purpose. Ship the unspectacular thing." }
        ]
    }

    private static func waitingLines() -> [Banter] {
        [
            .init(title: "Ready when inspiration hits.") { _ in "Waiting for local activity. Bring a real problem." },
            .init(title: "Nothing on the books.") { _ in "No local activity yet. The dashboard can wait. Your idea shouldn’t." },
            .init(title: "Give me a log to gossip about.") { _ in "Waiting on this Mac. Connect a provider, or at least touch a repo." },
            .init(title: "The silence is loud.") { _ in "No recorded responses. I can’t roast a pattern that refuses to exist." },
            .init(title: "Waiting on this Mac.") { _ in "Local logs are empty. The quotas, if you have them, are getting smug." },
            .init(title: "No local activity yet.") { _ in "Whenever you’re ready. Preferably with a smaller task than “rebuild everything.”" },
            .init(title: "Hook up a provider. Or don’t.") { _ in "Nothing to measure. Freedom, technically. Also a blank scoreboard." },
            .init(title: "Whenever you’re ready.") { _ in "Waiting for local activity. One honest prompt beats a perfect plan." }
        ]
    }
}
