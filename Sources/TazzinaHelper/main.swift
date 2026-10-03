import Foundation
import TazzinaShared

// Servizio di sistema di Tazzina. Gira come root e fa una sola cosa: impedisce lo stop a
// coperchio chiuso (`pmset disablesleep`) finché almeno un'app collegata lo chiede.
// Se l'app si chiude o va in crash la connessione cade e lo stop torna normale.

/// File che segnala "stop disattivato da noi": se il servizio riparte e lo trova,
/// ripristina subito lo stop (es. dopo un crash o una mancanza di corrente).
let flagFile = URL(fileURLWithPath: "/Library/Application Support/Tazzina/lid-sleep-disabled")

func runPmset(disableSleep: Bool) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = ["-a", "disablesleep", disableSleep ? "1" : "0"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        NSLog("Tazzina Helper: pmset non avviato: \(error.localizedDescription)")
        return false
    }
}

/// Tiene il conto delle connessioni che vogliono il Mac acceso a coperchio chiuso.
final class LidSleepState {
    private let queue = DispatchQueue(label: "com.github.gionnio.Tazzina.Helper.state")
    private var requesters = Set<ObjectIdentifier>()

    func restoreAfterUnexpectedExit() {
        queue.sync {
            guard FileManager.default.fileExists(atPath: flagFile.path) else { return }
            NSLog("Tazzina Helper: stop lasciato disattivato, lo ripristino")
            if runPmset(disableSleep: false) { try? FileManager.default.removeItem(at: flagFile) }
        }
    }

    func update(_ client: ObjectIdentifier, wants: Bool) -> Bool {
        queue.sync {
            let before = !requesters.isEmpty
            if wants { requesters.insert(client) } else { requesters.remove(client) }
            let after = !requesters.isEmpty
            if before == after { return true }
            if after {
                try? FileManager.default.createDirectory(
                    at: flagFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: flagFile.path, contents: Data())
                return runPmset(disableSleep: true)
            }
            let ok = runPmset(disableSleep: false)
            if ok { try? FileManager.default.removeItem(at: flagFile) }
            return ok
        }
    }
}

final class ClientSession: NSObject, LidControlProtocol {
    let id: ObjectIdentifier
    let state: LidSleepState

    init(id: ObjectIdentifier, state: LidSleepState) {
        self.id = id
        self.state = state
    }

    func keepAwakeWithLidClosed(_ enabled: Bool, reply: @escaping (Bool) -> Void) {
        reply(state.update(id, wants: enabled))
    }

    func version(reply: @escaping (String) -> Void) {
        reply(LidControlInfo.helperVersion)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let state: LidSleepState

    init(state: LidSleepState) {
        self.state = state
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(LidControlInfo.clientRequirement)
        let id = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: LidControlProtocol.self)
        connection.exportedObject = ClientSession(id: id, state: state)
        let release = { [state] in _ = state.update(id, wants: false) }
        connection.invalidationHandler = release
        connection.interruptionHandler = release
        connection.resume()
        return true
    }
}

let state = LidSleepState()
state.restoreAfterUnexpectedExit()
let delegate = ListenerDelegate(state: state)
let listener = NSXPCListener(machServiceName: LidControlInfo.machService)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
