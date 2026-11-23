import Foundation

public enum Format {
    /// Rounds down, so 99.6% reads as 99% and "100%" only ever means used up.
    public static func percent(_ value: Double?) -> String {
        guard let whole = wholePercent(value) else { return "—" }
        return "\(whole)%"
    }

    /// A percentage as a whole number that can't trap: finite, clamped to 0–1000, and nudged
    /// so floating-point noise (0.29 × 100 = 28.999…) doesn't round down a whole point.
    static func wholePercent(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int((min(max(value, 0), 1000) + 1e-9).rounded(.down))
    }

    /// "Resets in 42m", "Resets in 3h 5m", "Resets tomorrow 05:00" or "Resets Wed 05:00".
    public static func reset(
        _ date: Date?,
        now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let date, date > now, let minutes = minutesUntil(date, from: now) else { return nil }
        if minutes < 60 {
            return "Resets in \(minutes)m"
        }
        if minutes < 24 * 60 {
            return "Resets in \(minutes / 60)h \(minutes % 60)m"
        }
        let rounded = roundedToMinute(date)
        if isTomorrow(rounded, now: now, timeZone: timeZone) {
            return "Resets tomorrow \(time(rounded, locale: locale, timeZone: timeZone))"
        }
        // A weekday alone is ambiguous six or more days out ("Wed" could be today or next week).
        let template = minutes < 6 * 24 * 60 ? "EEEjjmm" : "EEEdMMMjjmm"
        return "Resets \(Formatters.date(template, locale: locale, timeZone: timeZone).string(from: rounded))"
    }

    /// The line under a row's bar: when it resets and whether usage is keeping pace, e.g.
    /// "Resets Wed 05:00 · ahead of pace", or why there's nothing to show.
    public static func caption(
        _ row: LimitRow,
        now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        if let reset = reset(row.resetsAt, now: now, locale: locale, timeZone: timeZone) {
            return [reset, pace(row.pace(at: now))].compactMap { $0 }.joined(separator: " · ")
        }
        guard row.percent == nil else { return nil }
        return row.id == "session" ? "Starts with your next message" : "No usage yet"
    }

    /// A row's title for VoiceOver, e.g. "Weekly, Fable" rather than reading out the "·".
    public static func spokenTitle(_ row: LimitRow) -> String {
        spokenTitle(row.title)
    }

    public static func spokenTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "Session (5h)", with: "5-hour session")
            .replacingOccurrences(of: " · ", with: ", ")
    }

    /// A row's value for VoiceOver, e.g. "Nearly used up, 94 percent used, 60 percent of the
    /// week gone, resets in 3 hours, 5 minutes". Says so when the numbers are out of date.
    public static func spokenValue(
        _ row: LimitRow,
        stale: Bool = false,
        now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let percent = row.percent else {
            return caption(row, now: now, locale: locale, timeZone: timeZone) ?? "No usage yet"
        }
        var parts: [String] = []
        switch row.severity {
        case .critical: parts.append(percent >= 100 ? "Limit reached" : "Nearly used up")
        case .warning: parts.append("Getting high")
        case .normal: break
        }
        parts.append("\(wholePercent(percent) ?? 0) percent used")
        if let elapsed = row.elapsedFraction(at: now) {
            parts.append("\(Int((elapsed * 100).rounded())) percent of the \(spokenWindow(row.windowLength)) gone")
        }
        if let pace = pace(row.pace(at: now)) {
            parts.append(pace)
        }
        if let resetsAt = row.resetsAt, resetsAt > now, let reset = spokenReset(resetsAt, now: now, locale: locale, timeZone: timeZone) {
            parts.append(reset)
        }
        if stale {
            parts.append("out of date")
        }
        return parts.joined(separator: ", ")
    }

    /// What to tell people when a service's numbers may be out of date, and what happens next.
    public static func problem(_ problem: Problem, service: Service, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch problem {
        case .tokenExpired:
            return "Login expired. Run \(service.loginTool) to renew it."
        case let .rateLimited(until):
            return "Too many requests. Retrying at \(time(until, locale: locale, timeZone: timeZone))."
        case .failed(.offline):
            return "You're offline. Retrying automatically."
        case .failed(.unreadable):
            return "Couldn't read \(service.name) usage. Try updating this app."
        case .failed(.loginUnreadable):
            return "Couldn't read your \(service.loginTool) login. Trying again shortly."
        case .failed(.server), .failed(.other):
            return "Couldn't load \(service.name) usage. Retrying automatically."
        }
    }

    /// Technical detail for a problem, if any, e.g. "HTTP 503".
    public static func problemDetail(_ problem: Problem) -> String? {
        switch problem {
        case let .failed(.server(status)): "HTTP \(status)"
        case let .failed(.other(message)): message
        default: nil
        }
    }

    /// "on track" or "ahead of pace": how usage compares with an even pace through the window,
    /// which the mark on each bar shows.
    public static func pace(_ pace: LimitRow.Pace?) -> String? {
        switch pace {
        case .onTrack: "on track"
        case .ahead: "ahead of pace"
        case nil: nil
        }
    }

    /// A clock time such as "20:15", in the user's preferred hour cycle.
    public static func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        Formatters.date("jjmm", locale: locale, timeZone: timeZone).string(from: date)
    }

    /// "Max 20x" from `max` plus `default_claude_max_20x`; "Pro" from `pro`.
    public static func claudePlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let type = subscriptionType, !type.isEmpty else { return nil }
        let name = type.prefix(1).uppercased() + type.dropFirst()
        if let tier = rateLimitTier, let match = tier.firstMatch(of: /_(\d+x)$/) {
            return "\(name) \(match.1)"
        }
        return name
    }

    /// A ChatGPT plan's display name, e.g. "Pro 100" for `prolite`.
    ///
    /// The usage endpoint only sends an identifier, and the names don't follow from it, so this
    /// mirrors the labels the Codex CLI shows in its own status screen
    /// (`codex-rs/tui/src/subscription.rs`). Unknown plans get no name rather than a guess.
    public static func chatGPTPlan(_ planType: String?) -> String? {
        guard let raw = planType?.lowercased(), !raw.isEmpty else { return nil }
        return chatGPTPlanNames[raw]
    }

    private static let chatGPTPlanNames: [String: String] = [
        "free": "Free",
        "go": "Go",
        "plus": "Plus",
        "pro": "Pro 200",
        "prolite": "Pro 100",
        "promax": "Pro 500",
        "team": "Business",
        "self_serve_business_usage_based": "Business",
        "self_serve_business_prolite": "Business Premium",
        "business": "Enterprise",
        "enterprise": "Enterprise",
        "hc": "Enterprise",
        "ent26": "Enterprise",
        "enterprise_cbp_usage_based": "Enterprise",
        "enterprise_cbp_automation": "Enterprise (Automation)",
        "edu": "Edu",
        "education": "Edu",
        "edu_plus": "Edu Plus",
        "edu_pro": "Edu Pro",
        "sci": "Academic Researchers",
        "sci_plus": "Academic Researchers Plus",
    ]

    /// A Cursor plan's display name, e.g. "Pro+" for `pro_plus`, from the membership type the
    /// Cursor app caches. Unknown plans get no name rather than a guess.
    public static func cursorPlan(_ membershipType: String?) -> String? {
        guard let raw = membershipType?.lowercased(), !raw.isEmpty else { return nil }
        return cursorPlanNames[raw]
    }

    private static let cursorPlanNames: [String: String] = [
        "free": "Hobby",
        "free_trial": "Pro Trial",
        "pro": "Pro",
        "pro_plus": "Pro+",
        "ultra": "Ultra",
        "enterprise": "Enterprise",
        // Cursor included with SuperGrok, which shares its usage with the SuperGrok plan.
        "super": "SuperGrok",
    ]

    /// "Session (5h)", "Daily", "Weekly" or "Monthly" for a usage window's length.
    public static func windowName(seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "Usage" }
        switch seconds {
        case 5 * 3600: return "Session (5h)"
        case 86_400: return "Daily"
        case 604_800: return "Weekly"
        case 28 * 86_400 ... 31 * 86_400: return "Monthly"
        case ..<3600: return "\(max(1, Int((Double(seconds) / 60).rounded())))-minute"
        case ..<86_400: return "\(Int((Double(seconds) / 3600).rounded()))-hour"
        default: return "\(Int((Double(seconds) / 86_400).rounded()))-day"
        }
    }

    /// A readable name for a server identifier: "Code review" from `code_review`.
    public static func limitName(_ identifier: String) -> String {
        let words = identifier.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Forgets cached formatters, e.g. after the person changes their region or clock settings.
    public static func clearCaches() {
        Formatters.clear()
    }

    // MARK: - Helpers

    /// Whole minutes until a date, rounded up, or nil if it's absurdly far off.
    private static func minutesUntil(_ date: Date, from now: Date) -> Int? {
        let minutes = (date.timeIntervalSince(now) / 60).rounded(.up)
        guard minutes.isFinite, minutes < 1_000_000_000 else { return nil }
        return Int(minutes)
    }

    /// Rounds rather than truncates, so a reset at 04:59:59.9 reads as 05:00.
    private static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }

    private static func isTomorrow(_ date: Date, now: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: tomorrow)
    }

    private static func spokenWindow(_ length: TimeInterval?) -> String {
        switch length {
        case 5 * 3600: "session"
        case 86_400: "day"
        case 604_800: "week"
        default: "window"
        }
    }

    private static func spokenReset(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String? {
        // Same rule as the visible caption: an absurdly distant date is treated as unknown.
        guard minutesUntil(date, from: now) != nil else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds < 24 * 3600 {
            let formatter = Formatters.duration(hours: seconds >= 3600, locale: locale)
            if let interval = formatter.string(from: (seconds / 60).rounded(.up) * 60) {
                return "resets in \(interval)"
            }
        }
        let rounded = roundedToMinute(date)
        if isTomorrow(rounded, now: now, timeZone: timeZone) {
            return "resets tomorrow at \(time(rounded, locale: locale, timeZone: timeZone))"
        }
        let template = seconds < 6 * 86_400 ? "EEEEjjmm" : "EEEEdMMMMjjmm"
        return "resets \(Formatters.date(template, locale: locale, timeZone: timeZone).string(from: rounded))"
    }
}

/// Formatters are expensive to create and the menu re-renders often, so each distinct
/// template, locale and time zone gets one formatter, reused from then on.
private enum Formatters {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var formatters: [String: DateFormatter] = [:]
        var durations: [String: DateComponentsFormatter] = [:]
    }

    private static let cache = Cache()

    static func date(_ template: String, locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let key = "\(template)|\(locale.identifier)|\(timeZone.identifier)"
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let formatter = cache.formatters[key] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        cache.formatters[key] = formatter
        return formatter
    }

    static func duration(hours: Bool, locale: Locale) -> DateComponentsFormatter {
        let key = "\(hours)|\(locale.identifier)"
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let formatter = cache.durations[key] {
            return formatter
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = hours ? [.hour, .minute] : [.minute]
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        cache.durations[key] = formatter
        return formatter
    }

    static func clear() {
        cache.lock.lock()
        cache.formatters.removeAll()
        cache.durations.removeAll()
        cache.lock.unlock()
    }
}
