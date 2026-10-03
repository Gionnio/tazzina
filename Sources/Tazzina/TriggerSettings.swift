import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TriggersPane: View {
    @ObservedObject var engine: TriggerEngine
    @ObservedObject var sessions: SessionManager
    @ObservedObject private var settings = AppSettings.shared
    @State private var editing: Trigger?
    @State private var isNew = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Use triggers", isOn: $settings.triggersEnabled)
                        .onChange(of: settings.triggersEnabled) { _, _ in engine.evaluate() }
                    Hint("A trigger keeps the Mac awake while all its conditions are true, and lets it sleep again when they stop. A session you start yourself always comes first.")
                }
                Toggle("Play the on/off sounds for triggers too", isOn: $settings.triggerSounds)
            }

            if engine.usesWiFi, !LocationPermission.shared.isGranted {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "location.slash").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("macOS shows the Wi-Fi network name only to apps allowed to use Location.")
                                .font(.callout)
                            Button("Open Location Settings") {
                                LocationPermission.shared.request()
                                NSWorkspace.shared.open(URL(string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                            }
                        }
                    }
                }
            }

            Section {
                if engine.triggers.isEmpty {
                    Text("No triggers yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach($engine.triggers) { $trigger in
                    TriggerRow(trigger: $trigger, status: status(of: trigger)) {
                        isNew = false
                        editing = trigger
                    } onDelete: {
                        engine.triggers.removeAll { $0.id == trigger.id }
                    }
                }
            } header: {
                Text("Triggers")
            } footer: {
                HStack {
                    Spacer()
                    Button {
                        isNew = true
                        editing = Trigger(name: String(localized: "New Trigger"))
                    } label: {
                        Label("Add Trigger", systemImage: "plus")
                    }
                }
            }
            .disabled(!settings.triggersEnabled)
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { trigger in
            TriggerEditor(draft: trigger, canUseLid: Lid.exists && sessions.lidHelper.state == .installed) { saved in
                if let saved {
                    if let index = engine.triggers.firstIndex(where: { $0.id == saved.id }) {
                        engine.triggers[index] = saved
                    } else {
                        engine.triggers.append(saved)
                    }
                }
                editing = nil
            }
        }
    }

    private func status(of trigger: Trigger) -> TriggerRow.Status {
        if case .trigger(let id, _)? = sessions.session?.source, id == trigger.id { return .running }
        return engine.matching.contains(trigger.id) ? .matching : .idle
    }
}

private struct TriggerRow: View {
    enum Status { case idle, matching, running }

    @Binding var trigger: Trigger
    let status: Status
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $trigger.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: trigger.name).fontWeight(.medium)
                Text(verbatim: trigger.conditions.isEmpty
                     ? String(localized: "No conditions")
                     : trigger.conditions.map(\.summary).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            switch status {
            case .running: badge("Active", color: .green)
            case .matching: badge("Paused", color: .orange)
            case .idle: EmptyView()
            }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help(Text("Edit"))
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(Text("Delete"))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }

    private func badge(_ text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
    }
}

// MARK: - Editor

private struct TriggerEditor: View {
    @State var draft: Trigger
    let canUseLid: Bool
    let done: (Trigger?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                }

                Section {
                    if draft.conditions.isEmpty {
                        Text("Add at least one condition.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(draft.conditions.indices, id: \.self) { index in
                        HStack(alignment: .top) {
                            ConditionEditor(condition: $draft.conditions[index])
                            Button(role: .destructive) {
                                draft.conditions.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help(Text("Remove"))
                        }
                    }
                } header: {
                    Text("Keep the Mac awake while all these are true")
                } footer: {
                    HStack {
                        Spacer()
                        Menu {
                            ForEach(Condition.Kind.allCases) { kind in
                                Button {
                                    draft.conditions.append(kind.makeDefault())
                                } label: {
                                    Label(kind.title, systemImage: kind.symbol)
                                }
                            }
                        } label: {
                            Label("Add Condition", systemImage: "plus")
                        }
                        .fixedSize()
                    }
                }

                Section("During the session") {
                    Toggle("Allow the display to sleep", isOn: $draft.allowDisplaySleep)
                    if Lid.exists {
                        Toggle("Stay awake with the lid closed", isOn: $draft.lidClosed)
                            .disabled(!canUseLid)
                        if !canUseLid {
                            Hint("Install the system service in the Closed Lid tab first.")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { done(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
    }
}

/// Modifica i valori di una condizione secondo il suo tipo.
private struct ConditionEditor: View {
    @Binding var condition: Condition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(condition.kind.title, systemImage: condition.kind.symbol)
                .fontWeight(.medium)
            editor
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var editor: some View {
        switch condition {
        case .appRunning(let id, let name):
            AppPicker(bundleID: id, name: name) { condition = .appRunning(bundleID: $0, name: $1) }
        case .appFrontmost(let id, let name):
            AppPicker(bundleID: id, name: name) { condition = .appFrontmost(bundleID: $0, name: $1) }
        case .wifi(let ssid):
            NameField(placeholder: "Network name", value: ssid,
                      suggestions: SystemState.currentSSID().map { [$0] } ?? []) { condition = .wifi(ssid: $0) }
        case .externalDisplay:
            Hint("True while at least one display other than the built-in one is connected.")
        case .power(let connected):
            Picker("", selection: Binding(get: { connected }, set: { condition = .power(connected: $0) })) {
                Text("Connected").tag(true)
                Text("Disconnected (on battery)").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case .batteryAbove(let percent):
            Stepper(value: Binding(get: { percent }, set: { condition = .batteryAbove(percent: $0) }),
                    in: 5...95, step: 5) {
                Text("Above \(percent)%")
            }
        case .schedule(let days, let start, let end):
            ScheduleEditor(days: days, start: start, end: end) {
                condition = .schedule(days: $0, startMinute: $1, endMinute: $2)
            }
        case .usbDevice(let name):
            NameField(placeholder: "Device name", value: name,
                      suggestions: SystemState.usbDeviceNames()) { condition = .usbDevice(name: $0) }
        case .bluetoothDevice(let name):
            NameField(placeholder: "Device name", value: name,
                      suggestions: SystemState.pairedBluetoothNames()) { condition = .bluetoothDevice(name: $0) }
        case .drive(let name):
            NameField(placeholder: "Drive name", value: name,
                      suggestions: SystemState.driveNames()) { condition = .drive(name: $0) }
        }
    }
}

/// Campo di testo con un menu dei valori disponibili ora (reti, dispositivi, dischi).
private struct NameField: View {
    let placeholder: LocalizedStringKey
    let value: String
    let suggestions: [String]
    let set: (String) -> Void

    var body: some View {
        HStack {
            TextField(placeholder, text: Binding(get: { value }, set: set))
                .labelsHidden()
            Menu {
                if suggestions.isEmpty {
                    Text("Nothing found")
                }
                ForEach(Array(Set(suggestions)).sorted(), id: \.self) { name in
                    Button(name) { set(name) }
                }
            } label: {
                Text("Choose")
            }
            .fixedSize()
        }
    }
}

private struct AppPicker: View {
    let bundleID: String
    let name: String
    let set: (String, String) -> Void

    var body: some View {
        HStack {
            if let icon = icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(verbatim: name.isEmpty ? String(localized: "No app chosen") : name)
                .foregroundStyle(name.isEmpty ? .secondary : .primary)
            Spacer()
            Menu {
                ForEach(runningApps, id: \.0) { id, appName in
                    Button(appName) { set(id, appName) }
                }
                Divider()
                Button("Other App…") { chooseApp() }
            } label: {
                Text("Choose")
            }
            .fixedSize()
        }
    }

    private var icon: NSImage? {
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier else { return }
        let appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        set(id, appName)
    }
}

private struct ScheduleEditor: View {
    let days: Set<Int>
    let start: Int
    let end: Int
    let set: (Set<Int>, Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Schedule.orderedDays, id: \.self) { day in
                    let on = days.contains(day)
                    Button {
                        var newDays = days
                        if on { newDays.remove(day) } else { newDays.insert(day) }
                        set(newDays, start, end)
                    } label: {
                        Text(verbatim: Schedule.dayName(day))
                            .frame(width: 26, height: 22)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(on ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("From")
                DatePicker("", selection: time(start) { set(days, $0, end) }, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Text("to")
                DatePicker("", selection: time(end) { set(days, start, $0) }, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            if end <= start {
                Hint("Ends the next day.")
            }
        }
    }

    /// Converte "minuti dalla mezzanotte" in una data di oggi per il DatePicker, e viceversa.
    private func time(_ minutes: Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }
    }
}
