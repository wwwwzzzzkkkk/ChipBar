import SwiftUI

/// A MacBook does not stop reporting power just because a particular SMC
/// battery key is absent or momentarily out of step with its chip sample.
/// Only draw a conservation Sankey when both domains are *individually* valid.
enum LaptopPowerPresentation: Equatable {
    case complete
    case systemAndChip
    case independent
    case unavailable

    init(reading: ChipBarPowerReading, chipWatts: Double?) {
        if LaptopPowerTopology(reading: reading, chipWatts: chipWatts) != nil {
            self = .complete
        } else if PowerDistribution(internalWatts: reading.systemWatts,
                                    chipWatts: chipWatts).otherWatts != nil {
            self = .systemAndChip
        } else if reading.adapterWatts != nil || reading.systemWatts != nil
                    || reading.batteryWatts != nil || chipWatts != nil {
            self = .independent
        } else {
            self = .unavailable
        }
    }
}

struct LaptopPowerFallbackView: View {
    let reading: ChipBarPowerReading
    let chipWatts: Double?
    let active: Bool

    private var mode: LaptopPowerPresentation {
        LaptopPowerPresentation(reading: reading, chipWatts: chipWatts)
    }

    private var distribution: PowerDistribution {
        PowerDistribution(internalWatts: reading.systemWatts,
                          chipWatts: chipWatts)
    }

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
                Text("PPBR: \(format(diag.batteryPPBR))")
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

            if mode == .systemAndChip {
                // When PSTR and macmon agree sufficiently to form a valid
                // system subtotal, only that *validated* section gets ribbons.
                PowerSankeyFlow(
                    distribution: distribution,
                    externalWatts: nil,
                    sourceTitle: "",
                    active: active,
                    internalTitle: "系统功率")
                Text(ChipBarLocale.choose(
                    "System-to-chip split only; adapter-to-battery flow unavailable.",
                    "仅显示系统至芯片的分流；适配器与电池之间的流向暂不可用。"))
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

            if reading.batteryWatts == nil {
                Label(ChipBarLocale.choose(
                    "Battery charge/discharge watts unavailable. This does not imply 0 W.",
                    "电池充放电功率暂无读数，不代表电池功率为 0 W。"),
                    systemImage: "battery.100percent")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if mode != .complete {
                Label(ChipBarLocale.choose(
                    "Power-source samples are not consistent enough for a battery flow.",
                    "电源分项读数暂不一致，因此没有绘制电池分流。"),
                    systemImage: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            diagnosticDisclosure
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
