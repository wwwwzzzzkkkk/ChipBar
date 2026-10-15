import Foundation
import Combine
import Darwin
import IOKit
import ChipBarCore

struct ActivitySnapshot: Sendable {
    let rows: [ApplicationActivityRow]
    let processCount: Int
    let readableCPUCount: Int
    let gpuClientCount: Int
    let neuralSupported: Bool
}

/// Serial actor state. No process arguments, command output or history.
actor ApplicationActivitySampler {
    private var accumulator = ActivityAccumulator()
    private var metadata: [Int32: (birth: UInt64, group: String, name: String, path: String?)] = [:]
    private var bundles: [String: String] = [:]
    private let secondsPerTick: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    func sample() -> ActivitySnapshot {
        autoreleasepool {
            let capacity = max(256, Int(proc_listallpids(nil, 0)) + 128)
            var pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            var processes: [ActivityProcess] = []
            var nextMetadata: [Int32: (birth: UInt64, group: String, name: String, path: String?)] = [:]
            var readable = 0
            var neuralSupported = false
            for pid in pids.prefix(max(0, min(Int(count), capacity))) where pid > 0 {
                var bsd = proc_bsdinfo()
                let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd)))
                guard bytes == MemoryLayout.size(ofValue: bsd) else { continue }
                let birth = bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec
                let info: (birth: UInt64, group: String, name: String, path: String?)
                if let cached = metadata[pid], cached.birth == birth { info = cached }
                else { info = identify(pid: pid, birth: birth) }
                nextMetadata[pid] = info
                var cpu: Double?
                var neural: UInt64?
                if #available(macOS 15.0, *) {
                    var usage = rusage_info_v6()
                    let result = withUnsafeMutablePointer(to: &usage) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V6, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
                    }
                    if result == 0 {
                        cpu = (Double(usage.ri_user_time) + Double(usage.ri_system_time)) * secondsPerTick
                        neural = usage.ri_neural_footprint
                        neuralSupported = true
                    }
                }
                if cpu == nil {
                    var usage = rusage_info_v4()
                    let result = withUnsafeMutablePointer(to: &usage) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
                    }
                    if result == 0 { cpu = (Double(usage.ri_user_time) + Double(usage.ri_system_time)) * secondsPerTick }
                }
                var verified = proc_bsdinfo()
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &verified, Int32(MemoryLayout.size(ofValue: verified))) == MemoryLayout.size(ofValue: verified),
                      verified.pbi_start_tvsec == bsd.pbi_start_tvsec, verified.pbi_start_tvusec == bsd.pbi_start_tvusec else { continue }
                if cpu != nil { readable += 1 }
                processes.append(ActivityProcess(pid: pid, birth: birth, group: info.group, name: info.name,
                    appPath: info.path, cpuSeconds: cpu, neuralBytes: neural))
            }
            metadata = nextMetadata
            let activePaths = Set(nextMetadata.values.compactMap(\.path))
            bundles = bundles.filter { activePaths.contains($0.key) }
            let clients = readGPUClients()
            let rows = accumulator.update(processes: processes, clients: clients, time: ProcessInfo.processInfo.systemUptime)
            return ActivitySnapshot(rows: rows, processCount: processes.count, readableCPUCount: readable,
                gpuClientCount: clients.count, neuralSupported: neuralSupported)
        }
    }

    private func identify(pid: Int32, birth: UInt64) -> (birth: UInt64, group: String, name: String, path: String?) {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let executable = length > 0 ? String(cString: buffer) : ""
        let parts = executable.components(separatedBy: "/")
        if let index = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
            let path = parts.prefix(index + 1).joined(separator: "/")
            let name: String
            if let cached = bundles[path] { name = cached }
            else {
                let bundle = Bundle(path: path)
                name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                bundles[path] = name
            }
            return (birth, path, name, path)
        }
        var nameBuffer = [CChar](repeating: 0, count: 1024)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(cString: nameBuffer)
        return (birth, "pid:\(pid):\(birth)", name.isEmpty ? "进程 \(pid)" : name, nil)
    }

    private func readGPUClients() -> [ActivityGPUClient] {
        var iterator: io_iterator_t = 0
        // User clients appear in the registry tree, not registered-service matches.
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [ActivityGPUClient] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard IOObjectConformsTo(entry, "AGXDeviceUserClient") != 0 else { continue }
            // AGX synthesizes AppUsage during property serialization; looking up
            // that key alone may return nil despite valid driver counters.
            var raw: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = raw?.takeRetainedValue() as? [String: Any],
                  let creator = properties["IOUserClientCreator"] as? String,
                  let usage = properties["AppUsage"] as? [[String: Any]], !usage.isEmpty else { continue }
            let scanner = Scanner(string: creator)
            guard scanner.scanString("pid ") != nil, let pid = scanner.scanInt32() else { continue }
            var counters: [UInt64] = []
            for item in usage {
                guard let number = item["accumulatedGPUTime"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0 else {
                    counters = []; break
                }
                counters.append(number.uint64Value)
            }
            var id: UInt64 = 0
            guard !counters.isEmpty, IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { continue }
            result.append(ActivityGPUClient(id: id, pid: pid, nanoseconds: counters))
        }
        return result
    }
}

@MainActor final class ApplicationActivityModel: ObservableObject {
    @Published private(set) var snapshot: ActivitySnapshot?
    private let sampler = ApplicationActivitySampler()

    func watch(interval: Int) async {
        snapshot = nil
        while !Task.isCancelled {
            let sampler = self.sampler
            let result = await Task.detached(priority: .utility) { await sampler.sample() }.value
            guard !Task.isCancelled else { return }
            snapshot = result
            do { try await Task.sleep(nanoseconds: UInt64(max(2000, interval)) * 1_000_000) }
            catch { return }
        }
    }
}
