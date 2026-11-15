import SwiftUI
import ChipBarCore

/// File-system capacities for mounted external drives. This is deliberately
/// independent of the optional smartctl/SMART feature and never needs sudo.
/// DiskActivitySampler caches APFS volume checks for 30 seconds.
extension Notification.Name {
    static let chipBarStorageLayoutDidChange =
        Notification.Name("ChipBarStorageLayoutDidChange")
}

struct ExternalVolumeCapacity: Identifiable {
    let diskID: String
    let volume: DiskVolumeSpace

    var id: String { volume.id }
}

/// Shared across Home and page round-trips; no repeated Disk Arbitration
/// scans when a SwiftUI page is remounted during a transition.
@MainActor final class ExternalStorageCapacityModel: ObservableObject {
    static let shared = ExternalStorageCapacityModel()

    @Published private(set) var volumes: [ExternalVolumeCapacity] = []
    @Published private(set) var sampled = false
    @Published private(set) var activity: DiskActivitySnapshot?

    private let sampler = DiskActivitySampler()
    private var lastSampleAt: Date?

    /// Display filesystem capacity per mounted external volume, never sum
    /// APFS sharing members. Identical APFS capacity/free records on one
    /// physical disk represent shared capacity and need one compact bar.
    static func displayRows(from snapshot: DiskActivitySnapshot) -> [ExternalVolumeCapacity] {
        snapshot.external.sorted().flatMap { diskID -> [ExternalVolumeCapacity] in
            var knownShared: Set<String> = []
            return (snapshot.volumes[diskID] ?? []).compactMap { volume in
                if volume.apfs {
                    let key = "\(volume.total):\(volume.available)"
                    guard knownShared.insert(key).inserted else { return nil }
                }
                return ExternalVolumeCapacity(diskID: diskID, volume: volume)
            }
        }
    }

    func watch() async {
        while !Task.isCancelled {
            // Native physical-disk byte counters refresh every two seconds;
            // volume capacity scans remain cached for 30 seconds.
            let needsCapacity = lastSampleAt.map { Date().timeIntervalSince($0) >= 30 } ?? true
            // The sampler already caches filesystem scans for 30 seconds, but
            // must be allowed to invalidate on physical disk insertion/removal.
            let result = await sampler.sampleAll(includeVolumes: true)
            guard !Task.isCancelled else { return }
            let previousConnected = activity?.connected ?? []
            let previousExternal = activity?.external ?? []
            let topologyChanged = previousExternal != result.external ||
                                  previousConnected != result.connected
            let showedExternal = !volumes.isEmpty || !previousExternal.isEmpty
            activity = result
            if needsCapacity || topologyChanged || !sampled {
                let nextVolumes = Self.displayRows(from: result)
                let countChanged = volumes.count != nextVolumes.count
                let contentChanged = countChanged ||
                    zip(volumes, nextVolumes).contains { old, new in
                        old.id != new.id || old.volume.total != new.volume.total ||
                        old.volume.available != new.volume.available ||
                        old.volume.name != new.volume.name
                    }
                if contentChanged { volumes = nextVolumes }
                if !sampled { sampled = true }
                lastSampleAt = Date()
                let showsExternal = !nextVolumes.isEmpty || !result.external.isEmpty
                // Only remeasure AppKit when a row enters/leaves, not when
                // internal counters first appear or rates change each tick.
                if countChanged || showedExternal != showsExternal {
                    NotificationCenter.default.post(name: .chipBarStorageLayoutDidChange,
                                                    object: nil)
                }
            }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
        }
    }
}

/// The capacity overview belongs on Home, not behind System Details or an
/// SSD disclosure. Temperatures, fan telemetry and SMART stay on that page.
struct StorageCapacitySection: View {
    @ObservedObject var state: DashboardState
    @StateObject private var internalStorage = InternalStorageModel.shared
    @StateObject private var externalStorage = ExternalStorageCapacityModel.shared

    // No placeholder card is rendered when no external device is detected.
    // A newly mounted drive automatically restores the two-column grid.
    private var showsExternalDrive: Bool {
        Self.shouldShowExternal(volumes: externalStorage.volumes,
                                snapshot: externalStorage.activity)
    }

    static func shouldShowExternal(volumes: [ExternalVolumeCapacity],
                                   snapshot: DiskActivitySnapshot?) -> Bool {
        !volumes.isEmpty || !(snapshot?.external.isEmpty ?? true)
    }

    private var columns: [GridItem] {
        let count = showsExternalDrive ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private var freshActivity: DiskActivitySnapshot? {
        guard let activity = externalStorage.activity,
              Date().timeIntervalSince(activity.date) <= 6 else { return nil }
        return activity
    }

    /// Sum counters only for connected *internal physical disks*.
    private var internalRates: (read: Double?, write: Double?) {
        guard let activity = freshActivity else { return (nil, nil) }
        let values = activity.rates.filter {
            activity.connected.contains($0.key) && !activity.external.contains($0.key)
        }.map { $0.value }
        guard !values.isEmpty else { return (nil, nil) }
        return (values.reduce(0) { $0 + $1.readMB },
                values.reduce(0) { $0 + $1.writeMB })
    }

    /// Whole-drive I/O, not a fabricated rate for an individual APFS volume.
    private func externalRates(for diskID: String) -> (read: Double?, write: Double?) {
        guard let activity = freshActivity,
              activity.connected.contains(diskID),
              let rate = activity.rates[diskID] else { return (nil, nil) }
        return (rate.readMB, rate.writeMB)
    }

    private var internalCard: some View {
        let rates = internalRates
        return StorageVolumeCard(
            title: "Macintosh HD",
            symbol: "internaldrive",
            total: internalStorage.capacity?.totalBytes,
            available: internalStorage.capacity?.availableBytes,
            placeholder: internalStorage.sampled ? "不可用" : "读取中…",
            readMB: rates.read,
            writeMB: rates.write)
    }

    @ViewBuilder private var externalCards: some View {
        if externalStorage.volumes.isEmpty {
            // Detected physical disk with no mountable filesystem.
            StorageVolumeCard(title: "外接储存", symbol: "externaldrive",
                              total: nil, available: nil, placeholder: "未挂载磁盘")
        } else {
            ForEach(externalStorage.volumes) { item in
                // Shared APFS volumes on one physical drive show the same
                // whole-drive rate rather than claiming per-volume counters.
                let rates = externalRates(for: item.diskID)
                Button {
                    guard !DashboardTileLayoutModel.shared.editing else { return }
                    state.selectedExternalVolumeID = item.id
                    state.sidePanel = .externalDisk
                } label: {
                    StorageVolumeCard(
                        title: item.volume.name.isEmpty ? "外接储存" : item.volume.name,
                        symbol: "externaldrive",
                        total: item.volume.total,
                        available: item.volume.available,
                        placeholder: "不可用",
                        readMB: rates.read,
                        writeMB: rates.write,
                        showsChevron: true)
                }
                .buttonStyle(ChipBarPressStyle())
                .accessibilityHint("查看外置磁盘详情")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("储存空间", systemImage: "internaldrive")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("可用容量")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                internalCard
                if showsExternalDrive {
                    externalCards
                }
            }
        }
        .task {
            // Retain the existing non-blocking 30-second capacity sources.
            do { try await Task.sleep(for: .milliseconds(420)) }
            catch { return }
            await internalStorage.watch()
        }
        .task {
            do { try await Task.sleep(for: .milliseconds(900)) }
            catch { return }
            await externalStorage.watch()
        }
    }
}

/// Clean volume summary: one readable available-space number and a restrained
/// usage runway. No repeated full-width capacity bars or redundant subtitles.
/// Capacity values are macOS file-system values, never invented telemetry.
private struct StorageVolumeCard: View {
    let title: String
    let symbol: String
    let total: Int64?
    let available: Int64?
    let placeholder: String
    var readMB: Double? = nil
    var writeMB: Double? = nil
    var showsChevron = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let accent = Color(red: 0.22, green: 0.65, blue: 0.79)

    private var capacity: (total: Int64, available: Int64)? {
        guard let total, let available, total > 0,
              available >= 0 && available <= total else { return nil }
        return (total, available)
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    private var usedFraction: Double {
        guard let capacity else { return 0 }
        return 1 - Double(capacity.available) / Double(capacity.total)
    }

    // Keep each SwiftUI result-builder small enough for release-mode type checking.
    // The cards retain the same hierarchy, fonts, dimensions and animation.
    private var cardHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(accent)
                .frame(width: 17)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if showsChevron {
                Text("已用 \(usagePercentageLabel)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
    }

    // A single fixed-height group prevents the normal/placeholder branches
    // from acquiring different VStack spacing and uneven bottom padding.
    private var capacityReadout: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let capacity {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatted(capacity.available))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .frame(height: 21, alignment: .leading)
                Text("总计 \(formatted(capacity.total))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(height: 13, alignment: .leading)
            } else {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(height: 21, alignment: .leading)
                Text("容量暂不可用")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(height: 13, alignment: .leading)
            }
        }
        .frame(height: 36, alignment: .center)
    }

    private var capacityRunway: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(accent.opacity(0.82))
                    .frame(width: geometry.size.width * usedFraction)
            }
        }
        .frame(height: 5)
        .animation(reduceMotion ? nil : ChipBarMotion.disclosure, value: usedFraction)
    }

    private var usagePercentageLabel: String {
        guard capacity != nil else { return "—" }
        return String(format: "%.0f%%", usedFraction * 100)
    }

    private var usageLine: some View {
        HStack(spacing: 7) {
            capacityRunway
            if !showsChevron {
                Text(usagePercentageLabel)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private func formattedRate(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, rate >= 0 else { return "—" }
        return String(format: "%.1f", rate)
    }

    private var diskSpeedLine: some View {
        Text("读 \(formattedRate(readMB)) · 写 \(formattedRate(writeMB)) MB/s")
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(height: 13, alignment: .leading)
    }

    private var accessibilitySummary: String {
        let speeds = "，读取 \(formattedRate(readMB)) MB/s，写入 \(formattedRate(writeMB)) MB/s"
        guard let capacity else { return "\(title)，\(placeholder)" + speeds }
        let percent = Int((usedFraction * 100).rounded())
        return "\(title)，可用 \(formatted(capacity.available))，总计 \(formatted(capacity.total))，已用 \(percent)%" + speeds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            cardHeader.frame(height: 16, alignment: .center)
            capacityReadout
            usageLine.frame(height: 12, alignment: .center)
            diskSpeedLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 16 + 36 + 12 + 13 + 3*5 = 92 pt. The remaining 4 pt is
        // distributed equally above and below, including empty-data states.
        .frame(height: 96, alignment: .center)
        .padding(10)
        .glassTile(radius: 26, interactive: showsChevron)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }
}
