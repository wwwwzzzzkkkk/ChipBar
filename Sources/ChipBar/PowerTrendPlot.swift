import SwiftUI
import ChipBarCore

/// Chart axes, gridlines and samples share one inset coordinate system.
/// Centering the top tick at y=0 previously let its glyph rise above the plot,
/// so a top-aligned headline still appeared vertically misaligned.
enum PowerTrendGeometry {
    static let yLabelInset: CGFloat = 6
    private static let eventSymbolSpacing: CGFloat = 19

    struct EventMarker: Identifiable {
        var id: Date { event.date }
        let event: PowerHistoryEvent
        let guideX: CGFloat
        let symbolPosition: CGPoint?
    }

    static func y(fraction: CGFloat, height: CGFloat) -> CGFloat {
        let inset = min(yLabelInset, max(0, height / 2))
        return inset + (max(0, height - inset * 2) * fraction)
    }

    static func clampedX(_ x: CGFloat, width: CGFloat, inset: CGFloat) -> CGFloat {
        let edge = min(inset, width / 2)
        return min(width - edge, max(edge, x))
    }

    static func eventMarkers(_ events: [PowerHistoryEvent], timeline: TrendTimeWindow,
                             width: CGFloat, showsSymbols: Bool) -> [EventMarker] {
        var lastXByRow = Array(repeating: -CGFloat.infinity, count: 3)
        return events.compactMap { event in
            guard let fraction = timeline.fraction(for: event.date) else { return nil }
            let x = width * fraction
            let guideX = clampedX(x, width: width, inset: 1)
            let symbolX = clampedX(x, width: width, inset: showsSymbols ? 8 : 2)
            let position: CGPoint?
            if !showsSymbols {
                position = CGPoint(x: symbolX, y: 4)
            } else if let row = lastXByRow.firstIndex(where: { symbolX - $0 >= eventSymbolSpacing }) {
                lastXByRow[row] = symbolX
                position = CGPoint(x: symbolX, y: 9 + CGFloat(row) * eventSymbolSpacing)
            } else {
                // The timeline still marks the exact time. The event list
                // remains selectable when every symbol row is occupied.
                position = nil
            }
            return EventMarker(event: event, guideX: guideX, symbolPosition: position)
        }
    }

    static func event(at location: CGPoint, in markers: [EventMarker], showsSymbols: Bool) -> Date? {
        let radius: CGFloat = showsSymbols ? 10 : 7
        let closest = markers.compactMap { marker -> (date: Date, distance: CGFloat)? in
            guard let position = marker.symbolPosition else { return nil }
            let dx = position.x - location.x
            let distance = showsSymbols ? hypot(dx, position.y - location.y) : abs(dx)
            return (marker.id, distance)
        }.min { $0.distance < $1.distance }
        guard let closest, closest.distance <= radius else { return nil }
        return closest.date
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
    var events: [PowerHistoryEvent] = []
    var selection: PowerHistorySelection? = nil
    var showsEventSymbols = false
    var onSelect: ((PowerHistorySelection?) -> Void)? = nil

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                GeometryReader { geometry in
                    ForEach(0..<3, id: \.self) { index in
                        Text(index == 2 ? "0" : tick(maximum * Double(2 - index) / 2))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 27, alignment: .trailing)
                            .position(x: 13.5, y: PowerTrendGeometry.y(
                                fraction: CGFloat(index) / 2,
                                height: geometry.size.height))
                    }
                }.frame(width: 27)
                GeometryReader { geometry in
                    let markers = PowerTrendGeometry.eventMarkers(
                        events, timeline: timeline, width: geometry.size.width, showsSymbols: showsEventSymbols)
                    ZStack {
                        Path { path in
                            for fraction in [0.0, 0.5, 1.0] {
                                let y = PowerTrendGeometry.y(
                                    fraction: fraction, height: geometry.size.height)
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                            }
                        }.stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                        if let date = selection?.date, let fraction = timeline.fraction(for: date) {
                            verticalGuide(x: PowerTrendGeometry.clampedX(geometry.size.width * fraction,
                                                                         width: geometry.size.width, inset: 1),
                                          height: geometry.size.height)
                                .stroke(accent.opacity(0.45), lineWidth: 1)
                        }
                        line(size: geometry.size)
                            .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        // A single valid sample, or isolated samples around gaps,
                        // would otherwise be invisible as a move-only path.
                        Path { path in
                            for index in points.indices {
                                let point = points[index]
                                let before = index > 0 && points[index - 1].segment == point.segment
                                let after = index + 1 < points.count && points[index + 1].segment == point.segment
                                if timeline.fraction(for: point.date) != nil && !before && !after {
                                    let position = position(point, size: geometry.size)
                                    path.addEllipse(in: CGRect(x: position.x - 2, y: position.y - 2, width: 4, height: 4))
                                }
                            }
                        }.fill(accent)
                        if case .sample(let date) = selection,
                           timeline.fraction(for: date) != nil,
                           let point = points.first(where: { $0.date == date }) {
                            let dot = position(point, size: geometry.size)
                            Circle().fill(accent).frame(width: 6, height: 6)
                                .position(x: PowerTrendGeometry.clampedX(dot.x, width: geometry.size.width, inset: 3),
                                          y: dot.y)
                        }
                        ForEach(markers) { marker in
                            eventMarker(marker, height: geometry.size.height)
                        }
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        onSelect?(selection(at: tap.location, width: geometry.size.width, markers: markers))
                    }, including: onSelect == nil ? .none : .all)
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
        .accessibilityLabel(ChipBarLocale.choose("Power trend", "功率趋势"))
        .accessibilityValue(ChipBarLocale.format("%d valid samples, %d power events",
                                                 "%d 个有效采样，%d 个电源事件",
                                                 points.count, events.count))
    }

    private func eventMarker(_ marker: PowerTrendGeometry.EventMarker, height: CGFloat) -> some View {
        let event = marker.event
        let selected = selection == .event(event.date)
        let color = event.kind.tint
        return ZStack {
            verticalGuide(x: marker.guideX, height: height)
                .stroke(color.opacity(selected ? 0.8 : 0.48),
                        style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: [3, 3]))
            if let position = marker.symbolPosition {
                if showsEventSymbols {
                    Image(systemName: event.kind.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 16, height: 16)
                        .background(.regularMaterial, in: Circle())
                        .position(position)
                } else {
                    Circle().fill(color).frame(width: 4, height: 4)
                        .position(position)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func verticalGuide(x: CGFloat, height: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: x, y: 5))
            path.addLine(to: CGPoint(x: x, y: height - 3))
        }
    }

    private func selection(at location: CGPoint, width: CGFloat,
                           markers: [PowerTrendGeometry.EventMarker]) -> PowerHistorySelection? {
        guard width > 0 else { return nil }
        if let date = PowerTrendGeometry.event(at: location, in: markers, showsSymbols: showsEventSymbols) {
            return .event(date)
        }
        let date = timeline.start.addingTimeInterval(location.x / width * TrendTimeWindow.duration)
        let point = points.filter { timeline.fraction(for: $0.date) != nil }.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
        guard let point,
              abs(position(point, size: CGSize(width: width, height: 0)).x - location.x) <= 12
        else { return nil }
        return .sample(point.date)
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
                guard timeline.fraction(for: point.date) != nil else { continue }
                let position = position(point, size: size)
                if previousSegment == point.segment { path.addLine(to: position) }
                else { path.move(to: position) }
                previousSegment = point.segment
            }
        }
    }
}
