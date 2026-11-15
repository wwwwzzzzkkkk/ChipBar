// USB-C telemetry pipeline. The SMC D-channel/IOPort UUID correlation is based on
// the open-source Wattson and WhatPort projects (MIT). See THIRD_PARTY_USBC_LICENSE.md.
import Foundation
import IOKit

/// One physical USB-C connector. The SMC figure is a measurement; USB speed
/// capability is not an achieved link and is deliberately kept separate.
struct USBCPortMeasurement: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let number: Int?
    let isConnected: Bool
    let protocolName: String
    let maximumGbps: Double?
    let currentGbps: Double?
    let voltage: Double?
    let current: Double?
    let watts: Double?

    var isSourcing: Bool { (watts ?? 0) > 0.05 }
    var status: String {
        if isSourcing { return "对外供电" }
        if isConnected { return "已连接 · 无功率读数" }
        return "未连接"
    }
}

struct USBCDeviceLink: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    /// Physical port, only when an ancestor publishes an explicit UsbIOPort path.
    let portID: String?
    let linkGbps: Double?
    let allocatedWatts: Double?
}

struct USBCPowerSnapshot: Equatable, Sendable {
    var ports: [USBCPortMeasurement] = []
    var devices: [USBCDeviceLink] = []

    /// Sum only verified SMC channels, not USB allocation budgets.
    /// Nil is missing telemetry; 0 requires an actual zero-current rail.
    var totalWatts: Double? {
        let readings = ports.compactMap(\.watts)
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +)
    }
    var sourcingPorts: [USBCPortMeasurement] {
        ports.filter(\.isSourcing).sorted { ($0.watts ?? 0) > ($1.watts ?? 0) }
    }
}

/// Read from a single existing SMC connection on the established power cadence.
/// All APIs are read-only; no sub-processes, drivers or elevated privileges.
enum USBCPowerReader {
    private struct Channel {
        let number: Int
        let uuid: String?
        let volts: Double?
        let amps: Double?

        var watts: Double? {
            guard let volts, let amps, volts.isFinite, amps.isFinite,
                  (4...60).contains(volts), (0...10).contains(amps)
            else { return nil }
            return volts * amps
        }
    }

    private struct ThunderboltLink {
        var supportedMask: Int = 0
        var supportedWidth: Int = 0
        var currentCode: Int = 0
        var currentWidth: Int = 0

        private static func laneGbps(_ code: Int) -> Double? {
            switch code {
            case 0x2: return 40
            case 0x4: return 20
            case 0x8: return 10
            default: return nil
            }
        }
        var maximumGbps: Double? {
            guard let code = [0x2, 0x4, 0x8].first(where: { supportedMask & $0 != 0 }),
                  let lane = Self.laneGbps(code), supportedWidth > 0 else { return nil }
            return lane * Double(supportedWidth)
        }
        var protocolName: String? {
            if supportedMask & 0x2 != 0 { return "Thunderbolt 5 / USB4 v2" }
            if supportedMask & 0x4 != 0 { return "Thunderbolt 4 / USB4" }
            if supportedMask & 0x8 != 0 { return "Thunderbolt 3" }
            return nil
        }
        var actualGbps: Double? {
            guard let lane = Self.laneGbps(currentCode), currentWidth > 0 else { return nil }
            return lane * Double(currentWidth)
        }
    }

    static func read(smc: SMCReader?, includeDevices: Bool = false) -> USBCPowerSnapshot {
        let channels: [Channel] = (1...4).map { number in
            let raw = smc?.describe("D\(number)UI")
            let uuid: String? = {
                guard let raw, raw.size == 16, raw.bytes.count == 16 else { return nil }
                let decoded = raw.bytes.map { String(format: "%02x", $0) }.joined()
                // An empty/uninitialized controller UUID is not a valid join key.
                return decoded.allSatisfy { $0 == "0" } ? nil : decoded
            }()
            return Channel(number: number, uuid: uuid,
                           volts: smc?.double("D\(number)JV"),
                           amps: smc?.double("D\(number)JI"))
        }
        let hasSMCUUIDs = channels.contains { $0.uuid != nil }
        let thunderbolt = thunderboltLinks()
        var iterator: io_iterator_t = 0
        // IOAccessoryManager is the common superclass of the physical
        // AppleHPM/AppleTCController port nodes across M1–M5 generations.
        // PortDescription and PortNumber are not reliable on every chip.
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccessoryManager"), &iterator)
                == KERN_SUCCESS
        else { return USBCPowerSnapshot() }
        defer { IOObjectRelease(iterator) }

        var ports: [USBCPortMeasurement] = []
        var seen = Set<String>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let props = properties(service),
                  let entryName = registryEntryName(service),
                  entryName == "Port-USB-C" || entryName.hasPrefix("Port-USB-C@")
            else { continue }
            // Keep only real built-in USB-C sockets; a subclass can include
            // internal accessory-manager services or non-USB-C connectors.
            if let type = props["PortTypeDescription"] as? String, type != "USB-C" {
                continue
            }
            if let builtIn = props["BuiltIn"] as? NSNumber, !builtIn.boolValue {
                continue
            }
            // IORegistry renders Port-USB-C@N by combining the registry entry
            // name with its *location in plane*. N is not part of the name.
            let number = registryPortNumber(service)
                ?? (props["PortNumber"] as? NSNumber)?.intValue
            let identity = normalisedUUID(controllerUUID(of: service))
            guard let key = portIdentifier(number: number, controllerUUID: identity),
                  seen.insert(key).inserted else { continue }
            let channel: Channel? = {
                if hasSMCUUIDs {
                    guard let identity else { return nil }
                    return channels.first { $0.uuid == identity }
                }
                // Legacy Apple Silicon without any DxUI keys. Never use this
                // fallback on machines which DO publish UUIDs: misattribution
                // is worse than an unavailable reading.
                guard let number else { return nil }
                return channels.first { $0.number == number }
            }()
            let supported = props["TransportsSupported"] as? [String] ?? []
            let active = (props["TransportsActive"] as? [String])
                ?? (props["TransportsProvisioned"] as? [String]) ?? []
            let tb = number.flatMap { thunderbolt[$0] }
            let protocolName: String
            if let name = tb?.protocolName {
                protocolName = name
            } else if supported.contains("CIO") {
                protocolName = "Thunderbolt / USB4"
            } else if supported.contains("USB3") {
                protocolName = "USB 3.x"
            } else if supported.contains("USB2") {
                protocolName = "USB 2.0"
            } else {
                protocolName = "USB-C"
            }
            // A transport name alone does not specify the negotiated or
            // maximum bit rate. Do not invent 10 Gb/s for every USB3 port.
            let maximum = tb?.maximumGbps
            // The Thunderbolt controller advertises a stale current-speed code
            // even on empty sockets. Show achieved speed only with active CIO.
            let actual = active.contains("CIO") ? tb?.actualGbps : nil
            ports.append(USBCPortMeasurement(
                id: key, label: number.map { "USB-C \($0)" } ?? "USB-C",
                number: number,
                isConnected: (props["ConnectionActive"] as? Bool)
                    ?? active.contains(where: { $0 != "CC" }),
                protocolName: protocolName, maximumGbps: maximum,
                currentGbps: actual,
                voltage: channel?.watts == nil ? nil : channel?.volts,
                current: channel?.watts == nil ? nil : channel?.amps,
                watts: channel?.watts
            ))
        }
        ports.sort {
            if $0.isSourcing != $1.isSourcing { return $0.isSourcing }
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            return ($0.number ?? Int.max) < ($1.number ?? Int.max)
        }
        // Deep USB device/ancestor enumeration is only needed while the
        // power sidecar is visible, not on every idle Home refresh.
        return USBCPowerSnapshot(ports: ports,
                                 devices: includeDevices ? usbDevices() : [])
    }

    private static func properties(_ service: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
                == KERN_SUCCESS else { return nil }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    /// The physical port's @N suffix is its IOService-plane location, which
    /// macOS represents in hex. The registry name alone is "Port-USB-C".
    private static func registryPortNumber(_ service: io_registry_entry_t) -> Int? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetLocationInPlane(service, kIOServicePlane, &buffer)
                == KERN_SUCCESS else { return nil }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        let location = String(decoding: buffer[..<length].map {
            UInt8(bitPattern: $0)
        }, as: UTF8.self)
        return Int(location, radix: 16)
    }

    private static func registryEntryName(_ service: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(service, &buffer) == KERN_SUCCESS else { return nil }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<length].map {
            UInt8(bitPattern: $0)
        }, as: UTF8.self)
    }

    /// Stable key also matches UsbIOPort ancestry on attached USB devices.
    /// Do not use a constant "Port-USB-C" ID for multiple physical sockets.
    static func portIdentifier(number: Int?, controllerUUID: String?) -> String? {
        if let number, number >= 0 {
            return "Port-USB-C@" + String(number, radix: 16)
        }
        if let controllerUUID, !controllerUUID.isEmpty {
            return "Port-USB-C-" + controllerUUID
        }
        return nil
    }

    /// The UUID normally belongs to the HPM parent, but some models add
    /// intermediate nodes. Read it only from an actual HPM controller ancestor.
    private static func controllerUUID(of service: io_registry_entry_t) -> String? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<12 {
            var buffer = [CChar](repeating: 0, count: 128)
            if IOObjectGetClass(current, &buffer) == KERN_SUCCESS {
                let length = buffer.firstIndex(of: 0) ?? buffer.count
                let className = String(decoding: buffer[..<length].map {
                    UInt8(bitPattern: $0)
                }, as: UTF8.self)
                if className == "AppleHPMDevice" ||
                    className.hasPrefix("AppleHPMDeviceHAL") {
                    return properties(current)?["UUID"] as? String
                }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
                    == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    static func normalisedUUID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hex = raw.lowercased().filter(\.isHexDigit)
        return hex.count == 32 ? hex : nil
    }

    private static func thunderboltLinks() -> [Int: ThunderboltLink] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOThunderboltPort"), &iterator)
                == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var links: [Int: ThunderboltLink] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let props = properties(service),
                  props["Description"] as? String == "Thunderbolt Port",
                  let socket = (props["Socket ID"] as? String).flatMap(Int.init)
                    ?? (props["Socket ID"] as? NSNumber)?.intValue else { continue }
            var link = links[socket] ?? ThunderboltLink()
            link.supportedMask |= (props["Supported Link Speed"] as? NSNumber)?.intValue ?? 0
            link.supportedWidth = max(link.supportedWidth,
                (props["Supported Link Width"] as? NSNumber)?.intValue ?? 0)
            let currentCode = (props["Current Link Speed"] as? NSNumber)?.intValue ?? 0
            if currentCode != 0 { link.currentCode = currentCode }
            link.currentWidth = max(link.currentWidth,
                (props["Current Link Width"] as? NSNumber)?.intValue ?? 0)
            links[socket] = link
        }
        return links
    }

    private static func usbDevices() -> [USBCDeviceLink] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOUSBHostDevice"), &iterator)
                == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [USBCDeviceLink] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let props = properties(service),
                  let location = (props["locationID"] as? NSNumber)?.intValue else { continue }
            let name = (props["USB Product Name"] as? String)
                ?? (props["kUSBProductString"] as? String)
                ?? (props["IOName"] as? String) ?? "USB 设备"
            let rawSpeed = (props["UsbLinkSpeed"] as? NSNumber)?.doubleValue
            let linkGbps = rawSpeed.flatMap { value -> Double? in
                guard value.isFinite, value > 0 else { return nil }
                return value / 1_000_000_000
            }
            let allocated = (props["UsbPowerSinkAllocation"] as? NSNumber)?.doubleValue
            result.append(USBCDeviceLink(id: location, name: name,
                                        portID: physicalPortName(of: service),
                                        linkGbps: linkGbps,
                                        allocatedWatts: allocated.map { $0 * 5 / 1000 }))
        }
        return result.sorted { $0.name < $1.name }
    }

    /// The physical USB-C port is an explicit registry path on UsbIOPort
    /// ancestors, including devices behind hubs. Never infer it just from the
    /// controller bus index: multiple physical sockets can share a controller.
    private static func physicalPortName(of device: io_registry_entry_t) -> String? {
        var current = device
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<20 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
                    == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
            guard let raw = IORegistryEntryCreateCFProperty(
                current, "UsbIOPort" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() else { continue }
            let path: String? = (raw as? String)
                ?? (raw as? Data).flatMap { String(data: $0, encoding: .utf8) }
            guard let path,
                  let name = path.trimmingCharacters(in: .controlCharacters)
                    .split(separator: "/").last.map(String.init),
                  name.hasPrefix("Port-USB-C@") else { continue }
            return name
        }
        return nil
    }
}
