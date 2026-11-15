import SwiftUI

/// The aggregate chip total comes from the SAME sample shown on Home.
/// Inconsistent/negative derived numbers are unavailable, never clamped
/// into made-up wattage values.
struct PowerDistribution {
    let internalWatts: Double?
    let chipWatts: Double?

    private var valid: (internalWatts: Double, chipWatts: Double)? {
        guard let internalWatts, let chipWatts,
              internalWatts.isFinite, chipWatts.isFinite,
              internalWatts > 0, chipWatts >= 0,
              chipWatts <= internalWatts else { return nil }
        return (internalWatts, chipWatts)
    }

    var otherWatts: Double? {
        valid.map { $0.internalWatts - $0.chipWatts }
    }

    var chipFraction: Double? {
        valid.map { $0.chipWatts / $0.internalWatts }
    }

    var otherFraction: Double? {
        chipFraction.map { 1 - $0 }
    }
}

/// Choose topology from hardware state, never from a model-name string.
enum PowerSourceMode: Equatable {
    case desktop
    case battery
    case adapter
    case adapterCharging
    case adapterAssisted

    init(reading: ChipBarPowerReading) {
        guard reading.hasBattery else { self = .desktop; return }
        guard reading.onAdapter else { self = .battery; return }
        if reading.isCharging, (reading.batteryWatts ?? 0) > 0.5 {
            self = .adapterCharging
        } else if (reading.batteryWatts ?? 0) < -0.5 {
            self = .adapterAssisted
        } else {
            self = .adapter
        }
    }

    var showsBatteryBranch: Bool {
        self == .adapterCharging || self == .adapterAssisted
    }
}


/// Geometry is derived only from valid measured watts. An inconsistent sensor
/// reading never becomes a plausible-looking Sankey flow.
struct PowerSankeyGeometry {
    static let wattsToPoints: CGFloat = 4.4
    static let maximumHeight: CGFloat = 150
    static let nodeGap: CGFloat = 16

    let totalHeight: CGFloat
    let chipHeight: CGFloat
    let otherHeight: CGFloat
    let sourceTop: CGFloat
    let chipTop: CGFloat
    let otherTop: CGFloat

    static func make(distribution: PowerDistribution, chartHeight: CGFloat = 190)
        -> PowerSankeyGeometry? {
        guard let internalWatts = distribution.internalWatts,
              let chipWatts = distribution.chipWatts,
              let otherWatts = distribution.otherWatts,
              internalWatts.isFinite, internalWatts > 0,
              chipWatts.isFinite, otherWatts.isFinite,
              chartHeight > nodeGap else { return nil }
        let scale = min(wattsToPoints,
                        min(maximumHeight, chartHeight - nodeGap) / CGFloat(internalWatts))
        let total = CGFloat(internalWatts) * scale
        let chip = CGFloat(chipWatts) * scale
        let other = total - chip
        let sourceTop = (chartHeight - total) / 2
        let rightTop = (chartHeight - total - nodeGap) / 2
        return PowerSankeyGeometry(
            totalHeight: total, chipHeight: chip, otherHeight: other,
            sourceTop: sourceTop, chipTop: rightTop,
            otherTop: rightTop + chip + nodeGap
        )
    }

    var chipCenter: CGFloat { chipTop + chipHeight / 2 }
    var otherCenter: CGFloat { otherTop + otherHeight / 2 }
}

/// The chart is drawn into a single Canvas. Its animated dashed lines are
/// invalidated only while the side panel is actually mounted and active.
private struct PowerSankeyFlow: View, Animatable {
    let distribution: PowerDistribution
    let externalWatts: Double?
    let sourceTitle: String
    let active: Bool

    // These three values are interpolated by SwiftUI between one-second samples.
    // Canvas geometry and every displayed number use the SAME intermediate frame.
    // This avoids abrupt geometry/label jumps without smoothing the sensor model.
    private var animatedInternalWatts: Double
    private var animatedChipWatts: Double
    private var animatedExternalWatts: Double

    init(distribution: PowerDistribution, externalWatts: Double?,
         sourceTitle: String, active: Bool) {
        self.distribution = distribution
        self.externalWatts = externalWatts
        self.sourceTitle = sourceTitle
        self.active = active
        animatedInternalWatts = distribution.internalWatts ?? 0
        animatedChipWatts = distribution.chipWatts ?? 0
        animatedExternalWatts = externalWatts ?? 0
    }

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(animatedInternalWatts,
                            AnimatablePair(animatedChipWatts, animatedExternalWatts)) }
        set {
            animatedInternalWatts = newValue.first
            animatedChipWatts = newValue.second.first
            animatedExternalWatts = newValue.second.second
        }
    }

    private var displayedDistribution: PowerDistribution {
        // An invalid sensor pair must stay unavailable, even during a transition.
        guard distribution.otherWatts != nil else { return distribution }
        return PowerDistribution(internalWatts: animatedInternalWatts,
                                 chipWatts: animatedChipWatts)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let amber = Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)

    private func value(_ watts: Double?) -> String {
        guard let watts, watts.isFinite, watts >= 0 else { return "—" }
        return String(format: "%.1f", watts)
    }

    private func fraction(_ portion: Double?) -> String {
        guard let portion, portion.isFinite else { return "—" }
        return String(format: "%.0f%%", portion * 100)
    }

    private var accessibleText: String {
        let total = distribution.internalWatts
        let chip = distribution.chipWatts
        let other = distribution.otherWatts
        return "内部功率 \(value(total)) 瓦，其中芯片 \(value(chip)) 瓦，其余部件 \(value(other)) 瓦（估算）"
    }

    private var leftLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("内部功率")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value(displayedDistribution.internalWatts))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text("W")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                Text(sourceTitle)
                Text(value(externalWatts == nil ? nil : animatedExternalWatts))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .opacity(externalWatts == nil ? 0.48 : 1)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .frame(width: 82, alignment: .leading)
    }

    private func outputLabel(_ name: String, watts: Double?, percent: Double?,
                             tint: Color, estimated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(name).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value(watts))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text("W").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(fraction(percent))
                if estimated { Text("· 估算") }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(width: 88, alignment: .leading)
        .opacity(watts == nil ? 0.48 : 1)
    }

    /// Draw one closed Bezier ribbon. The top and bottom horizontal control
    /// points both sit on the same midpoint, avoiding sharp or angled joins.
    private func ribbon(x0: CGFloat, x1: CGFloat,
                        sourceTop: CGFloat, targetTop: CGFloat,
                        height: CGFloat) -> Path {
        let midpoint = (x0 + x1) / 2
        return Path { path in
            path.move(to: CGPoint(x: x0, y: sourceTop))
            path.addCurve(to: CGPoint(x: x1, y: targetTop),
                          control1: CGPoint(x: midpoint, y: sourceTop),
                          control2: CGPoint(x: midpoint, y: targetTop))
            path.addLine(to: CGPoint(x: x1, y: targetTop + height))
            path.addCurve(to: CGPoint(x: x0, y: sourceTop + height),
                          control1: CGPoint(x: midpoint, y: targetTop + height),
                          control2: CGPoint(x: midpoint, y: sourceTop + height))
            path.closeSubpath()
        }
    }

    private func flowLine(x0: CGFloat, x1: CGFloat,
                          from: CGFloat, to: CGFloat) -> Path {
        let midpoint = (x0 + x1) / 2
        return Path { path in
            path.move(to: CGPoint(x: x0, y: from))
            path.addCurve(to: CGPoint(x: x1, y: to),
                          control1: CGPoint(x: midpoint, y: from),
                          control2: CGPoint(x: midpoint, y: to))
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize, phase: CGFloat,
                      geometry: PowerSankeyGeometry) {
        let barWidth: CGFloat = 6
        let leftX: CGFloat = 90
        let rightX = max(leftX + 40, size.width - 96)
        let startX = leftX + barWidth
        let sourceChipTop = geometry.sourceTop
        let sourceOtherTop = geometry.sourceTop + geometry.chipHeight

        func fillBand(_ path: Path, start: Color, end: Color, glow: Bool) {
            let gradient = Gradient(colors: [start, end])
            let fill = GraphicsContext.Shading.linearGradient(
                gradient, startPoint: CGPoint(x: startX, y: 0),
                endPoint: CGPoint(x: rightX, y: 0))
            if glow {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: amber.opacity(0.32), radius: 8))
                    layer.fill(path, with: fill)
                }
            }
            context.fill(path, with: fill)
        }

        if geometry.chipHeight > 0 {
            let path = ribbon(x0: startX, x1: rightX,
                              sourceTop: sourceChipTop, targetTop: geometry.chipTop,
                              height: geometry.chipHeight)
            fillBand(path, start: amber.opacity(0.25), end: amber.opacity(0.8), glow: true)
        }
        if geometry.otherHeight > 0 {
            let path = ribbon(x0: startX, x1: rightX,
                              sourceTop: sourceOtherTop, targetTop: geometry.otherTop,
                              height: geometry.otherHeight)
            // Semantic contrast: the lower band stays legible on both light and dark glass.
            fillBand(path, start: Color.primary.opacity(0.26),
                     end: Color.primary.opacity(0.50), glow: false)
        }

        let lineStyle = StrokeStyle(lineWidth: 2, lineCap: .round,
                                    dash: [2, 10], dashPhase: phase)
        if geometry.chipHeight > 0 {
            let path = flowLine(x0: startX, x1: rightX,
                                from: sourceChipTop + geometry.chipHeight / 2,
                                to: geometry.chipCenter)
            context.stroke(path, with: .color(amber.opacity(0.95)), style: lineStyle)
        }
        if geometry.otherHeight > 0 {
            let path = flowLine(x0: startX, x1: rightX,
                                from: sourceOtherTop + geometry.otherHeight / 2,
                                to: geometry.otherCenter)
            context.stroke(path, with: .color(Color.primary.opacity(0.72)), style: lineStyle)
        }
        // One rounded source rail, split into measured chip and estimated
        // other-component colors, as in the reference. Clipping once avoids
        // a visible seam or separate rounded caps at the internal division.
        context.drawLayer { node in
            let source = Path(roundedRect: CGRect(x: leftX, y: geometry.sourceTop,
                                                   width: barWidth, height: geometry.totalHeight),
                              cornerRadius: 3)
            node.clip(to: source)
            node.fill(source, with: .color(Color.primary.opacity(0.62)))
            node.fill(Path(CGRect(x: leftX, y: geometry.sourceTop,
                                  width: barWidth, height: geometry.chipHeight)),
                      with: .color(amber))
        }
        context.fill(Path(roundedRect: CGRect(x: rightX, y: geometry.chipTop,
                                               width: barWidth, height: geometry.chipHeight),
                          cornerRadius: 3), with: .color(amber))
        context.fill(Path(roundedRect: CGRect(x: rightX, y: geometry.otherTop,
                                               width: barWidth, height: geometry.otherHeight),
                          cornerRadius: 3), with: .color(Color.primary.opacity(0.62)))
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = PowerSankeyGeometry.make(distribution: displayedDistribution)
            ZStack(alignment: .topLeading) {
                if let geometry {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                            paused: !active || reduceMotion)) { time in
                        // Negative phase moves the round dashes left-to-right;
                        // one complete 12-point pattern traverses in 1.1 s.
                        let elapsed = time.date.timeIntervalSinceReferenceDate
                        let phase = (!active || reduceMotion) ? CGFloat.zero :
                            -CGFloat((elapsed * 12 / 1.1).truncatingRemainder(dividingBy: 12))
                        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                            draw(in: context, size: size, phase: phase, geometry: geometry)
                        }
                    }
                    .accessibilityHidden(true)
                }
                leftLabel
                    .position(x: 41, y: 95)
                outputLabel("芯片", watts: displayedDistribution.chipWatts,
                            percent: displayedDistribution.chipFraction,
                            tint: amber, estimated: false)
                    .position(x: proxy.size.width - 44, y: 56)
                outputLabel("其余部件", watts: displayedDistribution.otherWatts,
                            percent: displayedDistribution.otherFraction,
                            tint: Color.primary.opacity(0.72), estimated: true)
                    .position(x: proxy.size.width - 44, y: 142)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: 190)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleText)
    }
}

struct PowerSupplyDetailView: View {
    @ObservedObject var monitor: Monitor
    let active: Bool
    let close: () -> Void
    @ObservedObject private var sampler = ChipBarPowerFlowModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var reading: ChipBarPowerReading { sampler.reading }
    private var breakdown: PowerDistribution {
        PowerDistribution(internalWatts: reading.systemWatts,
                          chipWatts: sampler.chipWattsAtReading)
    }
    private var mode: PowerSourceMode { PowerSourceMode(reading: reading) }
    private var supplyTitle: String {
        mode == .battery ? "电池供电" : "外部供电"
    }
    private var supplyWatts: Double? {
        if mode == .battery {
            guard let watts = reading.batteryWatts, watts.isFinite, watts < 0
            else { return nil }
            return abs(watts)
        }
        guard reading.hasBattery, reading.onAdapter else { return nil }
        return reading.adapterWatts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Button(action: close) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 29)
                        .glassTile(radius: 14, interactive: true)
                }
                .accessibilityLabel("返回主页面")
                VStack(alignment: .leading, spacing: 2) {
                    Text("电源与功率").font(.headline)
                    Text(reading.live ? "传感器在线 · \(PowerSamplingCadence.seconds) 秒采样" :
                         "等待传感器 · \(PowerSamplingCadence.seconds) 秒采样")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(reading.live ? "实时" : "离线")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(reading.live ? Color.green : Color.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background((reading.live ? Color.green : Color.secondary).opacity(0.12),
                                in: Capsule(style: .continuous))
            }
            .frame(height: 40)

            // A fixed native side-panel frame avoids the jump seen when an
            // expandable port row changes its intrinsic height. Only the
            // interior scrolls, leaving the existing Sankey geometry intact.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("功率流向").font(.caption.weight(.semibold))
                            Spacer(minLength: 4)
                            Text("左 → 右 · 条带粗细 = 瓦数")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        PowerSankeyFlow(distribution: breakdown, externalWatts: supplyWatts,
                                        sourceTitle: supplyTitle, active: active && reading.live)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.70),
                                       value: breakdown.internalWatts)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.70),
                                       value: breakdown.chipWatts)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.70),
                                       value: supplyWatts)
                    }
                    .padding(12)
                    .glassTile(radius: 26)

                    USBCPowerSection(snapshot: reading.usb)
                    USBDeviceLinkSection(devices: reading.usb.devices)
                }
                .padding(.vertical, 2)
            }
            .frame(height: SidePanelLayout.powerHeight - SidePanelLayout.padding * 2 - 50)
        }
    }
}
