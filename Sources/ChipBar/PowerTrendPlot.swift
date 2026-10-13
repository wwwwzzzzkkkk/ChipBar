import SwiftUI

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
    let axisDates: [Date]
    let dateFormat: Date.FormatStyle
    let accent: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                GeometryReader { geometry in
                    ForEach(0..<3, id: \.self) { index in
                        Text(index == 2 ? "0" : tick(maximum * Double(2 - index) / 2))
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                            .position(x: 14, y: geometry.size.height * Double(index) / 2)
                    }
                }.frame(width: 28)
                GeometryReader { geometry in
                    ZStack {
                        Path { path in
                            for fraction in [0.0, 0.5, 1.0] {
                                let y = geometry.size.height * fraction
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
                ForEach(Array(axisDates.enumerated()), id: \.offset) { index, date in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(date, format: dateFormat).fixedSize(horizontal: true, vertical: false)
                }
            }.padding(.leading, 34).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("功率趋势")
        .accessibilityValue("\(points.count) 个有效采样，最新 \(points.last.map { String(format: "%.1f", $0.power) } ?? "—") 瓦")
    }

    private func tick(_ value: Double) -> String {
        String(format: maximum < 10 ? "%.1f" : "%.0f", value)
    }

    private func position(_ point: Point, size: CGSize) -> CGPoint {
        let start = axisDates.first ?? point.date
        let duration = (axisDates.last ?? start).timeIntervalSince(start)
        let fraction = duration > 0 ? point.date.timeIntervalSince(start) / duration : 0.5
        return CGPoint(x: size.width * min(1, max(0, fraction)),
                       y: size.height * (1 - min(1, max(0, point.power / maximum))))
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
