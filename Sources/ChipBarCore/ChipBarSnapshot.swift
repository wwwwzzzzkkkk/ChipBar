import Foundation
import Security

/// A read-only, Codable rendering contract shared by ChipBar and ChipBarWidgets.
/// Values in this type come from the existing host monitor; the widget never
/// talks to SMC, Mach, disk services, or processes.
public struct ChipBarSnapshot: Codable, Sendable {
    public struct Metric: Codable, Sendable {
        public var percent: Double
        public var watts: Double
        public var tempC: Double?

        public init(percent: Double, watts: Double, tempC: Double?) {
            self.percent = percent
            self.watts = watts
            self.tempC = tempC
        }
    }

    public struct MemMetric: Codable, Sendable {
        public var percent: Double
        public var usedGB: Double
        public var totalGB: Double

        public init(percent: Double, usedGB: Double, totalGB: Double) {
            self.percent = percent
            self.usedGB = usedGB
            self.totalGB = totalGB
        }
    }

    public struct Volume: Codable, Sendable, Identifiable {
        public var name: String
        public var freeBytes: Int64
        public var totalBytes: Int64
        public var readMBs: Double?
        public var writeMBs: Double?
        public var id: String { name }

        public init(name: String, freeBytes: Int64, totalBytes: Int64,
                    readMBs: Double?, writeMBs: Double?) {
            self.name = name
            self.freeBytes = max(0, freeBytes)
            self.totalBytes = max(0, totalBytes)
            self.readMBs = readMBs?.isFinite == true ? readMBs : nil
            self.writeMBs = writeMBs?.isFinite == true ? writeMBs : nil
        }

        public var usedPercent: Double {
            guard totalBytes > 0 else { return 0 }
            return max(0, min(100,
                Double(totalBytes - freeBytes) / Double(totalBytes) * 100))
        }
    }

    public var timestamp: Date
    public var chipPower: Double
    public var avgPower: Double
    public var peakPower: Double
    /// Forty evenly spaced points from oldest to newest within ten minutes.
    public var powerSeries: [Double]
    public var internalPower: Double?
    public var cpu: Metric
    public var gpu: Metric
    public var mem: MemMetric
    public var cores: [Double]
    public var fanRPM: Int?
    public var aneWatts: Double
    public var volumes: [Volume]

    /// Display metadata, not synthetic measurements.
    public var chipName: String
    /// Only use a measured/verified CPU topology. 10 + 5 for sample M5 Pro.
    public var performanceCoreCount: Int

    public init(timestamp: Date, chipPower: Double, avgPower: Double,
                peakPower: Double, powerSeries: [Double], internalPower: Double?,
                cpu: Metric, gpu: Metric, mem: MemMetric, cores: [Double],
                fanRPM: Int?, aneWatts: Double, volumes: [Volume],
                chipName: String = "Apple Silicon", performanceCoreCount: Int = 10) {
        self.timestamp = timestamp
        self.chipPower = chipPower
        self.avgPower = avgPower
        self.peakPower = peakPower
        self.powerSeries = Array(powerSeries.prefix(40))
        self.internalPower = internalPower
        self.cpu = cpu
        self.gpu = gpu
        self.mem = mem
        self.cores = Array(cores.prefix(32)).map { min(100, max(0, $0)) }
        self.fanRPM = fanRPM
        self.aneWatts = aneWatts
        self.volumes = volumes
        self.chipName = chipName
        self.performanceCoreCount = min(self.cores.count, max(0, performanceCoreCount))
    }

    public func isStale(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(timestamp) > 180 ||
        date.timeIntervalSince(timestamp) < -60
    }

    /// Fixed sample data is for #Preview and automated tests ONLY; the runtime
    /// provider uses nil when a real snapshot file is absent.
    public static var preview: ChipBarSnapshot {
        let curve: [Double] = [
            4.3, 4.6, 6.7, 4.9, 3.8, 5.0, 8.2, 4.6, 4.1, 5.7,
            10.5, 6.1, 4.0, 3.6, 5.2, 4.6, 12.1, 5.2, 3.9, 4.3,
            3.5, 5.7, 4.0, 3.8, 4.4, 6.0, 4.2, 4.7, 5.6, 7.5,
            5.1, 4.0, 3.6, 5.4, 8.6, 5.8, 5.1, 7.2, 10.2, 11.6
        ]
        return ChipBarSnapshot(
            timestamp: Date(), chipPower: 11.6, avgPower: 6.2,
            peakPower: 23, powerSeries: curve, internalPower: 27.3,
            cpu: .init(percent: 29, watts: 9.7, tempC: 67.5),
            gpu: .init(percent: 42, watts: 1.9, tempC: 63.8),
            mem: .init(percent: 84, usedGB: 20.2, totalGB: 24),
            cores: [31, 48, 66, 39, 25, 6, 7, 4, 3, 5, 21, 27, 34, 23, 17],
            fanRPM: 1008, aneWatts: 0,
            volumes: [
                .init(name: "Macintosh HD",
                      freeBytes: 142_230_000_000, totalBytes: 494_330_000_000,
                      readMBs: 21.6, writeMBs: 1.7),
                .init(name: "Zark",
                      freeBytes: 1_370_000_000_000, totalBytes: 2_050_000_000_000,
                      readMBs: 0, writeMBs: 0)
            ], chipName: "Apple M5 Pro", performanceCoreCount: 10)
    }
}

/// Both signed targets use the SAME App Group. The current open-source
/// release remains ad-hoc signed, so it uses the existing extension-container
/// fallback until both targets are signed by a single Apple Developer Team.
/// Do not call containerURL without checking group membership: the WidgetKit
/// descriptor process may otherwise fail to launch an unentitled extension.
public enum ChipBarSnapshotStore {
    public static let groupID = "group.local.chipbar.shared"
    public static let newOverviewKind = "ChipBar.Overview"
    public static let newStorageKind = "ChipBar.Storage"
    private static let fileName = "snapshot.json"

    private static func entitledGroupURL() -> URL? {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault),
              let groups = SecTaskCopyValueForEntitlement(
                  task, "com.apple.security.application-groups" as CFString, nil)
                  as? [String],
              groups.contains(groupID) else { return nil }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("ChipBar", isDirectory: true)
    }

    /// Ad-hoc fallback mirrors the previous ChipBar telemetry contract. The
    /// extension's home is its own sandbox, while the unsandboxed host writes
    /// through the same physical path; old telemetry.json is untouched.
    private static func fallbackDirectory(isExtension: Bool) -> URL? {
        let manager = FileManager.default
        if isExtension {
            return manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("ChipBar", isDirectory: true)
        }
        return manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/local.chipbar.monitor.widgets/Data/Library/Application Support/ChipBar",
                                    isDirectory: true)
    }

    private static func directory(isExtension: Bool) -> URL? {
        entitledGroupURL() ?? fallbackDirectory(isExtension: isExtension)
    }

    public static func write(_ snapshot: ChipBarSnapshot) throws {
        guard let folder = directory(isExtension: false) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        guard data.count <= 256 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    public static func readForWidget() -> ChipBarSnapshot? {
        var candidates: [URL] = []
        if let group = entitledGroupURL() {
            candidates.append(group.appendingPathComponent(fileName))
        }
        if let legacy = fallbackDirectory(isExtension: true) {
            candidates.append(legacy.appendingPathComponent(fileName))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  data.count <= 256 * 1024,
                  let snapshot = try? decoder.decode(ChipBarSnapshot.self, from: data)
            else { continue }
            return snapshot
        }
        return nil
    }
}
