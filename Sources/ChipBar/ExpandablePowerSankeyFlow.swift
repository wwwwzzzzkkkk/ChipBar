import SwiftUI

/// Strict read-only SMC/macmon power balance. Never render a fabricated branch
/// when sensor values are missing, contradictory, or stale.
struct PowerFlowTopology: Hashable {
    let mode: PowerSourceMode
    let adapterWatts: Double?
    let batteryWatts: Double
    let systemWatts: Double
    let chipWatts: Double
    let otherWatts: Double
    let batteryPercent: Double?
    let batteryCharged: Bool
    let batteryIsCached: Bool
    let hasBreakdown: Bool
    let showsSupply: Bool

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
        guard reading.live, let system = reading.systemWatts, system.isFinite, system > 0 else {
            return nil
        }
        let mode = PowerSourceMode(reading: reading)
        let validChip = chipWatts.flatMap { chip in
            chip.isFinite && chip >= 0 && chip <= system ? chip : nil
        }
        if mode == .desktop {
            self.init(systemWatts: system, chipWatts: validChip, mode: mode)
            return
        }
        guard let chip = validChip, let pack = reading.batteryWatts, pack.isFinite, abs(pack) < 500 else {
            return nil
        }

        let expectedSystem: Double
        if reading.onAdapter {
            guard let watts = reading.adapterWatts,
                  watts.isFinite, watts >= 0, watts < 500 else { return nil }
            expectedSystem = watts - pack
        } else {
            guard pack < -0.5 else { return nil }
            expectedSystem = -pack
        }
        guard expectedSystem > 0,
              abs(expectedSystem - system) <= max(0.25, system * 0.015)
        else { return nil }

        // Do not invent charging when IOPowerSources reports no charging.
        if mode == .adapter && (abs(pack) > 0.5 || reading.isCharging) { return nil }
        if mode == .adapterCharging && !(pack > 0.5) { return nil }
        if mode == .adapterAssisted && !(pack < -0.5) { return nil }

        self.init(systemWatts: system, chipWatts: chip, mode: mode, supply: reading)
    }

    // The laptop fallback can still draw the independently validated
    // system-to-chip side even when source or battery power is unknown.
    init?(validatedSystemOf reading: ChipBarPowerReading, chipWatts: Double?) {
        let distribution = PowerDistribution(internalWatts: reading.systemWatts, chipWatts: chipWatts)
        guard let system = reading.systemWatts, distribution.otherWatts != nil else { return nil }
        self.init(systemWatts: system, chipWatts: chipWatts, mode: PowerSourceMode(reading: reading))
    }

    private init(systemWatts: Double, chipWatts: Double?, mode: PowerSourceMode,
                 supply: ChipBarPowerReading? = nil) {
        self.mode = mode
        self.adapterWatts = supply.flatMap { $0.onAdapter ? $0.adapterWatts : nil }
        self.batteryWatts = supply?.batteryWatts ?? 0
        self.systemWatts = systemWatts
        self.chipWatts = chipWatts ?? 0
        self.otherWatts = chipWatts.map { systemWatts - $0 } ?? 0
        self.batteryPercent = supply?.batteryPercent
        self.batteryCharged = supply?.isCharged ?? false
        self.batteryIsCached = supply?.diagnostics.batterySource == "AppleSmartBattery (cached)"
        self.hasBreakdown = chipWatts != nil
        self.showsSupply = supply != nil
    }
}

/// Visual tuning in SwiftUI points. Colors are uncomposited sRGB endpoints.
private enum LaptopFlowStyle {
    static let pointsPerWatt: CGFloat = 3.7
    static let mergeEnd: CGFloat = 0.80
    static let splitStart: CGFloat = 0.20
    private static let nodeRadius: CGFloat = 13
    static let nodeGap: CGFloat = 5
    static let inputStartColor = Color(red: 0.40, green: 0.36, blue: 0.28)
    static let inputEndColor = Color(red: 0.38, green: 0.43, blue: 0.61)
    static let outputStartColor = Color(red: 0.34, green: 0.39, blue: 0.52)
    static let outputEndColor = Color(red: 0.30, green: 0.31, blue: 0.33)
    static let gradientOpacity = 0.64
    static let disclosure = Animation.easeInOut(duration: 0.32)
    static let crossfade = Animation.easeInOut(duration: 0.18)
    static let mergeMidpoint = centerlineMidpoint(start: 0, end: mergeEnd)
    static let splitMidpoint = centerlineMidpoint(start: splitStart, end: 1)

    static func cornerRadius(width: CGFloat, height: CGFloat) -> CGFloat {
        min(nodeRadius, width / 2, height / 2)
    }

    private static func centerlineMidpoint(start: CGFloat, end: CGFloat) -> CGFloat {
        let target = (0.5 - start) / (end - start)
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<12 {
            let t = (lower + upper) / 2
            // Horizontal Bézier control points are at half the curved span.
            let x = t * (1.5 + t * (t - 1.5))
            if x < target { lower = t }
            else { upper = t }
        }
        let t = (lower + upper) / 2
        return t * t * (3 - 2 * t)
    }
}

/// Physical stages: adapter/battery -> system/charging -> chip/other.
/// A shared scale sets each junction's total width. A minimum visual width
/// keeps small nonzero branches legible without changing their watt labels.
struct LaptopSankeyGeometry {
    static let height: CGFloat = 224
    static let labelInset: CGFloat = 23
    static let gap: CGFloat = 12
    static let minimumRibbonHeight: CGFloat = 22

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

    static func make(_ flow: PowerFlowTopology) -> LaptopSankeyGeometry {
        make(systemWatts: flow.systemWatts, chargeWatts: flow.chargeWatts,
             assistWatts: flow.assistWatts, chipWatts: flow.chipWatts)
    }

    static func make(systemWatts: Double, chargeWatts: Double,
                     assistWatts: Double, chipWatts: Double) -> LaptopSankeyGeometry {
        let leadingWatts = max(0, systemWatts + chargeWatts - assistWatts)
        let otherWatts = max(0, systemWatts - chipWatts)
        let grossWatts = systemWatts + chargeWatts
        let capacity = height - labelInset * 2 - gap
        let s = min(LaptopFlowStyle.pointsPerWatt, capacity / CGFloat(max(grossWatts, 1)))
        let chipMinimum = chipWatts > 0 ? minimumRibbonHeight : 0
        let otherMinimum = otherWatts > 0 ? minimumRibbonHeight : 0
        let systemMinimum = chipMinimum + otherMinimum
        let chargeMinimum = chargeWatts > 0 ? minimumRibbonHeight : 0
        let inputMinimum = leadingWatts > 0 ? minimumRibbonHeight : 0
        let assistMinimum = assistWatts > 0 ? minimumRibbonHeight : 0

        let total = max(CGFloat(grossWatts) * s, systemMinimum + chargeMinimum, inputMinimum + assistMinimum)
        // Borrow display width from the adjacent branch at each junction.
        // The two children always add up to the width of their parent.
        let systemH = chargeWatts > 0
            ? min(max(CGFloat(systemWatts) * s, systemMinimum), total - chargeMinimum) : total
        let chargeH = total - systemH
        let inputH = assistWatts > 0
            ? (leadingWatts > 0 ? min(max(CGFloat(leadingWatts) * s, inputMinimum), total - assistMinimum) : 0)
            : total
        let assistH = total - inputH
        let chipH = otherWatts > 0
            ? min(max(CGFloat(chipWatts) * s, chipMinimum), systemH - otherMinimum) : systemH
        let otherH = systemH - chipH
        // Place the merged flow between the two input lanes. The inlet and
        // outlet remain aligned while disclosure only extends the right side.
        let top = labelInset
        let inputGap = inputH > 0 && assistH > 0 ? gap : 0
        let systemTop = top + inputGap / 2
        // Open the outlet gap equally above and below the system split.
        let outputGap = chipH > 0 && otherH > 0 ? gap : 0
        let rightTop = systemTop - outputGap / 2
        return LaptopSankeyGeometry(
            scale: s,
            leftTop: top + assistH + inputGap,
            inputHeight: inputH,
            assistTop: top,
            assistHeight: assistH,
            systemTop: systemTop,
            systemHeight: systemH,
            chargeTop: systemTop + systemH + (chargeH > 0 ? gap : 0),
            chargeHeight: chargeH,
            chipTop: rightTop,
            chipHeight: chipH,
            otherTop: rightTop + chipH + outputGap,
            otherHeight: otherH
        )
    }
}

struct ExpandablePowerSankeyFlow: View, Animatable {
    typealias ChartWatts = AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>
    let flow: PowerFlowTopology
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Binding var detailsExpanded: Bool
    var animatableData: ChartWatts

    init(flow: PowerFlowTopology, active: Bool, detailsExpanded: Binding<Bool>) {
        self.flow = flow
        self.active = active
        _detailsExpanded = detailsExpanded
        animatableData = ChartWatts(
            AnimatablePair(flow.systemWatts, flow.chargeWatts),
            AnimatablePair(flow.assistWatts, flow.chipWatts))
    }

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

    /// The two wide lanes adapt with the sidecar without changing node order.
    private struct Columns {
        let source: CGFloat
        let inlet: CGFloat
        let merge: CGFloat
        let system: CGFloat
        let split: CGFloat
        let outlet: CGFloat
        let destination: CGFloat
        let endpointWidth: CGFloat
        let systemWidth: CGFloat

        init(width: CGFloat, hasInputs: Bool) {
            let gap = min(LaptopFlowStyle.nodeGap, width * 0.015)
            endpointWidth = width * 0.132
            systemWidth = width * (hasInputs ? 0.18 : 0.28)
            source = endpointWidth / 2
            inlet = endpointWidth + gap
            system = hasInputs ? width / 2 : systemWidth / 2
            merge = system - systemWidth / 2 - gap
            split = system + systemWidth / 2 + gap
            outlet = width - inlet
            destination = width - source
        }
    }

    private func wattLabel(_ value: Double, size: CGFloat = 15) -> some View {
        Text(watts(value) + " W")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.65)
    }

    private func endpoint(_ title: String, symbol: String, height: CGFloat, width: CGFloat,
                          inputTotal: Double? = nil) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: height < 32 ? 11 : 15, weight: .medium))
            if let inputTotal {
                wattLabel(inputTotal, size: 9)
                    .accessibilityLabel(title + ", " + watts(inputTotal) + " W")
            } else if height >= 48 {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: width, height: height)
        .background {
            Color.clear
                .glassTile(radius: LaptopFlowStyle.cornerRadius(width: width, height: height))
                .allowsHitTesting(false)
        }
        .accessibilityHidden(inputTotal == nil)
    }

    private func systemCard(_ value: Double, height: CGFloat, width: CGFloat) -> some View {
        let title = flow.mode == .desktop
            ? ChipBarLocale.choose("Internal power", "内部功率")
            : ChipBarLocale.choose("System power", "系统功率")
        let radius = LaptopFlowStyle.cornerRadius(width: width, height: height)
        let action = !flow.hasBreakdown
            ? ChipBarLocale.choose("Waiting for a valid chip reading", "等待有效的芯片功率读数")
            : detailsExpanded ? ChipBarLocale.choose("Hide system breakdown", "收起系统用电明细")
                                     : ChipBarLocale.choose("Show system breakdown", "展开系统用电明细")
        return Button {
            detailsExpanded.toggle()
        } label: {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 4) {
                    Image(systemName: flow.mode == .desktop ? "desktopcomputer" : "laptopcomputer")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(title)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    wattLabel(value, size: 13).foregroundStyle(.secondary)
                    disclosureIndicator(size: 8)
                }
                HStack(spacing: 3) {
                    if flow.mode == .desktop {
                        Text(title)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                    wattLabel(value, size: 11)
                    disclosureIndicator(size: 7)
                }
            }
            .padding(.horizontal, 4)
            .frame(width: width, height: height)
            .background {
                Color.clear
                    .glassTile(radius: radius)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect(cornerRadius: radius))
        }
        .buttonStyle(.plain)
        .disabled(!flow.hasBreakdown)
        .help(action)
        .accessibilityLabel(title + ", " + watts(value) + " W")
        .accessibilityHint(action)
    }

    private func disclosureIndicator(size: CGFloat) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: size, weight: .semibold))
            .rotationEffect(.degrees(detailsExpanded ? 90 : 0))
            .opacity(flow.hasBreakdown ? 1 : 0)
    }

    private enum RibbonEdge { case top, bottom }

    private func ribbon(from x0: CGFloat, to x1: CGFloat, at y0: CGFloat, to y1: CGFloat,
                        height: CGFloat, start: CGFloat, end: CGFloat,
                        joinedAtStart: RibbonEdge? = nil, joinedAtEnd: RibbonEdge? = nil) -> Path {
        let span = x1 - x0
        let radius = LaptopFlowStyle.cornerRadius(width: span, height: height)
        let topLeft = joinedAtStart == .top ? 0 : radius
        let topRight = joinedAtEnd == .top ? 0 : radius
        let bottomLeft = joinedAtStart == .bottom ? 0 : radius
        let bottomRight = joinedAtEnd == .bottom ? 0 : radius
        let bottom0 = y0 + height
        let bottom1 = y1 + height

        // Use the same Bézier span on both edges so the band keeps its thickness.
        let first = max(x0 + max(topLeft, bottomLeft), x0 + span * start)
        let last = min(x1 - max(topRight, bottomRight), x0 + span * end)
        let middle = (first + last) / 2

        return Path { path in
            path.move(to: CGPoint(x: x0 + topLeft, y: y0))
            path.addLine(to: CGPoint(x: first, y: y0))
            path.addCurve(to: CGPoint(x: last, y: y1),
                          control1: CGPoint(x: middle, y: y0), control2: CGPoint(x: middle, y: y1))
            path.addLine(to: CGPoint(x: x1 - topRight, y: y1))
            path.addQuadCurve(to: CGPoint(x: x1, y: y1 + topRight), control: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x1, y: bottom1 - bottomRight))
            path.addQuadCurve(to: CGPoint(x: x1 - bottomRight, y: bottom1), control: CGPoint(x: x1, y: bottom1))
            path.addLine(to: CGPoint(x: last, y: bottom1))
            path.addCurve(to: CGPoint(x: first, y: bottom0),
                          control1: CGPoint(x: middle, y: bottom1), control2: CGPoint(x: middle, y: bottom0))
            path.addLine(to: CGPoint(x: x0 + bottomLeft, y: bottom0))
            path.addQuadCurve(to: CGPoint(x: x0, y: bottom0 - bottomLeft), control: CGPoint(x: x0, y: bottom0))
            path.addLine(to: CGPoint(x: x0, y: y0 + topLeft))
            path.addQuadCurve(to: CGPoint(x: x0 + topLeft, y: y0), control: CGPoint(x: x0, y: y0))
            path.closeSubpath()
        }
    }

    private func glassRibbons(_ shape: LaptopPowerGlassShape, from: Color, to: Color,
                              x0: CGFloat, x1: CGFloat, width: CGFloat) -> some View {
        let opacity = colorScheme == .dark ? LaptopFlowStyle.gradientOpacity : LaptopFlowStyle.gradientOpacity * 0.60
        let gradient = LinearGradient(colors: [from.opacity(opacity), to.opacity(opacity)],
            startPoint: UnitPoint(x: x0 / max(width, 1), y: 0.5),
            endPoint: UnitPoint(x: x1 / max(width, 1), y: 0.5))
        return Group {
            if #available(macOS 26.0, *) {
                shape.fill(gradient).glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
                    .overlay { shape.fill(gradient) }
                    .overlay { shape.stroke(.primary.opacity(0.14), lineWidth: 0.6) }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    var statusLabel: some View {
        Text(batteryStateTitle + batteryCaption)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private var flowGraph: some View {
        GeometryReader { proxy in
            let system = animatableData.first.first
            let charge = animatableData.first.second
            let assist = animatableData.second.first
            let chip = animatableData.second.second
            let geometry = LaptopSankeyGeometry.make(
                systemWatts: system, chargeWatts: charge, assistWatts: assist, chipWatts: chip)
            let hasInputs = flow.showsSupply
            let showDetails = flow.hasBreakdown && detailsExpanded
            let columns = Columns(width: proxy.size.width, hasInputs: hasInputs)
            let inputX = (columns.inlet + columns.merge) / 2
            let outputX = (columns.split + columns.outlet) / 2
            let inputBottom = geometry.leftTop + geometry.systemHeight
            let inputTarget = geometry.systemTop + geometry.assistHeight
            let inputY = geometry.leftTop + geometry.inputHeight / 2
            let systemY = geometry.systemTop + geometry.systemHeight / 2
            let chargeY = geometry.chargeTop + geometry.chargeHeight / 2
            let assistY = geometry.assistTop + geometry.assistHeight / 2
            let outputBoundary = geometry.systemTop + geometry.chipHeight

            let supply = hasInputs
                ? supplyPaths(geometry, columns: columns, inputBottom: inputBottom, inputTarget: inputTarget)
                : Path()
            let outputs = flow.hasBreakdown ? outputPaths(geometry, columns: columns, boundary: outputBoundary) : Path()
            let sourceSymbol = flow.mode == .battery ? "battery.75percent" : "powerplug"
            let batteryTitle = ChipBarLocale.choose("Battery", "电池")
            let chipTitle = ChipBarLocale.choose("Chip", "芯片")
            let otherTitle = flow.mode == .desktop ? ChipBarLocale.choose("Other", "其余部件")
                                                   : ChipBarLocale.choose("Other", "其他")

            if hasInputs {
                glassRibbons(LaptopPowerGlassShape(ribbons: supply, anchor: columns.merge, expansion: 1),
                             from: LaptopFlowStyle.inputStartColor, to: LaptopFlowStyle.inputEndColor,
                             x0: columns.inlet, x1: columns.merge, width: proxy.size.width)
            }

            glassRibbons(LaptopPowerGlassShape(ribbons: outputs, anchor: columns.split,
                                              expansion: showDetails || reduceMotion ? 1 : 0),
                         from: LaptopFlowStyle.outputStartColor, to: LaptopFlowStyle.outputEndColor,
                         x0: columns.split, x1: columns.outlet, width: proxy.size.width)
                .opacity(showDetails || !reduceMotion ? 1 : 0)
                .animation(reduceMotion ? LaptopFlowStyle.crossfade : LaptopFlowStyle.disclosure,
                           value: showDetails)

            if geometry.assistHeight > 0 {
                endpoint(batteryTitle, symbol: "battery.75percent",
                         height: geometry.assistHeight, width: columns.endpointWidth)
                    .position(x: columns.source, y: assistY)
                wattLabel(assist)
                    .accessibilityLabel(batteryTitle + ", " + watts(assist) + " W")
                    .position(x: inputX, y: assistY + (geometry.systemTop - geometry.assistTop) * LaptopFlowStyle.mergeMidpoint)
            }
            if hasInputs && geometry.inputHeight > 0 {
                endpoint(sourceName, symbol: sourceSymbol, height: geometry.inputHeight,
                         width: columns.endpointWidth, inputTotal: charge > 0 ? system + charge : nil)
                    .position(x: columns.source, y: inputY)
                if geometry.chargeHeight == 0 {
                    let value = max(0, system - assist)
                    wattLabel(value)
                        .accessibilityLabel(sourceName + ", " + watts(value) + " W")
                        .position(x: inputX, y: inputY + (inputTarget - geometry.leftTop) * LaptopFlowStyle.mergeMidpoint)
                }
            }

            systemCard(system, height: geometry.systemHeight, width: columns.systemWidth)
                .position(x: columns.system, y: systemY)
            if geometry.chargeHeight > 0 {
                wattLabel(system)
                    .accessibilityLabel(ChipBarLocale.choose("System power", "系统功率") + ", " + watts(system) + " W")
                    .position(x: inputX, y: geometry.leftTop + geometry.systemHeight / 2
                              + (geometry.systemTop - geometry.leftTop) * LaptopFlowStyle.splitMidpoint)
                wattLabel(charge)
                    .accessibilityLabel(ChipBarLocale.choose("Battery charging", "电池充电") + ", " + watts(charge) + " W")
                    .position(x: inputX, y: inputBottom + geometry.chargeHeight / 2
                              + (geometry.chargeTop - inputBottom) * LaptopFlowStyle.splitMidpoint)
                endpoint(ChipBarLocale.choose("Charging", "充电"), symbol: "battery.100percent.bolt",
                         height: geometry.chargeHeight, width: columns.systemWidth)
                    .position(x: columns.system, y: chargeY)
            }

            Group {
                if geometry.chipHeight > 0 {
                    endpoint(chipTitle, symbol: "cpu", height: geometry.chipHeight, width: columns.endpointWidth)
                        .position(x: columns.destination, y: geometry.chipTop + geometry.chipHeight / 2)
                    wattLabel(chip)
                        .accessibilityLabel(chipTitle + ", " + watts(chip) + " W")
                        .position(x: outputX, y: geometry.systemTop + geometry.chipHeight / 2
                                  + (geometry.chipTop - geometry.systemTop) * LaptopFlowStyle.splitMidpoint)
                }
                if geometry.otherHeight > 0 {
                    endpoint(otherTitle, symbol: "ellipsis", height: geometry.otherHeight, width: columns.endpointWidth)
                        .position(x: columns.destination, y: geometry.otherTop + geometry.otherHeight / 2)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        wattLabel(max(0, system - chip))
                        if flow.mode == .desktop {
                            Text(ChipBarLocale.choose("est.", "估算"))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ChipBarLocale.choose("Other components, estimated", "其余部件，估算")
                                        + ", " + watts(max(0, system - chip)) + " W")
                        .position(x: outputX, y: outputBoundary + geometry.otherHeight / 2
                                  + (geometry.otherTop - outputBoundary) * LaptopFlowStyle.splitMidpoint)
                }
            }
            .opacity(showDetails ? 1 : 0)
            .animation(reduceMotion ? LaptopFlowStyle.crossfade
                       : .easeOut(duration: 0.16).delay(showDetails ? 0.16 : 0),
                       value: showDetails)
            .accessibilityHidden(!showDetails)
            .allowsHitTesting(false)
        }
        .frame(height: LaptopSankeyGeometry.height)
    }

    private func supplyPaths(_ g: LaptopSankeyGeometry, columns: Columns,
                             inputBottom: CGFloat, inputTarget: CGFloat) -> Path {
        var result = Path()
        let charging = g.chargeHeight > 0
        if g.inputHeight > 0 {
            result.addPath(ribbon(from: columns.inlet, to: columns.merge, at: g.leftTop,
                to: inputTarget, height: charging ? g.systemHeight : g.inputHeight,
                start: charging ? LaptopFlowStyle.splitStart : 0,
                end: charging ? 1 : LaptopFlowStyle.mergeEnd,
                joinedAtStart: charging ? .bottom : nil,
                joinedAtEnd: g.assistHeight > 0 ? .top : nil))
        }
        if charging {
            result.addPath(ribbon(from: columns.inlet, to: columns.merge, at: inputBottom,
                to: g.chargeTop, height: g.chargeHeight, start: LaptopFlowStyle.splitStart, end: 1,
                joinedAtStart: .top))
        } else if g.assistHeight > 0 {
            result.addPath(ribbon(from: columns.inlet, to: columns.merge, at: g.assistTop,
                to: g.systemTop, height: g.assistHeight, start: 0, end: LaptopFlowStyle.mergeEnd,
                joinedAtEnd: g.inputHeight > 0 ? .bottom : nil))
        }
        return result
    }

    private func outputPaths(_ g: LaptopSankeyGeometry, columns: Columns, boundary: CGFloat) -> Path {
        var result = Path()
        if g.chipHeight > 0 {
            result.addPath(ribbon(from: columns.split, to: columns.outlet, at: g.systemTop,
                to: g.chipTop, height: g.chipHeight, start: LaptopFlowStyle.splitStart, end: 1,
                joinedAtStart: g.otherHeight > 0 ? .bottom : nil))
        }
        if g.otherHeight > 0 {
            result.addPath(ribbon(from: columns.split, to: columns.outlet, at: boundary,
                to: g.otherTop, height: g.otherHeight, start: LaptopFlowStyle.splitStart, end: 1,
                joinedAtStart: g.chipHeight > 0 ? .top : nil))
        }
        return result
    }

    var body: some View {
        Group {
            if active && reduceMotion {
                flowGraph
                    .id(flow)
                    .transition(.opacity)
            } else {
                flowGraph
            }
        }
        .animation(active && reduceMotion ? LaptopFlowStyle.crossfade : nil, value: reduceMotion ? flow : nil)
        .accessibilityElement(children: .contain)
    }
}

private struct LaptopPowerGlassShape: Shape {
    let ribbons: Path
    let anchor: CGFloat
    var expansion: CGFloat

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard expansion > 0 else { return Path() }
        let path = ribbons.applying(CGAffineTransform(
            a: expansion, b: 0, c: 0, d: 1, tx: anchor * (1 - expansion), ty: 0))
        if #available(macOS 26.0, *) {
            return path.normalized(eoFill: false)
        }
        return path
    }
}
