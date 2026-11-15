import Foundation

/// Capacity of exactly one boot-data volume, not the sum of APFS volumes.
/// Both values use bytes and are validated before they reach the UI.
public struct InternalStorageCapacity: Sendable, Equatable {
    public let totalBytes: Int64
    public let availableBytes: Int64

    public init?(totalBytes: Int64, availableBytes: Int64) {
        guard totalBytes > 0, availableBytes >= 0, availableBytes <= totalBytes else { return nil }
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedFraction: Double {
        1 - Double(availableBytes) / Double(totalBytes)
    }

    public var availableText: String {
        ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .decimal)
    }

    public var totalText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .decimal)
    }
}
