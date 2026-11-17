import Foundation
import Combine
import IOKit
import IOKit.ps

/// Expose raw sensor availability so an absent battery rail does not erase
/// independently measured adapter/system/SoC readings.
struct PowerSensorDiagnostics: Equatable, Sendable {
    var adapterPDTR: Double?
    var systemPSTR: Double?
    var batteryPPBR: Double?
    var batteryB0APMilliwatts: Double?
    var registryBatteryWatts: Double?
    var batteryCurrentB0AC: Double?
    var batteryVoltageB0AV: Double?
    var systemSource: String?
    var batterySource: String?

    static let empty = PowerSensorDiagnostics()
}

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
    var isCharged: Bool = false
    var diagnostics: PowerSensorDiagnostics = .empty

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
            // Read the three SMC physical domains independently. A missing
            // PPBR/B0AC must NOT invalidate a good PDTR or PSTR measurement.
            let rawAdapter = smc?.double("PDTR")
            let rawSystem = smc?.double("PSTR")
            let rawPack = smc?.double("PPBR")
            let rawB0AP = smc?.double("B0AP")
            let current = smc?.double("B0AC")
            let voltage = smc?.double("B0AV")
            var packReading = Self.selectBatteryPower(
                directWatts: rawPack,
                currentMilliAmps: current,
                voltageMilliVolts: voltage,
                directMilliWatts: rawB0AP)
            // AppleSmartBattery may update more slowly than SMC. Read the
            // published values only when SMC is missing or reports near zero
            // despite an active charge/discharge state. No extra timer.
            let needsRegistry = packReading == nil ||
                (abs(packReading?.watts ?? 0) <= 0.25 &&
                 (battery.charging || !battery.connected))
            let registry = needsRegistry ? Self.registryBatteryPower() : nil
            if let registry, Self.registryPowerMatchesState(
                registry, onAdapter: battery.connected, charging: battery.charging),
               packReading == nil || abs(registry) > 0.25 {
                packReading = (registry, "AppleSmartBattery (cached)")
            }
            let adapter = battery.connected ? Self.power(rawAdapter, allowZero: true) : nil
            let frame = Self.laptopSystemFrame(
                onAdapter: battery.connected,
                adapterWatts: adapter,
                batteryWatts: packReading?.watts,
                measuredSystemWatts: rawSystem,
                batteryIsCached: packReading?.source == "AppleSmartBattery (cached)")

            let observed = (adapter != nil && (adapter ?? 0) > 0)
                || frame.systemWatts != nil || packReading != nil
            checkConnection(healthy: observed)
            let hasBatteryPower = packReading != nil
            var availableKeys = [String]()
            if adapter != nil { availableKeys.append("PDTR") }
            if let systemSource = frame.systemSource { availableKeys.append(systemSource) }
            if let source = packReading?.source { availableKeys.append(source) }

            let sourceDescription = observed
                ? (hasBatteryPower ? "SMC 已采样 · 系统与电池分流需核验"
                                   : "SMC 部分数据可用 · 电池功率暂不可用")
                : "SMC 功率传感器暂不可用"
            return ChipBarPowerReading(
                hasBattery: true, onAdapter: battery.connected,
                isCharging: battery.charging, batteryPercent: battery.percent,
                adapterWatts: adapter, batteryWatts: packReading?.watts,
                systemWatts: frame.systemWatts,
                sourceLabel: sourceDescription, live: observed,
                sourceKey: availableKeys.isEmpty ? nil : availableKeys.joined(separator: " + "),
                usb: usb, isCharged: battery.charged,
                diagnostics: PowerSensorDiagnostics(
                    adapterPDTR: Self.power(rawAdapter, allowZero: true),
                    systemPSTR: Self.power(rawSystem, allowZero: true),
                    batteryPPBR: Self.validPackWatts(rawPack),
                    batteryB0APMilliwatts: rawB0AP,
                    registryBatteryWatts: registry,
                    batteryCurrentB0AC: current,
                    batteryVoltageB0AV: voltage,
                    systemSource: frame.systemSource,
                    batterySource: packReading?.source)
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

    /// Select a valid system load without requiring battery telemetry.
    /// A measured PSTR is an independent system-side value (sometimes slightly
    /// delayed); a PDTR adapter value is NEVER silently relabelled as system.
    /// When both adapter and pack are available from the same short SMC pass,
    /// their net balance is preferred for a conservational flow chart.
    static func laptopSystemFrame(onAdapter: Bool, adapterWatts: Double?,
                                  batteryWatts: Double?, measuredSystemWatts: Double?,
                                  batteryIsCached: Bool = false)
        -> (systemWatts: Double?, systemSource: String?) {
        let measured = power(measuredSystemWatts, allowZero: false)
        if onAdapter {
            if let adapter = power(adapterWatts, allowZero: true),
               let pack = validPackWatts(batteryWatts) {
                let net = adapter - pack
                if net > 0, net < 500 {
                    // A cached registry battery read must not override a
                    // materially different independent system rail.
                    if batteryIsCached, let measured,
                       abs(measured - net) > max(3, measured * 0.15) {
                        return (measured, "PSTR")
                    }
                    return (net, batteryIsCached ? "PDTR−battery (cached estimate)" : "PDTR−battery")
                }
            }
        } else if let pack = validPackWatts(batteryWatts), pack < -0.5 {
            if batteryIsCached, let measured,
               abs(measured + pack) > max(3, measured * 0.15) {
                return (measured, "PSTR")
            }
            return (-pack, batteryIsCached ? "battery discharge (cached)" : "battery discharge")
        }
        if let measured { return (measured, "PSTR") }
        return (nil, nil)
    }

    private static func validPackWatts(_ value: Double?) -> Double? {
        guard let value, value.isFinite, abs(value) < 500 else { return nil }
        return value
    }

    /// Prefer the battery-pack power rail if present and active, but accept
    /// current × voltage if the direct sensor is missing or only reports zero.
    /// A real 0 W from either source remains 0 W (not nil).
    static func selectBatteryPower(directWatts: Double?, currentMilliAmps: Double?,
                                   voltageMilliVolts: Double?, directMilliWatts: Double? = nil)
        -> (watts: Double, source: String)? {
        let direct = validPackWatts(directWatts)
        let b0ap = validPackWatts(directMilliWatts.map { $0 / 1_000 })
        let derived = batteryWatts(currentMilliAmps: currentMilliAmps,
                                   voltageMilliVolts: voltageMilliVolts)
        // B0AP is the signed battery pack power supported by the Apple
        // Silicon SMC battery driver. Prefer an active signed direct reading.
        if let b0ap, abs(b0ap) > 0.25 { return (b0ap, "B0AP") }
        if let direct, abs(direct) > 0.25 { return (direct, "PPBR") }
        if let derived, abs(derived) > 0.25 { return (derived, "B0AC/B0AV") }
        if let b0ap { return (b0ap, "B0AP") }
        if let direct { return (direct, "PPBR") }
        if let derived { return (derived, "B0AC/B0AV") }
        return nil
    }

    static func batteryWatts(currentMilliAmps: Double?, voltageMilliVolts: Double?) -> Double? {
        guard let current = currentMilliAmps, let voltage = voltageMilliVolts,
              current.isFinite, voltage.isFinite,
              abs(current) < 20_000, voltage > 1_000, voltage < 30_000
        else { return nil }
        return validPackWatts(current * voltage / 1_000_000)
    }

    /// IORegistry can publish a negative integer as unsigned two's complement.
    /// Decode both 64-bit and legacy 32-bit representations without abs().
    static func signedBatteryCurrent(_ number: NSNumber) -> Double {
        let value = number.int64Value
        if value > Int64(Int32.max), value <= Int64(UInt32.max) {
            return Double(Int32(bitPattern: UInt32(value)))
        }
        return Double(value)
    }

    static func registryPowerMatchesState(_ watts: Double, onAdapter: Bool, charging: Bool) -> Bool {
        guard validPackWatts(watts) != nil else { return false }
        if !onAdapter { return watts < 0 }
        if charging { return watts >= 0 }
        // While connected and not charging, the battery can assist.
        return watts <= 0.5
    }

    private static func registryBatteryPower() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> NSNumber? {
            IORegistryEntryCreateCFProperty(service, key as CFString,
                                            kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        }
        // InstantAmperage is preferred. Amperage is a slower published average.
        let current = (number("InstantAmperage") ?? number("Amperage")).map(signedBatteryCurrent)
        return batteryWatts(currentMilliAmps: current,
                            voltageMilliVolts: number("Voltage")?.doubleValue)
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
        var charged: Bool
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
                charging: (dict[kIOPSIsChargingKey] as? Bool) ?? false,
                charged: (dict[kIOPSIsChargedKey] as? Bool) ?? false
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
