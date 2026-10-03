import AppKit
import Combine

/// L'icona nella barra dei menu. Clic sinistro: attiva/disattiva (o menu, a scelta).
/// Clic destro o ctrl-clic: sempre il menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sessions: SessionManager
    private let triggers: TriggerEngine
    private let settings = AppSettings.shared
    private let openSettings: () -> Void
    private let openAbout: () -> Void
    private let untilWindow = UntilTimeWindow()
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    static let durations = [5, 15, 30, 60, 120, 180, 240, 360, 480, 720]
    private static let extensions = [15, 30, 60, 120]

    init(sessions: SessionManager, triggers: TriggerEngine, openSettings: @escaping () -> Void, openAbout: @escaping () -> Void) {
        self.sessions = sessions
        self.triggers = triggers
        self.openSettings = openSettings
        self.openAbout = openAbout
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        statusItem.autosaveName = "TazzinaStatusItem"

        sessions.$session
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    // MARK: - Icona

    private func refresh() {
        let session = sessions.session
        let symbol = session == nil ? "cup.and.saucer" : "cup.and.saucer.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tazzina")
        image?.isTemplate = true
        statusItem.button?.image = image

        var title = ""
        if settings.showRemainingTime, let remaining = session?.remaining() {
            title = " " + TimeText.compact(remaining)
        }
        statusItem.button?.title = title
        statusItem.button?.toolTip = session == nil
            ? String(localized: "Tazzina: off")
            : String(localized: "Tazzina: keeping your Mac awake")

        // Aggiorna il tempo rimanente solo quando serve mostrarlo.
        refreshTimer?.invalidate()
        refreshTimer = nil
        if settings.showRemainingTime, session?.isTimed == true {
            let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if !wantsMenu, settings.leftClickToggles {
            sessions.toggle()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        buildMenu(menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Senza menu assegnato il clic torna a chiamare `clicked`.
        statusItem.menu = nil
    }

    // MARK: - Menu

    private func buildMenu(_ menu: NSMenu) {
        if let session = sessions.session {
            menu.addItem(disabled(String(localized: "Tazzina is on")))
            if case .trigger(_, let name) = session.source {
                menu.addItem(disabled(String(localized: "Started by the “\(name)” trigger"), small: true))
            }
            menu.addItem(disabled(TimeText.describe(session), small: true))
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "Turn Off")) { [weak self] in self?.sessions.stop() })
            if session.isTimed {
                menu.addItem(submenu(String(localized: "Extend"), items: Self.extensions.map { minutes in
                    item("+ " + TimeText.duration(minutes: minutes)) { [weak self] in
                        self?.sessions.extend(minutes: minutes)
                    }
                }))
            }
            let display = item(String(localized: "Allow Display Sleep")) { [weak self] in
                self?.sessions.setAllowDisplaySleep(!session.allowDisplaySleep)
            }
            display.state = session.allowDisplaySleep ? .on : .off
            menu.addItem(display)
            if Lid.exists, sessions.lidHelper.state == .installed {
                let lid = item(String(localized: "Stay Awake with Lid Closed")) { [weak self] in
                    self?.sessions.setLidClosed(!session.lidClosed)
                }
                lid.state = session.lidClosed ? .on : .off
                menu.addItem(lid)
            }
            menu.addItem(.separator())
            menu.addItem(disabled(String(localized: "Start a New Session")))
        } else {
            menu.addItem(disabled(String(localized: "Tazzina is off")))
            menu.addItem(.separator())
        }

        menu.addItem(item(String(localized: "Indefinitely")) { [weak self] in self?.sessions.start(.none) })
        menu.addItem(submenu(String(localized: "For"), items: Self.durations.map { minutes in
            item(TimeText.duration(minutes: minutes)) { [weak self] in self?.sessions.start(.minutes(minutes)) }
        }))
        menu.addItem(submenu(String(localized: "Until"), items: untilItems()))
        menu.addItem(submenu(String(localized: "While App Is Running"), items: appItems()))

        menu.addItem(.separator())
        let useTriggers = item(String(localized: "Use Triggers")) { [weak self] in
            guard let self else { return }
            settings.triggersEnabled.toggle()
            triggers.evaluate()
        }
        useTriggers.state = settings.triggersEnabled ? .on : .off
        menu.addItem(useTriggers)
        menu.addItem(item(String(localized: "Settings…"), key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(item(String(localized: "About Tazzina")) { [weak self] in self?.openAbout() })
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit Tazzina"), key: "q") { NSApp.terminate(nil) })
    }

    private func untilItems() -> [NSMenuItem] {
        let calendar = Calendar.current
        let now = Date.now
        // Le prossime 8 ore piene.
        guard let nextHour = calendar.nextDate(after: now, matching: DateComponents(minute: 0),
                                               matchingPolicy: .nextTime) else { return [] }
        var items: [NSMenuItem] = (0..<8).compactMap { offset in
            guard let date = calendar.date(byAdding: .hour, value: offset, to: nextHour) else { return nil }
            return item(TimeText.clock(date)) { [weak self] in self?.sessions.start(.until(date)) }
        }
        items.append(.separator())
        items.append(item(String(localized: "Other Time…")) { [weak self] in
            self?.untilWindow.show { date in self?.sessions.start(.until(date)) }
        })
        return items
    }

    private func appItems() -> [NSMenuItem] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> (String, String, NSImage?)? in
                guard let id = app.bundleIdentifier else { return nil }
                return (id, app.localizedName ?? id, app.icon)
            }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        guard !apps.isEmpty else { return [disabled(String(localized: "No open apps"))] }
        return apps.map { id, name, icon in
            let entry = item(name) { [weak self] in self?.sessions.start(.whileAppRuns(bundleID: id, name: name)) }
            icon?.size = NSSize(width: 16, height: 16)
            entry.image = icon
            return entry
        }
    }

    // MARK: - Utilità

    private func item(_ title: String, key: String = "", action: @escaping () -> Void) -> NSMenuItem {
        ActionMenuItem(title: title, key: key, action: action)
    }

    private func disabled(_ title: String, small: Bool = false) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        if small {
            entry.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
        }
        return entry
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        entry.submenu = menu
        return entry
    }
}

/// Voce di menu che esegue una closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Testi per tempi e durate.
enum TimeText {
    static func duration(minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .full
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes)"
    }

    /// Formato breve per la barra dei menu: "1:20" oppure "45m".
    static func compact(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes >= 60 { return String(format: "%d:%02d", minutes / 60, minutes % 60) }
        return "\(minutes)m"
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: max(60, seconds.rounded(.up))) ?? ""
    }

    static func clock(_ date: Date) -> String {
        let sameDay = Calendar.current.isDateInToday(date)
        return date.formatted(sameDay ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute())
    }

    static func describe(_ session: Session) -> String {
        switch session.limit {
        case .none:
            return String(localized: "No time limit")
        case .whileAppRuns(_, let name):
            return String(localized: "While \(name) is running")
        case .minutes, .until:
            guard let ends = session.ends, let left = session.remaining() else { return "" }
            return String(localized: "Until \(clock(ends)) (\(remaining(left)) left)")
        }
    }
}
