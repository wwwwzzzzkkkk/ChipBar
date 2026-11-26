import SwiftUI
import ChipBarCore

struct HistoricalApplicationUsageView: View {
    let date: Date?
    let timeline: TrendTimeWindow
    @ObservedObject private var activity = ApplicationActivityModel.shared
    @State private var showsMemory = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frame = date.flatMap { activity.history.nearest(to: $0, in: timeline) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(ChipBarLocale.choose("Application usage", "应用占用"))
                    .font(.caption.weight(.semibold))
                Spacer()
                if let frame {
                    Text(ChipBarLocale.choose("Sample \(time(frame.date))", "采样 \(time(frame.date))"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LiquidGlassSegmentedSelector(
                    selection: $showsMemory,
                    options: [.init(value: false, title: "CPU"),
                              .init(value: true, title: ChipBarLocale.choose("Memory", "内存"))],
                    accessibilityLabel: ChipBarLocale.choose("Historical app metric", "应用占用指标"),
                    height: 26)
                .frame(width: 110)
            }
            ZStack(alignment: .topLeading) {
                ranking(frame, showsMemory: showsMemory)
                    .id(showsMemory)
                    .transition(.opacity)
            }
            .frame(height: 51, alignment: .topLeading)
            .animation(reduceMotion ? nil : ChipBarMotion.navigation, value: showsMemory)
        }
        .padding(12)
        .frame(height: 120, alignment: .topLeading)
        .glassTile(radius: 26)
    }

    @ViewBuilder private func ranking(_ frame: ApplicationUsageHistory.Frame?, showsMemory: Bool) -> some View {
        let rows = (showsMemory ? frame?.memory : frame?.cpu) ?? []
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text(frame == nil
                     ? ChipBarLocale.choose("No app sample near this time", "这一时刻附近没有应用采样")
                     : ChipBarLocale.choose("No application readings for this metric", "此指标暂无可用的应用读数"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        if let path = row.appPath {
                            Image(nsImage: ApplicationIconCache.icon(for: path))
                                .resizable().interpolation(.high)
                                .frame(width: 14, height: 14)
                                .accessibilityHidden(true)
                        }
                        Text(row.name).lineLimit(1).truncationMode(.middle).help(row.name)
                        Spacer(minLength: 4)
                        Text(reading(row, showsMemory: showsMemory)).monospacedDigit()
                    }
                    .font(.caption)
                    .frame(height: 17)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
            .locale(Locale(identifier: "en_GB")))
    }

    private func reading(_ row: ApplicationActivityRow, showsMemory: Bool) -> String {
        if showsMemory {
            return ApplicationMemoryDisplay.text(bytes: row.physicalBytes,
                                                 approximate: row.memoryIsRSSApproximation)
        }
        return row.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
    }
}
