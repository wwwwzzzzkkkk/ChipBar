import SwiftUI
import ChipBarCore

struct SSDSection: View {
    @ObservedObject var ssd: ExternalSSDMonitor
    var body: some View {
        if ssd.enabled {
            VStack(alignment: .leading, spacing: 8) {
                Label("外接 NVMe SSD", systemImage: "externaldrive").font(.subheadline.weight(.medium))
                ForEach(ssd.readings) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.temperature?.model ?? row.name).lineLimit(1)
                            Spacer()
                            Text(row.temperature.flatMap { $0.isFresh() ? $0.composite : nil }
                                .map { String(format: "%.0f °C", $0) } ?? "—")
                                .monospacedDigit().fontWeight(.medium)
                        }.font(.caption)
                        if let reading = row.temperature, reading.isFresh() {
                            Text("综合温度 · \(row.id)").font(.caption2).foregroundStyle(.secondary)
                            let sensors = reading.sensors.enumerated().compactMap { index, value in
                                value.map { String(format: "传感器 %d：%.0f°C", index + 1, $0) }
                            }
                            if !sensors.isEmpty { Text(sensors.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
                            Text(health(reading)).font(.caption2)
                                .foregroundStyle(reading.passed == false || (reading.criticalWarning ?? 0) != 0 ? Color.orange : Color.secondary)
                            Text("更新于 \(reading.date.formatted(date: .omitted, time: .standard))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let error = row.error { Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                Text(ssd.status).font(.caption2).foregroundStyle(.secondary)
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
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
            Toggle("读取外接 NVMe SSD 温度", isOn: $ssd.enabled)
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
