import AppKit
import Combine
import UserNotifications

/// Quanto deve durare una sessione.
enum SessionLimit: Equatable {
    case none
    case minutes(Int)
    case until(Date)
    case whileAppRuns(bundleID: String, name: String)
}

/// Chi ha avviato la sessione.
enum SessionSource: Equatable {
    case manual
    case trigger(id: UUID, name: String)
}

struct Session {
    let limit: SessionLimit
    var source: SessionSource = .manual
    let started: Date
    /// Momento di fine per le sessioni a tempo.
    var ends: Date?
    var allowDisplaySleep: Bool
    var lidClosed: Bool

    var isTimed: Bool { ends != nil }

    func remaining(at now: Date = .now) -> TimeInterval? {
        ends.map { max(0, $0.timeIntervalSince(now)) }
    }
}

enum EndReason {
    case user, timeUp, appQuit(String), lowBattery(Int), unplugged, triggerEnded(String), quitting

    var notificationText: String? {
        switch self {
        case .user, .quitting, .triggerEnded: nil
        case .timeUp: String(localized: "Time is up. Your Mac can sleep again.")
        case .appQuit(let app): String(localized: "\(app) was closed. Your Mac can sleep again.")
        case .lowBattery(let percent): String(localized: "Battery dropped to \(percent)%. Your Mac can sleep again.")
        case .unplugged: String(localized: "The power adapter was disconnected. Your Mac can sleep again.")
        }
    }
}

/// Avvia e termina le sessioni, e decide quando finiscono da sole.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var session: Session?
    /// Chiamato quando spegni a mano una sessione avviata da un trigger.
    var onUserStoppedTrigger: ((UUID) -> Void)?

    let lidHelper = LidHelper()
    private let settings = AppSettings.shared
    private let blocker = SleepBlocker()
    private var endTimer: Timer?
    private var powerWatcher: PowerWatcher?
    private var lastPower = PowerStatus.read()
    private var lidRequested = false
    private var observers: [NSObjectProtocol] = []
    private var settingsObserver: AnyCancellable?

    var isActive: Bool { session != nil }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appTerminated(app) }
        })
        // I timer si fermano durante lo stop: al risveglio ricontrolla la scadenza.
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDeadline() }
        })
        powerWatcher = PowerWatcher { [weak self] status in self?.powerChanged(status) }
        lidHelper.onRestart = { [weak self] in
            guard let self else { return }
            lidRequested = false
            syncLidMode()
        }
    }

    // MARK: - Comandi

    func toggle() {
        if isActive {
            stop()
        } else {
            start(settings.quickDuration > 0 ? .minutes(settings.quickDuration) : .none)
        }
    }

    func start(_ limit: SessionLimit, source: SessionSource = .manual,
               allowDisplaySleep: Bool? = nil, lidClosed: Bool? = nil) {
        let wasActive = isActive
        let now = Date.now
        var ends: Date?
        switch limit {
        case .minutes(let minutes): ends = now.addingTimeInterval(TimeInterval(minutes * 60))
        case .until(let date): ends = date
        case .none, .whileAppRuns: break
        }
        if case .whileAppRuns(let bundleID, _) = limit,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            return
        }
        session = Session(
            limit: limit,
            source: source,
            started: now,
            ends: ends,
            allowDisplaySleep: allowDisplaySleep ?? settings.allowDisplaySleep,
            lidClosed: (lidClosed ?? settings.lidClosedByDefault) && lidHelper.state == .installed
        )
        lastPower = PowerStatus.read()
        apply()
        scheduleEnd()
        // Sostituire una sessione già attiva non è un'attivazione: niente suono.
        if !wasActive, settings.playStartSound, source == .manual || settings.triggerSounds {
            SystemSounds.play(settings.startSound)
        }
    }

    func stop(_ reason: EndReason = .user) {
        guard let ended = session else { return }
        if case .user = reason, case .trigger(let id, _) = ended.source { onUserStoppedTrigger?(id) }
        session = nil
        endTimer?.invalidate()
        endTimer = nil
        apply()
        if case .quitting = reason { return }
        if settings.playStopSound, ended.source == .manual || settings.triggerSounds {
            SystemSounds.play(settings.stopSound)
        }
        if settings.notifyOnAutomaticEnd, let text = reason.notificationText { notify(text) }
    }

    func extend(minutes: Int) {
        guard var current = session, let ends = current.ends else { return }
        current.ends = max(ends, .now).addingTimeInterval(TimeInterval(minutes * 60))
        session = current
        scheduleEnd()
    }

    func setAllowDisplaySleep(_ allow: Bool) {
        session?.allowDisplaySleep = allow
        apply()
    }

    func setLidClosed(_ enabled: Bool) {
        session?.lidClosed = enabled && lidHelper.state == .installed
        apply()
    }

    // MARK: - Stato del sistema

    private func apply() {
        blocker.update(active: session != nil, allowDisplaySleep: session?.allowDisplaySleep ?? true)
        syncLidMode()
    }

    private func syncLidMode() {
        let wanted = session?.lidClosed ?? false
        guard wanted != lidRequested else { return }
        lidRequested = wanted
        Task {
            let ok = await lidHelper.setKeepAwakeWithLidClosed(wanted)
            // Se il servizio non risponde non facciamo finta che funzioni.
            if wanted, !ok, lidRequested {
                lidRequested = false
                session?.lidClosed = false
            }
        }
    }

    private func scheduleEnd() {
        endTimer?.invalidate()
        endTimer = nil
        guard let ends = session?.ends else { return }
        let timer = Timer(fire: ends, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDeadline() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    private func checkDeadline() {
        guard let session else { return }
        if let remaining = session.remaining(), remaining <= 0.5 {
            stop(.timeUp)
        } else {
            scheduleEnd()
        }
        if case .whileAppRuns(let bundleID, let name) = session.limit,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            stop(.appQuit(name))
        }
    }

    private func appTerminated(_ app: NSRunningApplication?) {
        guard case .whileAppRuns(let bundleID, let name)? = session?.limit,
              app?.bundleIdentifier == bundleID,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .allSatisfy({ $0.isTerminated }) else { return }
        stop(.appQuit(name))
    }

    private func powerChanged(_ status: PowerStatus) {
        defer { lastPower = status }
        guard session != nil else { return }
        if settings.endWhenUnplugged, status.onBattery, !lastPower.onBattery {
            stop(.unplugged)
        } else if settings.endOnLowBattery, status.onBattery, let percent = status.batteryPercent,
                  percent <= settings.lowBatteryPercent {
            stop(.lowBattery(percent))
        }
    }

    private func notify(_ text: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Session ended")
            content.body = text
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
