import Foundation

public enum ApplicationActivityCachePolicy {
    public static let lifetime: TimeInterval = 10

    public static func isFresh(sampledAt: TimeInterval, now: TimeInterval) -> Bool {
        now >= sampledAt && now - sampledAt <= lifetime
    }
}

public struct ActivityProcess: Sendable {
    public let pid: Int32
    public let birth: UInt64
    public let group: String
    public let name: String
    public let appPath: String?
    public let cpuSeconds: Double?
    public let neuralBytes: UInt64?
    public let physicalBytes: UInt64?
    public let memoryIsRSSApproximation: Bool
    public init(pid: Int32, birth: UInt64, group: String, name: String, appPath: String? = nil,
                cpuSeconds: Double?, neuralBytes: UInt64? = nil, physicalBytes: UInt64? = nil,
                memoryIsRSSApproximation: Bool = false) {
        self.pid = pid; self.birth = birth; self.group = group; self.name = name
        self.appPath = appPath; self.cpuSeconds = cpuSeconds; self.neuralBytes = neuralBytes
        self.physicalBytes = physicalBytes
        self.memoryIsRSSApproximation = memoryIsRSSApproximation
    }
}

public struct ActivityGPUClient: Sendable {
    public let id: UInt64
    public let pid: Int32
    public let nanoseconds: [UInt64]
    public init(id: UInt64, pid: Int32, nanoseconds: [UInt64]) {
        self.id = id; self.pid = pid; self.nanoseconds = nanoseconds
    }
}

public struct ApplicationActivityRow: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let appPath: String?
    public var cpuPercent: Double?
    public var gpuPercent: Double?
    public var neuralBytes: UInt64?
    /// Sum of the readable processes' physical footprints, in bytes.
    public var physicalBytes: UInt64?
    public var memoryIsRSSApproximation: Bool
    public var processCount: Int
}

/// Single source of truth for the Memory tab and CLI diagnostic output.
/// Discard readings that are too small to represent a valid resident process
/// rather than rendering misleading "0.0 KB" on a machine with visible apps.
public enum ApplicationMemoryDisplay {
    public static let minimumDisplayBytes: UInt64 = 64 * 1024

    public static func validatedBytes(_ bytes: UInt64?) -> UInt64? {
        guard let bytes, bytes >= minimumDisplayBytes else { return nil }
        return bytes
    }

    public static func text(bytes: UInt64?, approximate: Bool) -> String {
        guard let bytes = validatedBytes(bytes) else { return "—" }
        let number = Double(bytes)
        let value: String
        if bytes >= 1_000_000_000 {
            value = String(format: "%.2f GB", number / 1_000_000_000)
        } else if bytes >= 1_000_000 {
            value = String(format: "%.1f MB", number / 1_000_000)
        } else {
            value = String(format: "%.1f KB", number / 1_000)
        }
        return approximate ? "≈" + value : value
    }
}

/// Only current process/client baselines are retained. Missing data stays nil.
public struct ActivityAccumulator: Sendable {
    private struct CPU: Sendable { let birth: UInt64; let seconds: Double; let time: Double }
    private struct GPU: Sendable { let pid: Int32; let birth: UInt64; let counters: [UInt64]; let time: Double }
    private var cpu: [Int32: CPU] = [:]
    private var gpu: [UInt64: GPU] = [:]
    public init() {}

    public mutating func update(processes: [ActivityProcess], clients: [ActivityGPUClient], time: Double) -> [ApplicationActivityRow] {
        var nextCPU: [Int32: CPU] = [:]
        var nextGPU: [UInt64: GPU] = [:]
        var rows: [String: ApplicationActivityRow] = [:]
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        var gpuRates: [Int32: Double] = [:]
        for client in clients {
            guard let process = byPID[client.pid], !client.nanoseconds.isEmpty else { continue }
            if let before = gpu[client.id], before.pid == client.pid, before.birth == process.birth,
               before.counters.count == client.nanoseconds.count,
               time > before.time, time - before.time <= 30,
               zip(client.nanoseconds, before.counters).allSatisfy({ $0 >= $1 }) {
                let delta = zip(client.nanoseconds, before.counters).reduce(0.0) { $0 + Double($1.0 - $1.1) }
                gpuRates[client.pid, default: 0] += delta / 1_000_000_000 / (time - before.time) * 100
            }
            nextGPU[client.id] = GPU(pid: client.pid, birth: process.birth, counters: client.nanoseconds, time: time)
        }
        for process in processes {
            var cpuRate: Double?
            if let seconds = process.cpuSeconds, seconds.isFinite, seconds >= 0 {
                if let before = cpu[process.pid], before.birth == process.birth,
                   time > before.time, time - before.time <= 30, seconds >= before.seconds {
                    cpuRate = (seconds - before.seconds) / (time - before.time) * 100
                }
                nextCPU[process.pid] = CPU(birth: process.birth, seconds: seconds, time: time)
            }
            var row = rows[process.group] ?? ApplicationActivityRow(id: process.group, name: process.name,
                appPath: process.appPath, cpuPercent: nil, gpuPercent: nil, neuralBytes: nil,
                physicalBytes: nil, memoryIsRSSApproximation: false, processCount: 0)
            row.processCount += 1
            if let cpuRate { row.cpuPercent = (row.cpuPercent ?? 0) + cpuRate }
            if let rate = gpuRates[process.pid] { row.gpuPercent = (row.gpuPercent ?? 0) + rate }
            if let bytes = process.neuralBytes {
                let (total, overflow) = (row.neuralBytes ?? 0).addingReportingOverflow(bytes)
                row.neuralBytes = overflow ? UInt64.max : total
            }
            // Zero isn't a useful memory reading; keep unavailable data as nil.
            if let bytes = process.physicalBytes, bytes > 0 {
                let (total, overflow) = (row.physicalBytes ?? 0).addingReportingOverflow(bytes)
                row.physicalBytes = overflow ? UInt64.max : total
                row.memoryIsRSSApproximation = row.memoryIsRSSApproximation || process.memoryIsRSSApproximation
            }
            rows[process.group] = row
        }
        cpu = nextCPU; gpu = nextGPU
        return Array(rows.values)
    }
}
