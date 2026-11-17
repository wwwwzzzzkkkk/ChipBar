import SwiftUI

/// Strict read-only SMC/macmon power balance. Never render a fabricated branch
/// when sensor values are missing, contradictory, or stale.
struct LaptopPowerTopology: Equatable {
    let mode: PowerSourceMode
    let adapterWatts: Double?
    let batteryWatts: Double
    let systemWatts: Double
    let chipWatts: Double
    let otherWatts: Double
    let batteryPercent: Double?
    let batteryCharged: Bool
    let batteryIsCached: Bool

    var hasBatteryTransfer: Bool {
        // Only actual, validated charge or adapter-assist causes a 3-stage
        // layout. A zero-current battery would otherwise create a misleading
        // full-width adapter -> system ribbon and no battery branch.
        chargeWatts > 0.5 || assistWatts > 0.5
    }

    var chargeWatts: Double { mode == .adapterCharging ? batteryWatts : 0 }
    var assistWatts: Double { mode == .adapterAssisted ? -batteryWatts : 0 }
    var sourceWatts: Double { mode == .battery ? -batteryWatts : (adapterWatts ?? 0) }

    init?(reading: ChipBarPowerReading, chipWatts: Double?) {
        guard reading.hasBattery, reading.live,
              let system = reading.systemWatts, system.isFinite, system > 0,
              let chip = chipWatts, chip.isFinite, chip >= 0, chip <= system,
              let pack = reading.batteryWatts, pack.isFinite, abs(pack) < 500
        else { return nil }

        let mode = PowerSourceMode(reading: reading)
        let input: Double?
        let expectedSystem: Double
        if reading.onAdapter {
            guard let watts = reading.adapterWatts,
                  watts.isFinite, watts >= 0, watts < 500 else { return nil }
            input = watts
            expectedSystem = watts - pack
        } else {
            guard pack < -0.5 else { return nil }
            input = nil
            expectedSystem = -pack
        }
        guard expectedSystem > 0,
              abs(expectedSystem - system) <= max(0.25, system * 0.015)
        else { return nil }

        // Do not invent charging when IOPowerSources reports no charging.
        if mode == .adapter && (abs(pack) > 0.5 || reading.isCharging) { return nil }
        if mode == .adapterCharging && !(pack > 0.5) { return nil }
        if mode == .adapterAssisted && !(pack < -0.5) { return nil }

        self.mode = mode
        self.adapterWatts = input
        self.batteryWatts = pack
        self.systemWatts = system
        self.chipWatts = chip
        self.otherWatts = system - chip
        self.batteryPercent = reading.batteryPercent
        self.batteryCharged = reading.isCharged
        self.batteryIsCached = reading.diagnostics.batterySource == "AppleSmartBattery (cached)"
    }
}

/// Physical stages: adapter/battery -> system/charging -> chip/other.
/// One watt-to-point scale applies to the entire graph, including both
/// branches of charging and battery-assisted operation.
struct LaptopSankeyGeometry {
    static let height: CGFloat = 132
    static let gap: CGFloat = 12

    let scale: CGFloat
    let leftTop: CGFloat
    let inputHeight: CGFloat
    let assistTop: CGFloat
    let assistHeight: CGFloat
    let systemTop: CGFloat
    let systemHeight: CGFloat
    let chargeTop: CGFloat
    let chargeHeight: CGFloat
    let chipTop: CGFloat
    let chipHeight: CGFloat
    let otherTop: CGFloat
    let otherHeight: CGFloat

    static func make(_ flow: LaptopPowerTopology) -> LaptopSankeyGeometry {
        let largest = max(flow.sourceWatts + flow.assistWatts,
                          flow.systemWatts + flow.chargeWatts)
        // Deliberately slimmer than the desktop Sankey: wide pale ribbons
        // dominated the MacBook detail card and looked like a solid rectangle.
        let s = min(CGFloat(2.45), (height - 30 - gap) / CGFloat(max(largest, 1)))
        let inputH = CGFloat(flow.sourceWatts) * s
        let assistH = CGFloat(flow.assistWatts) * s
        let systemH = CGFloat(flow.systemWatts) * s
        let chargeH = CGFloat(flow.chargeWatts) * s
        let chipH = CGFloat(flow.chipWatts) * s
        let otherH = CGFloat(flow.otherWatts) * s
        let leftH = inputH + assistH + (assistH > 0 ? gap : 0)
        let middleH = systemH + chargeH + (chargeH > 0 ? gap : 0)
        let rightH = chipH + otherH + (chipH > 0 && otherH > 0 ? gap : 0)
        let lTop = (height - leftH) / 2
        let mTop = (height - middleH) / 2
        let rTop = (height - rightH) / 2
        return LaptopSankeyGeometry(
            scale: s,
            leftTop: lTop,
            inputHeight: inputH,
            assistTop: lTop + inputH + (assistH > 0 ? gap : 0),
            assistHeight: assistH,
            systemTop: mTop,
            systemHeight: systemH,
            chargeTop: mTop + systemH + (chargeH > 0 ? gap : 0),
            chargeHeight: chargeH,
            chipTop: rTop,
            chipHeight: chipH,
            otherTop: rTop + chipH + (chipH > 0 && otherH > 0 ? gap : 0),
            otherHeight: otherH
        )
    }
}

struct LaptopPowerSankeyFlow: View {
    let flow: LaptopPowerTopology
    let active: Bool

    private let primary = Color.primary

    private func watts(_ n: Double) -> String { String(format: "%.1f", n) }

    private var sourceName: String {
        flow.mode == .battery
            ? ChipBarLocale.choose("Battery power", "电池供电")
            : ChipBarLocale.choose("Adapter input", "适配器输入")
    }

    private var batteryStateTitle: String {
        switch flow.mode {
        case .adapterCharging:
            return ChipBarLocale.choose("Charging battery", "电池充电中")
        case .adapterAssisted:
            return ChipBarLocale.choose("Battery assisting", "电池辅助供电")
        case .adapter:
            return flow.batteryCharged
                ? ChipBarLocale.choose("Battery charged · 0 W", "电池已充满 · 0 W")
                : ChipBarLocale.choose("Battery not charging · 0 W", "电池暂未充电 · 0 W")
        case .battery:
            return ChipBarLocale.choose("Running on battery", "正在使用电池")
        case .desktop:
            return ChipBarLocale.choose("Desktop Mac", "台式 Mac")
        }
    }

    private var batteryCaption: String {
        if let percentage = flow.batteryPercent, percentage.isFinite {
            return " · \(Int(percentage.rounded()))%"
        }
        return ""
    }

    private var assistCaption: String? {
        flow.assistWatts > 0.5
            ? ChipBarLocale.choose("Battery assists " + watts(flow.assistWatts) + " W",
                                   "电池补能 " + watts(flow.assistWatts) + " W")
            : nil
    }

    private var chargeCaption: String? {
        flow.chargeWatts > 0.5
            ? ChipBarLocale.choose("Battery charging " + watts(flow.chargeWatts) + " W",
                                   "电池充电 " + watts(flow.chargeWatts) + " W")
            : nil
    }

    private func valueColumn(_ title: String, value: Double,
                             detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ChipBarLocale.localized(title))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(watts(value))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text("W")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ribbon(from x0: CGFloat, to x1: CGFloat,
                        at sourceY: CGFloat, to targetY: CGFloat,
                        height: CGFloat) -> Path {
        let mid = (x0 + x1) / 2
        return Path { p in
            p.move(to: CGPoint(x: x0, y: sourceY))
            p.addCurve(to: CGPoint(x: x1, y: targetY),
                       control1: CGPoint(x: mid, y: sourceY),
                       control2: CGPoint(x: mid, y: targetY))
            p.addLine(to: CGPoint(x: x1, y: targetY + height))
            p.addCurve(to: CGPoint(x: x0, y: sourceY + height),
                       control1: CGPoint(x: mid, y: targetY + height),
                       control2: CGPoint(x: mid, y: sourceY + height))
            p.closeSubpath()
        }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let g = LaptopSankeyGeometry.make(flow)
        let width: CGFloat = 6
        let left: CGFloat = 12
        let middle = size.width * 0.5 - 3
        let right = size.width - 18

        func band(x0: CGFloat, x1: CGFloat, from y0: CGFloat,
                  to y1: CGFloat, height: CGFloat, opacity: Double) {
            guard height > 0 else { return }
            let path = ribbon(from: x0, to: x1, at: y0, to: y1, height: height)
            context.fill(path, with: .linearGradient(
                Gradient(colors: [primary.opacity(opacity * 0.28),
                                  primary.opacity(opacity * 0.66)]),
                startPoint: CGPoint(x: x0, y: 0),
                endPoint: CGPoint(x: x1, y: 0)))
        }

        func rail(x: CGFloat, y: CGFloat, height: CGFloat, opacity: Double) {
            guard height > 0 else { return }
            let shape = Path(roundedRect: CGRect(x: x, y: y,
                                                width: width, height: height),
                             cornerRadius: 3)
            context.fill(shape, with: .color(primary.opacity(opacity)))
        }

        // Charge mode: adapter splits into system and battery charging.
        // Assist mode: adapter + battery merge into the system.
        if g.chargeHeight > 0 {
            band(x0: left + width, x1: middle,
                 from: g.leftTop, to: g.systemTop,
                 height: g.systemHeight, opacity: 0.65)
            band(x0: left + width, x1: middle,
                 from: g.leftTop + g.systemHeight, to: g.chargeTop,
                 height: g.chargeHeight, opacity: 0.30)
        } else if g.assistHeight > 0 {
            band(x0: left + width, x1: middle,
                 from: g.leftTop, to: g.systemTop,
                 height: g.inputHeight, opacity: 0.65)
            band(x0: left + width, x1: middle,
                 from: g.assistTop, to: g.systemTop + g.inputHeight,
                 height: g.assistHeight, opacity: 0.30)
        } else {
            band(x0: left + width, x1: middle,
                 from: g.leftTop, to: g.systemTop,
                 height: g.systemHeight, opacity: 0.65)
        }

        // Battery charging is NEVER included in chip/other system load.
        band(x0: middle + width, x1: right,
             from: g.systemTop, to: g.chipTop,
             height: g.chipHeight, opacity: 0.85)
        band(x0: middle + width, x1: right,
             from: g.systemTop + g.chipHeight, to: g.otherTop,
             height: g.otherHeight, opacity: 0.42)

        rail(x: left, y: g.leftTop, height: g.inputHeight, opacity: 0.68)
        rail(x: left, y: g.assistTop, height: g.assistHeight, opacity: 0.42)
        rail(x: middle, y: g.systemTop, height: g.systemHeight, opacity: 0.75)
        rail(x: middle, y: g.chargeTop, height: g.chargeHeight, opacity: 0.40)
        rail(x: right, y: g.chipTop, height: g.chipHeight, opacity: 0.95)
        rail(x: right, y: g.otherTop, height: g.otherHeight, opacity: 0.52)
    }

    private var statusRow: some View {
        HStack(spacing: 7) {
            Image(systemName: flow.mode == .battery ? "battery.75percent" :
                  flow.hasBatteryTransfer ? "battery.100percent.bolt" : "battery.100percent")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(batteryStateTitle + batteryCaption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if flow.mode == .adapter {
                Text(ChipBarLocale.choose("No charging flow", "无充电分流"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var compactFlow: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow
            // When pack current is 0 W, the real topology has only one
            // system input. Reuse the proven desktop two-branch drawing
            // instead of repeating identical adapter/system watt bars.
            PowerSankeyFlow(
                distribution: PowerDistribution(internalWatts: flow.systemWatts,
                                                chipWatts: flow.chipWatts),
                externalWatts: nil, sourceTitle: "", active: active,
                internalTitle: "系统功率")
        }
        .accessibilityElement(children: .contain)
    }

    private var splitFlow: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow
            HStack(alignment: .top, spacing: 8) {
                valueColumn(sourceName, value: flow.sourceWatts, detail: assistCaption)
                valueColumn(ChipBarLocale.choose("System power", "系统功率"),
                            value: flow.systemWatts, detail: chargeCaption)
                valueColumn(ChipBarLocale.choose("Chip", "芯片"),
                            value: flow.chipWatts)
            }
            .frame(height: 62, alignment: .top)

            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(context: context, size: size)
            }
            .frame(height: LaptopSankeyGeometry.height)
            .accessibilityHidden(true)
            .opacity(active ? 1 : 0.45)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if flow.chargeWatts > 0.5 {
                    Text(ChipBarLocale.choose(
                        "To battery " + watts(flow.chargeWatts) + " W",
                        "充入电池 " + watts(flow.chargeWatts) + " W"))
                } else if flow.assistWatts > 0.5 {
                    Text(ChipBarLocale.choose(
                        "From battery " + watts(flow.assistWatts) + " W",
                        "电池补能 " + watts(flow.assistWatts) + " W"))
                }
                Spacer(minLength: 5)
                Text(ChipBarLocale.choose(
                    "Other components " + watts(flow.otherWatts) + " W (est.)",
                    "其他部件 " + watts(flow.otherWatts) + " W（估算）"))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if flow.hasBatteryTransfer {
                splitFlow
            } else {
                compactFlow
            }
            Text(flow.batteryIsCached
                 ? ChipBarLocale.choose(
                    "Estimated flow from cached macOS battery telemetry; battery values may lag.",
                    "根据 macOS 电池缓存读数估算流向，电池数据可能有延迟。")
                 : ChipBarLocale.choose(
                    "System power is estimated from SMC input minus battery power; chip power comes from macmon.",
                    "系统功率根据 SMC 输入与电池净功率差估算；芯片功率来自 macmon。"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChipBarLocale.choose(
            "\(sourceName) \(watts(flow.sourceWatts)) W, system \(watts(flow.systemWatts)) W, battery charging \(watts(flow.chargeWatts)) W, battery assistance \(watts(flow.assistWatts)) W, chip \(watts(flow.chipWatts)) W, other components \(watts(flow.otherWatts)) W.",
            "\(sourceName) \(watts(flow.sourceWatts)) 瓦，系统 \(watts(flow.systemWatts)) 瓦，电池充电 \(watts(flow.chargeWatts)) 瓦，电池补能 \(watts(flow.assistWatts)) 瓦，芯片 \(watts(flow.chipWatts)) 瓦，其余部件 \(watts(flow.otherWatts)) 瓦。"))
    }
}
