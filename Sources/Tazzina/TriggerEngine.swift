import AppKit

/// Salva i trigger e decide quando avviare o fermare le loro sessioni.
///
/// Regole: una sessione avviata a mano ha sempre la precedenza. Se spegni a mano una sessione
/// avviata da un trigger, quel trigger resta in pausa finché le sue condizioni non smettono di valere.
@MainActor
final class TriggerEngine: ObservableObject {
    @Published var triggers: [Trigger] {
        didSet {
            save()
            evaluate()
        }
    }
    /// Trigger le cui condizioni valgono in questo momento.
    @Published private(set) var matching = Set<UUID>()

    private static let storageKey = "triggers"
    private static let interval: TimeInterval = 15

    private let sessions: SessionManager
    private let settings = AppSettings.shared
    private var paused = Set<UUID>()
    private var timer: Timer?
    private var powerWatcher: PowerWatcher?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(sessions: SessionManager) {
        self.sessions = sessions
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Trigger].self, from: data) {
            triggers = saved
        } else {
            triggers = []
        }

        sessions.onUserStoppedTrigger = { [weak self] id in self?.paused.insert(id) }
        LocationPermission.shared.onChange = { [weak self] in self?.evaluate() }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            observe(workspace, name)
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification)
        powerWatcher = PowerWatcher { [weak self] _ in self?.evaluate() }

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // Piccolo ritardo: l'elenco delle app o dei dischi si aggiorna subito dopo la notifica.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
        observers.append((center, token))
    }

    var usesWiFi: Bool {
        triggers.contains { $0.enabled && $0.conditions.contains { $0.kind == .wifi } }
    }

    func trigger(id: UUID) -> Trigger? {
        triggers.first { $0.id == id }
    }

    func evaluate() {
        let active = settings.triggersEnabled ? triggers.filter { $0.enabled && !$0.conditions.isEmpty } : []
        let kinds = Set(active.flatMap { $0.conditions.map(\.kind) })
        if kinds.contains(.wifi) { LocationPermission.shared.request() }
        let state = SystemState.read(for: kinds)

        let nowMatching = Set(active.filter { trigger in trigger.conditions.allSatisfy { $0.isMet(in: state) } }.map(\.id))
        if nowMatching != matching { matching = nowMatching }
        paused.formIntersection(nowMatching)

        var runningTrigger: UUID?
        switch sessions.session?.source {
        case .manual?:
            return
        case .trigger(let id, _)?:
            if nowMatching.contains(id) { return }
            runningTrigger = id
        case nil:
            break
        }

        // Il primo trigger dell'elenco che vale e non è in pausa.
        if let next = active.first(where: { nowMatching.contains($0.id) && !paused.contains($0.id) }) {
            sessions.start(.none,
                           source: .trigger(id: next.id, name: next.name),
                           allowDisplaySleep: next.allowDisplaySleep,
                           lidClosed: next.lidClosed)
        } else if let id = runningTrigger {
            sessions.stop(.triggerEnded(trigger(id: id)?.name ?? ""))
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(triggers) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
