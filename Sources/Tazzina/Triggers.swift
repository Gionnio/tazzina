import AppKit
import CoreLocation
import CoreWLAN
import IOBluetooth
import IOKit

/// Una regola che tiene sveglio il Mac finché tutte le sue condizioni sono vere.
struct Trigger: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var enabled = true
    var conditions: [Condition] = []
    var allowDisplaySleep = false
    var lidClosed = false
}

/// Una singola condizione di un trigger.
enum Condition: Codable, Hashable, Identifiable {
    case appRunning(bundleID: String, name: String)
    case appFrontmost(bundleID: String, name: String)
    case wifi(ssid: String)
    case externalDisplay
    case power(connected: Bool)
    case batteryAbove(percent: Int)
    case schedule(days: Set<Int>, startMinute: Int, endMinute: Int)
    case usbDevice(name: String)
    case bluetoothDevice(name: String)
    case drive(name: String)

    var id: Self { self }

    enum Kind: String, CaseIterable, Identifiable {
        case appRunning, appFrontmost, wifi, externalDisplay, power, batteryAbove, schedule,
             usbDevice, bluetoothDevice, drive

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appRunning: String(localized: "App is running")
            case .appFrontmost: String(localized: "App is in front")
            case .wifi: String(localized: "Wi-Fi network")
            case .externalDisplay: String(localized: "External display connected")
            case .power: String(localized: "Power adapter")
            case .batteryAbove: String(localized: "Battery level")
            case .schedule: String(localized: "Time of day")
            case .usbDevice: String(localized: "USB device connected")
            case .bluetoothDevice: String(localized: "Bluetooth device connected")
            case .drive: String(localized: "Drive connected")
            }
        }

        var symbol: String {
            switch self {
            case .appRunning: "app.badge"
            case .appFrontmost: "macwindow"
            case .wifi: "wifi"
            case .externalDisplay: "display"
            case .power: "powerplug"
            case .batteryAbove: "battery.75percent"
            case .schedule: "calendar.badge.clock"
            case .usbDevice: "cable.connector"
            case .bluetoothDevice: "headphones"
            case .drive: "externaldrive"
            }
        }

        /// Condizione nuova con valori iniziali sensati.
        func makeDefault() -> Condition {
            switch self {
            case .appRunning: .appRunning(bundleID: "", name: "")
            case .appFrontmost: .appFrontmost(bundleID: "", name: "")
            case .wifi: .wifi(ssid: SystemState.currentSSID() ?? "")
            case .externalDisplay: .externalDisplay
            case .power: .power(connected: true)
            case .batteryAbove: .batteryAbove(percent: 30)
            case .schedule: .schedule(days: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 18 * 60)
            case .usbDevice: .usbDevice(name: "")
            case .bluetoothDevice: .bluetoothDevice(name: "")
            case .drive: .drive(name: "")
            }
        }
    }

    var kind: Kind {
        switch self {
        case .appRunning: .appRunning
        case .appFrontmost: .appFrontmost
        case .wifi: .wifi
        case .externalDisplay: .externalDisplay
        case .power: .power
        case .batteryAbove: .batteryAbove
        case .schedule: .schedule
        case .usbDevice: .usbDevice
        case .bluetoothDevice: .bluetoothDevice
        case .drive: .drive
        }
    }

    /// Descrizione breve per l'elenco dei trigger.
    var summary: String {
        switch self {
        case .appRunning(_, let name): String(localized: "\(name.isEmpty ? "?" : name) is running")
        case .appFrontmost(_, let name): String(localized: "\(name.isEmpty ? "?" : name) is in front")
        case .wifi(let ssid): String(localized: "Wi-Fi “\(ssid)”")
        case .externalDisplay: String(localized: "External display")
        case .power(let connected): connected ? String(localized: "On power adapter") : String(localized: "On battery")
        case .batteryAbove(let percent): String(localized: "Battery above \(percent)%")
        case .schedule(let days, let start, let end):
            "\(Schedule.daysText(days)) \(Schedule.timeText(start))–\(Schedule.timeText(end))"
        case .usbDevice(let name): "USB “\(name)”"
        case .bluetoothDevice(let name): "Bluetooth “\(name)”"
        case .drive(let name): String(localized: "Drive “\(name)”")
        }
    }

    func isMet(in state: SystemState) -> Bool {
        switch self {
        case .appRunning(let id, _): !id.isEmpty && state.runningApps.contains(id)
        case .appFrontmost(let id, _): !id.isEmpty && state.frontmostApp == id
        case .wifi(let ssid): !ssid.isEmpty && state.ssid == ssid
        case .externalDisplay: state.hasExternalDisplay
        case .power(let connected): state.power.onBattery != connected
        case .batteryAbove(let percent): (state.power.batteryPercent ?? 100) > percent
        case .schedule(let days, let start, let end): Schedule.contains(state.now, days: days, start: start, end: end)
        case .usbDevice(let name): !name.isEmpty && state.usbDevices.contains(name)
        case .bluetoothDevice(let name): !name.isEmpty && state.bluetoothDevices.contains(name)
        case .drive(let name): !name.isEmpty && state.drives.contains(name)
        }
    }
}

enum Schedule {
    /// Giorni con la numerazione di Calendar: 1 = domenica … 7 = sabato.
    static func contains(_ date: Date, days: Set<Int>, start: Int, end: Int) -> Bool {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday else { return false }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if start <= end {
            return days.contains(weekday) && minute >= start && minute < end
        }
        // Fascia che passa la mezzanotte (es. 22–6): la parte dopo mezzanotte appartiene al giorno prima.
        let yesterday = weekday == 1 ? 7 : weekday - 1
        return (days.contains(weekday) && minute >= start) || (days.contains(yesterday) && minute < end)
    }

    static func timeText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Giorni nell'ordine della settimana locale (es. lun…dom in Italia).
    static var orderedDays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    static func dayName(_ day: Int) -> String {
        Calendar.current.veryShortStandaloneWeekdaySymbols[day - 1]
    }

    static func daysText(_ days: Set<Int>) -> String {
        if days.count == 7 { return String(localized: "Every day") }
        if days == [2, 3, 4, 5, 6] { return String(localized: "Weekdays") }
        if days == [1, 7] { return String(localized: "Weekends") }
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        return orderedDays.filter(days.contains).map { symbols[$0 - 1] }.joined(separator: ", ")
    }
}

/// Fotografia dello stato del Mac, letta solo per le condizioni usate davvero.
struct SystemState {
    var now = Date.now
    var runningApps = Set<String>()
    var frontmostApp: String?
    var ssid: String?
    var hasExternalDisplay = false
    var power = PowerStatus(onBattery: false, batteryPercent: nil)
    var usbDevices = Set<String>()
    var bluetoothDevices = Set<String>()
    var drives = Set<String>()

    @MainActor
    static func read(for kinds: Set<Condition.Kind>) -> SystemState {
        var state = SystemState()
        if kinds.contains(.appRunning) {
            state.runningApps = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        if kinds.contains(.appFrontmost) {
            state.frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        if kinds.contains(.wifi) { state.ssid = currentSSID() }
        if kinds.contains(.externalDisplay) { state.hasExternalDisplay = externalDisplayConnected() }
        if kinds.contains(.power) || kinds.contains(.batteryAbove) { state.power = PowerStatus.read() }
        if kinds.contains(.usbDevice) { state.usbDevices = Set(usbDeviceNames()) }
        if kinds.contains(.bluetoothDevice) { state.bluetoothDevices = Set(connectedBluetoothNames()) }
        if kinds.contains(.drive) { state.drives = Set(driveNames()) }
        return state
    }

    /// Nome della rete Wi-Fi attuale. macOS lo rivela solo con il permesso Posizione.
    static func currentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    @MainActor
    static func externalDisplayConnected() -> Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) == 0
        }
    }

    static func usbDeviceNames() -> [String] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
                == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while case let device = IOIteratorNext(iterator), device != IO_OBJECT_NULL {
            defer { IOObjectRelease(device) }
            if let name = IORegistryEntryCreateCFProperty(device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                names.append(name)
            }
        }
        return names
    }

    static func pairedBluetoothNames() -> [String] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.compactMap(\.name)
    }

    static func connectedBluetoothNames() -> [String] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.filter { $0.isConnected() }.compactMap(\.name)
    }

    static func driveNames() -> [String] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.filter { $0.path != "/" }.compactMap { try? $0.resourceValues(forKeys: [.volumeNameKey]).volumeName }
    }
}

/// Chiede il permesso Posizione, necessario a macOS per leggere il nome della rete Wi-Fi.
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()
    private let manager = CLLocationManager()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var isGranted: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedAlways || status == .authorized
    }

    var isDenied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    func request() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in onChange?() }
    }
}
