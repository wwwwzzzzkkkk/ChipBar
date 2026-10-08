import SwiftUI
import Charts
import ChipBarCore

final class DashboardState: ObservableObject {
    @Published var chartMetric: PowerMetric = .total
    @Published var showSettings = false
    init(showSettings: Bool = false) { self.showSettings = showSettings }
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @StateObject private var state: DashboardState
    private let accent = Color(red: 0.22, green: 0.65, blue: 0.79)

    init(monitor: Monitor, showSettings: Bool = false) {
        self.monitor = monitor
        _state = StateObject(wrappedValue: DashboardState(showSettings: showSettings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            hero
            powerCards
            trend
            temperatures
            errorPanel
            Text(monitor.status).font(.caption).foregroundStyle(.secondary)
            settingsPanel
            footer
        }
        .padding(20).frame(width: 390)
    }

    @ViewBuilder private var header: some View {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ChipBar").font(.headline)
                    Text(monitor.sample?.chip ?? monitor.hardware)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(monitor.connected ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(monitor.paused ? "已暂停" : monitor.connected ? "实时" : "等待数据")
                    .font(.caption).foregroundStyle(.secondary)
            }

    }

    @ViewBuilder private var hero: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("芯片合计功率").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value(monitor.connected ? monitor.sample?.total : nil))
                        .font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("W").font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "bolt.fill").font(.title).foregroundStyle(accent.opacity(0.6))
                }
                Text("CPU + GPU + ANE · 非插座输入功率")
                    .font(.caption).foregroundStyle(.secondary)
            }

    }

    @ViewBuilder private var powerCards: some View {
            HStack(spacing: 10) {
                powerCard("CPU", monitor.sample?.cpu, "cpu")
                powerCard("GPU", monitor.sample?.gpu, "square.stack.3d.up")
                powerCard("ANE", monitor.sample?.ane, "sparkles")
            }

    }

    @ViewBuilder private var trend: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("功率趋势").font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("趋势指标", selection: $state.chartMetric) {
                        ForEach(PowerMetric.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
                if monitor.history.compactMap({ $0.power(state.chartMetric) }).isEmpty {
                    Text("等待有效采样后显示趋势")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 115)
                } else {
                    Chart {
                        ForEach(chartPoints) { point in
                            LineMark(x: .value("时间", point.date), y: .value("W", point.power),
                                     series: .value("连续采样", point.segment))
                                .foregroundStyle(accent).interpolationMethod(.linear)
                        }
                    }
                    .chartYScale(domain: 0...max(1, (monitor.history.compactMap { $0.power(state.chartMetric) }.max() ?? 1) * 1.15))
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute().second())
                    } }
                    .frame(height: 115)
                }
                HStack {
                    Text("最近 10 分钟 · W")
                    Spacer()
                    Text("均值 \(value(average)) W")
                }.font(.caption2).foregroundStyle(.secondary)
            }

    }

    @ViewBuilder private var temperatures: some View {
            HStack {
                Label("CPU \(temperature(monitor.sample?.cpuTemperature))", systemImage: "thermometer.medium")
                Spacer()
                Text("GPU \(temperature(monitor.sample?.gpuTemperature))")
            }.font(.subheadline).monospacedDigit()

    }

    @ViewBuilder private var errorPanel: some View {
            if let error = monitor.error {
                VStack(alignment: .leading, spacing: 5) {
                    Label("采样需要处理", systemImage: "exclamationmark.triangle").font(.caption.weight(.semibold))
                    Text(error).font(.caption).textSelection(.enabled).lineLimit(5)
                    Button("立即重试") { monitor.restart() }.font(.caption)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

    }

    @ViewBuilder private var settingsPanel: some View {
            if state.showSettings {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("刷新间隔", selection: $monitor.interval) {
                        Text("1 秒").tag(1000); Text("2 秒").tag(2000)
                        Text("5 秒").tag(5000); Text("10 秒").tag(10000)
                    }.pickerStyle(.segmented)
                    Picker("菜单栏显示", selection: $monitor.menuMetric) {
                        ForEach(PowerMetric.allCases) { Text($0.title).tag($0) }
                    }
                    HStack {
                        Button("选择 macmon…") { monitor.chooseExecutable() }
                        Spacer()
                        Button("自动查找") { monitor.useDefaultPath() }
                    }
                    Text(monitor.executablePath.isEmpty ? "尚未找到 macmon" : monitor.executablePath)
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("缺失指标显示 —。零值只表示 macmon 返回零，不能据此确认传感器支持。新芯片请先实测。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
    }

    @ViewBuilder private var footer: some View {
            VStack {
            Divider()
            HStack {
                Button { state.showSettings.toggle() } label: { Label("设置", systemImage: "slider.horizontal.3") }
                Spacer()
                Button(monitor.paused ? "继续" : "暂停") { monitor.togglePause() }
                Button("退出") { monitor.stop(forQuit: true); NSApplication.shared.terminate(nil) }
            }.buttonStyle(.borderless).font(.subheadline)
            }
    }

    private func powerCard(_ title: String, _ power: Double?, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text("\(value(monitor.connected ? power : nil)) W")
                .font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var average: Double? {
        let values = monitor.history.compactMap { $0.power(state.chartMetric) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    // Do not draw a line across sleep, restart or missing metric gaps.
    private struct ChartPoint: Identifiable {
        let id: UUID
        let date: Date
        let power: Double
        let segment: Int
    }
    private var chartPoints: [ChartPoint] {
        var segment = 0
        var previous: Sample?
        var points: [ChartPoint] = []
        for sample in monitor.history {
            if let previous, sample.date.timeIntervalSince(previous.date) > Double(monitor.interval) / 1000 * 2.5 || previous.power(state.chartMetric) == nil {
                segment += 1
            }
            if let power = sample.power(state.chartMetric) {
                points.append(ChartPoint(id: sample.id, date: sample.date, power: power, segment: segment))
            }
            previous = sample
        }
        return points
    }

    private func value(_ number: Double?) -> String { number.map { String(format: "%.1f", $0) } ?? "—" }
    private func temperature(_ number: Double?) -> String {
        guard monitor.connected, let number else { return "不可用" }
        return String(format: "%.1f °C", number)
    }
}
