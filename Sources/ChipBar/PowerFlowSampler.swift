import Foundation
import Combine
import IOKit
import IOKit.ps

/// Only the values observed in read-only SMC and IOPowerSources are shown.
/// An internal SMC DC rail is not a wall-socket AC power meter.
struct ChipBarPowerReading: Equatable, Sendable {
    var hasBattery: Bool
    var onAdapter: Bool
    var isCharging: Bool
    var batteryPercent: Double?
    var adapterWatts: Double?
    var batteryWatts: Double?
    var systemWatts: Double?
    var sourceLabel: String
    var live: Bool
    var sourceKey: String? = nil
    var usb: USBCPowerSnapshot = USBCPowerSnapshot()

    static let unavailable = ChipBarPowerReading(
        hasBattery: false, onAdapter: true, isCharging: false,
        batteryPercent: nil, adapterWatts: nil, batteryWatts: nil,
        systemWatts: nil, sourceLabel: "未检测到可用功率传感器", live: false
    )
}

/// The SMC/DC power rail is slower-changing than chip activity; poll it
/// independently from the user-configured macmon CPU/GPU sampling interval.
enum PowerSamplingCadence {
    static let seconds = 3
    static let nanoseconds: UInt64 = 3_000_000_000
}

actor ChipBarPowerSampler {
    private var smc: SMCReader?
    private var missed = 0

    func read(includeUSBDevices: Bool = false) -> ChipBarPowerReading {
        if smc == nil { smc = SMCReader() }
        // Collect USB-C telemetry from this same SMC connection, at the same
        // three-second cadence. No secondary timer or subprocess is needed.
        let usb = USBCPowerReader.read(smc: smc, includeDevices: includeUSBDevices)
        let battery = Self.batteryState()

        if let battery {
            let rawAdapter = smc?.double("PDTR")
            let current = smc?.double("B0AC")
            let voltage = smc?.double("B0AV")
            let pack: Double? = {
                guard let current, let voltage,
                      current.isFinite, voltage.isFinite,
                      abs(current) < 20_000, voltage > 1_000, voltage < 30_000 else { return nil }
                return current * voltage / 1_000_000
            }()
            let input = Self.power(rawAdapter, allowZero: true)
            let adapter = battery.connected ? input : 0
            let batteryWatts = pack
            let systemWatts: Double? = {
                guard let pack else { return nil }
                if !battery.connected { return pack < 0 ? -pack : nil }
                guard let input else { return nil }
                let result = input - pack
                return result >= 0 && result < 500 ? result : nil
            }()
            let available = pack != nil && (!battery.connected || input != nil)
            checkConnection(healthy: available)
            return ChipBarPowerReading(
                hasBattery: true, onAdapter: battery.connected,
                isCharging: battery.charging, batteryPercent: battery.percent,
                adapterWatts: adapter, batteryWatts: batteryWatts,
                systemWatts: systemWatts,
                sourceLabel: available ? "SMC 实时采样 · 系统侧为功率差估算" : "传感器暂不可用",
                live: available,
                sourceKey: available
                    ? (battery.connected ? "PDTR + B0AC/B0AV" : "B0AC/B0AV")
                    : nil,
                usb: usb
            )
        }

        // Desktop Apple Silicon: PSTR is preferred. On models with PSTR=0
        // the DC-in rail may be exposed as PDTR or PD0R instead.
        let candidates = ["PSTR", "PDTR", "PD0R"]
        var power: Double?
        var source = ""
        for key in candidates {
            if let watts = Self.power(smc?.double(key), allowZero: false) {
                power = watts
                source = key
                break
            }
        }
        checkConnection(healthy: power != nil)
        return ChipBarPowerReading(
            hasBattery: false, onAdapter: true, isCharging: false,
            batteryPercent: nil, adapterWatts: nil, batteryWatts: nil,
            systemWatts: power,
            sourceLabel: power == nil ? "未检测到内部系统功率传感器" : "SMC \(source) · 内部 DC 功率，非插座 AC 输入",
            live: power != nil, sourceKey: power == nil ? nil : source,
            usb: usb
        )
    }

    private func checkConnection(healthy: Bool) {
        if healthy { missed = 0; return }
        missed += 1
        if missed >= 3 {
            missed = 0
            if smc?.reconnect() != true { smc = SMCReader() }
        }
    }

    private static func power(_ value: Double?, allowZero: Bool) -> Double? {
        guard let value, value.isFinite,
              value < 500, (allowZero ? value >= 0 : value > 0) else { return nil }
        return value
    }

    private struct BatteryState {
        var percent: Double?
        var connected: Bool
        var charging: Bool
    }

    private static func batteryState() -> BatteryState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for item in sources {
            guard let dict = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                  (dict[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            let current = (dict[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maximum = (dict[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let percent = (current != nil && maximum != nil && maximum! > 0)
                ? min(100, max(0, current! / maximum! * 100)) : nil
            return BatteryState(
                percent: percent,
                connected: (dict[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                charging: (dict[kIOPSIsChargingKey] as? Bool) ?? false
            )
        }
        return nil
    }
}

@MainActor final class ChipBarPowerFlowModel: ObservableObject {
    static let shared = ChipBarPowerFlowModel()
    @Published private(set) var reading = ChipBarPowerReading.unavailable
    // Chip and system DC numbers are latched into one 3-second power frame.
    // The dashboard's independent 1/2/5/10 s macmon updates cannot jitter
    // the Sankey between SMC readings.
    @Published private(set) var chipWattsAtReading: Double?
    private let sampler = ChipBarPowerSampler()

    func watch(chipPower: @MainActor @escaping () -> Double?,
               needsUSBDevices: @MainActor @escaping () -> Bool = { false }) async {
        while !Task.isCancelled {
            let shouldEnumerateDevices = needsUSBDevices()
            let result = await sampler.read(includeUSBDevices: shouldEnumerateDevices)
            guard !Task.isCancelled else { return }
            chipWattsAtReading = chipPower()
            reading = result
            do { try await Task.sleep(nanoseconds: PowerSamplingCadence.nanoseconds) }
            catch { return }
        }
    }
}
