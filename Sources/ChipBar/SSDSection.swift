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
                }.buttonStyle(.plain)
                ForEach(ssd.readings) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.temperature?.model ?? row.name).lineLimit(1)
                            Spacer()
                            Text(liveTemperature(row).flatMap(\.composite)
                                .map { String(format: "%.0f °C", $0) } ?? "—")
                                .monospacedDigit().fontWeight(.medium)
                        }.font(.caption)
                        Text(spaceSummary(row.id)).font(.caption2).foregroundStyle(.secondary)
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
                    await activity.watch(ids: ssd.readings.map(\.id))
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
                    ForEach(volumes(row.id)) { volume in
                        Text("\(volume.name)：可用 \(bytes(volume.available)) / \(bytes(volume.total))\(volume.apfs ? " · APFS 共享空间" : "")")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = row.error { Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Text("读写速度为整盘实际 I/O，MB/s；面板可见时每 2 秒更新。空间每 30 秒更新，多个卷的共享容量不累加。")
                .font(.caption2).foregroundStyle(.secondary)
            Text(ssd.status).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func liveTemperature(_ row: SSDReading) -> SSDTemperature? {
        if let snapshot = activity.snapshot, !snapshot.connected.contains(row.id) { return nil }
        return row.temperature.flatMap { $0.isFresh() ? $0 : nil }
    }
    private func volumes(_ id: String) -> [DiskVolumeSpace] { activity.snapshot?.volumes[id] ?? [] }
    private func bytes(_ number: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: number, countStyle: .decimal)
    }
    private func spaceSummary(_ id: String) -> String {
        let spaces = volumes(id)
        if spaces.count == 1, let space = spaces.first { return "可用 \(bytes(space.available)) / \(bytes(space.total))" }
        if spaces.count > 1 { return "\(spaces.count) 个卷 · 展开详情查看可用空间" }
        return "可用空间 — · 未挂载或暂不可读"
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
            Divider()
            Toggle("监控外接 NVMe SSD", isOn: $ssd.enabled)
            if ssd.enabled {
                Toggle("菜单栏附加 SSD 综合温度", isOn: $ssd.showInMenu)
                Text("多盘显示最高综合温度；各盘详情见面板。每轮结束后等待 30 秒，不保存历史。")
                    .font(.caption2).foregroundStyle(.secondary)
                Picker("设备类型", selection: $ssd.deviceType) {
                    ForEach(SMARTDeviceType.allCases) { Text($0 == .auto ? "自动识别（推荐）" : $0.rawValue).tag($0) }
                }
                HStack {
                    Button("选择 smartctl…") { ssd.chooseExecutable() }
                    Spacer()
                    Button("自动查找") { ssd.useDefaultPath() }
                }
                Text(ssd.executablePath.isEmpty ? "请先安装：brew install smartmontools" : ssd.executablePath)
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                Toggle("使用已配置的非交互 sudo", isOn: $ssd.useSudo).disabled(!ssd.canUseSudo)
                Text("默认以普通用户读取。需要权限时，可按文档为固定只读命令配置授权，再开启此项；不会弹出密码框。自选程序仅以普通用户运行。")
                    .font(.caption2).foregroundStyle(.secondary)
                Link("安装、权限与硬盘盒兼容说明", destination: URL(string: "https://github.com/wwwwzzzzkkkk/ChipBar/blob/main/docs/EXTERNAL_SSD.md")!)
                    .font(.caption)
                Button("重新检测 SSD") { ssd.restart() }
                Text("传感器编号由 SSD 提供，不能据此确定主控或闪存位置。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
