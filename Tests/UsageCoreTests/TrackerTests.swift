import Foundation
import Testing
@testable import UsageCore

private func usage(_ service: Service, _ percent: Double, _ severity: Severity = .normal, resetsAt: Date? = nil) -> ServiceUsage {
    ServiceUsage(service: service, plan: nil, rows: [
        LimitRow(id: "weekly", title: "Weekly", percent: percent, resetsAt: resetsAt ?? now.addingTimeInterval(3 * 86_400),
                 severity: severity, windowLength: 604_800),
    ])
}

/// The services these tests exercise. Others the app supports are left out, so each expectation
/// lists only the services the test is about.
private let services: [Service] = [.claude, .chatGPT]

private func minutes(_ count: Double) -> Date {
    now.addingTimeInterval(count * 60)
}

@Suite struct TrackerTests {
    /// The bug that hid Claude: one failed check swapped the menu bar to ChatGPT's 35%.
    @Test func aFailedCheckKeepsAServiceInTheMenuBar() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 100, .critical)), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 35)), for: .chatGPT, at: now)
        for failure in [FetchOutcome.rateLimited(retryAfter: 300), .failed(.offline), .failed(.server(status: 503)),
                        .failed(.loginUnreadable), .tokenExpired(plan: nil)] {
            var copy = tracker
            copy.record(failure, for: .claude, at: minutes(2))
            let headline = copy.headline(at: minutes(3))
            #expect(headline?.service == .claude, "after \(failure)")
            #expect(headline?.row.percent == 100)
            #expect(headline?.isStale == false)
            #expect(copy.signedInServices == [.claude, .chatGPT])
        }
    }

    @Test func numbersGoOutOfDateAfterFifteenMinutesButStillCount() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 100, .critical)), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 35)), for: .chatGPT, at: now)
        tracker.record(.tokenExpired(plan: nil), for: .claude, at: minutes(5))
        #expect(!tracker.isStale(.claude, at: minutes(14)))
        #expect(tracker.isStale(.claude, at: minutes(16)))
        // An old reading is a lower bound, so it still leads; it's just marked out of date.
        let headline = tracker.headline(at: minutes(16))
        #expect(headline?.service == .claude)
        #expect(headline?.isStale == true)
        // A successful check clears it.
        tracker.record(.success(usage(.claude, 100, .critical)), for: .claude, at: minutes(17))
        #expect(!tracker.isStale(.claude, at: minutes(17)))
    }

    @Test func anOldButHigherReadingStillLeads() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.chatGPT, 95, .critical)), for: .chatGPT, at: now)
        tracker.record(.failed(.offline), for: .chatGPT, at: minutes(1))
        tracker.record(.success(usage(.claude, 92, .critical)), for: .claude, at: minutes(20))
        let headline = tracker.headline(at: minutes(20))
        #expect(headline?.service == .chatGPT)
        #expect(headline?.row.severity == .critical)  // still red: it's at least 95% now
        #expect(headline?.isStale == true)
    }

    @Test func aWindowThatHasResetNoLongerLeads() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 100, .critical, resetsAt: minutes(30))), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 35)), for: .chatGPT, at: now)
        #expect(tracker.headline(at: minutes(29))?.service == .claude)
        #expect(tracker.headline(at: minutes(31))?.service == .chatGPT)
    }

    @Test func onlyALoginMissingTwiceInARowSignsOut() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 50)), for: .claude, at: now)
        tracker.record(.failed(.loginUnreadable), for: .claude, at: minutes(2))
        #expect(tracker.signedInServices == [.claude])
        #expect(tracker.state(of: .claude)?.usage != nil)
        // Missing once (a tool replacing its login removes it for a moment): nothing changes,
        // and it's checked again in a minute.
        tracker.record(.notSignedIn, for: .claude, at: minutes(4))
        #expect(tracker.signedInServices == [.claude])
        #expect(tracker.headline(at: minutes(4))?.service == .claude)
        #expect(tracker.state(of: .claude)?.nextFetch == minutes(5))
        // Back again, so it carries on as before.
        tracker.record(.success(usage(.claude, 51)), for: .claude, at: minutes(5))
        tracker.record(.notSignedIn, for: .claude, at: minutes(10))
        #expect(tracker.signedInServices == [.claude])
        // Missing twice in a row: signed out.
        tracker.record(.notSignedIn, for: .claude, at: minutes(11))
        #expect(tracker.signedInServices.isEmpty)
        #expect(tracker.headline(at: minutes(11)) == nil)
    }

    @Test func rateLimitBackoffHoldsEvenForForcedRefreshes() {
        var tracker = UsageTracker()
        tracker.record(.rateLimited(retryAfter: 600), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 10)), for: .chatGPT, at: now)
        // Claude is held back until its backoff ends, forced or not. ChatGPT is fetched when it's
        // due, or when forced once its numbers are two minutes old.
        #expect(tracker.servicesToFetch(from: services, force: true, now: minutes(1)).isEmpty)
        #expect(tracker.servicesToFetch(from: services, force: true, now: minutes(3)) == [.chatGPT])
        #expect(tracker.servicesToFetch(from: services, force: false, now: minutes(3)).isEmpty)
        #expect(tracker.servicesToFetch(from: services, force: false, now: minutes(6)) == [.chatGPT])
        #expect(tracker.servicesToFetch(from: services, force: false, now: minutes(10)) == [.claude, .chatGPT])
    }

    @Test func checksAreScheduledByOutcome() {
        let cases: [(FetchOutcome, TimeInterval)] = [
            (.success(usage(.claude, 1)), 300), (.tokenExpired(plan: nil), 60), (.failed(.offline), 60),
            (.failed(.loginUnreadable), 60), (.failed(.server(status: 500)), 300), (.failed(.unreadable), 300),
            (.notSignedIn, 300), (.rateLimited(retryAfter: nil), 300), (.rateLimited(retryAfter: 0), 300),
            (.rateLimited(retryAfter: 30), 60), (.rateLimited(retryAfter: 900), 900),
        ]
        for (outcome, delay) in cases {
            var tracker = UsageTracker()
            tracker.record(outcome, for: .claude, at: now)
            #expect(tracker.state(of: .claude)?.nextFetch == now.addingTimeInterval(delay), "\(outcome)")
            #expect(tracker.nextWake(after: now) == now.addingTimeInterval(delay))
        }
        #expect(UsageTracker().nextWake(after: now) == now.addingTimeInterval(300))
    }

    @Test func repeatedRateLimitsBackOffFurtherUpToAnHour() {
        var tracker = UsageTracker()
        var waits: [TimeInterval] = []
        var time = now
        for _ in 0..<7 {
            tracker.record(.rateLimited(retryAfter: nil), for: .claude, at: time)
            let next = tracker.state(of: .claude)!.nextFetch
            waits.append(next.timeIntervalSince(time))
            time = next
        }
        #expect(waits == [300, 600, 1200, 2400, 3600, 3600, 3600])
        tracker.record(.success(usage(.claude, 1)), for: .claude, at: time)
        tracker.record(.rateLimited(retryAfter: nil), for: .claude, at: time)
        #expect(tracker.state(of: .claude)!.nextFetch == time.addingTimeInterval(300))  // reset by the success
    }

    @Test func loadingUntilEveryServiceHasBeenChecked() {
        var tracker = UsageTracker()
        #expect(tracker.isLoading)
        tracker.record(.notSignedIn, for: .chatGPT, at: now)
        tracker.record(.notSignedIn, for: .cursor, at: now)
        #expect(tracker.isLoading)
        tracker.record(.success(usage(.claude, 1)), for: .claude, at: now)
        #expect(!tracker.isLoading)
    }

    /// Six hours of polls with a mix of hiccups: Claude must never leave the menu bar, and only
    /// counts as out of date after fifteen minutes without a successful check.
    @Test func hoursOfPollingWithHiccups() {
        var tracker = UsageTracker()
        let hiccups: [FetchOutcome] = [.failed(.offline), .rateLimited(retryAfter: 120), .failed(.loginUnreadable),
                                       .failed(.server(status: 502)), .tokenExpired(plan: nil)]
        var lastSuccess = now
        for step in 0..<180 {
            let time = minutes(Double(step) * 2)
            // Mostly fine; every so often a run of one to six failed checks.
            let failing = step % 17 >= 11
            if failing {
                tracker.record(hiccups[step % hiccups.count], for: .claude, at: time)
            } else {
                tracker.record(.success(usage(.claude, 100, .critical)), for: .claude, at: time)
                lastSuccess = time
            }
            tracker.record(.success(usage(.chatGPT, 35)), for: .chatGPT, at: time)

            let headline = tracker.headline(at: time)
            #expect(headline?.service == .claude, "step \(step)")
            #expect(headline?.isStale == (time.timeIntervalSince(lastSuccess) > UsageTracker.staleAfter), "step \(step)")
        }
    }
}

@Suite struct LoginReadTests {
    @Test func onlyStatus44MeansNoKeychainItem() {
        let json = Data(#"{"claudeAiOauth":{"accessToken":"t"}}"#.utf8)
        #expect(ClaudeCredentialStore.keychainRead(status: 0, output: json) == .found(json))
        #expect(ClaudeCredentialStore.keychainRead(status: 44, output: Data()) == .missing)
        #expect(ClaudeCredentialStore.keychainRead(status: 51, output: Data()) == .unreadable)  // interaction not allowed
        #expect(ClaudeCredentialStore.keychainRead(status: 36, output: Data()) == .unreadable)  // keychain locked
        #expect(ClaudeCredentialStore.keychainRead(status: 0, output: Data()) == .unreadable)
    }

    @Test func anUnreadableClaudeLoginIsATemporaryFailure() async {
        let source = ClaudeSource(loadCredentials: { throw CredentialError.unreadable }, get: { _, _ in reply(200) })
        #expect(await source.fetch(now: now) == .failed(.loginUnreadable))
    }

    @Test func anUnreadableCodexLoginIsATemporaryFailure() async {
        let source = ChatGPTSource(loadCredentials: { throw CredentialError.unreadable }, get: { _, _ in reply(200) })
        #expect(await source.fetch(now: now) == .failed(.loginUnreadable))
    }

    @Test func codexLoginFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "llmits-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "auth.json")

        #expect(throws: CredentialError.notFound) { try ChatGPTCredentialStore.load(from: file) }
        try Data(#"{"tokens": {"access_tok"#.utf8).write(to: file)  // caught mid-write
        #expect(throws: CredentialError.unreadable) { try ChatGPTCredentialStore.load(from: file) }
        try Data(#"{"auth_mode": "apikey", "OPENAI_API_KEY": "sk-test"}"#.utf8).write(to: file)
        #expect(throws: CredentialError.notFound) { try ChatGPTCredentialStore.load(from: file) }
        try Data(#"{"tokens": {"access_token": "t", "account_id": "a"}}"#.utf8).write(to: file)
        #expect(try ChatGPTCredentialStore.load(from: file).accountID == "a")
    }

    @Test func unreadableLoginCopy() {
        #expect(Format.problem(.failed(.loginUnreadable), service: .claude) == "Couldn't read your Claude Code login. Trying again shortly.")
    }
}

@Suite struct SavedUsageTests {
    @Test func lastNumbersSurviveARelaunch() throws {
        var before = UsageTracker()
        before.record(.success(usage(.claude, 100, .critical)), for: .claude, at: now)
        before.record(.success(usage(.chatGPT, 36)), for: .chatGPT, at: now)
        before.record(.success(usage(.cursor, 5)), for: .cursor, at: now)
        let data = try #require(before.snapshot.encoded())

        var after = UsageTracker()
        after.restore(try #require(UsageTracker.Snapshot.decode(data)), at: minutes(1))
        // Shown straight away, current if recent...
        #expect(after.headline(at: minutes(1)) == UsageTracker.Headline(service: .claude, row: usage(.claude, 100, .critical).rows[0], isStale: false))
        #expect(!after.isLoading)
        // ...out of date if old...
        #expect(after.headline(at: minutes(20))?.isStale == true)
        // ...and checked once they're two minutes old, not before, even by Refresh.
        #expect(after.servicesToFetch(from: services, force: true, now: minutes(1)).isEmpty)
        #expect(after.servicesToFetch(from: services, force: false, now: minutes(2)) == [.claude, .chatGPT])
        // A login that has gone since drops out once its checks don't find it.
        after.record(.notSignedIn, for: .chatGPT, at: minutes(2))
        after.record(.notSignedIn, for: .chatGPT, at: minutes(3))
        #expect(after.signedInServices == [.claude, .cursor])
        #expect(after.snapshot.services.keys.sorted { $0.rawValue < $1.rawValue } == [.claude, .cursor])
    }

    @Test func savedNumbersNeverReplaceLiveOnes() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 10)), for: .claude, at: minutes(5))
        var old = UsageTracker()
        old.record(.success(usage(.claude, 90)), for: .claude, at: now)
        tracker.restore(old.snapshot, at: minutes(5))
        #expect(tracker.state(of: .claude)?.usage?.rows.first?.percent == 10)
    }

    /// Opening the menu, Refresh and waking all force a check, but only of services without
    /// numbers from the last two minutes, so a glance at the menu never trips a rate limit.
    @Test func forcedChecksSkipNumbersUnderTwoMinutesOld() {
        var tracker = UsageTracker()
        #expect(tracker.servicesToFetch(from: services, force: true, now: now) == [.claude, .chatGPT])
        tracker.record(.success(usage(.claude, 10)), for: .claude, at: now)
        // An expired Codex login (common when Codex isn't used much) once made every opening of
        // the menu fetch Claude again too.
        tracker.record(.tokenExpired(plan: nil), for: .chatGPT, at: now)
        #expect(tracker.servicesToFetch(from: services, force: true, now: minutes(0.5)) == [.chatGPT])
        #expect(tracker.servicesToFetch(from: services, force: true, now: minutes(2.5)) == [.claude, .chatGPT])
    }

    @Test func garbageSavedDataIsIgnored() {
        #expect(UsageTracker.Snapshot.decode(Data("not json".utf8)) == nil)
    }

    /// Relaunching straight after a check (as installing an update does) waits until the numbers
    /// are two minutes old, and a rate limit's wait carries over.
    @Test func aRelaunchKeepsToRecentNumbersAndRateLimits() throws {
        var before = UsageTracker()
        before.record(.success(usage(.chatGPT, 35)), for: .chatGPT, at: now)
        before.record(.success(usage(.claude, 100, .critical)), for: .claude, at: minutes(5))
        before.record(.rateLimited(retryAfter: 3600), for: .chatGPT, at: minutes(5))
        let data = try #require(before.snapshot.encoded())
        let saved = try #require(UsageTracker.Snapshot.decode(data))

        var soon = UsageTracker()
        soon.restore(saved, at: minutes(5.1))
        #expect(soon.servicesToFetch(from: services, force: true, now: minutes(5.1)).isEmpty)
        #expect(soon.servicesToFetch(from: services, force: false, now: minutes(7)) == [.claude])
        #expect(soon.state(of: .chatGPT)?.problem == .rateLimited(until: minutes(65)))
        #expect(soon.servicesToFetch(from: services, force: false, now: minutes(65)) == [.claude, .chatGPT])
        // Another rate limit straight after carries on doubling.
        soon.record(.rateLimited(retryAfter: nil), for: .chatGPT, at: minutes(65))
        #expect(soon.state(of: .chatGPT)?.backoffUntil == minutes(75))

        // Long after, the wait is over and forgotten.
        var later = UsageTracker()
        later.restore(saved, at: minutes(120))
        #expect(later.state(of: .chatGPT)?.backoffUntil == nil)
        #expect(later.state(of: .chatGPT)?.problem == nil)
        #expect(later.servicesToFetch(from: services, force: false, now: minutes(120)) == [.claude, .chatGPT])
        later.record(.rateLimited(retryAfter: nil), for: .chatGPT, at: minutes(120))
        #expect(later.state(of: .chatGPT)?.backoffUntil == minutes(125))
    }

    /// A service rate limited before it ever had numbers is remembered too, so a relaunch shows
    /// why it's empty and doesn't ask again too soon.
    @Test func aRateLimitBeforeAnyNumbersIsRemembered() throws {
        var before = UsageTracker()
        before.record(.rateLimited(retryAfter: 600), for: .claude, at: now)
        var after = UsageTracker()
        let data = try #require(before.snapshot.encoded())
        after.restore(try #require(UsageTracker.Snapshot.decode(data)), at: minutes(1))
        #expect(after.signedInServices == [.claude])
        #expect(after.state(of: .claude)?.problem == .rateLimited(until: minutes(10)))
        #expect(after.servicesToFetch(from: [.claude], force: true, now: minutes(1)).isEmpty)
    }

    /// An entry this build can't read (one saved by a newer version, say) drops only itself.
    @Test func anUnreadableSavedEntryKeepsTheRest() throws {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 100, .critical)), for: .claude, at: now)
        let data = try #require(tracker.snapshot.encoded())
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var services = try #require(object["services"] as? [String: Any])
        services["gemini"] = services["claude"]
        services["chatGPT"] = ["usage": "garbled"]
        object["services"] = services
        let decoded = try #require(UsageTracker.Snapshot.decode(try JSONSerialization.data(withJSONObject: object)))
        #expect(decoded.services.keys.map(\.rawValue) == ["claude"])
    }

    @Test func absurdSavedValuesAreHarmless() {
        var snapshot = UsageTracker.Snapshot()
        snapshot.services[.claude] = .init(backoffUntil: minutes(30), rateLimitStreak: .max)
        // A wait a year long can only be a clock problem: nothing worth restoring.
        snapshot.services[.chatGPT] = .init(backoffUntil: now.addingTimeInterval(365 * 86_400))
        var tracker = UsageTracker()
        tracker.restore(snapshot, at: now)
        tracker.record(.rateLimited(retryAfter: nil), for: .claude, at: minutes(30))
        #expect(tracker.state(of: .claude)?.backoffUntil == minutes(90))  // still at most an hour
        #expect(tracker.state(of: .chatGPT) == nil)
    }
}

// MARK: - Found by an adversarial review of the tracker; each failed before its fix.

private let claudeBody = """
{"limits": [{"kind": "weekly_scoped", "group": "weekly", "percent": 100, "severity": "critical",
             "resets_at": "2026-11-25T05:00:00Z", "scope": {"model": {"display_name": "Fable"}}}]}
"""
private let validClaude = ClaudeCredentials(accessToken: "token-A", expiresAt: now.addingTimeInterval(8 * 3600),
                                            subscriptionType: "max", rateLimitTier: "default_claude_max_20x")

/// A clock the fake endpoints can read, so they can rate-limit by simulated time.
private final class SimClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// What AppDelegate.refresh does, minus the drawing.
private func check(_ tracker: inout UsageTracker, _ sources: [any UsageSource], force: Bool, at time: Date) async {
    let due = tracker.servicesToFetch(from: sources.map(\.service), force: force, now: time)
    for source in sources where due.contains(source.service) {
        tracker.record(await source.fetch(now: time), for: source.service, at: time)
    }
}

@Suite struct TrackerReviewTests {
    /// The original "Claude disappeared" bug, on a first launch with nothing saved: a rate limit
    /// on Claude's first check treated it as signed out.
    @Test func aFirstCheckThatFailsStillCountsAsSignedIn() {
        for outcome in [FetchOutcome.rateLimited(retryAfter: 300), .failed(.offline), .failed(.server(status: 503)),
                        .failed(.unreadable), .failed(.other("TLS")), .tokenExpired(plan: nil)] {
            var tracker = UsageTracker()
            tracker.record(outcome, for: .claude, at: now)
            #expect(tracker.signedInServices == [.claude], "after \(outcome)")
        }
        // An unreadable login may not exist at all, so it signs nothing in by itself.
        var tracker = UsageTracker()
        tracker.record(.failed(.loginUnreadable), for: .claude, at: now)
        #expect(tracker.signedInServices.isEmpty)
    }

    /// Offline at login with nothing saved: the menu says so, rather than asking to sign in.
    @Test func offlineAtLaunchIsNotSignedOut() {
        var tracker = UsageTracker()
        tracker.record(.failed(.offline), for: .claude, at: now)
        tracker.record(.failed(.offline), for: .chatGPT, at: now)
        tracker.record(.failed(.offline), for: .cursor, at: now)
        #expect(tracker.signedInServices == [.claude, .chatGPT, .cursor])
        #expect(!tracker.isLoading)
    }

    /// End to end, against an endpoint that rate-limits like Anthropic's (one request per 30 s):
    /// glancing at the menu right after a check never fetches Claude again.
    @Test func openingTheMenuNeverRateLimitsARecentCheck() async {
        let clock = SimClock(now)
        let requests = Recorder<Date>()
        let claude = ClaudeSource(loadCredentials: { validClaude }, get: { _, _ in
            let time = clock.now
            let previous = requests.all.last
            requests.record(time)
            if let previous, time.timeIntervalSince(previous) < 30 { return reply(429) }
            return reply(200, claudeBody)
        })
        let expired = ChatGPTCredentials(accessToken: "t", accountID: nil, expiresAt: now.addingTimeInterval(-3600))
        let chatGPT = ChatGPTSource(loadCredentials: { expired }, get: { _, _ in reply(200) })
        let sources: [any UsageSource] = [claude, chatGPT]

        var tracker = UsageTracker()
        await check(&tracker, sources, force: false, at: now)  // the poll
        for seconds in [5.0, 10, 40, 70, 100] {  // glances at the menu
            clock.now = now.addingTimeInterval(seconds)
            await check(&tracker, sources, force: true, at: clock.now)
        }
        #expect(requests.all.count == 1)
        #expect(tracker.state(of: .claude)?.problem == nil)
        // Two minutes on, opening the menu does fetch it again.
        clock.now = minutes(2.5)
        await check(&tracker, sources, force: true, at: clock.now)
        #expect(requests.all.count == 2)
        #expect(tracker.state(of: .claude)?.problem == nil)
    }

    /// Setting the clock back must not stall checks for as long as the jump.
    @Test func aClockSetBackDoesNotStallChecks() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 100, .critical)), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 35)), for: .chatGPT, at: now)
        tracker.record(.rateLimited(retryAfter: nil), for: .chatGPT, at: minutes(1))

        let dayBack = now.addingTimeInterval(-86_400)
        #expect(tracker.nextWake(after: dayBack) == dayBack)
        #expect(tracker.servicesToFetch(from: services, force: false, now: dayBack) == [.claude, .chatGPT])
        // Numbers from "tomorrow" are out of date, and fetched when asked.
        #expect(tracker.isStale(.claude, at: dayBack))

        // Half an hour back: checks run now; a rate limit's wait runs longer, but never past an hour.
        let halfHourBack = now.addingTimeInterval(-1800)
        #expect(tracker.servicesToFetch(from: services, force: false, now: halfHourBack) == [.claude])
        #expect(tracker.nextWake(after: halfHourBack) == halfHourBack)
    }

    /// A service's own warning outranks a fuller limit its service doesn't flag.
    @Test func aWarningOutranksAFullerUnflaggedLimit() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 80, Severity(serverValue: "normal", percent: 80))), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 78, .warning)), for: .chatGPT, at: now)
        let headline = tracker.headline(at: now)
        #expect(headline?.service == .chatGPT)
        #expect(headline?.row.severity == .warning)
    }

    /// The app wakes to redraw when numbers go out of date or a window resets, even while every
    /// service is backing off for an hour.
    @Test func wakesForWhatChangesOnScreen() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 50, resetsAt: minutes(40))), for: .claude, at: now)
        tracker.record(.rateLimited(retryAfter: 3600), for: .claude, at: minutes(5))
        tracker.record(.rateLimited(retryAfter: 3600), for: .chatGPT, at: minutes(5))
        #expect(tracker.nextWake(after: minutes(5)) == minutes(15))  // Claude's numbers go out of date
        #expect(tracker.nextWake(after: minutes(15)) == minutes(40))  // its window resets
        #expect(tracker.nextWake(after: minutes(40)) == minutes(65))  // the waits end
    }

    @Test func retryAfterExtremesStayBetweenAMinuteAndAnHour() {
        let values: [TimeInterval?] = [.nan, .infinity, -.infinity, -5, 0, 0.5, 59.9, 1e308, 7200, nil]
        for retryAfter in values {
            var tracker = UsageTracker()
            var time = now
            for _ in 0..<70 {
                tracker.record(.rateLimited(retryAfter: retryAfter), for: .claude, at: time)
                let wait = tracker.state(of: .claude)!.nextFetch.timeIntervalSince(time)
                #expect(wait >= 60 && wait <= UsageTracker.maxBackoff, "\(String(describing: retryAfter)): \(wait)")
                time = tracker.state(of: .claude)!.nextFetch
            }
        }
    }

    @Test func aSaved100PercentThatResetWhileClosedNoLongerLeads() {
        var before = UsageTracker()
        before.record(.success(usage(.claude, 100, .critical, resetsAt: minutes(60))), for: .claude, at: now)
        before.record(.success(usage(.chatGPT, 35)), for: .chatGPT, at: now)
        var after = UsageTracker()
        after.restore(before.snapshot, at: minutes(120))
        let headline = after.headline(at: minutes(120))
        #expect(headline?.service == .chatGPT)
        #expect(headline?.row.percent == 35)
    }

    @Test func tiesGoToClaudeAndSeverityBreaksThem() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 90, .warning)), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 90, .critical)), for: .chatGPT, at: now)
        #expect(tracker.headline(at: now)?.service == .chatGPT)
        tracker.record(.success(usage(.chatGPT, 90, .warning)), for: .chatGPT, at: now)
        #expect(tracker.headline(at: now)?.service == .claude)
    }
}
