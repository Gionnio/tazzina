import AppKit
import Combine

@main
@MainActor
enum TazzinaApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sessions = SessionManager()
    private var statusBar: StatusBarController?
    private lazy var triggers = TriggerEngine(sessions: sessions)
    private lazy var settingsWindow = SettingsWindow(sessions: sessions, triggers: triggers)
    private let aboutWindow = AboutWindow()
    private var themeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyTheme()
        themeObserver = AppSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyTheme() }

        statusBar = StatusBarController(
            sessions: sessions,
            triggers: triggers,
            openSettings: { [weak self] in self?.settingsWindow.show() },
            openAbout: { [weak self] in self?.aboutWindow.show() }
        )
        Task { await sessions.lidHelper.updateIfNeeded() }

        if AppSettings.shared.startSessionAtLaunch {
            sessions.toggle()
        }
        triggers.evaluate()
    }

    /// Riaprire l'app (es. dal Finder) mostra le Impostazioni, visto che non ha finestre.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    /// Automazione: tazzina://on, tazzina://on?minutes=30, tazzina://on?app=com.apple.Safari,
    /// tazzina://off, tazzina://toggle
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "tazzina" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let minutes = query.first { $0.name == "minutes" }?.value.flatMap(Int.init)
            let appID = query.first { $0.name == "app" }?.value
            switch url.host {
            case "on":
                if let appID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first {
                    sessions.start(.whileAppRuns(bundleID: appID, name: app.localizedName ?? appID))
                } else if let minutes, minutes > 0 {
                    sessions.start(.minutes(minutes))
                } else {
                    sessions.start(.none)
                }
            case "off": sessions.stop()
            case "toggle": sessions.toggle()
            default: break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessions.stop(.quitting)
    }

    private func applyTheme() {
        NSApp.appearance = AppSettings.shared.appTheme.appearance
    }
}
