import SwiftUI

/// Compact, bounded percentage gauge embedded in a power card's upper-right.
/// Power readings are never normalised against an arbitrary wattage.
struct MetricRing: View {
    let title: String
    let caption: String
    let percentage: Double?
    let tint: Color
    /// Memory pressure is expressed by ring tint; its wording stays accessible.
    var status: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        guard let percentage, percentage.isFinite else { return 0 }
        return min(1, max(0, percentage / 100))
    }

    private var percentageText: String {
        guard let percentage, percentage.isFinite else { return "不可用" }
        return String(format: "%.0f%%", fraction * 100)
    }

    private var motion: Animation {
        reduceMotion ? .linear(duration: 0) : .spring(response: 0.55, dampingFraction: 1.0)
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(motion, value: fraction)
                if percentage != nil, percentage?.isFinite == true {
                    AnimatedPercentage(value: fraction * 100)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .animation(motion, value: fraction)
                } else {
                    Text("—")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            // Reserve one uniform caption baseline for all three gauges:
            // CPU/GPU show no '占用' text, ANE still says '内存'.
            Text(caption.isEmpty ? " " : caption)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 12)
                .accessibilityHidden(true)
        }
        .frame(width: 44, height: 62, alignment: .center)
        .help("\(title)：\(percentageText)" +
              (status.map { " · 内存压力：\($0)" } ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)：\(percentageText)" +
                            (status.map { "，内存压力\($0)" } ?? ""))
    }
}

/// Animatable numerical text shares the ring's spring timeline, so the number
/// doesn't jump to the new sample before the stroke catches up.
private struct AnimatedPercentage: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(String(format: "%.0f%%", value))
    }
}
