import Foundation

public struct DiskCounters: Sendable {
    public let identity: UInt64
    public let readBytes: UInt64
    public let writtenBytes: UInt64
    public init(identity: UInt64, readBytes: UInt64, writtenBytes: UInt64) {
        self.identity = identity; self.readBytes = readBytes; self.writtenBytes = writtenBytes
    }
}

public struct DiskRates: Sendable {
    public let readMB: Double
    public let writeMB: Double
}

/// One baseline per connected physical disk. A replaced disk or counter reset starts over.
public struct DiskRateAccumulator: Sendable {
    private var previous: [String: DiskCounters] = [:]
    private var previousTime: Double?
    public init() {}
    public mutating func update(_ counters: [String: DiskCounters], time: Double) -> [String: DiskRates] {
        defer { previous = counters; previousTime = time }
        guard let before = previousTime, time.isFinite, time > before, time - before <= 10 else { return [:] }
        let seconds = time - before
        var result: [String: DiskRates] = [:]
        for (id, current) in counters {
            guard let old = previous[id], old.identity == current.identity,
                  current.readBytes >= old.readBytes, current.writtenBytes >= old.writtenBytes else { continue }
            result[id] = DiskRates(readMB: Double(current.readBytes - old.readBytes) / seconds / 1_000_000,
                                   writeMB: Double(current.writtenBytes - old.writtenBytes) / seconds / 1_000_000)
        }
        return result
    }
}

public struct DiskVolumeSpace: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let total: Int64
    public let available: Int64
    public let apfs: Bool
    public init?(id: String, name: String, total: Int64, available: Int64, apfs: Bool) {
        guard total > 0, available >= 0, available <= total else { return nil }
        self.id = id; self.name = name; self.total = total; self.available = available; self.apfs = apfs
    }
    public var availableFraction: Double { Double(available) / Double(total) }
}
