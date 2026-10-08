import Foundation

public enum PowerMetric: String, CaseIterable, Identifiable {
    case total, cpu, gpu
    public var id: String { rawValue }
    public var title: String {
        switch self { case .total: return "芯片合计"; case .cpu: return "CPU"; case .gpu: return "GPU" }
    }
}

/// macmon pipe emits one JSON object per line; unknown fields are deliberately ignored.
public struct Sample: Identifiable {
    public let id = UUID()
    public let date: Date
    public let cpu: Double?
    public let gpu: Double?
    public let ane: Double?
    public let total: Double?
    public let cpuTemperature: Double?
    public let gpuTemperature: Double?
    public let chip: String?
    public let model: String?
    public var derivedTotal: Bool

    public func power(_ metric: PowerMetric) -> Double? {
        switch metric { case .total: return total; case .cpu: return cpu; case .gpu: return gpu }
    }

    public static func decode(_ data: Data, receivedAt: Date = Date()) throws -> Sample {
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: data) }
        catch { throw ParseError.invalidJSON }
        guard let object = decoded as? [String: Any] else {
            throw ParseError.notMetrics
        }
        func number(_ value: Any?, temperature: Bool = false) -> Double? {
            guard let n = value as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let value = n.doubleValue
            guard value.isFinite, value >= 0 else { return nil }
            if temperature && (value <= 0 || value > 150) { return nil }
            return value
        }
        let cpu = number(object["cpu_power"])
        let gpu = number(object["gpu_power"])
        let ane = number(object["ane_power"])
        let reported = number(object["all_power"])
        let summed: Double? = cpu.flatMap { c in gpu.flatMap { g in ane.map { c + g + $0 } } }
        let temp = object["temp"] as? [String: Any] ?? [:]
        let cpuTemp = number(temp["cpu_temp_avg"], temperature: true)
        let gpuTemp = number(temp["gpu_temp_avg"], temperature: true)
        guard cpu != nil || gpu != nil || reported != nil || ane != nil || cpuTemp != nil || gpuTemp != nil else {
            throw ParseError.notMetrics
        }
        let soc = object["soc"] as? [String: Any]
        return Sample(date: receivedAt, cpu: cpu, gpu: gpu, ane: ane,
                      total: reported ?? summed, cpuTemperature: cpuTemp, gpuTemperature: gpuTemp,
                      chip: soc?["chip_name"] as? String, model: soc?["mac_model"] as? String,
                      derivedTotal: reported == nil && summed != nil)
    }
}

import CoreFoundation

public enum ParseError: Error, LocalizedError {
    case notMetrics, oversizedLine, invalidJSON
    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "macmon 输出不是有效 JSON。请检查所选程序及 macmon pipe 接口。"
        case .notMetrics: return "JSON 中没有可用的功率或温度指标。请检查 macmon 版本和硬件支持。"
        case .oversizedLine: return "macmon 输出超出 1 MB 限制，采样已停止。"
        }
    }
}

/// Handles split UTF-8 bytes and multiple lines in a single read, without unbounded buffering.
public struct LineBuffer {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= 1_048_576 else { throw ParseError.oversizedLine }
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        guard buffer.count <= 1_048_576 else { throw ParseError.oversizedLine }
        return lines
    }
    public mutating func finish() -> Data? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : buffer
    }
}
