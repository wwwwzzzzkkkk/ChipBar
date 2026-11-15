import Foundation
import Darwin
import IOKit

/// The perflevel *names* must come from the current chip. An M5 Pro can have
/// "Super" + "Performance", not "Performance" + "Efficiency".
struct CPUCoreTier: Equatable, Sendable {
    let name: String
    let count: Int

    var shortTitle: String {
        switch name.lowercased() {
        case "super": return "超级核"
        case "performance": return "性能核"
        case "efficiency": return "能效核"
        default: return name
        }
    }
}

struct CPUCoreTopology: Sendable {
    let levels: [CPUCoreTier]
    /// Only populated if ALL logical IDs were independently verified in the
    /// IODeviceTree registry and match named perflevel counts.
    let namesByLogicalID: [Int: String]

    static let current = readCurrent()

    /// Derive core labels only when name, cluster type AND logical core counts
    /// agree. Apple may reorder logical IDs; do not assume contiguous tiers.
    static func verifiedLabels(levels: [CPUCoreTier],
                               clusterTypesByID: [Int: String],
                               logicalCPUCount: Int) -> [Int: String] {
        guard !levels.isEmpty, logicalCPUCount > 0,
              levels.reduce(0, { $0 + $1.count }) == logicalCPUCount,
              clusterTypesByID.count == logicalCPUCount,
              Set(clusterTypesByID.keys) == Set(0..<logicalCPUCount) else { return [:] }

        let hasSuper = levels.contains { $0.name.caseInsensitiveCompare("Super") == .orderedSame }
        var letters: [String: String] = [:]
        for level in levels {
            let kind: String
            switch level.name.lowercased() {
            case "super": kind = "P"
            case "performance": kind = hasSuper ? "M" : "P"
            case "efficiency": kind = "E"
            default: return [:]
            }
            guard letters[kind] == nil else { return [:] }
            letters[kind] = level.shortTitle
            let count = clusterTypesByID.values.filter { $0 == kind }.count
            guard count == level.count else { return [:] }
        }

        guard Set(clusterTypesByID.values) == Set(letters.keys) else { return [:] }
        return clusterTypesByID.compactMapValues { letters[$0] }
    }

    private static func readCurrent() -> CPUCoreTopology {
        let numberOfLevels = min(8, max(0, numericSysctl("hw.nperflevels") ?? 0))
        let levels = (0..<numberOfLevels).compactMap { index -> CPUCoreTier? in
            guard let name = stringSysctl("hw.perflevel\(index).name"),
                  let count = numericSysctl("hw.perflevel\(index).logicalcpu"),
                  count > 0 else { return nil }
            return CPUCoreTier(name: name, count: count)
        }
        guard levels.count == numberOfLevels else {
            return CPUCoreTopology(levels: [], namesByLogicalID: [:])
        }
        let types = deviceTreeClusterTypes() ?? [:]
        let labels = verifiedLabels(levels: levels,
                                    clusterTypesByID: types,
                                    logicalCPUCount: ProcessInfo.processInfo.processorCount)
        return CPUCoreTopology(levels: levels, namesByLogicalID: labels)
    }

    private static func numericSysctl(_ key: String) -> Int? {
        var result: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &result, &length, nil, 0) == 0,
              length == MemoryLayout<Int32>.size else { return nil }
        return Int(result)
    }

    private static func stringSysctl(_ key: String) -> String? {
        var count = 0
        guard sysctlbyname(key, nil, &count, nil, 0) == 0,
              count > 1, count < 256 else { return nil }
        var chars = [CChar](repeating: 0, count: count)
        let success = chars.withUnsafeMutableBufferPointer {
            sysctlbyname(key, $0.baseAddress, &count, nil, 0)
        }
        guard success == 0 else { return nil }
        let result = String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return result.isEmpty ? nil : result
    }

    private static func deviceTreeClusterTypes() -> [Int: String]? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var result: [Int: String] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let idValue = IORegistryEntryCreateCFProperty(
                      entry, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let clusterValue = IORegistryEntryCreateCFProperty(
                      entry, "cluster-type" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let id = cpuIdentifier(idValue),
                  let kind = clusterLetter(clusterValue), result[id] == nil else { continue }
            result[id] = kind
        }
        return result.isEmpty ? nil : result
    }

    private static func cpuIdentifier(_ value: Any) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let data = value as? Data, data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        return Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 |
                   UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
    }

    private static func clusterLetter(_ value: Any) -> String? {
        if let text = value as? String { return String(text.prefix(1)) }
        guard let data = value as? Data else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let letter = String(text.prefix(1))
        return ["P", "M", "E"].contains(letter) ? letter : nil
    }
}
