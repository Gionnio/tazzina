import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Le "asserzioni" di risparmio energia: finché sono attive macOS non va in stop per inattività.
/// Si vedono con `pmset -g assertions`.
@MainActor
final class SleepBlocker {
    private var systemID: IOPMAssertionID?
    private var displayID: IOPMAssertionID?

    func update(active: Bool, allowDisplaySleep: Bool) {
        systemID = set(systemID, on: active, type: "PreventUserIdleSystemSleep")
        displayID = set(displayID, on: active && !allowDisplaySleep, type: "PreventUserIdleDisplaySleep")
    }

    private func set(_ id: IOPMAssertionID?, on: Bool, type: String) -> IOPMAssertionID? {
        if !on {
            if let id { IOPMAssertionRelease(id) }
            return nil
        }
        if let id { return id }
        var newID = IOPMAssertionID(0)
        let reason = "Tazzina keeps this Mac awake" as CFString
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &newID)
        return result == kIOReturnSuccess ? newID : nil
    }
}

struct PowerStatus: Equatable {
    var onBattery: Bool
    /// Carica in percentuale, nil sui Mac senza batteria.
    var batteryPercent: Int?

    static func read() -> PowerStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerStatus(onBattery: false, batteryPercent: nil)
        }
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var status = PowerStatus(onBattery: source == kIOPSBatteryPowerValue, batteryPercent: nil)
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for item in list {
            guard let desc = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let now = desc[kIOPSCurrentCapacityKey] as? Int,
                  let full = desc[kIOPSMaxCapacityKey] as? Int, full > 0 else { continue }
            status.batteryPercent = Int((Double(now) / Double(full) * 100).rounded())
        }
        return status
    }
}

/// Avvisa quando cambia l'alimentazione (alimentatore collegato/scollegato, livello batteria),
/// senza controlli periodici.
@MainActor
final class PowerWatcher {
    private var source: CFRunLoopSource?
    private let onChange: (PowerStatus) -> Void

    init(onChange: @escaping (PowerStatus) -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let watcher = Unmanaged<PowerWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange(PowerStatus.read()) }
        }
        if let loop = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
            source = loop
        }
    }

    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
    }
}

enum Lid {
    /// true se il coperchio è chiuso, nil sui Mac senza coperchio (desktop).
    static func isClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
    }

    static var exists: Bool { isClosed() != nil }
}
