import Foundation
import ServiceManagement
import TazzinaShared

/// Installa e usa il servizio di sistema che tiene acceso il Mac a coperchio chiuso.
@MainActor
final class LidHelper: ObservableObject {
    enum State {
        case notInstalled, needsApproval, installed
    }

    @Published private(set) var state: State = .notInstalled
    /// Chiamato se il servizio si riavvia: va ripetuta la richiesta in corso.
    var onRestart: (() -> Void)?

    private let service = SMAppService.daemon(plistName: LidControlInfo.daemonPlist)
    private var connection: NSXPCConnection?

    init() {
        refresh()
    }

    func refresh() {
        state = switch service.status {
        case .enabled: .installed
        case .requiresApproval: .needsApproval
        default: .notInstalled
        }
    }

    func install() {
        do {
            try service.register()
        } catch {
            NSLog("Tazzina: registrazione del servizio: \(error.localizedDescription)")
        }
        refresh()
        if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstall() async {
        connection?.invalidate()
        connection = nil
        try? await service.unregister()
        refresh()
    }

    /// Dopo un aggiornamento dell'app registra di nuovo il servizio, se è cambiato.
    func updateIfNeeded() async {
        guard state == .installed else { return }
        let running = await callHelper { helper, done in helper.version { done($0) } }
        guard running != LidControlInfo.helperVersion else { return }
        connection?.invalidate()
        connection = nil
        try? await service.unregister()
        try? service.register()
        refresh()
    }

    /// Restituisce true se il servizio ha applicato la richiesta.
    func setKeepAwakeWithLidClosed(_ enabled: Bool) async -> Bool {
        guard state == .installed else { return false }
        return await callHelper { helper, done in helper.keepAwakeWithLidClosed(enabled) { done($0) } } ?? false
    }

    private func callHelper<T: Sendable>(
        _ call: @escaping (LidControlProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) async -> T? {
        let connection = currentConnection()
        return await withCheckedContinuation { continuation in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                NSLog("Tazzina: servizio non raggiungibile: \(error.localizedDescription)")
                once.run { continuation.resume(returning: nil) }
            }
            guard let helper = proxy as? LidControlProtocol else {
                once.run { continuation.resume(returning: nil) }
                return
            }
            call(helper) { value in once.run { continuation.resume(returning: value) } }
        }
    }

    /// Una connessione che resta aperta: se l'app si chiude o va in crash il servizio lo
    /// capisce dalla connessione caduta e ripristina lo stop.
    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let new = NSXPCConnection(machServiceName: LidControlInfo.machService, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: LidControlProtocol.self)
        new.setCodeSigningRequirement(LidControlInfo.helperRequirement)
        new.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        new.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.onRestart?() }
        }
        new.resume()
        connection = new
        return new
    }
}

/// Evita di riprendere due volte la stessa continuation (risposta + errore XPC).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}
