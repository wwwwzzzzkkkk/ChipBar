import SwiftUI
import ChipBarCore

/// Chart axes, gridlines and samples share one inset coordinate system.
/// Centering the top tick at y=0 previously let its glyph rise above the plot,
/// so a top-aligned headline still appeared vertically misaligned.
enum PowerTrendGeometry {
    static let yLabelInset: CGFloat = 6

    static func y(fraction: CGFloat, height: CGFloat) -> CGFloat {
        let inset = min(yLabelInset, max(0, height / 2))
        return inset + (max(0, height - inset * 2) * fraction)
    }
}

/// A bounded path rebuilt from the current history. Avoid retaining a chart mark
/// and axis identity graph for each new timestamp during long sampling sessions.
struct PowerTrendPlot: View {
    struct Point {
        let date: Date
        let power: Double
        let segment: Int
    }

    let points: [Point]
    let maximum: Double
    let timeline: TrendTimeWindow
    let accent: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                GeometryReader { geometry in
                    ForEach(0..<3, id: \.self) { index in
                        Text(index == 2 ? "0" : tick(maximum * Double(2 - index) / 2))
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 27, alignment: .trailing)
                            .position(x: 13.5, y: PowerTrendGeometry.y(
                                fraction: CGFloat(index) / 2,
                                height: geometry.size.height))
                    }
                }.frame(width: 27)
                GeometryReader { geometry in
                    ZStack {
                        Path { path in
                            for fraction in [0.0, 0.5, 1.0] {
                                let y = PowerTrendGeometry.y(
                                    fraction: fraction, height: geometry.size.height)
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                            }
                        }.stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        line(size: geometry.size)
                            .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        // A single valid sample, or isolated samples around gaps,
                        // would otherwise be invisible as a move-only path.
                        Path { path in
                            for index in points.indices {
                                let point = points[index]
                                let before = index > 0 && points[index - 1].segment == point.segment
                                let after = index + 1 < points.count && points[index + 1].segment == point.segment
                                if !before && !after {
                                    let position = position(point, size: geometry.size)
                                    path.addEllipse(in: CGRect(x: position.x - 2, y: position.y - 2, width: 4, height: 4))
                                }
                            }
                        }.fill(accent)
                    }.clipped()
                }.accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                ForEach(Array(timeline.ticks.enumerated()), id: \.offset) { index, date in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(TrendTimeWindow.clockLabel(date))
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
            }.padding(.leading, 31).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("功率趋势")
        .accessibilityValue("\(points.count) 个有效采样，最新 \(points.last.map { String(format: "%.1f", $0.power) } ?? "—") 瓦")
    }

    private func tick(_ value: Double) -> String {
        String(format: maximum < 10 ? "%.1f" : "%.0f", value)
    }

    private func position(_ point: Point, size: CGSize) -> CGPoint {
        let fraction = timeline.fraction(for: point.date) ?? 0
        return CGPoint(x: size.width * fraction,
                       y: PowerTrendGeometry.y(
                           fraction: 1 - min(1, max(0, point.power / maximum)),
                           height: size.height))
    }

    private func line(size: CGSize) -> Path {
        Path { path in
            var previousSegment: Int?
            for point in points {
                let position = position(point, size: size)
                if previousSegment == point.segment { path.addLine(to: position) }
                else { path.move(to: position) }
                previousSegment = point.segment
            }
        }
    }
}
