import Foundation
import ChipBarCore

/// Keep the visible rankings for the same rolling window as the power chart.
struct ApplicationUsageHistory {
    static let interval: TimeInterval = 5
    private let matchTolerance: TimeInterval = 5
    private let maximumFrames = Int(TrendTimeWindow.duration / interval) + 1

    struct Frame {
        let date: Date
        let cpu: [ApplicationActivityRow]
        let memory: [ApplicationActivityRow]
    }

    private var frames: [Frame] = []
    private var lastUptime: TimeInterval?

    mutating func record(_ snapshot: ActivitySnapshot, at date: Date, includesCPU: Bool) -> Bool {
        if let lastUptime, snapshot.sampledAt - lastUptime < Self.interval - 0.05 { return false }
        lastUptime = snapshot.sampledAt
        let apps = snapshot.rows.filter { $0.appPath != nil }
        frames.removeAll { $0.date > date || date.timeIntervalSince($0.date) > TrendTimeWindow.duration }
        frames.append(Frame(date: date,
                            cpu: includesCPU ? Self.topApps(apps, by: \.cpuPercent) : [],
                            memory: Self.topApps(apps) {
                                ApplicationMemoryDisplay.validatedBytes($0.physicalBytes).map(Double.init)
                            }))
        if frames.count > maximumFrames {
            frames.removeFirst(frames.count - maximumFrames)
        }
        return true
    }

    func nearest(to date: Date, in timeline: TrendTimeWindow) -> Frame? {
        guard timeline.fraction(for: date) != nil else { return nil }
        let matching = frames.filter {
            $0.date >= timeline.start && abs(date.timeIntervalSince($0.date)) <= matchTolerance
        }
        return matching.min {
            abs(date.timeIntervalSince($0.date)) < abs(date.timeIntervalSince($1.date))
        }
    }

    private static func topApps(_ apps: [ApplicationActivityRow],
                                by value: (ApplicationActivityRow) -> Double?) -> [ApplicationActivityRow] {
        let measured = apps.compactMap { row -> (row: ApplicationActivityRow, value: Double)? in
            guard let number = value(row), number.isFinite, number > 0 else { return nil }
            return (row, number)
        }
        return measured.sorted {
            $0.value == $1.value ? $0.row.id < $1.row.id : $0.value > $1.value
        }.prefix(3).map(\.row)
    }
}
