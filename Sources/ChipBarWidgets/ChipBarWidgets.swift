import Foundation
import SwiftUI
import WidgetKit

// MARK: - New, versioned kind identifiers

/// New kinds do NOT reuse legacy IDs. Previously installed widgets continue
/// to work after upgrade because every legacy kind remains registered below.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: ChipBarSnapshot?
    let selectedVolume: String?
    let isPlaceholder: Bool
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: nil,
                      selectedVolume: nil, isPlaceholder: true)
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (SnapshotEntry) -> Void) {
        // Missing file never shows sample data as if it were genuine.
        completion(SnapshotEntry(date: Date(),
                                 snapshot: ChipBarSnapshotStore.readForWidget(),
                                 selectedVolume: nil, isPlaceholder: false))
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = ChipBarSnapshotStore.readForWidget()
        var entries = [SnapshotEntry(date: now, snapshot: snapshot,
                                     selectedVolume: nil, isPlaceholder: false)]
        if let snapshot {
            // Schedule a stale-state transition without TimelineView or a
            // continuously running clock. WidgetKit may defer this entry.
            let expiry = snapshot.timestamp.addingTimeInterval(181)
            if expiry > now {
                entries.append(SnapshotEntry(date: expiry, snapshot: snapshot,
                                             selectedVolume: nil,
                                             isPlaceholder: false))
            }
        }
        completion(Timeline(entries: entries,
                            policy: .after(now.addingTimeInterval(5 * 60))))
    }
}

struct ChipBarOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ChipBarSnapshotStore.newOverviewKind,
                            provider: SnapshotProvider()) { entry in
            GlassOverviewContent(snapshot: entry.snapshot, now: entry.date,
                                 placeholder: entry.isPlaceholder)
        }
        .configurationDisplayName("ChipBar · 总览")
        .description("芯片功率、占用、逐核心负载和储存空间。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// The same new kind is backed by an App Intent on macOS 14+ and a
// non-configurable StaticConfiguration on macOS 13. The WidgetBundle builder,
// not a function returning opaque WidgetConfiguration, selects the branch:
// the two opaque configuration types must never share an ordinary if/else
// return expression (Swift reports "branches have mismatching types").
@available(macOS 14.0, *)
struct ChipBarStorageIntentWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: ChipBarSnapshotStore.newStorageKind,
                               intent: StorageVolumeIntent.self,
                               provider: StorageIntentProvider()) { entry in
            GlassStorageContent(snapshot: entry.snapshot,
                                selectedVolume: (entry.selectedVolume == "全部" ||
                                                 entry.selectedVolume == "All")
                                    ? nil : entry.selectedVolume,
                                now: entry.date,
                                placeholder: entry.isPlaceholder)
        }
        .configurationDisplayName("ChipBar · 储存空间")
        .description("查看磁盘容量和读写速率，可选择单个卷。")
        .supportedFamilies([.systemSmall])
    }
}

struct ChipBarStorageWidget: Widget {
    // WidgetBundleBuilder permits only a single #available branch, without
    // an else. On macOS 13 the static widget owns ChipBar.Storage; on 14+
    // this hidden compatibility widget uses a different kind while the
    // configurable App Intent widget owns ChipBar.Storage.
    private var fallbackKind: String {
        if #available(macOS 14.0, *) {
            return "ChipBar.Storage.macOS13-fallback"
        }
        return ChipBarSnapshotStore.newStorageKind
    }
    private var fallbackFamilies: [WidgetFamily] {
        if #available(macOS 14.0, *) { return [] }
        return [.systemSmall]
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: fallbackKind,
                            provider: SnapshotProvider()) { entry in
            GlassStorageContent(snapshot: entry.snapshot,
                                selectedVolume: nil,
                                now: entry.date,
                                placeholder: entry.isPlaceholder)
        }
        .configurationDisplayName("ChipBar · 储存空间")
        .description("查看两个储存卷的剩余容量和读写速率。")
        .supportedFamilies(fallbackFamilies)
    }
}

// MARK: - Legacy widget IDs; NEVER delete or rename

private enum LegacyWidgetTile: String {
    case overview, powerTrend, cpu, gpu, memory, cpuCores
    case fan, ane, storage, powerSupply, applications

    var title: String {
        switch self {
        case .overview: return "ChipBar 仪表盘"
        case .powerTrend: return "芯片功率趋势"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .cpuCores: return "CPU 各核心"
        case .fan: return "风扇"
        case .ane: return "ANE"
        case .storage: return "储存空间"
        case .powerSupply: return "内部功率"
        case .applications: return "应用占用"
        }
    }

    // Gallery descriptors must use direct literals; computed/interpolated
    // descriptions previously caused chronod's getAllDescriptors to fail.
    var galleryTitle: LocalizedStringKey {
        switch self {
        case .overview: return "ChipBar · 仪表盘"
        case .powerTrend: return "ChipBar · 芯片功率趋势"
        case .cpu: return "ChipBar · CPU"
        case .gpu: return "ChipBar · GPU"
        case .memory: return "ChipBar · 内存"
        case .cpuCores: return "ChipBar · CPU 各核心"
        case .fan: return "ChipBar · 风扇"
        case .ane: return "ChipBar · ANE"
        case .storage: return "ChipBar · 储存空间"
        case .powerSupply: return "ChipBar · 内部功率"
        case .applications: return "ChipBar · 应用占用"
        }
    }

    var key: String {
        switch self {
        case .overview, .powerTrend: return "chip"
        case .cpu: return "cpuUsage"
        case .gpu: return "gpuUsage"
        case .memory: return "ramPercentage"
        case .cpuCores: return "cpuUsage"
        case .fan: return "fanRPM"
        case .ane: return "anePower"
        case .storage: return "storageFreeGB"
        case .powerSupply: return "internalPower"
        case .applications: return "cpuUsage"
        }
    }
}

/// Existing JSON contract remains readable even if an App Group is activated
/// for the NEW snapshot contract. Avoid an unentitled app-group lookup here.
private struct LegacyTelemetry {
    let values: [String: Any]

    static func read() -> LegacyTelemetry {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = directory?.appendingPathComponent("ChipBar/telemetry.json")
        guard let url, let data = try? Data(contentsOf: url),
              data.count <= 128 * 1024,
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return LegacyTelemetry(values: [:]) }
        return LegacyTelemetry(values: values)
    }

    func number(_ name: String) -> Double? {
        guard let value = (values[name] as? NSNumber)?.doubleValue,
              value.isFinite, value >= 0 else { return nil }
        return value
    }

    func doubles(_ name: String) -> [Double] {
        (values[name] as? [NSNumber])?.map(\.doubleValue) ?? []
    }
}

private struct LegacyEntry: TimelineEntry {
    let date: Date
    let payload: LegacyTelemetry
    let placeholder: Bool
}

private struct LegacyProvider: TimelineProvider {
    func placeholder(in context: Context) -> LegacyEntry {
        LegacyEntry(date: .now, payload: LegacyTelemetry(values: [:]), placeholder: true)
    }
    func getSnapshot(in context: Context, completion: @escaping (LegacyEntry) -> Void) {
        completion(LegacyEntry(date: .now, payload: .read(), placeholder: false))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LegacyEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [LegacyEntry(date: now, payload: .read(),
                                                 placeholder: false)],
                            policy: .after(now.addingTimeInterval(5 * 60))))
    }
}

private protocol LegacyModule {
    static var tile: LegacyWidgetTile { get }
}
private enum OldOverview: LegacyModule { static let tile: LegacyWidgetTile = .overview }
private enum OldPowerTrend: LegacyModule { static let tile: LegacyWidgetTile = .powerTrend }
private enum OldCPU: LegacyModule { static let tile: LegacyWidgetTile = .cpu }
private enum OldGPU: LegacyModule { static let tile: LegacyWidgetTile = .gpu }
private enum OldMemory: LegacyModule { static let tile: LegacyWidgetTile = .memory }
private enum OldCores: LegacyModule { static let tile: LegacyWidgetTile = .cpuCores }
private enum OldFan: LegacyModule { static let tile: LegacyWidgetTile = .fan }
private enum OldANE: LegacyModule { static let tile: LegacyWidgetTile = .ane }
private enum OldStorage: LegacyModule { static let tile: LegacyWidgetTile = .storage }
private enum OldPowerSupply: LegacyModule { static let tile: LegacyWidgetTile = .powerSupply }
private enum OldApplications: LegacyModule { static let tile: LegacyWidgetTile = .applications }

private struct LegacyWidget<Module: LegacyModule>: Widget {
    init() {}

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "local.chipbar.telemetry.\(Module.tile.rawValue)",
                            provider: LegacyProvider()) { entry in
            LegacyCard(tile: Module.tile, entry: entry)
        }
        .configurationDisplayName(Module.tile.galleryTitle)
        // Static literal: WidgetKit may crash on an interpolated description.
        .description("兼容旧版 ChipBar 小组件，保留桌面已有的配置。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct LegacyCard: View {
    let tile: LegacyWidgetTile
    let entry: LegacyEntry
    @Environment(\.widgetFamily) private var family

    private func number(_ key: String, precision: Int = 1) -> String {
        GlassFormat.decimal(entry.payload.number(key), precision: precision)
    }

    var body: some View {
        GlassWidgetCanvas {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    IconChip(symbol: tile == .storage ? "externaldrive" :
                                 "waveform.path.ecg",
                             color: GlassPalette.power, size: 24)
                    Text(tile.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                if tile == .cpuCores {
                    Text("CPU 各核心")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    CoreBarsView(values: entry.payload.doubles("coreUsage"),
                                 perfCount: 10, height: family == .systemSmall ? 56 : 90)
                } else if tile == .powerTrend || tile == .overview {
                    GlassNumberText(text: number("chip"), unit: "W",
                                    size: family == .systemSmall ? 27 : 38,
                                    tint: GlassPalette.power)
                    SparklineView(values: entry.payload.doubles("powerHistory"),
                                  color: GlassPalette.power, showGrid: true,
                                  average: entry.payload.number("averagePower"),
                                  current: entry.payload.number("chip"))
                        .frame(height: family == .systemSmall ? 48 : 88)
                } else if tile == .storage {
                    GlassNumberText(text: number("storageFreeGB"),
                                    unit: "GB", size: 24, tint: GlassPalette.cpu)
                    UsageBar(percent: 100 * max(0, 1 -
                        (entry.payload.number("storageFreeGB") ?? 0) /
                        max(1, entry.payload.number("storageTotalGB") ?? 1)),
                        color: GlassPalette.cpu)
                } else {
                    let key = tile.key
                    GlassNumberText(text: number(key,
                                                  precision: tile == .fan ? 0 : 1),
                                    unit: tile == .fan ? "RPM" :
                                          (tile == .cpu || tile == .gpu ||
                                           tile == .memory || tile == .applications)
                                          ? "%" : "W",
                                    size: family == .systemSmall ? 30 : 43,
                                    tint: GlassPalette.power)
                    if tile == .cpu || tile == .gpu || tile == .memory {
                        UsageBar(percent: entry.payload.number(key) ?? 0,
                                 color: tile == .cpu ? GlassPalette.cpu :
                                        tile == .gpu ? GlassPalette.gpu :
                                        GlassPalette.memoryColor(
                                            entry.payload.number(key) ?? 0))
                    }
                }
                Spacer(minLength: 0)
                Text("最近一次监测快照")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .redacted(reason: entry.placeholder ? .placeholder : [])
        }
        .widgetURL(URL(string: "chipbar://main"))
    }
}

@main
struct ChipBarWidgets: WidgetBundle {
    @WidgetBundleBuilder var body: some Widget {
        ChipBarOverviewWidget()
        // macOS 13 static fallback is always present in the bundle but
        // hidden on 14+; only the App Intent configuration is then visible.
        ChipBarStorageWidget()
        if #available(macOS 14.0, *) {
            ChipBarStorageIntentWidget()
        }

        // Keeping all eleven legacy IDs prevents placed widgets disappearing.
        LegacyWidget<OldOverview>()
        LegacyWidget<OldPowerTrend>()
        LegacyWidget<OldCPU>()
        LegacyWidget<OldGPU>()
        LegacyWidget<OldMemory>()
        LegacyWidget<OldCores>()
        LegacyWidget<OldFan>()
        LegacyWidget<OldANE>()
        LegacyWidget<OldStorage>()
        LegacyWidget<OldPowerSupply>()
        LegacyWidget<OldApplications>()
    }
}

// MARK: - Design-time previews (never used as a production fallback)

@available(macOS 14.0, *)
#Preview(as: .systemSmall) {
    ChipBarOverviewWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview,
                  selectedVolume: nil, isPlaceholder: false)
}

@available(macOS 14.0, *)
#Preview(as: .systemMedium) {
    ChipBarOverviewWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview,
                  selectedVolume: nil, isPlaceholder: false)
}

@available(macOS 14.0, *)
#Preview(as: .systemLarge) {
    ChipBarOverviewWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview,
                  selectedVolume: nil, isPlaceholder: false)
}

@available(macOS 14.0, *)
#Preview(as: .systemSmall) {
    ChipBarStorageWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview,
                  selectedVolume: nil, isPlaceholder: false)
}
