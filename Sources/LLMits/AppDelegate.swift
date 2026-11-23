import AppKit
import OSLog
import ServiceManagement
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let sources: [any UsageSource] = [ClaudeSource(), ChatGPTSource(), CursorSource()]
    /// What's known about each service, and the rules for what to fetch and show. Tested in UsageCore.
    private var tracker = UsageTracker()
    private var isRefreshing = false
    /// A forced refresh asked for while another was under way, to run once that one ends.
    private var pendingForcedRefresh = false
    private var isMenuOpen = false
    /// What was last written to UserDefaults, so unchanged numbers aren't written again.
    private var savedSnapshot: UsageTracker.Snapshot?

    /// Every menu item is kept and updated in place. An open menu's item list is only replaced
    /// when its structure changes, so it never jumps or loses the highlight under the pointer.
    private var reusableItems: [String: NSMenuItem] = [:]
    private lazy var refreshItem = actionItem("Refresh", #selector(refreshNow), key: "r")
    private lazy var launchAtLoginItem = actionItem("Launch at Login", #selector(toggleLaunchAtLogin))
    /// Chooses which limits the menu bar shows. Its items are kept and updated in place too.
    private lazy var menuBarItem: NSMenuItem = {
        let item = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Show in Menu Bar")
        // Enabled by hand: once three limits are chosen, the rest are greyed out.
        submenu.autoenablesItems = false
        item.submenu = submenu
        return item
    }()
    private var choiceItems: [String: NSMenuItem] = [:]
    /// The limits chosen for the menu bar. Empty means the tightest limit, the default.
    private var chosenLimits: Set<LimitChoice> = []
    private lazy var quitItem: NSMenuItem = {
        let item = NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.target = NSApp
        return item
    }()

    private var lastButton: ButtonContent?
    /// Asking ServiceManagement is a cross-process call, so it's checked once per menu opening.
    private var launchesAtLogin = false
    /// One line per check, with no secrets: `log show --predicate 'subsystem == "<bundle id>"'`.
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LLMits", category: "usage")

    /// Where the last numbers are kept between launches (usage and times only).
    private static let savedUsageKey = "savedUsage"
    /// Whether the person turned on Launch at Login here, so it can be restored after an update.
    private static let launchAtLoginKey = "launchAtLogin"
    /// The limits chosen for the menu bar, as "service/title".
    private static let menuBarLimitsKey = "menuBarLimits"

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LLMits"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Remember the item's position, and let people ⌘-drag it out of the menu bar to remove
        // it (which quits the app): it's their choice whether it lives there, not the app's.
        statusItem.autosaveName = "LLMits"
        statusItem.behavior = .terminationOnRemoval
        statusItem.isVisible = true
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
        // Start from the last numbers, so a relaunch never shows a blank menu bar (or asks a
        // server again before it's ready).
        if let data = UserDefaults.standard.data(forKey: Self.savedUsageKey),
           let snapshot = UsageTracker.Snapshot.decode(data) {
            tracker.restore(snapshot, at: .now)
            savedSnapshot = snapshot
        }
        let stored = UserDefaults.standard.stringArray(forKey: Self.menuBarLimitsKey) ?? []
        chosenLimits = Set(stored.compactMap(LimitChoice.init(stored:)).prefix(UsageTracker.menuBarLimit))
        render()
        restoreLaunchAtLogin()

        Task {
            while !Task.isCancelled {
                await refresh(force: false)
                // Between 5 seconds and an hour, whatever the clock or a server says; waking from
                // sleep, opening the menu and Refresh all check sooner anyway.
                let wait = tracker.nextWake(after: .now).timeIntervalSinceNow
                let seconds = wait.isFinite ? min(max(wait, 5), 3600) : UsageTracker.pollInterval
                // The tolerance lets macOS batch this wake-up with others to save energy.
                try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(10))
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        }
        // Region, clock and time zone changes all affect how times are written.
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    Format.clearCaches()
                    self?.render()
                }
            }
        }
        // A clock set back leaves checks scheduled far ahead; the tracker treats those as due.
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                Format.clearCaches()
                await self?.refresh(force: false)
            }
        }
    }

    // MARK: - Fetching

    /// Fetches every service that's due, concurrently. Forced (Refresh, opening the menu, waking),
    /// it also fetches any without numbers from the last two minutes, but never one that's
    /// backing off after a rate limit.
    private func refresh(force: Bool) async {
        guard !isRefreshing else {
            // Run once this one ends, for whatever it isn't fetching.
            pendingForcedRefresh = pendingForcedRefresh || force
            return
        }
        let now = Date.now
        let due = tracker.servicesToFetch(from: sources.map(\.service), force: force, now: now)
        guard !due.isEmpty else {
            // Nothing to fetch, but numbers may have gone out of date or a window reset.
            render()
            return
        }

        isRefreshing = true
        render()  // shows "Updating…"
        await withTaskGroup(of: (Service, FetchOutcome).self) { group in
            for source in sources where due.contains(source.service) {
                group.addTask { (source.service, await source.fetch(now: now)) }
            }
            // Each result shows as soon as it arrives, so one slow service never holds up another.
            for await (service, outcome) in group {
                tracker.record(outcome, for: service, at: .now)
                record(outcome, for: service)
                saveSnapshot()
                render()
            }
        }
        isRefreshing = false
        render()
        releaseFreedMemory()
        if pendingForcedRefresh {
            pendingForcedRefresh = false
            await refresh(force: true)
        }
    }

    /// Keeps the last numbers, and any rate limit's wait, for the next launch.
    private func saveSnapshot() {
        let snapshot = tracker.snapshot
        guard snapshot != savedSnapshot, let data = snapshot.encoded() else { return }
        UserDefaults.standard.set(data, forKey: Self.savedUsageKey)
        savedSnapshot = snapshot
    }

    private func record(_ outcome: FetchOutcome, for service: Service) {
        let name = service.name
        switch outcome {
        case let .success(usage):
            // Notice rather than info, so every check stays in the log: macOS keeps info lines
            // only briefly, in memory.
            log.notice("\(name, privacy: .public): updated, \(usage.rows.count) limits")
        case .tokenExpired:
            log.notice("\(name, privacy: .public): login expired")
        case .notSignedIn:
            log.notice("\(name, privacy: .public): not signed in")
        case let .rateLimited(retryAfter):
            log.notice("\(name, privacy: .public): rate limited, retry after \(retryAfter ?? -1, privacy: .public)s")
        case let .failed(failure):
            log.error("\(name, privacy: .public): failed, \(String(describing: failure), privacy: .public)")
        }
    }

    // MARK: - Rendering

    private func render() {
        let now = Date.now
        updateButton(now: now)
        if isMenuOpen {
            updateMenu(now: now)
        }
    }

    private struct ButtonContent: Equatable {
        var rows: [StatusIcon.Row]
        var title: String
    }

    /// The menu bar item: the limits shown as dots (a 3 × 5 grid for one, a row of five each for
    /// two or three), and the number of the tightest.
    private func updateButton(now: Date) {
        guard let button = statusItem.button else { return }
        let shown = tracker.menuBarLimits(chosen: chosenLimits, at: now)
        let allStale = !shown.isEmpty && shown.allSatisfy(\.isStale)
        let content = ButtonContent(
            // Dots and whole percents mean a redraw only when something visible changes.
            rows: shown.map { StatusIcon.Row(percent: $0.row.percent, severity: $0.row.severity, faded: $0.isStale && !allStale) },
            title: Format.percent(UsageTracker.tightest(of: shown)?.row.percent)
        )
        if content != lastButton {
            // Colour goes on the icon only, never the text, so the percentage keeps the menu bar's
            // own contrast on any wallpaper. It stays even when the numbers are old: usage only
            // rises within a window, so an old reading is never worse than the truth.
            button.image = StatusIcon.image(rows: content.rows)
            button.title = content.title
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            lastButton = content
        }
        // Dimmed when everything it shows is out of date; one old row among current ones is fainter.
        button.appearsDisabled = shown.isEmpty || allStale

        button.setAccessibilityLabel("Usage limits")
        guard !shown.isEmpty else {
            button.setAccessibilityValue(tracker.isLoading ? "Loading" : "No data")
            button.toolTip = appName
            return
        }
        button.setAccessibilityValue(shown.map {
            "\($0.service.name), \(Format.spokenTitle($0.row)): \(Format.spokenValue($0.row, stale: $0.isStale, now: now))"
        }.joined(separator: "; "))
        button.toolTip = shown.map {
            let caption = Format.caption($0.row, now: now).map { "\n\($0)" } ?? ""
            // Says why a row is faded, as VoiceOver does.
            let stale = $0.isStale ? " (out of date)" : ""
            return "\($0.service.name) \($0.row.title): \(Format.percent($0.row.percent))\(stale)\(caption)"
        }.joined(separator: "\n\n")
    }

    /// Updates the menu's contents in place, rebuilding its item list only if its shape changed.
    private func updateMenu(now: Date) {
        var items: [NSMenuItem] = []
        var used = Set<String>()

        func reused<View: NSView>(_ key: String, _ make: () -> View) -> (NSMenuItem, View) {
            used.insert(key)
            if let item = reusableItems[key], let view = item.view as? View {
                return (item, view)
            }
            let view = make()
            // No title: AppKit sizes the menu from titles even for view items, so one would widen
            // it past the rows. Each view carries its own accessibility label instead.
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.view = view
            // Informational: arrow keys skip it rather than landing on an invisible highlight.
            item.isEnabled = false
            reusableItems[key] = item
            return (item, view)
        }
        func separator(_ key: String) -> NSMenuItem {
            used.insert(key)
            if let item = reusableItems[key] {
                return item
            }
            let item = NSMenuItem.separator()
            reusableItems[key] = item
            return item
        }
        func notice(_ key: String, _ text: String, detail: String?, showsIcon: Bool) -> NSMenuItem {
            let (item, view) = reused(key) { NoticeView() }
            view.update(text: text, detail: detail, showsIcon: showsIcon)
            return item
        }

        let services = tracker.signedInServices
        // One notice is enough when every service is offline.
        let allOffline = !services.isEmpty && services.allSatisfy { tracker.state(of: $0)?.problem == .failed(.offline) }
        if allOffline {
            items.append(notice("notice.offline", Format.problem(.failed(.offline), service: .claude), detail: nil, showsIcon: true))
        }
        if services.isEmpty {
            items.append(tracker.isLoading
                ? notice("notice.empty", "Loading…", detail: nil, showsIcon: false)
                : notice("notice.empty", "Sign in to Claude Code or Codex to see your limits.",
                         detail: "Run claude then /login, or codex login.", showsIcon: false))
        }

        for (index, service) in services.enumerated() {
            guard let state = tracker.state(of: service) else { continue }
            if index > 0 || allOffline {
                items.append(separator("separator.\(service.rawValue)"))
            }
            let (header, headerView) = reused("header.\(service.rawValue)") { SectionHeaderView() }
            let headerTitle = [service.name, state.plan].compactMap { $0 }.joined(separator: " ")
            headerView.update(title: headerTitle, logo: ServiceLogo.image(for: service))
            items.append(header)

            // The explanation comes first, above the numbers it qualifies.
            if let problem = state.problem, !allOffline {
                let updated = state.lastUpdated.map { "Updated \(Format.time($0))" }
                let detail = [updated, Format.problemDetail(problem)].compactMap { $0 }.joined(separator: " · ")
                items.append(notice("notice.\(service.rawValue)", Format.problem(problem, service: service),
                                    detail: detail.isEmpty ? nil : detail, showsIcon: true))
            }

            let stale = tracker.isStale(service, at: now)
            let rows = state.usage?.rows(at: now) ?? []
            for row in rows {
                let key = "row.\(service.rawValue).\(row.id)"
                // The same item twice would make AppKit throw and drop the rest of the menu.
                guard !used.contains(key) else { continue }
                let (item, view) = reused(key) { LimitRowView() }
                view.update(row: row, stale: stale, now: now)
                items.append(item)
            }
            if rows.isEmpty, state.problem == nil {
                items.append(notice("notice.\(service.rawValue).empty", state.usage == nil ? "Loading…" : "No usage limits reported",
                                    detail: nil, showsIcon: false))
            }
        }

        items.append(separator("separator.actions"))
        let lastUpdated = services.compactMap { tracker.state(of: $0)?.lastUpdated }.max()
        let status = isRefreshing ? "Updating…" : lastUpdated.map { "Updated \(Format.time($0))" }
        // `subtitle` runs on macOS 14.4 and later but isn't in every SDK this can be built with, so
        // it's set by name when the running system has it.
        if refreshItem.responds(to: NSSelectorFromString("setSubtitle:")) {
            refreshItem.setValue(status, forKey: "subtitle")
        } else if let status {
            used.insert("info.updated")
            let info = reusableItems["info.updated"] ?? NSMenuItem(title: "", action: nil, keyEquivalent: "")
            info.title = status
            reusableItems["info.updated"] = info
            items.append(info)
        }
        items.append(refreshItem)
        updateMenuBarChoices(now: now)
        items.append(menuBarItem)
        if isBundledApp {
            launchAtLoginItem.state = launchesAtLogin ? .on : .off
        } else {
            launchAtLoginItem.action = nil  // only a bundled .app can be a login item
            launchAtLoginItem.toolTip = "Available when running the bundled app"
        }
        items.append(launchAtLoginItem)
        items.append(separator("separator.quit"))
        items.append(quitItem)

        reusableItems = reusableItems.filter { used.contains($0.key) }
        apply(items, to: menu)
    }

    /// Makes the menu's items match `items` with the fewest insertions and removals. Replacing the
    /// whole list would drop the keyboard highlight and can leave an open menu mis-sized.
    private func apply(_ items: [NSMenuItem], to menu: NSMenu) {
        guard menu.items.map(ObjectIdentifier.init) != items.map(ObjectIdentifier.init) else { return }
        let wanted = Set(items.map(ObjectIdentifier.init))
        for item in menu.items.reversed() where !wanted.contains(ObjectIdentifier(item)) {
            menu.removeItem(item)
        }
        for (index, item) in items.enumerated() {
            if index < menu.items.count, menu.items[index] === item {
                continue
            }
            if item.menu === menu {
                menu.removeItem(item)
            }
            menu.insertItem(item, at: index)
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if isBundledApp {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
        // Countdowns such as "Resets in 3h 5m" move on while the menu is closed.
        updateMenu(now: .now)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // Only services without numbers from the last two minutes are fetched.
        Task { await refresh(force: true) }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        releaseFreedMemory()
    }

    /// Fetching (TLS, JSON) and drawing the menu leave freed but still-dirty heap pages behind.
    /// Once the work has settled, hand them back to the system: about 1 MB measured after a menu
    /// open and close. A few milliseconds, at most once per poll or menu close.
    private func releaseFreedMemory() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard !isMenuOpen, !isRefreshing else { return }
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// The Show in Menu Bar submenu: the tightest limit (the default), then every limit under its
    /// service, up to three of which can be ticked.
    private func updateMenuBarChoices(now: Date) {
        guard let submenu = menuBarItem.submenu else { return }
        var items: [NSMenuItem] = []
        var used = Set<String>()
        func reused(_ key: String, _ make: () -> NSMenuItem) -> NSMenuItem {
            used.insert(key)
            if let item = choiceItems[key] {
                return item
            }
            let item = make()
            choiceItems[key] = item
            return item
        }

        let available = tracker.choices(at: now)
        let active = chosenLimits.intersection(available)
        let tightest = reused("tightest") { actionItem("Most Urgent Limit", #selector(showTightestLimit)) }
        tightest.state = active.isEmpty ? .on : .off
        items.append(tightest)

        let full = active.count >= UsageTracker.menuBarLimit
        for service in Service.allCases {
            let choices = available.filter { $0.service == service }
            guard !choices.isEmpty else { continue }
            items.append(reused("separator.\(service.rawValue)") { .separator() })
            items.append(reused("header.\(service.rawValue)") { .sectionHeader(title: service.name) })
            for choice in choices {
                let key = "choice.\(choice.stored)"
                // The same item twice would make AppKit throw.
                guard !used.contains(key) else { continue }
                let item = reused(key) {
                    let item = actionItem(choice.title, #selector(toggleMenuBarLimit(_:)))
                    // Section headers are skipped by arrow keys and VoiceOver, so the service goes here.
                    item.setAccessibilityLabel("\(choice.service.name), \(Format.spokenTitle(choice.title))")
                    return item
                }
                item.representedObject = choice.stored
                item.state = active.contains(choice) ? .on : .off
                // Three rows of dots is all the menu bar has room for; say so on the greyed-out rest.
                item.isEnabled = item.state == .on || !full
                item.toolTip = item.isEnabled ? nil : "The menu bar shows up to three limits. Untick one to show this one instead."
                items.append(item)
            }
        }
        choiceItems = choiceItems.filter { used.contains($0.key) }
        apply(items, to: submenu)
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        Task { await refresh(force: true) }
    }

    @objc private func showTightestLimit() {
        chosenLimits = []
        saveChosenLimits()
    }

    @objc private func toggleMenuBarLimit(_ sender: NSMenuItem) {
        guard let stored = sender.representedObject as? String, let choice = LimitChoice(stored: stored) else { return }
        chosenLimits = tracker.toggling(choice, in: chosenLimits, at: .now)
        saveChosenLimits()
    }

    private func saveChosenLimits() {
        UserDefaults.standard.set(chosenLimits.map(\.stored).sorted(), forKey: Self.menuBarLimitsKey)
        render()
    }

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        launchesAtLogin = service.status == .enabled
        UserDefaults.standard.set(launchesAtLogin || service.status == .requiresApproval, forKey: Self.launchAtLoginKey)
        render()
    }

    /// Each build is ad-hoc signed, so after an update macOS may no longer count the app as
    /// registered. If the person had turned Launch at Login on here, quietly register again;
    /// if they turned it off in System Settings instead (status "requires approval"), leave it.
    private func restoreLaunchAtLogin() {
        guard isBundledApp, UserDefaults.standard.bool(forKey: Self.launchAtLoginKey) else { return }
        let service = SMAppService.mainApp
        if service.status == .notRegistered || service.status == .notFound {
            try? service.register()
        }
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
