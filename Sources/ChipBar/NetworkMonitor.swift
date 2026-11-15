import Foundation
import Combine
import Darwin
import ChipBarCore

@MainActor final class NetworkMonitor: ObservableObject {
    @Published private(set) var rate: NetworkRate?
    @Published private(set) var interfaces: [String] = []
    private var activity = NetworkActivity()
    private var paused = true

    init(start: Bool = true) { if start { setPaused(false) } }

    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        activity = NetworkActivity(); rate = nil; interfaces = []
    }

    func sample() {
        guard !paused else { return }
        guard let counters = Self.counters() else {
            activity = NetworkActivity(); rate = nil; interfaces = []; return
        }
        let names = counters.keys.sorted()
        if interfaces != names { interfaces = names }
        rate = activity.update(counters, at: ProcessInfo.processInfo.systemUptime)
    }

    /// NET_RT_IFLIST2 provides 64-bit counters; getifaddrs wraps after 4 GB.
    nonisolated static func counters() -> [String: NetworkBytes]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0, size <= 4_194_304 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        var counters: [String: NetworkBytes] = [:]
        var offset = 0
        while offset + 4 <= size {
            let length = buffer.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
            guard length >= 4, offset + length <= size else { return nil }
            defer { offset += length }
            guard buffer[offset + 3] == RTM_IFINFO2 else { continue }
            guard length >= MemoryLayout<if_msghdr2>.size else { return nil }
            let item = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
            guard
                  item.ifm_flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING),
                  item.ifm_flags & IFF_LOOPBACK == 0 else { continue }
            var nameBytes = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            guard if_indextoname(UInt32(item.ifm_index), &nameBytes) != nil else { continue }
            let name = String(cString: nameBytes)
            // Exclude loopback, VPN and peer-to-peer interfaces to avoid counting traffic twice.
            guard name.hasPrefix("en") else { continue }
            counters[name] = NetworkBytes(received: item.ifm_data.ifi_ibytes, sent: item.ifm_data.ifi_obytes)
        }
        return counters
    }
}
