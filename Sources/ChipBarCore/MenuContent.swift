import Foundation

public enum MenuContent: String, CaseIterable, Identifiable {
    case logo, power, utilization, memory, cpuTemperature, fans, network, disk, externalDisk
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .logo: return "显示 Logo"
        case .power: return "功率"
        case .utilization: return "CPU / GPU 占用率"
        case .memory: return "系统内存使用率"
        case .cpuTemperature: return "CPU 温度"
        case .fans: return "风扇转速"
        case .network: return "实时上传 / 下载速度"
        case .disk: return "硬盘总读取 / 写入速度"
        case .externalDisk: return "外置硬盘读取 / 写入速度"
        }
    }
}

/// One compact two-line column. Transfer columns use a value on both lines.
public struct MenuReadout: Identifiable, Equatable {
    public let id: String
    public let top: String
    public let bottom: String
    public let pairedValues: Bool
    public init(_ id: String, _ top: String, _ bottom: String, pairedValues: Bool = false) {
        self.id = id; self.top = top; self.bottom = bottom; self.pairedValues = pairedValues
    }

    public static func rate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        let units = ["B/s", "K/s", "M/s", "G/s", "T/s"]
        var value = bytes, index = 0
        while value >= 1_000, index < units.count - 1 { value /= 1_000; index += 1 }
        return String(format: value >= 100 || index == 0 ? "%.0f%@" : "%.1f%@", value, units[index])
    }
}
