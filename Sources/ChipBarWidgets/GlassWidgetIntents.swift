import AppIntents
import SwiftUI
import WidgetKit

/// macOS 14+ configuration. On macOS 13 the same *new* kind is registered
/// using StaticConfiguration and displays both volumes when available.
@available(macOS 14.0, *)
struct StorageVolumeOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        let names = ChipBarSnapshotStore.readForWidget()?.volumes.map(\.name) ?? []
        // All is a presentation option, not an on-disk volume name. Localize
        // the option title without turning the stored real volume IDs into
        // translated strings.
        return [String(localized: "全部")] + Array(Set(names)).sorted()
    }
}

@available(macOS 14.0, *)
struct StorageVolumeIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择储存卷"
    static var description = IntentDescription("选择一个卷，或同时显示两个储存卷。")

    @Parameter(title: "卷", optionsProvider: StorageVolumeOptions())
    var volumeName: String?

    init() {}
}

@available(macOS 14.0, *)
struct StorageIntentProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: nil, selectedVolume: nil,
                      isPlaceholder: true)
    }

    func snapshot(for configuration: StorageVolumeIntent,
                  in context: Context) async -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: ChipBarSnapshotStore.readForWidget(),
                      selectedVolume: configuration.volumeName,
                      isPlaceholder: false)
    }

    func timeline(for configuration: StorageVolumeIntent,
                  in context: Context) async -> Timeline<SnapshotEntry> {
        let now = Date()
        let entry = SnapshotEntry(date: now,
                                  snapshot: ChipBarSnapshotStore.readForWidget(),
                                  selectedVolume: configuration.volumeName,
                                  isPlaceholder: false)
        // A request is not a guarantee; macOS schedules actual updates.
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(5 * 60)))
    }
}
