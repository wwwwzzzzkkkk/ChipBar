import Foundation
import ChipBarCore

/// Immutable 10-minute graph data, computed once per incoming macmon sample
/// while the dashboard is visible. SwiftUI renders it without rescanning all
/// 600 historical records for every independent preference/disk notification.
struct PowerChartSnapshot {
    let points: [PowerTrendPlot.Point]
    let maximum: Double
    let average: Double?
    let timeline: TrendTimeWindow

    func including(_ events: [PowerHistoryEvent]) -> Self {
        guard let latest = events.last?.date, latest > timeline.end else { return self }
        let window = TrendTimeWindow(endingAt: latest)
        let visible = points.filter { window.fraction(for: $0.date) != nil }
        guard visible.count != points.count else {
            return Self(points: points, maximum: maximum, average: average, timeline: window)
        }
        let values = visible.map(\.power)
        return Self(points: visible, maximum: max(1, (values.max() ?? 1) * 1.15),
                    average: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
                    timeline: window)
    }

    static var empty: Self {
        Self(points: [], maximum: 1, average: nil,
             timeline: TrendTimeWindow(endingAt: Date()))
    }

    static func build(history: [Sample], intervalMillis: Int) -> Self {
        let timeline = TrendTimeWindow(endingAt: history.last?.date ?? Date())
        var previous: Sample?
        var segment = 0
        var points: [PowerTrendPlot.Point] = []
        points.reserveCapacity(history.count)
        var sum = 0.0
        var count = 0
        var maximumObserved: Double?
        let gap = Double(intervalMillis) / 1_000 * 2.5

        for sample in history {
            // Retain the exact original mean/max semantics; only plotted
            // samples are restricted to the visible ten-minute time domain.
            if let power = sample.total {
                sum += power
                count += 1
                maximumObserved = max(maximumObserved ?? power, power)
            }
            guard timeline.fraction(for: sample.date) != nil else {
                previous = nil
                continue
            }
            if let previous,
               sample.date.timeIntervalSince(previous.date) > gap ||
               previous.total == nil {
                segment += 1
            }
            if let power = sample.total {
                points.append(.init(date: sample.date, power: power, segment: segment))
            }
            previous = sample
        }

        // Match the pre-cache axis rule exactly, including sub-1 W values.
        let maximum = max(1, (maximumObserved ?? 1) * 1.15)
        return Self(points: points, maximum: maximum,
                    average: count == 0 ? nil : sum / Double(count),
                    timeline: timeline)
    }
}
