import Foundation

public struct NetworkBytes {
    public let received: UInt64
    public let sent: UInt64
    public init(received: UInt64, sent: UInt64) { self.received = received; self.sent = sent }
}

public struct NetworkRate {
    public let download: Double
    public let upload: Double
    public static func text(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB/s", bytes / 1_000) }
        return String(format: "%.0f B/s", bytes)
    }
}

/// Delta each interface separately: reconnects and counter resets establish a new baseline.
public struct NetworkActivity {
    private var previous: [String: NetworkBytes] = [:]
    private var timestamp: TimeInterval?
    public init() {}
    public mutating func update(_ counters: [String: NetworkBytes], at now: TimeInterval) -> NetworkRate? {
        defer { previous = counters; timestamp = now }
        guard let timestamp, now > timestamp, now - timestamp <= 30 else { return nil }
        var download = 0.0, upload = 0.0, valid = false
        for (name, current) in counters {
            guard let old = previous[name], current.received >= old.received, current.sent >= old.sent else { continue }
            download += Double(current.received - old.received)
            upload += Double(current.sent - old.sent)
            valid = true
        }
        return valid ? NetworkRate(download: download / (now - timestamp), upload: upload / (now - timestamp)) : nil
    }
}
