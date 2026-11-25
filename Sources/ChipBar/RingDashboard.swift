import SwiftUI
import ChipBarCore

/// The original ChipBar circular runway, promoted to the dashboard's primary
/// visual element.  All three gauges use the same geometry and animated arc.
struct DashboardRunway: View {
    let title: String
    let percentage: Double?
    let color: Color
    let subtitle: String
    let detail: String
    var pressureStatus: String? = nil
    var capacityReadout: String? = nil
    var active = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.compactDashboard) private var compact

    private var fraction: Double {
        guard let percentage, percentage.isFinite else { return 0 }
        return max(0, min(1, percentage / 100))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(height: 15)
                .padding(.bottom, 5)
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion || !active ? nil :
                        .spring(response: 0.55, dampingFraction: 1), value: fraction)
                VStack(spacing: 1) {
                    if percentage?.isFinite == true {
                        RunwayPercentage(value: fraction * 100)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                    } else {
                        Text("—").font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if capacityReadout == nil {
                        Text(detail)
                            .font(.system(size: compact ? 9 : 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .monospacedDigit()
            }
            .frame(width: compact ? 51 : 65, height: compact ? 51 : 65)
            .padding(.bottom, 6)
            .accessibilityHidden(true)
            Text(capacityReadout ?? subtitle)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 8 : 10)
        .padding(.horizontal, 5)
        .glassTile(radius: 22, subdued: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(percentage.map { String(format: "%.0f%%", $0) } ?? "占用不可用")，\(subtitle)，" +
                            (capacityReadout == nil ? "温度 \(detail)" : detail) +
                            (pressureStatus.map { "，内存压力\($0)" } ?? ""))
    }
}

private struct RunwayPercentage: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(String(format: "%.0f%%", value))
    }
}

/// The Neural Engine has a real power reading but no trustworthy aggregate
/// utilization counter.  Keep it as a separate, quiet metric instead of
/// displaying RAM utilization under an ANE heading.
struct DashboardANEStrip: View {
    let power: Double?
    let connected: Bool
    @Environment(\.compactDashboard) private var compact

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0.22, green: 0.65, blue: 0.79))
            Text("ANE")
                .font(.caption.weight(.medium))
            Spacer(minLength: 2)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                AnimatedMetricValue(value: connected ? power : nil)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("W").font(.caption2).foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 35 : 43)
        .glassTile(radius: 26)
        .accessibilityElement(children: .combine)
    }
}
