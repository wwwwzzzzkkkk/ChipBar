import SwiftUI
import ChipBarCore

/// The Home card and the detail page share ExternalStorageCapacityModel.
/// Temperature comes from the existing disk-ID-aware SMART reader.
struct ExternalDiskDetailView: View {
    let volumeID: String
    @ObservedObject var ssd: ExternalSSDMonitor
    let close: () -> Void

    @StateObject private var storage = ExternalStorageCapacityModel.shared
    private let teal = Color(red: 0.22, green: 0.72, blue: 0.64)
    private let amber = Color(red: 0.93, green: 0.62, blue: 0.27)
    private let violet = Color(red: 0.68, green: 0.47, blue: 0.89)
    private let blue = Color(red: 0.28, green: 0.62, blue: 0.91)

    private var selection: ExternalVolumeCapacity? {
        storage.volumes.first { $0.id == volumeID }
    }
    private var diskID: String? { selection?.diskID }
    private var temperature: SSDReading? {
        guard let diskID, ssd.enabled else { return nil }
        return ssd.readings.first { $0.id == diskID }
    }
    private var rates: DiskRates? {
        guard let diskID, let snapshot = storage.activity,
              Date().timeIntervalSince(snapshot.date) <= 6,
              snapshot.external.contains(diskID),
              snapshot.connected.contains(diskID) else { return nil }
        return snapshot.rates[diskID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: close) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 29)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                }
                .accessibilityLabel("返回主页面")
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection?.volume.name ?? "外置硬盘")
                        .font(.headline)
                        .lineLimit(1)
                    Text("外接 NVMe SSD")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(teal)
                    .frame(width: 31, height: 31)
                    .background(teal.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9))
            }
            .frame(height: 42)

            if let selected = selection {
                capacityCard(selected.volume)
                HStack(spacing: 7) {
                    metricTile("温度", value: temperature?.temperature.flatMap {
                        $0.isFresh() ? $0.composite : nil
                    }.map { String(format: "%.0f", $0) } ?? "—",
                               unit: "°C", symbol: "thermometer.medium", color: amber)
                    metricTile("读取", value: (rates?.readMB).map {
                        String(format: "%.1f", $0)
                    } ?? "—", unit: "MB/s", symbol: "arrow.down", color: blue)
                    metricTile("写入", value: (rates?.writeMB).map {
                        String(format: "%.1f", $0)
                    } ?? "—", unit: "MB/s", symbol: "arrow.up", color: violet)
                }
                menuToggleCard(diskID: selected.diskID)
            } else {
                Text("磁盘已断开")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: storage.volumes.map(\.id)) { ids in
            if !ids.contains(volumeID) { close() }
        }
        .onAppear {
            if selection == nil { close() }
            else if !ssd.enabled { ssd.enabled = true }
        }
    }

    private func capacityCard(_ volume: DiskVolumeSpace) -> some View {
        let fraction = 1 - volume.availableFraction
        let values = spaceText(volume.available)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text(temperature?.temperature?.model ??
                     temperature?.name ?? "NVMe SSD")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(String(format: "已用 %.0f%%", fraction * 100))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(values.amount)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
                Text(values.unit + " 可用")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text("总计 \(formatBytes(volume.total))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule().fill(LinearGradient(colors: [teal.opacity(0.75), teal],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))
    }

    private func metricTile(_ label: String, value: String,
                            unit: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(label).foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .medium))
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
    }

    private func menuToggleCard(diskID: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("在菜单栏显示").font(.caption.weight(.semibold))
                Text("显示此磁盘的温度")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { ssd.showsTemperatureInMenu(for: diskID) },
                set: { ssd.setTemperatureInMenu($0, for: diskID) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("在菜单栏显示此磁盘温度")
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 13))
    }

    private func spaceText(_ bytes: Int64) -> (amount: String, unit: String) {
        let numeric = Double(bytes)
        if numeric >= 1_000_000_000_000 {
            return (String(format: "%.2f", numeric / 1_000_000_000_000), "TB")
        }
        if numeric >= 1_000_000_000 {
            return (String(format: "%.1f", numeric / 1_000_000_000), "GB")
        }
        return (String(format: "%.0f", numeric / 1_000_000), "MB")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let text = spaceText(bytes)
        return text.amount + " " + text.unit
    }
}
