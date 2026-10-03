import AppKit
import SwiftUI

/// Mostra l'icona nel Dock solo mentre è aperta una finestra dell'app.
@MainActor
enum DockIcon {
    private static var openWindows = Set<ObjectIdentifier>()

    static func windowOpened(_ window: NSWindow) {
        openWindows.insert(ObjectIdentifier(window))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowClosed(_ window: NSWindow) {
        openWindows.remove(ObjectIdentifier(window))
        if openWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Finestra riutilizzabile che segue il tema scelto e gestisce l'icona nel Dock.
@MainActor
class ManagedWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?

    func present(title: String, style: NSWindow.StyleMask, makeContent: () -> NSView) {
        let window = self.window ?? {
            let new = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
            new.isReleasedWhenClosed = false
            new.delegate = self
            new.contentView = makeContent()
            new.center()
            self.window = new
            return new
        }()
        window.title = title
        window.appearance = AppSettings.shared.appTheme.appearance
        DockIcon.windowOpened(window)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window { DockIcon.windowClosed(window) }
    }
}

@MainActor
final class SettingsWindow: ManagedWindow {
    private let sessions: SessionManager
    private let triggers: TriggerEngine

    init(sessions: SessionManager, triggers: TriggerEngine) {
        self.sessions = sessions
        self.triggers = triggers
    }

    func show() {
        sessions.lidHelper.refresh()
        present(title: String(localized: "Tazzina Settings"), style: [.titled, .closable]) {
            NSView()
        }
        guard let window, !(window.contentViewController is SettingsTabs) else { return }
        let tabs = SettingsTabs()
        tabs.add("general", String(localized: "General"), symbol: "gearshape") { GeneralPane() }
        let sessions = sessions, triggers = triggers
        tabs.add("triggers", String(localized: "Triggers"), symbol: "bolt") {
            TriggersPane(engine: triggers, sessions: sessions)
        }
        tabs.add("session", String(localized: "Session"), symbol: "timer") { SessionPane() }
        tabs.add("sounds", String(localized: "Sounds"), symbol: "speaker.wave.2") { SoundsPane() }
        if Lid.exists {
            let helper = sessions.lidHelper
            tabs.add("lid", String(localized: "Closed Lid"), symbol: "laptopcomputer") { LidPane(helper: helper) }
        }
        tabs.restoreSelection()
        window.contentViewController = tabs
        window.toolbarStyle = .preference
        window.center()
    }
}

/// Schede nella barra degli strumenti, come le Impostazioni delle app di sistema.
/// La finestra prende l'altezza della scheda scelta, che viene ricordata.
private final class SettingsTabs: NSTabViewController {
    private static let selectionKey = "settingsTab"

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        tabStyle = .toolbar
        transitionOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func add(_ id: String, _ title: String, symbol: String, @ViewBuilder pane: () -> some View) {
        let host = NSHostingController(rootView: SettingsPane(content: pane))
        host.sizingOptions = .preferredContentSize
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.identifier = id
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
    }

    func restoreSelection() {
        let saved = UserDefaults.standard.string(forKey: Self.selectionKey)
        if let index = tabViewItems.firstIndex(where: { $0.identifier as? String == saved }) {
            selectedTabViewItemIndex = index
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if let id = item?.identifier as? String { UserDefaults.standard.set(id, forKey: Self.selectionKey) }
    }
}

@MainActor
final class AboutWindow: ManagedWindow {
    func show() {
        present(title: "", style: [.titled, .closable, .fullSizeContentView]) {
            NSHostingView(rootView: AboutView())
        }
        window?.titlebarAppearsTransparent = true
        window?.isMovableByWindowBackground = true
    }
}

/// "Altro orario…": scegli fino a quando tenere sveglio il Mac.
@MainActor
final class UntilTimeWindow: ManagedWindow {
    func show(onStart: @escaping (Date) -> Void) {
        window?.close()
        let defaultDate = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        let view = UntilTimeView(date: defaultDate) { [weak self] date in
            if let date { onStart(date) }
            self?.window?.close()
        }
        if let window {
            window.contentView = NSHostingView(rootView: view)
        }
        present(title: String(localized: "Keep Awake Until"), style: [.titled, .closable]) {
            NSHostingView(rootView: view)
        }
    }
}

private struct UntilTimeView: View {
    @State var date: Date
    let done: (Date?) -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep the Mac awake until:")
                .font(.headline)
            DatePicker("", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { done(date) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(date <= .now)
            }
        }
        .padding(20)
        .frame(width: 320)
        .preferredColorScheme(settings.appTheme.colorScheme)
    }
}

// MARK: - Informazioni

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 110, height: 110)
                .shadow(radius: 4)

            VStack(spacing: 5) {
                Text(verbatim: "Tazzina")
                    .font(.system(size: 26, weight: .bold))
                Text("Version \(version) (\(build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(width: 280)
                .padding(.vertical, 4)

            HStack(spacing: 4) {
                Text("Made with")
                Image(systemName: "heart.fill").foregroundStyle(.red)
                Text("by Gionnio").fontWeight(.medium)
            }

            Link(destination: URL(string: "https://github.com/Gionnio/tazzina")!) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("GitHub Repository").fontWeight(.medium)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            Spacer().frame(height: 4)

            VStack(spacing: 3) {
                Text(verbatim: "MIT License")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(verbatim: "Copyright © 2026 Gionnio")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(30)
        .frame(width: 320)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
