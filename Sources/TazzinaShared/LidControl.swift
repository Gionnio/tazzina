import Foundation

/// Nomi e requisiti condivisi tra l'app e il servizio di sistema che gestisce il coperchio chiuso.
public enum LidControlInfo {
    public static let appIdentifier = "com.github.gionnio.Tazzina"
    public static let helperIdentifier = "com.github.gionnio.Tazzina.Helper"
    public static let machService = helperIdentifier
    public static let daemonPlist = "\(helperIdentifier).plist"
    /// Da incrementare quando cambia il servizio, così l'app lo registra di nuovo.
    public static let helperVersion = "1"

    /// L'app è firmata ad-hoc: il servizio accetta solo client con questo identificativo di firma.
    public static let clientRequirement = "identifier \"\(appIdentifier)\""
    public static let helperRequirement = "identifier \"\(helperIdentifier)\""
}

/// Interfaccia XPC del servizio di sistema.
@objc public protocol LidControlProtocol {
    /// Chiede di tenere acceso il Mac anche a coperchio chiuso (`true`) o di tornare al
    /// comportamento normale (`false`). La richiesta vale finché la connessione resta aperta.
    func keepAwakeWithLidClosed(_ enabled: Bool, reply: @escaping (Bool) -> Void)

    /// Versione del servizio, per capire se va reinstallato dopo un aggiornamento dell'app.
    func version(reply: @escaping (String) -> Void)
}
