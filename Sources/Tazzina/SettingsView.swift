import ServiceManagement
import SwiftUI

/// Adatta una scheda delle Impostazioni alla finestra: larghezza fissa, altezza del contenuto.
struct SettingsPane<Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .scrollDisabled(true)
            .frame(width: 520)
            .fixedSize(horizontal: false, vertical: true)
            .preferredColorScheme(settings.appTheme.colorScheme)
    }
}

/// Spiegazione breve sotto un'opzione.
struct Hint: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Generale

struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Start a session when Tazzina opens", isOn: $settings.startSessionAtLaunch)
                    Hint("Uses the quick session duration below.")
                }
            }

            Section("Menu bar icon") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Left click", selection: $settings.leftClickToggles) {
                        Text("Turns Tazzina on or off").tag(true)
                        Text("Opens the menu").tag(false)
                    }
                    Hint("Right click or Control-click always opens the menu.")
                }
                Picker("Quick session duration", selection: $settings.quickDuration) {
                    Text("No time limit").tag(0)
                    Divider()
                    ForEach(StatusBarController.durations, id: \.self) { minutes in
                        Text(TimeText.duration(minutes: minutes)).tag(minutes)
                    }
                }
                Toggle("Show remaining time next to the icon", isOn: $settings.showRemainingTime)
            }

            Section {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Tazzina: avvio al login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Sessione

struct SessionPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Allow the display to sleep", isOn: $settings.allowDisplaySleep)
                    Hint("The Mac stays awake but the screen can turn off. Applies to new sessions; you can change it from the menu during a session.")
                }
            }

            Section("Battery") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("End the session when the battery is low", isOn: $settings.endOnLowBattery)
                    Hint("Only while running on battery.")
                }
                if settings.endOnLowBattery {
                    Stepper(value: $settings.lowBatteryPercent, in: 5...90, step: 5) {
                        Text("Below \(settings.lowBatteryPercent)%")
                    }
                }
                Toggle("End the session when the power adapter is disconnected", isOn: $settings.endWhenUnplugged)
            }

            Section("Notifications") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Notify me when a session ends on its own", isOn: $settings.notifyOnAutomaticEnd)
                    Hint("When time is up, the chosen app is closed or the battery runs low.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Suoni

struct SoundsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                SoundRow(title: "Play a sound when Tazzina turns on",
                         enabled: $settings.playStartSound, sound: $settings.startSound)
                SoundRow(title: "Play a sound when Tazzina turns off",
                         enabled: $settings.playStopSound, sound: $settings.stopSound)
            } footer: {
                Hint("The turn-off sound also plays when a session ends on its own.")
            }

            Section {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $settings.soundVolume, in: 0...1) { editing in
                        if !editing { SystemSounds.play(settings.startSound) }
                    }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
            } header: {
                Text("Volume")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SoundRow: View {
    let title: LocalizedStringKey
    @Binding var enabled: Bool
    @Binding var sound: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(title, isOn: $enabled)
            HStack {
                Picker("Sound", selection: $sound) {
                    ForEach(SystemSounds.names, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .onChange(of: sound) { _, name in SystemSounds.play(name) }
                Button {
                    SystemSounds.play(sound)
                } label: {
                    Image(systemName: "play.fill")
                }
                .help(Text("Play"))
            }
            .disabled(!enabled)
        }
    }
}

// MARK: - Coperchio chiuso

struct LidPane: View {
    @ObservedObject var helper: LidHelper
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Hint("macOS always sleeps when you close the lid, even if an app asks it not to. To keep working with the lid closed, Tazzina needs a small system service, approved once in System Settings. Sleep goes back to normal as soon as the session ends, Tazzina quits or crashes.")
            }

            Section("System service") {
                HStack {
                    statusBadge
                    Spacer()
                    switch helper.state {
                    case .notInstalled:
                        Button("Install") { helper.install() }
                    case .needsApproval:
                        Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                        Button("Check Again") { helper.refresh() }
                    case .installed:
                        Button("Remove") { Task { await helper.uninstall() } }
                    }
                }
                if helper.state == .needsApproval {
                    Hint("In System Settings › General › Login Items & Extensions, turn on Tazzina under “Allow in the Background”.")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Stay awake with the lid closed in every new session", isOn: $settings.lidClosedByDefault)
                    Hint("You can also turn it on or off for the current session from the menu.")
                }
                .disabled(helper.state != .installed)
            } footer: {
                Label("Don't put a running Mac in a bag: with the lid closed and no airflow it can overheat.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .onAppear { helper.refresh() }
    }

    @ViewBuilder private var statusBadge: some View {
        switch helper.state {
        case .installed: badge("Installed", color: .green)
        case .needsApproval: badge("Waiting for approval", color: .orange)
        case .notInstalled: badge("Not installed", color: .secondary)
        }
    }

    private func badge(_ text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
    }
}
