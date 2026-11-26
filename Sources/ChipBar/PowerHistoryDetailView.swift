import SwiftUI
import ChipBarCore

extension PowerHistoryEventKind {
    var title: String {
        switch self {
        case .connected: return ChipBarLocale.choose("Plugged in", "接电")
        case .disconnected: return ChipBarLocale.choose("Unplugged", "拔电")
        case .batteryAssisted: return ChipBarLocale.choose("Battery assist", "电池补能")
        case .connectedWithBatteryAssist:
            return ChipBarLocale.choose("Plugged in · Battery assist", "接电 · 电池补能")
        }
    }

    var symbol: String {
        switch self {
        case .connected: return "powerplug.fill"
        case .disconnected: return "powerplug"
        case .batteryAssisted, .connectedWithBatteryAssist: return "battery.50percent"
        }
    }

    var tint: Color {
        switch self {
        case .connected: return .mint
        case .disconnected: return .orange
        case .batteryAssisted, .connectedWithBatteryAssist: return .purple
        }
    }
}

struct PowerHistoryDetailView: View {
    @ObservedObject var monitor: Monitor
    @Binding var selection: PowerHistorySelection?
    let close: () -> Void
    @ObservedObject private var power = ChipBarPowerFlowModel.shared

    var body: some View {
        DashboardGlassContainer { content }
            .environment(\.appearsActive, true)
    }

    private var content: some View {
        let chart = monitor.powerChart.including(power.events)
        let timeline = chart.timeline
        let events = power.events.filter { timeline.fraction(for: $0.date) != nil }
        let visibleSelection = selection.flatMap { timeline.fraction(for: $0.date) == nil ? nil : $0 }
        let effectiveSelection = visibleSelection ?? chart.points.last.map { .sample($0.date) }
        return VStack(alignment: .leading, spacing: 10) {
            header
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(ChipBarLocale.choose("Chip power", "芯片总功率")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(ChipBarLocale.choose("Average \(watts(chart.average))", "均值 \(watts(chart.average))"))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                PowerTrendPlot(points: chart.points, maximum: chart.maximum, timeline: timeline,
                               accent: .primary, events: events, selection: effectiveSelection,
                               showsEventSymbols: true, onSelect: { if let point = $0 { selection = point } })
                    .frame(height: 142)
                    .overlay {
                        if chart.points.isEmpty {
                            Text(ChipBarLocale.choose("Waiting for chip power samples", "等待功率采样"))
                                .font(.caption).foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(12)
            .glassTile(radius: 20, tint: Color.primary.opacity(0.07), highlightsEdges: true)

            eventStrip(events)
            inspector(selection: effectiveSelection, events: events)
            HistoricalApplicationUsageView(date: effectiveSelection?.date, timeline: timeline)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .glassTile(radius: 13, interactive: true)
            }
            .accessibilityLabel(ChipBarLocale.choose("Close power history", "关闭功率历史"))
            VStack(alignment: .leading, spacing: 1) {
                Text(ChipBarLocale.choose("Power history", "功率历史")).font(.headline)
                Text(ChipBarLocale.choose("Last 10 minutes", "最近 10 分钟"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func eventStrip(_ events: [PowerHistoryEvent]) -> some View {
        ViewThatFits(in: .horizontal) {
            eventButtons(events)
            ScrollView(.horizontal) { eventButtons(events) }
                .scrollIndicators(.hidden)
        }
        .frame(height: 30, alignment: .leading)
    }

    @ViewBuilder private func eventButtons(_ events: [PowerHistoryEvent]) -> some View {
        if events.isEmpty {
            Label(ChipBarLocale.choose("No power source changes in this window", "这 10 分钟没有电源切换"),
                  systemImage: "powerplug")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 5)
        } else {
            HStack(spacing: 6) {
                ForEach(events.reversed()) { event in
                    let selected = selection == .event(event.date)
                    Button {
                        selection = .event(event.date)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: event.kind.symbol).foregroundStyle(event.kind.tint)
                            Text(event.kind.title)
                            Text(time(event.date)).foregroundStyle(.secondary)
                        }
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(selected ? event.kind.tint.opacity(0.19) : Color.primary.opacity(0.07),
                                    in: Capsule())
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.fixedSize(horizontal: true, vertical: false)
        }
    }

    private func inspector(selection: PowerHistorySelection?, events: [PowerHistoryEvent]) -> some View {
        let event = events.first { selection == .event($0.date) }
        let sample = event?.chipSample ?? monitor.history.first { selection == .sample($0.date) }
        let title = event?.kind.title ?? ChipBarLocale.choose("Chip sample", "芯片采样")
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: event?.kind.symbol ?? "waveform.path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(event?.kind.tint ?? .primary)
                Spacer()
                if let percent = event?.reading.batteryPercent {
                    Text(String(format: "%.0f%%", percent))
                        .foregroundStyle(.secondary)
                }
                Text(selection.map { time($0.date) } ?? "—")
                    .foregroundStyle(.secondary)
            }.font(.caption.monospacedDigit())
            HStack(spacing: 6) {
                metric(ChipBarLocale.choose("Chip", "芯片"), watts(sample?.total))
                if let event {
                    let estimated = event.reading.systemWatts != nil && event.reading.diagnostics.systemSource != "PSTR"
                    metric(estimated ? ChipBarLocale.choose("Internal (est.)", "内部功率（估算）")
                           : ChipBarLocale.choose("Internal", "内部功率"), watts(event.reading.systemWatts))
                    metric(ChipBarLocale.choose("Adapter", "适配器"), watts(event.reading.adapterWatts))
                    metric(batteryLabel(event.reading.batteryWatts), watts(event.reading.batteryWatts.map(abs)))
                } else {
                    metric("CPU", watts(sample?.cpu))
                    metric("GPU", watts(sample?.gpu))
                    metric("ANE", watts(sample?.ane))
                }
            }
            if let event, let sample, time(sample.date) != time(event.date) {
                Text(ChipBarLocale.choose("Chip sampled at \(time(sample.date))",
                                           "芯片采样于 \(time(sample.date))"))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(height: 96, alignment: .topLeading)
        .glassTile(radius: 18, tint: Color.primary.opacity(0.07), highlightsEdges: true)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
            .locale(Locale(identifier: "en_GB")))
    }

    private func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f W", value)
    }

    private func batteryLabel(_ value: Double?) -> String {
        if let value, value > 0 { return ChipBarLocale.choose("Battery in", "充入电池") }
        if let value, value < 0 { return ChipBarLocale.choose("Battery out", "电池输出") }
        return ChipBarLocale.choose("Battery net", "电池净功率")
    }
}
