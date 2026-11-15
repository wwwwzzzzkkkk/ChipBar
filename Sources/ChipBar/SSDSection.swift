import SwiftUI
import ChipBarCore

struct SSDSection: View {
    @ObservedObject var ssd: ExternalSSDMonitor
    @ObservedObject var state: DashboardState
    @StateObject private var activity = DiskActivityModel()
    var body: some View {
        if ssd.enabled {
            VStack(alignment: .leading, spacing: 8) {
                Button { state.showSSDDetails.toggle() } label: {
                    HStack {
                        Label("外接 NVMe SSD", systemImage: "externaldrive").font(.subheadline.weight(.medium))
                        Spacer()
                        Text(state.showSSDDetails ? "收起" : "详情").font(.caption)
                        Image(systemName: "chevron.down").font(.caption2)
                            .rotationEffect(.degrees(180 * state.ssdExpansion))
                    }.contentShape(Rectangle())
                }.buttonStyle(ChipBarPressStyle())
                ForEach(ssd.readings) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.temperature?.model ?? row.name).lineLimit(1)
                            Spacer()
                            Text(liveTemperature(row).flatMap(\.composite)
                                .map { String(format: "%.0f °C", $0) } ?? "—")
                                .monospacedDigit().fontWeight(.medium)
                        }.font(.caption)
                        Text(speedSummary(row.id)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                details.fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { state.ssdDetailsHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { state.ssdDetailsHeight = $0 }
                    })
                    .frame(height: state.ssdDetailsHeight * state.ssdExpansion, alignment: .top)
                    .opacity(state.ssdExpansion).clipped()
                    .accessibilityHidden(!state.showSSDDetails).disabled(!state.showSSDDetails)
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .task(id: ssd.readings.map(\.id).joined(separator: ",")) {
                    guard !ssd.readings.isEmpty else { return }
                    // Disk Arbitration and IOKit scans belong after the
                    // window spring, not in the first frames of expansion.
                    // Cancel automatically if the section is collapsed.
                    do { try await Task.sleep(for: .milliseconds(560)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    await activity.watch(ids: ssd.readings.map(\.id), includeVolumes: false)
                }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ssd.readings) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text("综合温度 · \(row.id)").font(.caption2).foregroundStyle(.secondary)
                    if let reading = liveTemperature(row) {
                        let sensors = reading.sensors.enumerated().compactMap { index, value in
                            value.map { String(format: "传感器 %d：%.0f°C", index + 1, $0) }
                        }
                        if !sensors.isEmpty { Text(sensors.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
                        Text(health(reading)).font(.caption2)
                            .foregroundStyle(reading.passed == false || (reading.criticalWarning ?? 0) != 0 ? Color.orange : Color.secondary)
                        Text("温度更新于 \(reading.date.formatted(date: .omitted, time: .standard))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let error = row.error { Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Text("读写速度为整盘实际 I/O，MB/s；面板可见时每 2 秒更新。容量和占用进度请查看主页「储存空间」。")
                .font(.caption2).foregroundStyle(.secondary)
            Text(ssd.status).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func liveTemperature(_ row: SSDReading) -> SSDTemperature? {
        if let snapshot = activity.snapshot, !snapshot.connected.contains(row.id) { return nil }
        return row.temperature.flatMap { $0.isFresh() ? $0 : nil }
    }
    private func speedSummary(_ id: String) -> String {
        guard let snapshot = activity.snapshot, snapshot.connected.contains(id),
              Date().timeIntervalSince(snapshot.date) <= 6 else { return "读取 — · 写入 — MB/s" }
        guard let rate = snapshot.rates[id] else { return "读取 — · 写入 — MB/s · 等待采样" }
        return String(format: "读取 %.1f · 写入 %.1f MB/s", rate.readMB, rate.writeMB)
    }

    private func health(_ reading: SSDTemperature) -> String {
        var result = "SMART：" + (reading.passed.map { $0 ? "PASSED" : "警告" } ?? "未知")
        if let warning = reading.criticalWarning, warning != 0 { result += String(format: " · 严重警告 0x%02X", warning) }
        if let used = reading.percentageUsed { result += " · 寿命消耗估计 \(used)%" }
        if reading.partialRead { result += " · 部分命令失败" }
        return result
    }
}

struct SSDSettings: View {
    @ObservedObject var ssd: ExternalSSDMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("监控外接 NVMe SSD", isOn: $ssd.enabled)
                .toggleStyle(ChipBarGlassToggleStyle())
            if ssd.enabled {
                // Keep previously configured paths and permissions internally.
                // Device selection uses auto detection by default and never
                // silently grants sudo access when the control is hidden.
                if ssd.executablePath.isEmpty {
                    Text("未找到 smartctl，温度监控暂不可用；可通过 Homebrew 安装 smartmontools。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Link("安装、权限与硬盘盒兼容说明", destination: URL(string: "https://github.com/wwwwzzzzkkkk/macmon/blob/chipbar/apps/ChipBar/docs/EXTERNAL_SSD.md")!)
                    .font(.caption)
                Button("重新检测 SSD") { ssd.restart() }
            }
        }
    }
}
