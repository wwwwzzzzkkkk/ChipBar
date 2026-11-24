import SwiftUI

struct LaptopPowerFallbackView: View {
    let reading: ChipBarPowerReading
    let chipWatts: Double?
    let active: Bool
    @Binding var detailsExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var batteryStatus: String {
        if !reading.onAdapter {
            return ChipBarLocale.choose("Battery supply", "电池供电")
        }
        if reading.isCharged {
            return ChipBarLocale.choose("Battery charged", "电池已充满")
        }
        if reading.isCharging {
            return ChipBarLocale.choose("Charging indicated by macOS",
                                        "macOS 显示正在充电")
        }
        return ChipBarLocale.choose("Battery not charging", "电池暂未充电")
    }

    private func format(_ watts: Double?) -> String {
        guard let watts, watts.isFinite else { return "—" }
        return String(format: "%.1f W", watts)
    }

    private func metric(_ title: String, value: Double?,
                        detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(format(value))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if let detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diagnosticDisclosure: some View {
        DisclosureGroup {
            let diag = reading.diagnostics
            VStack(alignment: .leading, spacing: 5) {
                Text("PDTR: \(format(diag.adapterPDTR))  ·  PSTR: \(format(diag.systemPSTR))")
                Text("PPBR: \(format(diag.batteryPPBR))  ·  B0AP: \(format(diag.batteryB0APMilliwatts.map { $0 / 1000 }))")
                Text("AppleSmartBattery: \(format(diag.registryBatteryWatts))")
                let current = diag.batteryCurrentB0AC.map {
                    String(format: "%.0f mA", $0)
                } ?? "—"
                let voltage = diag.batteryVoltageB0AV.map {
                    String(format: "%.0f mV", $0)
                } ?? "—"
                Text("B0AC: \(current)  ·  B0AV: \(voltage)")
                Text(ChipBarLocale.choose(
                    "System source: \(diag.systemSource ?? "unavailable"); battery source: \(diag.batterySource ?? "unavailable")",
                    "系统来源：\(diag.systemSource ?? "不可用")；电池来源：\(diag.batterySource ?? "不可用")"))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, 5)
        } label: {
            Label(ChipBarLocale.choose("Read-only sensor diagnostics",
                                       "查看传感器读数（只读）"),
                  systemImage: "waveform.path.ecg")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityHint(ChipBarLocale.choose(
            "Shows each sampled SMC sensor; unavailable is not zero.",
            "显示各 SMC 读数；不可用不等于零。"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "battery.100percent")
                    .foregroundStyle(.secondary)
                Text(batteryStatus)
                    .font(.system(size: 11, weight: .medium))
                if let percent = reading.batteryPercent {
                    Text("\(Int(percent.rounded()))%")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            // These figures are separate measurement boundaries. We must not
            // connect PDTR -> chip as a power flow with unknown battery watts.
            HStack(alignment: .top, spacing: 8) {
                metric(ChipBarLocale.choose("Adapter input", "适配器输入"),
                       value: reading.onAdapter ? reading.adapterWatts : nil,
                       detail: "SMC PDTR")
                metric(ChipBarLocale.choose("System power", "系统功率"),
                       value: reading.systemWatts,
                       detail: reading.diagnostics.systemSource)
                metric(ChipBarLocale.choose("Chip", "芯片"),
                       value: chipWatts, detail: "macmon")
            }

            if let flow = PowerFlowTopology(validatedSystemOf: reading, chipWatts: chipWatts) {
                ExpandablePowerSankeyFlow(flow: flow, active: active, detailsExpanded: $detailsExpanded)
                    .animation(active && !reduceMotion
                               ? .spring(response: 0.36, dampingFraction: 1) : nil, value: flow)
                Text(ChipBarLocale.choose(
                    "System-to-chip flow is independently valid.",
                    "已验证系统至芯片的功率分流。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Label(ChipBarLocale.choose(
                    "Independent readings only; insufficient consistent data for a flow diagram.",
                    "仅显示独立测量值；没有足够一致的数据连接功率流向。"),
                    systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
            }

            let reason: String = {
                if reading.batteryWatts == nil {
                    return ChipBarLocale.choose("No valid battery power sample; unknown is not 0 W.",
                                                "未取得有效电池功率读数；未知不代表 0 W。")
                }
                if reading.onAdapter && reading.adapterWatts == nil {
                    return ChipBarLocale.choose("Adapter input measurement is missing.",
                                                "缺少适配器输入功率读数。")
                }
                if reading.isCharging && (reading.batteryWatts ?? 0) <= 0.5 {
                    return ChipBarLocale.choose("Charging status and sampled battery power disagree.",
                                                "充电状态与电池功率读数暂不一致。")
                }
                return ChipBarLocale.choose("Independent samples do not yet support a consistent complete flow.",
                                            "独立采样值暂未满足完整功率流向的校验条件。")
            }()
            HStack(spacing: 6) {
                Text(ChipBarLocale.choose("Battery net power", "电池净功率"))
                Spacer(minLength: 0)
                Text(format(reading.batteryWatts)).monospacedDigit()
            }
            .font(.caption.weight(.medium))
            if reading.diagnostics.batterySource == "AppleSmartBattery (cached)" {
                Text(ChipBarLocale.choose("Battery sample may lag (macOS cache).", "macOS 电池缓存读数可能有延迟。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Label(reason, systemImage: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            diagnosticDisclosure
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
