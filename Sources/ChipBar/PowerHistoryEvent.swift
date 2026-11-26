import Foundation
import ChipBarCore

enum PowerHistoryEventKind: Hashable {
    case connected
    case disconnected
    case batteryAssisted
    case connectedWithBatteryAssist
}

struct PowerHistoryEvent: Identifiable {
    var id: Date { date }
    let date: Date
    let kind: PowerHistoryEventKind
    let reading: ChipBarPowerReading
    let chipSample: Sample?
}

enum PowerHistorySelection: Equatable {
    case event(Date)
    case sample(Date)

    var date: Date {
        switch self {
        case .event(let date), .sample(let date): return date
        }
    }
}

/// The power rail has its own sampling clock. Capture the reading that
/// detected each transition so opening the timeline later can't change it.
struct PowerHistoryEvents {
    private struct State {
        let date: Date
        let onAdapter: Bool
        let assisted: Bool?
    }

    private var previous: State?
    private(set) var events: [PowerHistoryEvent] = []

    mutating func resetContinuity() { previous = nil }

    @discardableResult
    mutating func record(_ reading: ChipBarPowerReading, at date: Date,
                         chipSample: Sample?, maximumChipAge: TimeInterval) -> Bool {
        let previousCount = events.count
        events.removeAll { date.timeIntervalSince($0.date) > TrendTimeWindow.duration || $0.date > date }
        let pruned = events.count != previousCount
        guard reading.hasBattery else {
            resetContinuity()
            return pruned
        }

        let prior = previous.flatMap { state in
            let elapsed = date.timeIntervalSince(state.date)
            return elapsed > 0 && elapsed <= Double(PowerSamplingCadence.seconds) * 3 ? state : nil
        }
        let watts = reading.batteryWatts.flatMap { $0.isFinite ? $0 : nil }
        let observedAssist = watts.map { $0 < PowerSourceMode.batteryAssistThreshold }
        let assisted = reading.onAdapter ? observedAssist ??
            (prior?.onAdapter == true ? prior?.assisted : nil) : false
        previous = State(date: date, onAdapter: reading.onAdapter, assisted: assisted)
        guard let prior else { return pruned }

        let kind: PowerHistoryEventKind
        switch (prior.onAdapter, reading.onAdapter) {
        case (false, true):
            kind = assisted == true ? .connectedWithBatteryAssist : .connected
        case (true, false): kind = .disconnected
        case (true, true) where prior.assisted == false && observedAssist == true:
            kind = .batteryAssisted
        default: return pruned
        }

        let freshChipSample = chipSample.flatMap { sample in
            let age = date.timeIntervalSince(sample.date)
            return (0...maximumChipAge).contains(age) && sample.total != nil ? sample : nil
        }
        events.append(PowerHistoryEvent(date: date, kind: kind, reading: reading,
                                        chipSample: freshChipSample))
        return true
    }
}
