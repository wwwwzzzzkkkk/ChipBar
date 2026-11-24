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
    private static let verticalInset: CGFloat = 12
    private static let maximumRibbonHeight: CGFloat = 166
    static let gap: CGFloat = 12
    static let maximumHeight = maximumRibbonHeight + gap + 2 * verticalInset
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

    func contentHeight(showsSupply: Bool, showsBreakdown: Bool) -> CGFloat {
        var bottom = systemTop + systemHeight
        if showsSupply {
            bottom = max(bottom, leftTop + inputHeight, assistTop + assistHeight, chargeTop + chargeHeight)
        }
        if showsBreakdown {
            bottom = max(bottom, chipTop + chipHeight, otherTop + otherHeight)
        }
        return bottom + Self.verticalInset
    }

    static func make(_ flow: PowerFlowTopology) -> LaptopSankeyGeometry {
        make(systemWatts: flow.systemWatts, chargeWatts: flow.chargeWatts,
             assistWatts: flow.assistWatts, chipWatts: flow.chipWatts)
    }

    static func make(systemWatts: Double, chargeWatts: Double,
                     assistWatts: Double, chipWatts: Double,
                     chargePresence: CGFloat = 1, assistPresence: CGFloat = 1) -> LaptopSankeyGeometry {
        let leadingWatts = max(0, systemWatts + chargeWatts - assistWatts)
        let otherWatts = max(0, systemWatts - chipWatts)
        let grossWatts = systemWatts + chargeWatts
        let s = min(LaptopFlowStyle.pointsPerWatt, maximumRibbonHeight / CGFloat(max(grossWatts, 1)))
        let chipMinimum = chipWatts > 0 ? minimumRibbonHeight : 0
        let otherMinimum = otherWatts > 0 ? minimumRibbonHeight : 0
        let systemMinimum = chipMinimum + otherMinimum
        let chargeMinimum = chargeWatts > 0 ? minimumRibbonHeight * chargePresence : 0
        let inputMinimum = leadingWatts > 0 ? minimumRibbonHeight : 0
        let assistMinimum = assistWatts > 0 ? minimumRibbonHeight * assistPresence : 0

        let total = max(CGFloat(grossWatts) * s, systemMinimum + chargeMinimum, inputMinimum + assistMinimum)
        // Borrow display width from the adjacent branch at each junction.
        // The two children always add up to the width of their parent.
        let systemH = chargeWatts > 0
            ? min(max(CGFloat(systemWatts) * s, systemMinimum), total - chargeMinimum) : total
        let chargeH = total - systemH
        let inputH = assistWatts > 0
            ? max(chargeH, leadingWatts > 0
                    ? min(max(CGFloat(leadingWatts) * s, inputMinimum), total - assistMinimum) : 0)
            : total
        let assistH = total - inputH
        let chipH = otherWatts > 0
            ? min(max(CGFloat(chipWatts) * s, chipMinimum), systemH - otherMinimum) : systemH
        let otherH = systemH - chipH
        // Place the merged flow between the two input lanes.
        let top = verticalInset
        let inputGap = inputH > 0 && assistH > 0 ? gap * assistPresence : 0
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
            chargeTop: systemTop + systemH + (chargeH > 0 ? gap * chargePresence : 0),
            chargeHeight: chargeH,
            chipTop: rightTop,
            chipHeight: chipH,
            otherTop: rightTop + chipH + outputGap,
            otherHeight: otherH
        )
    }
}

struct PowerSankeyDiagram: View, Animatable {
    static let inputSpring = Animation.spring(response: 0.52, dampingFraction: 1)

    typealias Pair = AnimatablePair<Double, Double>
    typealias ChartWatts = AnimatablePair<AnimatablePair<Pair, Pair>, AnimatablePair<Pair, Double>>
    let flow: PowerFlowTopology
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var animatableData: ChartWatts

    init(flow: PowerFlowTopology, active: Bool) {
        self.flow = flow
        self.active = active
        animatableData = ChartWatts(
            AnimatablePair(Pair(flow.systemWatts, flow.chargeWatts), Pair(flow.assistWatts, flow.chipWatts)),
            AnimatablePair(Pair(flow.chargeWatts > 0 ? 1 : 0, flow.assistWatts > 0 ? 1 : 0),
                           flow.showsSupply ? 1 : 0))
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

        init(width: CGFloat, supplyPresence: CGFloat) {
            let gap = min(LaptopFlowStyle.nodeGap, width * 0.015)
            endpointWidth = width * 0.132
            systemWidth = width * (0.28 - 0.10 * supplyPresence)
            source = endpointWidth / 2
            inlet = endpointWidth + gap
            system = systemWidth / 2 + (width - systemWidth) / 2 * supplyPresence
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
                .contentTransition(.opacity)
                .font(.system(size: height < 32 ? 11 : 15, weight: .medium))
            if let inputTotal {
                wattLabel(inputTotal, size: 9)
                    .accessibilityLabel(title + ", " + watts(inputTotal) + " W")
                    .transition(.opacity)
            } else if height >= 48 {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .transition(.opacity)
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
        return ViewThatFits(in: .vertical) {
            VStack(spacing: 4) {
                Image(systemName: flow.mode == .desktop ? "desktopcomputer" : "laptopcomputer")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                wattLabel(value, size: 13).foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                if flow.mode == .desktop {
                    Text(title)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                wattLabel(value, size: 11)
            }
        }
        .padding(.horizontal, 4)
        .frame(width: width, height: height)
        .background {
            Color.clear
                .glassTile(radius: LaptopFlowStyle.cornerRadius(width: width, height: height))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ", " + watts(value) + " W")
    }

    private enum RibbonEdge { case top, bottom }

    private func ribbon(from x0: CGFloat, to x1: CGFloat, at y0: CGFloat, to y1: CGFloat,
                        height: CGFloat, start: CGFloat, end: CGFloat,
                        joinedAtStart: RibbonEdge? = nil, joinedAtEnd: RibbonEdge? = nil,
                        startJoin: CGFloat = 1, endJoin: CGFloat = 1) -> Path {
        let span = x1 - x0
        let radius = LaptopFlowStyle.cornerRadius(width: span, height: height)
        let topLeft = radius * (1 - (joinedAtStart == .top ? startJoin : 0))
        let topRight = radius * (1 - (joinedAtEnd == .top ? endJoin : 0))
        let bottomLeft = radius * (1 - (joinedAtStart == .bottom ? startJoin : 0))
        let bottomRight = radius * (1 - (joinedAtEnd == .bottom ? endJoin : 0))
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
        let system = max(0, animatableData.first.first.first)
        let charge = max(0, animatableData.first.first.second)
        let assist = max(0, animatableData.first.second.first)
        let chip = min(system, max(0, animatableData.first.second.second))
        let chargePresence = CGFloat(min(1, max(0, animatableData.second.first.first)))
        let assistPresence = CGFloat(min(1, max(0, animatableData.second.first.second)))
        let supplyPresence = CGFloat(min(1, max(0, animatableData.second.second)))
        let geometry = LaptopSankeyGeometry.make(
            systemWatts: system, chargeWatts: charge, assistWatts: assist, chipWatts: chip,
            chargePresence: chargePresence, assistPresence: assistPresence)
        let hasInputs = supplyPresence > 0

        return GeometryReader { proxy in
            let columns = Columns(width: proxy.size.width, supplyPresence: supplyPresence)
            let inputX = (columns.inlet + columns.merge) / 2
            let outputX = (columns.split + columns.outlet) / 2
            let primaryHeight = max(0, geometry.inputHeight - geometry.chargeHeight)
            let inputBottom = geometry.leftTop + primaryHeight
            let inputTarget = geometry.systemTop + geometry.assistHeight
            let inputY = geometry.leftTop + geometry.inputHeight / 2
            let systemY = geometry.systemTop + geometry.systemHeight / 2
            let chargeY = geometry.chargeTop + geometry.chargeHeight / 2
            let assistY = geometry.assistTop + geometry.assistHeight / 2
            let outputBoundary = geometry.systemTop + geometry.chipHeight

            let showSupply = hasInputs && columns.merge > columns.inlet
            let curveStart = LaptopFlowStyle.splitStart * chargePresence
            let curveEnd = LaptopFlowStyle.mergeEnd + (1 - LaptopFlowStyle.mergeEnd) * chargePresence
            let supply = showSupply
                ? supplyPaths(geometry, columns: columns, inputBottom: inputBottom, inputTarget: inputTarget,
                              primaryHeight: primaryHeight, curveStart: curveStart, curveEnd: curveEnd,
                              chargePresence: chargePresence, assistPresence: assistPresence)
                : Path()
            let outputs = flow.hasBreakdown ? outputPaths(geometry, columns: columns, boundary: outputBoundary) : Path()
            let sourceSymbol = flow.mode == .battery ? "battery.75percent" : "powerplug"
            let batteryTitle = ChipBarLocale.choose("Battery", "电池")
            let chipTitle = ChipBarLocale.choose("Chip", "芯片")
            let otherTitle = flow.mode == .desktop ? ChipBarLocale.choose("Other", "其余部件")
                                                   : ChipBarLocale.choose("Other", "其他")

            if showSupply {
                glassRibbons(LaptopPowerGlassShape(ribbons: supply),
                             from: LaptopFlowStyle.inputStartColor, to: LaptopFlowStyle.inputEndColor,
                             x0: columns.inlet, x1: columns.merge, width: proxy.size.width)
                    .opacity(supplyPresence)
            }

            if flow.hasBreakdown {
                glassRibbons(LaptopPowerGlassShape(ribbons: outputs),
                             from: LaptopFlowStyle.outputStartColor, to: LaptopFlowStyle.outputEndColor,
                             x0: columns.split, x1: columns.outlet, width: proxy.size.width)
            }

            if active && !reduceMotion && (!supply.isEmpty || !outputs.isEmpty) {
                PowerRibbonGlint(supply: supply, outputs: outputs)
            }

            if showSupply && geometry.assistHeight > 0 {
                endpoint(batteryTitle, symbol: "battery.75percent",
                         height: geometry.assistHeight, width: columns.endpointWidth)
                    .position(x: columns.source, y: assistY)
                    .opacity(assistPresence * supplyPresence)
                wattLabel(assist)
                    .accessibilityLabel(batteryTitle + ", " + watts(assist) + " W")
                    .position(x: inputX, y: assistY + (geometry.systemTop - geometry.assistTop) * LaptopFlowStyle.mergeMidpoint)
                    .opacity(assistPresence * supplyPresence)
            }
            if showSupply && geometry.inputHeight > 0 {
                endpoint(sourceName, symbol: sourceSymbol, height: geometry.inputHeight,
                         width: columns.endpointWidth, inputTotal: flow.chargeWatts > 0 ? system + charge : nil)
                    .position(x: columns.source, y: inputY)
                    .opacity(supplyPresence)
                let value = max(0, system - assist)
                let midpoint = LaptopFlowStyle.mergeMidpoint
                    + (LaptopFlowStyle.splitMidpoint - LaptopFlowStyle.mergeMidpoint) * chargePresence
                let title = flow.chargeWatts > 0 ? ChipBarLocale.choose("System power", "系统功率") : sourceName
                wattLabel(value)
                    .accessibilityLabel(title + ", " + watts(value) + " W")
                    .position(x: inputX, y: geometry.leftTop + primaryHeight / 2
                              + (inputTarget - geometry.leftTop) * midpoint)
                    .opacity(supplyPresence)
            }

            systemCard(system, height: geometry.systemHeight, width: columns.systemWidth)
                .position(x: columns.system, y: systemY)
            if showSupply && geometry.chargeHeight > 0 {
                wattLabel(charge)
                    .accessibilityLabel(ChipBarLocale.choose("Battery charging", "电池充电") + ", " + watts(charge) + " W")
                    .position(x: inputX, y: inputBottom + geometry.chargeHeight / 2
                              + (geometry.chargeTop - inputBottom) * LaptopFlowStyle.splitMidpoint)
                    .opacity(chargePresence * supplyPresence)
                endpoint(ChipBarLocale.choose("Charging", "充电"), symbol: "battery.100percent.bolt",
                         height: geometry.chargeHeight, width: columns.systemWidth)
                    .position(x: columns.system, y: chargeY)
                    .opacity(chargePresence * supplyPresence)
            }

            if flow.hasBreakdown {
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
        }
        .frame(height: geometry.contentHeight(showsSupply: hasInputs, showsBreakdown: flow.hasBreakdown))
    }

    private func supplyPaths(_ g: LaptopSankeyGeometry, columns: Columns,
                             inputBottom: CGFloat, inputTarget: CGFloat, primaryHeight: CGFloat,
                             curveStart: CGFloat, curveEnd: CGFloat,
                             chargePresence: CGFloat, assistPresence: CGFloat) -> Path {
        var result = Path()
        if primaryHeight > 0 {
            result.addPath(ribbon(from: columns.inlet, to: columns.merge, at: g.leftTop,
                to: inputTarget, height: primaryHeight, start: curveStart, end: curveEnd,
                joinedAtStart: .bottom, joinedAtEnd: .top,
                startJoin: chargePresence, endJoin: assistPresence))
        }
        // Liquid Glass can highlight a subpixel outline as a bright line.
        if g.chargeHeight >= 0.75 {
            result.addPath(ribbon(from: columns.inlet, to: columns.merge, at: inputBottom,
                to: g.chargeTop, height: g.chargeHeight, start: LaptopFlowStyle.splitStart, end: 1,
                joinedAtStart: .top, startJoin: chargePresence))
        }
        if g.assistHeight >= 0.75 {
            result.addPath(ribbon(from: columns.inlet, to: columns.merge, at: g.assistTop,
                to: g.systemTop, height: g.assistHeight, start: 0, end: LaptopFlowStyle.mergeEnd,
                joinedAtEnd: primaryHeight > 0 ? .bottom : nil, endJoin: assistPresence))
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
        .animation(active && reduceMotion ? LaptopFlowStyle.crossfade : nil,
                   value: reduceMotion ? flow : nil)
        .accessibilityElement(children: .contain)
    }
}

private struct LaptopPowerGlassShape: Shape {
    let ribbons: Path

    func path(in rect: CGRect) -> Path {
        if #available(macOS 26.0, *) {
            return ribbons.normalized(eoFill: false)
        }
        return ribbons
    }
}

private struct PowerRibbonGlint: View {
    let supply: Path
    let outputs: Path
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let path = Path { path in
            path.addPath(supply)
            path.addPath(outputs)
        }
        let bounds = path.boundingRect
        let opacity = colorScheme == .dark ? 0.17 : 0.26
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { frame in
            Canvas { context, _ in
                let halfWidth = min(34, max(15, bounds.width * 0.11))
                let speed = 105.0
                let travel = bounds.width + 2 * halfWidth + speed * 0.6
                let elapsed = frame.date.timeIntervalSinceReferenceDate
                let offset = (elapsed * speed).truncatingRemainder(dividingBy: travel)
                let x = bounds.minX - halfWidth + offset
                let glint = GraphicsContext.Shading.linearGradient(
                    Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(opacity * 0.4), location: 0.34),
                        .init(color: .white.opacity(opacity), location: 0.54),
                        .init(color: .clear, location: 1)
                    ]),
                    startPoint: CGPoint(x: x - halfWidth, y: 0),
                    endPoint: CGPoint(x: x + halfWidth, y: 0))
                context.fill(path, with: glint)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
