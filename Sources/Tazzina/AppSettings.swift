import AppKit
import SwiftUI

/// Tutte le preferenze dell'app, salvate in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // Generale
    @AppStorage("leftClickToggles") var leftClickToggles = true { willSet { objectWillChange.send() } }
    /// Durata in minuti della sessione avviata con il clic sinistro (0 = senza limite).
    @AppStorage("quickDuration") var quickDuration = 0 { willSet { objectWillChange.send() } }
    @AppStorage("showRemainingTime") var showRemainingTime = true { willSet { objectWillChange.send() } }
    @AppStorage("startSessionAtLaunch") var startSessionAtLaunch = false { willSet { objectWillChange.send() } }
    @AppStorage("appTheme") var theme = AppTheme.system.rawValue { willSet { objectWillChange.send() } }

    // Sessione
    @AppStorage("allowDisplaySleep") var allowDisplaySleep = false { willSet { objectWillChange.send() } }
    @AppStorage("endOnLowBattery") var endOnLowBattery = false { willSet { objectWillChange.send() } }
    @AppStorage("lowBatteryPercent") var lowBatteryPercent = 20 { willSet { objectWillChange.send() } }
    @AppStorage("endWhenUnplugged") var endWhenUnplugged = false { willSet { objectWillChange.send() } }
    @AppStorage("notifyOnAutomaticEnd") var notifyOnAutomaticEnd = true { willSet { objectWillChange.send() } }

    // Suoni
    @AppStorage("playStartSound") var playStartSound = true { willSet { objectWillChange.send() } }
    @AppStorage("startSound") var startSound = "Glass" { willSet { objectWillChange.send() } }
    @AppStorage("playStopSound") var playStopSound = true { willSet { objectWillChange.send() } }
    @AppStorage("stopSound") var stopSound = "Bottle" { willSet { objectWillChange.send() } }
    @AppStorage("soundVolume") var soundVolume = 0.7 { willSet { objectWillChange.send() } }

    // Trigger
    @AppStorage("triggersEnabled") var triggersEnabled = true { willSet { objectWillChange.send() } }
    /// Suoni di accensione/spegnimento anche per le sessioni dei trigger.
    @AppStorage("triggerSounds") var triggerSounds = true { willSet { objectWillChange.send() } }

    // Coperchio chiuso
    @AppStorage("lidClosedByDefault") var lidClosedByDefault = false { willSet { objectWillChange.send() } }

    var appTheme: AppTheme { AppTheme(rawValue: theme) ?? .system }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Per le finestre AppKit, dove `preferredColorScheme` non arriva.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Suoni di sistema di macOS (/System/Library/Sounds).
@MainActor
enum SystemSounds {
    private static let folder = URL(fileURLWithPath: "/System/Library/Sounds")
    /// Riferimento al suono in riproduzione, così non viene liberato a metà.
    private static var current: NSSound?

    static let names: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()

    static func play(_ name: String, volume: Double? = nil) {
        let volume = volume ?? AppSettings.shared.soundVolume
        let url = folder.appendingPathComponent(name).appendingPathExtension("aiff")
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return }
        current?.stop()
        sound.volume = Float(max(0, min(1, volume)))
        sound.play()
        current = sound
    }
}
