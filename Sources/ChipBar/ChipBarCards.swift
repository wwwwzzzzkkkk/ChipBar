import SwiftUI

/// Interpolate the displayed number rather than snapping text while the
/// adjacent ring springs to the new sample. Fixed width/monospaced digits
/// prevent neighboring controls from shifting while values change.
struct AnimatedMetricValue: View, Animatable {
    var value: Double?
    var decimals: Int = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: Double {
        get { value ?? 0 }
        set {
            if value != nil { value = newValue }
        }
    }

    var body: some View {
        Text(value.flatMap { $0.isFinite ? String(format: "%.*f", decimals, $0) : nil } ?? "—")
            .monospacedDigit()
            .animation(reduceMotion ? nil : ChipBarMotion.selection, value: value)
    }
}

struct PowerMetricCard: View {
    let title: String
    let power: Double?
    let connected: Bool
    let icon: String

    /// A fixed, top-trailing gauge slot keeps CPU, GPU and memory aligned.
    let ringTitle: String
    let ringCaption: String
    let utilization: Double?
    let ringTint: Color
    var ringStatus: String? = nil

    /// Only CPU/GPU cards show a temperature. ANE reserves the same row.
    var temperature: Double? = nil
    var showsTemperature = false
    var recentPowers: [Double] = []

    private var temperatureText: String {
        guard connected, let temperature, temperature.isFinite else { return "—°C" }
        return String(format: "%.1f°C", temperature)
    }

    private var powerDescription: String {
        guard connected, let power, power.isFinite else { return "不可用" }
        return String(format: "%.1f W", power)
    }

    private var usageDescription: String {
        guard connected, let utilization, utilization.isFinite else { return "不可用" }
        return String(format: "%.0f%%", min(100, max(0, utilization)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Left: name / wattage / temperature. Right: an equal-height ring.
            // Separate columns prevent the gauge from covering CPU/GPU titles.
            HStack(alignment: .center, spacing: 5) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: icon)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(height: 14, alignment: .leading)

                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        AnimatedMetricValue(value: connected ? power : nil)
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .layoutPriority(1)
                        Text("W")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 27, alignment: .leading)

                    Text(showsTemperature ? temperatureText : " ")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(height: 12, alignment: .leading)
                        .opacity(showsTemperature ? 1 : 0)
                        .help(showsTemperature ? "\(title) 温度：\(temperatureText)" : "")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 62, alignment: .center)

                MetricRing(title: ringTitle, caption: ringCaption,
                           percentage: connected ? utilization : nil,
                           tint: ringTint, status: ringStatus)
            }
            .frame(height: 62)

            PowerSparkline(values: recentPowers)
                .frame(height: 17)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .glassTile(radius: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) 功率 \(powerDescription)，\(ringTitle) \(usageDescription)" +
                            (showsTemperature ? "，温度 \(temperatureText)" : "") +
                            (ringStatus.map { "，内存压力\($0)" } ?? ""))
    }
}

/// Very small bounded history, without Chart / per-point view allocation.
struct PowerSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let points = values.suffix(24).filter { $0.isFinite && $0 >= 0 }
            if points.count >= 2 {
                let smallest = points.min() ?? 0
                let biggest = points.max() ?? 1
                let range = max(0.4, biggest - smallest)
                Path { path in
                    for (index, number) in points.enumerated() {
                        let x = geometry.size.width * CGFloat(index) / CGFloat(points.count - 1)
                        let y = geometry.size.height * (1 - CGFloat((number - smallest) / range))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Shared compact progress component for internal disk / future SSD cards.
/// Avoids GeometryReader's default infinite ideal height by fixing it to 4 pt.
struct CapacityProgressTrack: View {
    let usedFraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        guard let usedFraction, usedFraction.isFinite else { return 0 }
        return max(0, min(1, usedFraction))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(Color(red: 0.22, green: 0.65, blue: 0.79).opacity(0.70))
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
        .animation(reduceMotion ? nil : ChipBarMotion.disclosure, value: fraction)
        .accessibilityHidden(true)
    }
}
