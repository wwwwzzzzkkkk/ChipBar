import Foundation
import IOKit
import DiskArbitration
import Combine
import ChipBarCore

struct DiskActivitySnapshot: Sendable {
    var rates: [String: DiskRates] = [:]
    var volumes: [String: [DiskVolumeSpace]] = [:]
    var connected: Set<String> = []
    var external: Set<String> = []
    var date = Date()

    func menuRates(externalOnly: Bool = false, at now: Date = Date(),
                   maximumAge: TimeInterval = 6) -> (read: Double?, write: Double?) {
        guard now.timeIntervalSince(date) <= maximumAge else { return (nil, nil) }
        let selected = rates.filter { connected.contains($0.key) && (!externalOnly || external.contains($0.key)) }
        guard !selected.isEmpty else { return (nil, nil) }
        return (selected.values.reduce(0) { $0 + $1.readMB } * 1_000_000,
                selected.values.reduce(0) { $0 + $1.writeMB } * 1_000_000)
    }

    func externalMenuReadout(at now: Date = Date(), maximumAge: TimeInterval = 6) -> MenuReadout? {
        guard !external.intersection(connected).isEmpty else { return nil }
        let rates = menuRates(externalOnly: true, at: now, maximumAge: maximumAge)
        return MenuReadout("externalDisk", "ER " + MenuReadout.rate(rates.read),
                           "EW " + MenuReadout.rate(rates.write), pairedValues: true)
    }
}

/// Native registry counters, without subprocesses or SMART polling at the fast interval.
actor DiskActivitySampler {
    private var accumulator = DiskRateAccumulator()
    private var cachedVolumes: [String: [DiskVolumeSpace]] = [:]
    private var lastCapacity: Double = -.infinity
    private var identities: [String: UInt64] = [:]

    func sampleAll(includeVolumes: Bool = false) -> DiskActivitySnapshot {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else { return DiskActivitySnapshot() }
        defer { IOObjectRelease(iterator) }
        var ids: [String] = []
        while case let media = IOIteratorNext(iterator), media != 0 {
            defer { IOObjectRelease(media) }
            guard IORegistryEntryCreateCFProperty(media, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool == true,
                  let id = IORegistryEntryCreateCFProperty(media, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(media, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            if IOObjectConformsTo(parent, "IOBlockStorageDriver") != 0 { ids.append(id) }
        }
        return sample(ids: ids.sorted(), externalOnly: false, includeVolumes: includeVolumes)
    }

    func sample(ids: [String], externalOnly: Bool = true, includeVolumes: Bool = true) -> DiskActivitySnapshot {
        autoreleasepool {
            guard let session = DASessionCreate(kCFAllocatorDefault) else { return DiskActivitySnapshot() }
            var counters: [String: DiskCounters] = [:]
            var connected: Set<String> = []
            var external: Set<String> = []
            var currentIdentities: [String: UInt64] = [:]
            for id in ids.prefix(8) where ExternalDisk.validIdentifier(id) {
                guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/" + id),
                      let desc = DADiskCopyDescription(disk) as? [String: Any],
                      !externalOnly || desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false,
                      desc[kDADiskDescriptionMediaWholeKey as String] as? Bool == true else { continue }
                let media = DADiskCopyIOMedia(disk)
                guard media != 0 else { continue }
                defer { IOObjectRelease(media) }
                var identity: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(media, &identity) == KERN_SUCCESS else { continue }
                connected.insert(id); currentIdentities[id] = identity
                if desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false { external.insert(id) }
                if let statistics = Self.driverStatistics(media) {
                    counters[id] = DiskCounters(identity: identity, readBytes: statistics.0, writtenBytes: statistics.1)
                }
            }
            let time = ProcessInfo.processInfo.systemUptime
            if includeVolumes && (time - lastCapacity >= 30 || currentIdentities != identities) {
                cachedVolumes = Self.volumeSpaces(session: session, ids: connected)
                lastCapacity = time
            }
            identities = currentIdentities
            cachedVolumes = cachedVolumes.filter { connected.contains($0.key) }
            return DiskActivitySnapshot(rates: accumulator.update(counters, time: time), volumes: cachedVolumes, connected: connected, external: external)
        }
    }

    private static func driverStatistics(_ media: io_registry_entry_t) -> (UInt64, UInt64)? {
        var entry = media
        IOObjectRetain(entry)
        defer { if entry != 0 { IOObjectRelease(entry) } }
        for _ in 0..<32 {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0,
               let statistics = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let read = unsigned(statistics["Bytes (Read)"]), let written = unsigned(statistics["Bytes (Write)"]) {
                return (read, written)
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(entry); entry = parent
        }
        return nil
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0 else { return nil }
        return n.uint64Value
    }

    /// Walk all parent branches, so a volume spanning multiple disks is never assigned twice.
    private static func physicalParents(_ media: io_registry_entry_t, ids: Set<String>) -> Set<String> {
        var result: Set<String> = []
        var visited: Set<UInt64> = []
        var pending = [media]
        IOObjectRetain(media)
        defer { pending.forEach { IOObjectRelease($0) } }
        var count = 0
        while let entry = pending.popLast() {
            defer { IOObjectRelease(entry) }
            count += 1
            if count > 128 { return [] }
            var identity: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &identity) == KERN_SUCCESS,
                  visited.insert(identity).inserted else { continue }
            if let bsd = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               ExternalDisk.validIdentifier(bsd),
               IORegistryEntryCreateCFProperty(entry, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool == true {
                // Record every physical ancestor, including disks outside the requested set.
                var parent: io_registry_entry_t = 0
                if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
                    if IOObjectConformsTo(parent, "IOBlockStorageDriver") != 0 { result.insert(bsd) }
                    IOObjectRelease(parent)
                }
            }
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS {
                while true { let parent = IOIteratorNext(iterator); if parent == 0 { break }; pending.append(parent) }
                IOObjectRelease(iterator)
            }
        }
        return result.count == 1 ? result.intersection(ids) : []
    }

    private static func volumeSpaces(session: DASession, ids: Set<String>) -> [String: [DiskVolumeSpace]] {
        var result: [String: [DiskVolumeSpace]] = [:]
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) ?? []
        for url in urls.prefix(128) {
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let desc = DADiskCopyDescription(disk) as? [String: Any],
                  desc[kDADiskDescriptionVolumeNetworkKey as String] as? Bool != true else { continue }
            let media = DADiskCopyIOMedia(disk)
            guard media != 0 else { continue }
            defer { IOObjectRelease(media) }
            guard let id = physicalParents(media, ids: ids).first,
                  let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity,
                  let space = DiskVolumeSpace(id: url.path, name: values.volumeName ?? url.lastPathComponent,
                                              total: Int64(total), available: Int64(available),
                                              apfs: desc[kDADiskDescriptionVolumeKindKey as String] as? String == "apfs" || desc[kDADiskDescriptionVolumeKindKey as String] as? String == "APFS") else { continue }
            result[id, default: []].append(space)
        }
        return result.mapValues { $0.sorted { $0.name < $1.name } }
    }
}

@MainActor final class DiskActivityModel: ObservableObject {
    @Published private(set) var snapshot: DiskActivitySnapshot?
    func watch(ids: [String], includeVolumes: Bool = true) async {
        snapshot = nil
        let sampler = DiskActivitySampler()
        while !Task.isCancelled {
            let next = await sampler.sample(ids: ids, includeVolumes: includeVolumes)
            guard !Task.isCancelled else { return }
            snapshot = next
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        }
    }
}
