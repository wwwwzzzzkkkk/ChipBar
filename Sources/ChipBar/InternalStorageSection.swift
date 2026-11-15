import SwiftUI
import DiskArbitration
import ChipBarCore

/// Uses the boot APFS Data volume rather than summing mounted APFS volumes:
/// System, Data and Preboot can all share the same physical container.
/// Disk Arbitration confirms that the selected volume is on an internal disk.
/// External boot volumes are deliberately not described as internal storage.
actor InternalStorageSampler {
    // System Settings/Finder "available" may include purgeable APFS space;
    // volumeAvailableCapacity alone reports a smaller raw free-space figure.
    // Prefer the user-available figure but reject invalid/oversized values.
    static func checkedCapacity(total: Int64, important: Int64?, raw: Int64?) -> InternalStorageCapacity? {
        for available in [important, raw] {
            if let available,
               let capacity = InternalStorageCapacity(totalBytes: total, availableBytes: available) {
                return capacity
            }
        }
        return nil
    }

    func read() -> InternalStorageCapacity? {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        for path in ["/System/Volumes/Data", "/"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: path),
                  let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let details = DADiskCopyDescription(disk) as? [String: Any],
                  details[kDADiskDescriptionDeviceInternalKey as String] as? Bool == true,
                  details[kDADiskDescriptionVolumeNetworkKey as String] as? Bool != true,
                  let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity,
                  let capacity = Self.checkedCapacity(
                      total: Int64(total),
                      important: values.volumeAvailableCapacityForImportantUsage,
                      raw: values.volumeAvailableCapacity.map { Int64($0) }) else { continue }
            return capacity
        }
        return nil
    }
}

@MainActor final class InternalStorageModel: ObservableObject {
    static let shared = InternalStorageModel()
    private var lastSampleAt: Date?
    @Published private(set) var capacity: InternalStorageCapacity?
    @Published private(set) var sampled = false

    func watch() async {
        let sampler = InternalStorageSampler()
        while !Task.isCancelled {
            // View transitions may remount the card several times. Reuse its
            // most recent capacity instead of rescanning on each animation.
            if lastSampleAt == nil || Date().timeIntervalSince(lastSampleAt!) >= 30 {
                let value = await sampler.read()
                guard !Task.isCancelled else { return }
                capacity = value
                sampled = true
                lastSampleAt = Date()
            }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
        }
    }
}

struct InternalStorageSection: View {
    @StateObject private var model = InternalStorageModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("内置储存", systemImage: "internaldrive")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                if let capacity = model.capacity {
                    Text("可用 \(capacity.availableText)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    Text(model.sampled ? "不可用" : "读取中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            CapacityProgressTrack(usedFraction: model.capacity?.usedFraction)
            HStack {
                if let capacity = model.capacity {
                    Text("已使用 \(ByteCountFormatter.string(fromByteCount: capacity.totalBytes - capacity.availableBytes, countStyle: .decimal))")
                    Spacer()
                    Text("总容量 \(capacity.totalText)")
                } else {
                    Text(model.sampled ? "无法确认内置启动磁盘；不计入外置盘" : "正在读取系统数据卷容量…")
                    Spacer(minLength: 0)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .padding(11)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
        .task {
            // First APFS/Disk Arbitration read is delayed until the glass
            // panel has finished its opening spring animation.
            do { try await Task.sleep(for: .milliseconds(560)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await model.watch()
        }
        .accessibilityElement(children: .combine)
    }
}
