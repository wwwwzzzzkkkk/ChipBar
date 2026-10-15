import Foundation
import CoreFoundation

public enum SMARTDeviceType: String, CaseIterable, Identifiable, Sendable {
    case auto, nvme, sntasmedia, sntjmicron, sntrealtek
    public var id: String { rawValue }
}

public enum SSDReadError: Error, LocalizedError, Equatable {
    case invalidJSON, permission, unsupported, commandFailed, invalidDevice
    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "smartctl 未返回有效 JSON，请使用支持 -j 的 smartmontools。"
        case .permission: return "读取权限不足。请查看 SSD 设置中的权限说明。"
        case .unsupported: return "未返回 NVMe 温度；请检查硬盘盒 SMART 透传或设备类型设置。"
        case .commandFailed: return "SMART 读取失败；请检查连接、权限及设备类型。"
        case .invalidDevice: return "外接物理磁盘已断开或无法确认。"
        }
    }
}

public struct SSDTemperature: Sendable, Equatable {
    public let model: String
    public let composite: Double?
    /// Sparse positions preserve the actual NVMe sensor numbers.
    public let sensors: [Double?]
    public let passed: Bool?
    public let criticalWarning: Int?
    public let percentageUsed: Int?
    public let partialRead: Bool
    public let date: Date

    public func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age <= 90
    }

    public static func decode(_ data: Data, exitStatus: Int32 = 0, date: Date = Date()) throws -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SSDReadError.invalidJSON
        }
        let meta = root["smartctl"] as? [String: Any] ?? [:]
        let status = Int(exitStatus) | (integer(meta["exit_status"]) ?? 0)
        let messages = (meta["messages"] as? [[String: Any]] ?? [])
            .compactMap { $0["string"] as? String }.joined(separator: " ").lowercased()
        if messages.contains("permission denied") || messages.contains("operation not permitted") {
            throw SSDReadError.permission
        }
        // Bits 3–7 report health/log warnings, not failure to read temperature.
        guard status & 3 == 0 else { throw SSDReadError.commandFailed }
        guard let log = root["nvme_smart_health_information_log"] as? [String: Any] else {
            throw SSDReadError.unsupported
        }
        let generic = root["temperature"] as? [String: Any]
        let composite = temperature(log["temperature"]) ?? temperature(generic?["current"])
        let sensors = Array((log["temperature_sensors"] as? [Any] ?? []).prefix(8)).map(temperature)
        guard composite != nil || sensors.contains(where: { $0 != nil }) else { throw SSDReadError.unsupported }
        let health = (root["smart_status"] as? [String: Any])?["passed"] as? NSNumber
        let passed = health.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
        let used = integer(log["percentage_used"])
        return Self(model: String((root["model_name"] as? String ?? "NVMe SSD").prefix(120)),
                    composite: composite, sensors: sensors, passed: passed,
                    criticalWarning: integer(log["critical_warning"]),
                    percentageUsed: used.flatMap { (0...255).contains($0) ? $0 : nil },
                    partialRead: status & 4 != 0, date: date)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value.rounded() == value, (-1_000_000...1_000_000).contains(value) else { return nil }
        return Int(value)
    }
    private static func temperature(_ value: Any?) -> Double? {
        guard let value = number(value), (-40...125).contains(value) else { return nil }
        return value
    }
}

public struct ExternalDisk: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public static func identifiers(from data: Data) throws -> [String] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let disks = root["AllDisksAndPartitions"] as? [[String: Any]] else { throw SSDReadError.invalidDevice }
        return Array(Set(disks.compactMap { $0["DeviceIdentifier"] as? String }.filter(validIdentifier))).sorted()
    }

    public static func decodeInfo(_ data: Data, expectedID: String) throws -> Self {
        guard validIdentifier(expectedID),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["DeviceIdentifier"] as? String == expectedID,
              info["Internal"] as? Bool == false, info["WholeDisk"] as? Bool == true,
              info["VirtualOrPhysical"] as? String == "Physical" else { throw SSDReadError.invalidDevice }
        return Self(id: expectedID, name: String((info["MediaName"] as? String ?? expectedID).prefix(120)))
    }

    public static func validIdentifier(_ id: String) -> Bool {
        id.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil && id.count <= 20
    }

    public func smartArguments(type: SMARTDeviceType) -> [String] {
        ["-j", "-i", "-H", "-A", "-d", type.rawValue, "/dev/" + id]
    }
}
