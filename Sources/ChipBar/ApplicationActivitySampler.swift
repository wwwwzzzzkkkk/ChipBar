import Foundation
import Combine
import Darwin
import IOKit
import ChipBarCore

struct ActivitySnapshot: Sendable {
    let sampledAt: TimeInterval
    let rows: [ApplicationActivityRow]
    let processCount: Int
    let readableCPUCount: Int
    let readableMemoryCount: Int
    let approximateMemoryCount: Int
    let gpuClientCount: Int
    /// Whether IOKit GPU user-client counters were sampled this round.
    let gpuSampled: Bool
    let neuralSupported: Bool
}

/// Keep GPU-tab changes responsive without rescanning the full registry on
/// every CPU, memory or ANE update.
enum ApplicationActivitySamplingPolicy {
    static func needsRefresh(_ snapshot: ActivitySnapshot?, includeGPU: Bool,
                             now: TimeInterval) -> Bool {
        guard let snapshot else { return true }
        return !ApplicationActivityCachePolicy.isFresh(sampledAt: snapshot.sampledAt, now: now)
            || (includeGPU && !snapshot.gpuSampled)
    }
}

/// Memory footprint is preferred (Activity Monitor-compatible), but on some
/// macOS versions libproc reports a successful query with a zero footprint.
/// A second V4 query, then a resident-size fallback, prevents false 0.0 MB.
///
/// RSS includes shared resident pages and is NOT identical to physical footprint.
/// The fallback source propagates to the UI so it can be labelled as approximate.
enum ProcessMemoryReader {
    // A real macOS process footprint is page-backed. Some macOS releases
    // return tiny positive placeholder values from libproc; treating 1 byte
    // as valid bypassed RSS fallback and displayed "0.0 KB" for every app.
    // Reject implausible sub-64 KiB values instead of representing them as usage.
    static let minimumPlausibleBytes: UInt64 = 64 * 1024

    static func isPlausible(_ bytes: UInt64?) -> Bool {
        guard let bytes else { return false }
        return bytes >= minimumPlausibleBytes
    }

    static func read(pid: Int32, initialFootprint: UInt64?) -> (bytes: UInt64?, approximate: Bool) {
        if isPlausible(initialFootprint) { return (initialFootprint, false) }

        var legacy = rusage_info_v4()
        let legacyResult = withUnsafeMutablePointer(to: &legacy) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4,
                UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        if legacyResult == 0, isPlausible(legacy.ri_phys_footprint) {
            return (legacy.ri_phys_footprint, false)
        }

        // RSS is a separate estimate and may differ from Activity Monitor's
        // Physical Footprint. Mark its use as approximate in the ranking.
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize,
              isPlausible(task.pti_resident_size) else {
            return (nil, false)
        }
        return (task.pti_resident_size, true)
    }
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

    func sample(includeGPU: Bool = true) -> ActivitySnapshot {
        autoreleasepool {
            let capacity = max(256, Int(proc_listallpids(nil, 0)) + 128)
            var pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            var processes: [ActivityProcess] = []
            var nextMetadata: [Int32: (birth: UInt64, group: String, name: String, path: String?)] = [:]
            var readable = 0
            var readableMemory = 0
            var approximateMemory = 0
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
                var physical: UInt64?
                if #available(macOS 15.0, *) {
                    var usage = rusage_info_v6()
                    let result = withUnsafeMutablePointer(to: &usage) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V6, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
                    }
                    if result == 0 {
                        cpu = (Double(usage.ri_user_time) + Double(usage.ri_system_time)) * secondsPerTick
                        neural = usage.ri_neural_footprint
                        physical = usage.ri_phys_footprint
                        neuralSupported = true
                    }
                }
                // Preserve the original CPU fallback, but do not confuse a
                // successful query with a valid nonzero memory observation.
                if cpu == nil {
                    var usage = rusage_info_v4()
                    let result = withUnsafeMutablePointer(to: &usage) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V4,
                            UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
                    }
                    if result == 0 {
                        cpu = (Double(usage.ri_user_time) + Double(usage.ri_system_time)) * secondsPerTick
                        physical = usage.ri_phys_footprint
                    }
                }
                let memory = ProcessMemoryReader.read(pid: pid, initialFootprint: physical)
                var verified = proc_bsdinfo()
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &verified, Int32(MemoryLayout.size(ofValue: verified))) == MemoryLayout.size(ofValue: verified),
                      verified.pbi_start_tvsec == bsd.pbi_start_tvsec, verified.pbi_start_tvusec == bsd.pbi_start_tvusec else { continue }
                if cpu != nil { readable += 1 }
                if memory.bytes != nil { readableMemory += 1 }
                if memory.approximate { approximateMemory += 1 }
                processes.append(ActivityProcess(pid: pid, birth: birth, group: info.group, name: info.name,
                    appPath: info.path, cpuSeconds: cpu, neuralBytes: neural, physicalBytes: memory.bytes,
                    memoryIsRSSApproximation: memory.approximate))
            }
            metadata = nextMetadata
            let activePaths = Set(nextMetadata.values.compactMap(\.path))
            bundles = bundles.filter { activePaths.contains($0.key) }
            // A recursive IOKit walk is only needed for the GPU ranking.
            let clients = includeGPU ? readGPUClients() : []
            let sampledAt = ProcessInfo.processInfo.systemUptime
            let rows = accumulator.update(processes: processes, clients: clients, time: sampledAt)
            return ActivitySnapshot(sampledAt: sampledAt, rows: rows, processCount: processes.count, readableCPUCount: readable,
                readableMemoryCount: readableMemory, approximateMemoryCount: approximateMemory,
                gpuClientCount: clients.count, gpuSampled: includeGPU, neuralSupported: neuralSupported)
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
    static let shared = ApplicationActivityModel()

    @Published private(set) var snapshot: ActivitySnapshot?
    private let sampler = ApplicationActivitySampler()
    private var inFlightSample: Task<ActivitySnapshot, Never>?
    private var inFlightToken = UUID()

    func watch(interval: Int, includeGPU: Bool) async {
        var sampleNext = ApplicationActivitySamplingPolicy.needsRefresh(
            snapshot, includeGPU: includeGPU, now: ProcessInfo.processInfo.systemUptime)
        while !Task.isCancelled {
            if sampleNext {
                let result = await sampleOnce(includeGPU: includeGPU)
                guard !Task.isCancelled else { return }
                snapshot = result
            }
            sampleNext = true
            do { try await Task.sleep(nanoseconds: UInt64(max(2000, interval)) * 1_000_000) }
            catch { return }
        }
    }

    private func sampleOnce(includeGPU: Bool) async -> ActivitySnapshot {
        if let inFlightSample {
            let existing = await inFlightSample.value
            // A GPU-tab switch may overlap a CPU-only scan; do not reuse
            // incomplete GPU readings after the selector changes.
            if !includeGPU || existing.gpuSampled { return existing }
        }
        let sampler = self.sampler
        let token = UUID()
        inFlightToken = token
        let task = Task.detached(priority: .utility) {
            await sampler.sample(includeGPU: includeGPU)
        }
        inFlightSample = task
        let result = await task.value
        if inFlightToken == token { inFlightSample = nil }
        return result
    }
}
