import Foundation
import WidgetKit
import ChipBarCore

/// Widgets have OS-budgeted timelines. The host app publishes recent metrics
/// to the extension sandbox; it does not create any widget-side SMC reader or
/// long-lived background process.
@MainActor final class WidgetTelemetryBridge {
    static let shared = WidgetTelemetryBridge()

    // Ad-hoc releases cannot claim an Apple Team ID app-group entitlement.
    // Use the extension's own sandbox file and avoid unentitled group access.
    private static let extensionID = "local.chipbar.monitor.widgets"

    private var lastWrite: Date?
    private var lastReload: Date?
    private var lastNewWidgetReload: Date?
    private var lastCoreSample: Date?
    private var lastCoreAttempt: Date?
    private var cores: [Double] = []
    private let coreSampler = CPUCoreSampler()
    private var coreSampling = false
    // Like CPU cores, disk capacity sampling cannot rely on a dashboard view:
    // the menu-bar app may run for days without that view being opened.
    private let internalStorageSampler = InternalStorageSampler()
    private let diskSampler = DiskActivitySampler()
    private var storageSampling = false
    private var lastStorageAttempt: Date?
    private var lastStorageSample: Date?
    private var bootCapacity: InternalStorageCapacity?
    private var physicalDisk: DiskActivitySnapshot?
    private var lastPayload: [String: Any]?

    // Persist a fresh payload approximately every 15 seconds while the host
    // runs. The operating system may still postpone displaying the new image.
    // No busy timer: calls arrive from the existing macmon stream.
    func publish(_ sample: Sample, history: [Sample]) {
        let now = Date()
        updateCoreReadingsIfNeeded(now: now)
        updateStorageReadingsIfNeeded(now: now)
        if let lastWrite, now.timeIntervalSince(lastWrite) < 15 { return }
        var values: [String: Any] = [
            "timestamp": now.timeIntervalSince1970
        ]
        func write(_ name: String, _ number: Double?) {
            if let number, number.isFinite && number >= 0 { values[name] = number }
        }
        write("chip", sample.total)
        write("cpuPower", sample.cpu)
        write("gpuPower", sample.gpu)
        write("anePower", sample.ane)
        write("cpuUsage", sample.cpuUtilization)
        write("gpuUsage", sample.gpuUtilization)
        write("cpuTemperature", sample.cpuTemperature)
        write("gpuTemperature", sample.gpuTemperature)
        write("fanRPM", sample.fans.map(\.rpm).max())
        write("ramPercentage", sample.memory?.usedPercent)
        write("ramUsed", sample.memory?.usedGiB)
        write("ramTotal", sample.memory?.totalGiB)
        write("internalPower", ChipBarPowerFlowModel.shared.reading.systemWatts)
        // Descriptive labels and aggregates for the high-density glass
        // dashboard. These are real measurements, not design-mock values.
        if let chip = sample.chip, !chip.isEmpty {
            values["chipName"] = String(chip.prefix(56))
        }
        if let model = sample.model, !model.isEmpty {
            values["macModel"] = String(model.prefix(56))
        }

        // Keep at most 24 real historical samples from the recent 10 minutes.
        let recent = history.filter { now.timeIntervalSince($0.date) <= 600 }
        let strideBy = max(1, (recent.count + 23) / 24)
        let realPowers = recent.compactMap(\.total).filter { $0.isFinite && $0 >= 0 }
        if !realPowers.isEmpty {
            write("averagePower", realPowers.reduce(0, +) / Double(realPowers.count))
            write("peakPower", realPowers.max())
        }
        values["powerHistory"] = Swift.stride(from: 0, to: recent.count, by: strideBy)
            .compactMap { recent[$0].total }.filter { $0.isFinite && $0 >= 0 }

        // CPUCoreLoadModel is only active when the dashboard is open.
        // For widgets use the independently sampled Mach utilization cache,
        // collected on a low-frequency background actor instead.
        mergeCoreReadings(into: &values)

        mergeStorageReadings(into: &values)

        if let snapshot = ApplicationActivityModel.shared.snapshot {
            let top = snapshot.rows
                .filter { ($0.cpuPercent ?? 0) > 0 }
                .sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
                .prefix(3)
            values["applicationNames"] = top.map(\.name)
            values["applicationCPU"] = top.map { $0.cpuPercent ?? 0 }
        }

        writePayload(values, now: now)

        // New Codable contract is additive. The legacy telemetry file and
        // every old widget kind continue working unchanged.
        if let snapshot = makeSharedSnapshot(sample: sample, history: history,
                                             legacy: values, now: now) {
            do {
                try ChipBarSnapshotStore.write(snapshot)
                if lastNewWidgetReload.map({ now.timeIntervalSince($0) >= 120 }) ?? true {
                    lastNewWidgetReload = now
                    WidgetCenter.shared.reloadTimelines(
                        ofKind: ChipBarSnapshotStore.newOverviewKind)
                    WidgetCenter.shared.reloadTimelines(
                        ofKind: ChipBarSnapshotStore.newStorageKind)
                }
            } catch {
                // A missing App Group entitlement never interrupts monitoring;
                // the existing extension-container fallback is best-effort.
            }
        }
    }

    private func makeSharedSnapshot(sample: Sample, history: [Sample],
                                    legacy: [String: Any], now: Date) -> ChipBarSnapshot? {
        // Do not replace missing readings with the #Preview sample values.
        guard let watts = sample.total, watts.isFinite, watts >= 0 else { return nil }
        let readings = history.filter {
            now.timeIntervalSince($0.date) >= 0 &&
            now.timeIntervalSince($0.date) <= 600 &&
            $0.total?.isFinite == true
        }.sorted { $0.date < $1.date }
        let valid = readings.compactMap(\.total)
        let average = valid.isEmpty ? watts : valid.reduce(0, +) / Double(valid.count)
        let peak = valid.max() ?? watts

        // Forty time-uniform points over ten minutes, from oldest to latest.
        let series: [Double] = (0..<40).map { step in
            let time = now.addingTimeInterval(-600 + Double(step) * 600 / 39)
            guard let nearest = readings.min(by: {
                abs($0.date.timeIntervalSince(time)) <
                    abs($1.date.timeIntervalSince(time))
            }), let value = nearest.total else { return watts }
            return max(0, value)
        }

        let rawCores = legacy["coreUsage"] as? [Double] ?? []
        var orderedCores = rawCores
        var performance = min(10, rawCores.count)
        let topology = CPUCoreTopology.current.namesByLogicalID
        if rawCores.count == 15 && topology.count == 15 {
            let perfIDs = (0..<15).filter { topology[$0] == "性能核" }
            let superIDs = (0..<15).filter { topology[$0] == "超级核" }
            if perfIDs.count == 10 && superIDs.count == 5 {
                orderedCores = (perfIDs + superIDs).map { rawCores[$0] }
                performance = 10
            }
        }

        func number(_ key: String) -> Double? {
            legacy[key] as? Double
        }
        func volume(name: String, prefix: String) -> ChipBarSnapshot.Volume? {
            guard let free = number(prefix + "FreeGB"),
                  let total = number(prefix + "TotalGB"),
                  total > 0, free >= 0, free <= total,
                  total < Double(Int64.max) / 1_000_000_000 else { return nil }
            return .init(name: name,
                         freeBytes: Int64(free * 1_000_000_000),
                         totalBytes: Int64(total * 1_000_000_000),
                         readMBs: number(prefix + "ReadMB"),
                         writeMBs: number(prefix + "WriteMB"))
        }

        var volumes: [ChipBarSnapshot.Volume] = []
        // The boot APFS container is a single capacity bar.
        if var disk = volume(name: "Macintosh HD", prefix: "storage") {
            disk.readMBs = number("storageReadMB")
            disk.writeMBs = number("storageWriteMB")
            volumes.append(disk)
        }

        // The legacy menu summary exposes only its first external volume.
        // The new AppIntent must offer ALL mounted external volumes, using
        // the already available disk snapshots; no additional sampling.
        let currentDisk = physicalDisk.flatMap { disk -> DiskActivitySnapshot? in
            let age = now.timeIntervalSince(disk.date)
            return age >= 0 && age <= 90 ? disk : nil
        }
        let source = ExternalStorageCapacityModel.shared
        let rows = currentDisk.map(ExternalStorageCapacityModel.displayRows(from:))
            ?? source.volumes
        let activity = currentDisk ?? source.activity
        var seenVolumeNames = Set(volumes.map(\.name))
        for row in rows.prefix(12) {
            let disk = row.volume
            guard disk.total > 0, disk.available >= 0,
                  disk.available <= disk.total,
                  seenVolumeNames.insert(disk.name).inserted else { continue }
            let rates: DiskRates? = activity.flatMap { snapshot in
                let age = now.timeIntervalSince(snapshot.date)
                guard age >= 0, age <= 90,
                      snapshot.connected.contains(row.diskID) else { return nil }
                return snapshot.rates[row.diskID]
            }
            volumes.append(.init(name: disk.name,
                                 freeBytes: disk.available,
                                 totalBytes: disk.total,
                                 readMBs: rates?.readMB,
                                 writeMBs: rates?.writeMB))
        }
        // Preserve the previous first-volume fallback if a drive's capacity
        // model is still warming up; never duplicate an already listed drive.
        if rows.isEmpty, let name = legacy["externalName"] as? String,
           !seenVolumeNames.contains(name),
           let disk = volume(name: name, prefix: "external") {
            volumes.append(disk)
        }

        return ChipBarSnapshot(
            timestamp: now,
            chipPower: watts,
            avgPower: average,
            peakPower: peak,
            powerSeries: series,
            internalPower: number("internalPower"),
            cpu: .init(percent: sample.cpuUtilization ?? 0,
                       watts: sample.cpu ?? 0,
                       tempC: sample.cpuTemperature),
            gpu: .init(percent: sample.gpuUtilization ?? 0,
                       watts: sample.gpu ?? 0,
                       tempC: sample.gpuTemperature),
            mem: .init(percent: sample.memory?.usedPercent ?? 0,
                       usedGB: sample.memory?.usedGiB ?? 0,
                       totalGB: sample.memory?.totalGiB ?? 0),
            cores: orderedCores,
            fanRPM: sample.fans.map(\.rpm).max().map(Int.init),
            aneWatts: sample.ane ?? 0,
            volumes: volumes,
            chipName: sample.chip ?? "Apple Silicon",
            performanceCoreCount: performance)
    }

    private func mergeCoreReadings(into values: inout [String: Any]) {
        guard let lastCoreSample,
              Date().timeIntervalSince(lastCoreSample) <= 90,
              !cores.isEmpty else { return }
        values["coreUsage"] = cores.map { min(100, max(0, $0)) }
        let verified = CPUCoreTopology.current.namesByLogicalID
        if verified.count == cores.count {
            values["coreTiers"] = cores.indices.map { verified[$0] ?? "" }
        }
    }

    private func mergeStorageReadings(into values: inout [String: Any]) {
        // When a drive has been unplugged, clear any stale external fields
        // before writing the latest snapshot. Do not claim old I/O speeds.
        for key in ["storageFreeGB", "storageTotalGB", "storageReadMB",
                    "storageWriteMB", "externalName", "externalFreeGB",
                    "externalTotalGB", "externalReadMB", "externalWriteMB"] {
            values.removeValue(forKey: key)
        }
        let capacity = bootCapacity ?? InternalStorageModel.shared.capacity
        if let capacity {
            values["storageFreeGB"] = Double(capacity.availableBytes) / 1_000_000_000
            values["storageTotalGB"] = Double(capacity.totalBytes) / 1_000_000_000
        }
        let fallback = ExternalStorageCapacityModel.shared
        let freshDisk = physicalDisk.flatMap { snapshot in
            Date().timeIntervalSince(snapshot.date) < 90 ? snapshot : nil
        }
        let disk = freshDisk ?? fallback.activity
        let external: [ExternalVolumeCapacity]
        if let freshDisk {
            external = ExternalStorageCapacityModel.displayRows(from: freshDisk)
        } else {
            external = fallback.volumes
        }
        if let drive = external.first {
            values["externalName"] = String(drive.volume.name.prefix(40))
            values["externalFreeGB"] = Double(drive.volume.available) / 1_000_000_000
            values["externalTotalGB"] = Double(drive.volume.total) / 1_000_000_000
        }
        if let disk, Date().timeIntervalSince(disk.date) <= 90 {
            let internalRates = disk.rates.filter {
                disk.connected.contains($0.key) && !disk.external.contains($0.key)
            }.map(\.value)
            if !internalRates.isEmpty {
                values["storageReadMB"] = internalRates.reduce(0) { $0 + $1.readMB }
                values["storageWriteMB"] = internalRates.reduce(0) { $0 + $1.writeMB }
            }
            if let drive = external.first,
               disk.connected.contains(drive.diskID),
               let rates = disk.rates[drive.diskID] {
                values["externalReadMB"] = rates.readMB
                values["externalWriteMB"] = rates.writeMB
            }
        }
    }

    private func updateStorageReadingsIfNeeded(now: Date) {
        // Reuse the existing native samplers, on demand. At most one bounded
        // scan each 45 seconds; never add a continuously running disk task.
        guard !storageSampling,
              lastStorageAttempt.map({ now.timeIntervalSince($0) >= 45 }) ?? true else { return }
        lastStorageAttempt = now
        storageSampling = true
        Task { [weak self] in
            guard let self else { return }
            let capacity = await self.internalStorageSampler.read()
            // Two physical counter samples are needed to compute true MB/s.
            _ = await self.diskSampler.sampleAll(includeVolumes: true)
            do { try await Task.sleep(for: .milliseconds(1_000)) }
            catch { self.storageSampling = false; return }
            let snapshot = await self.diskSampler.sampleAll(includeVolumes: true)
            self.bootCapacity = capacity
            self.physicalDisk = snapshot
            self.lastStorageSample = Date()
            self.storageSampling = false
            if var payload = self.lastPayload {
                self.mergeStorageReadings(into: &payload)
                payload["timestamp"] = Date().timeIntervalSince1970
                self.writePayload(payload, now: Date())
            }
        }
    }

    private func updateCoreReadingsIfNeeded(now: Date) {
        // Throttle attempts as well as successful reads; on an unsupported
        // host a failed Mach call must not cause retries every macmon tick.
        guard !coreSampling,
              lastCoreAttempt.map({ now.timeIntervalSince($0) >= 20 }) ?? true else { return }
        lastCoreAttempt = now
        coreSampling = true
        Task { [weak self] in
            guard let self else { return }
            // host_processor_info exposes cumulative ticks: discard the
            // baseline, then calculate utilization across a real interval.
            _ = await self.coreSampler.read()
            do { try await Task.sleep(for: .milliseconds(650)) }
            catch { self.coreSampling = false; return }
            guard let percentages = await self.coreSampler.read(),
                  !percentages.isEmpty else {
                self.coreSampling = false
                return
            }
            let at = Date()
            self.cores = percentages
            self.lastCoreSample = at
            self.coreSampling = false
            // First successful CPU-core sample should reach disk immediately,
            // not require the user to open the home dashboard.
            if var payload = self.lastPayload {
                self.mergeCoreReadings(into: &payload)
                payload["timestamp"] = at.timeIntervalSince1970
                self.writePayload(payload, now: at)
            }
        }
    }

    private func writePayload(_ payload: [String: Any], now: Date) {
        // The unsandboxed host writes only non-sensitive, read-only telemetry
        // to the WidgetKit extension's own Application Support container.
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(Self.extensionID)/Data/Library/Application Support/ChipBar")
            .appendingPathComponent("telemetry.json")
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            try data.write(to: destination, options: .atomic)
            lastWrite = now
            lastPayload = payload
            if lastReload.map({ now.timeIntervalSince($0) >= 120 }) ?? true {
                lastReload = now
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            // A missing extension container is not a reason to interrupt
            // ChipBar's main monitoring.
        }
    }
}
