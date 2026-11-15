import Foundation
import CryptoKit

/// The v3.6 cluster wire format contains observations only. It intentionally
/// has no command, executable path, shell, task submission or control fields.
public struct ClusterTaskReadout: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let state: String
    /// Optional value 0...1. Never derived from CPU usage.
    public let progress: Double?
    /// Simulated seconds written to a live OpenFAST ASCII .out file.
    public let currentSimTime: Double?
    public let targetSimTime: Double?
    /// Real wall-clock runtime and approximate remaining wall-clock seconds.
    public let elapsedSeconds: Double?
    public let remainingSeconds: Double?
    /// Observation provenance: "log", "out", or external reporter.
    public let progressSource: String?

    public init(id: String, title: String, state: String, progress: Double?,
                currentSimTime: Double? = nil, targetSimTime: Double? = nil,
                elapsedSeconds: Double? = nil, remainingSeconds: Double? = nil,
                progressSource: String? = nil) {
        self.id = String(id.prefix(96))
        self.title = String(title.prefix(120))
        self.state = String(state.prefix(32))
        self.progress = progress?.isFinite == true
            ? min(1, max(0, progress!)) : nil
        self.currentSimTime = Self.validNonnegative(currentSimTime)
        self.targetSimTime = Self.validNonnegative(targetSimTime)
        self.elapsedSeconds = Self.validNonnegative(elapsedSeconds)
        self.remainingSeconds = Self.validNonnegative(remainingSeconds)
        self.progressSource = progressSource.map { String($0.prefix(24)) }
    }

    private static func validNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

public struct ClusterNodeReadout: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let chip: String
    public let timestamp: Date
    public let cpu: Double?
    public let gpu: Double?
    public let memoryUsedGB: Double?
    public let memoryTotalGB: Double?
    public let chipWatts: Double?
    public let cpuTemperatureC: Double?
    /// Highest actually sampled fan speed. nil means no readable sensor.
    public let fanRPM: Double?
    public let tasks: [ClusterTaskReadout]

    public init(id: String, name: String, chip: String, timestamp: Date,
                cpu: Double?, gpu: Double?, memoryUsedGB: Double?,
                memoryTotalGB: Double?, chipWatts: Double?,
                cpuTemperatureC: Double?, fanRPM: Double? = nil,
                tasks: [ClusterTaskReadout]) {
        self.id = String(id.prefix(64))
        self.name = String(name.prefix(64))
        self.chip = String(chip.prefix(64))
        self.timestamp = timestamp
        self.cpu = Self.percentage(cpu)
        self.gpu = Self.percentage(gpu)
        self.memoryUsedGB = Self.nonnegative(memoryUsedGB)
        self.memoryTotalGB = Self.nonnegative(memoryTotalGB)
        self.chipWatts = Self.nonnegative(chipWatts)
        self.cpuTemperatureC = cpuTemperatureC?.isFinite == true
            ? cpuTemperatureC : nil
        self.fanRPM = Self.nonnegative(fanRPM)
        self.tasks = Array(tasks.prefix(12))
    }

    public func isOnline(at date: Date = Date()) -> Bool {
        abs(date.timeIntervalSince(timestamp)) <= 12
    }

    private static func percentage(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    private static func nonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

public enum ClusterWireError: Error {
    case invalidKey, oversized, invalidFrame, expired
}

/// Version 1 uses AES-GCM authenticated encryption with a user-shared random
/// 256-bit key. Bonjour reveals only service availability; measurements and
/// external task status are never sent in cleartext. No remote commands exist.
public enum ClusterSecureWire {
    public static let maximumFrameBytes = 16_384
    public static let serviceType = "_chipbar-mon._tcp"

    public static func seal(_ snapshot: ClusterNodeReadout,
                            key: Data) throws -> Data {
        guard key.count == 32 else { throw ClusterWireError.invalidKey }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(snapshot)
        guard plaintext.count <= 12_000 else { throw ClusterWireError.oversized }
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        guard let combined = box.combined, combined.count <= maximumFrameBytes else {
            throw ClusterWireError.oversized
        }
        let count = UInt32(combined.count)
        return Data([
            UInt8(truncatingIfNeeded: count >> 24),
            UInt8(truncatingIfNeeded: count >> 16),
            UInt8(truncatingIfNeeded: count >> 8),
            UInt8(truncatingIfNeeded: count)
        ]) + combined
    }

    public static func open(_ data: Data, key: Data,
                            now: Date = Date()) throws -> ClusterNodeReadout {
        guard key.count == 32 else { throw ClusterWireError.invalidKey }
        guard data.count >= 28, data.count <= maximumFrameBytes else {
            throw ClusterWireError.invalidFrame
        }
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ClusterNodeReadout.self, from: plaintext)
        guard !snapshot.id.isEmpty,
              !snapshot.name.isEmpty,
              abs(now.timeIntervalSince(snapshot.timestamp)) <= 30 else {
            throw ClusterWireError.expired
        }
        return snapshot
    }
}
