import SwiftUI
import ChipBarCore

struct HistoricalApplicationUsageView: View {
    let date: Date?
    let timeline: TrendTimeWindow
    @ObservedObject private var activity = ApplicationActivityModel.shared
    @State private var showsMemory = false

    var body: some View {
        let frame = date.flatMap { activity.history.nearest(to: $0, in: timeline) }
        let rows = (showsMemory ? frame?.memory : frame?.cpu) ?? []
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
                Picker(ChipBarLocale.choose("Historical app metric", "应用占用指标"), selection: $showsMemory) {
                    Text("CPU").tag(false)
                    Text(ChipBarLocale.choose("Memory", "内存")).tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 110)
            }

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
                        Text(reading(row)).monospacedDigit()
                    }
                    .font(.caption)
                    .frame(height: 17)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(12)
        .frame(height: 120, alignment: .topLeading)
        .glassTile(radius: 18, tint: Color.primary.opacity(0.07), highlightsEdges: true)
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
            .locale(Locale(identifier: "en_GB")))
    }

    private func reading(_ row: ApplicationActivityRow) -> String {
        if showsMemory {
            return ApplicationMemoryDisplay.text(bytes: row.physicalBytes,
                                                 approximate: row.memoryIsRSSApproximation)
        }
        return row.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
    }
}
