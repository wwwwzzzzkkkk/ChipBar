import Foundation
import CoreGraphics
import Testing
import ChipBarCore
@testable import ChipBar

struct PowerHistoryEventTests {
    private let start = Date(timeIntervalSince1970: 1_795_400_000)

    private func reading(adapter: Bool, batteryWatts: Double?, hasBattery: Bool = true) -> ChipBarPowerReading {
        ChipBarPowerReading(hasBattery: hasBattery, onAdapter: adapter,
                           isCharging: (batteryWatts ?? 0) > 0, batteryPercent: 78,
                           adapterWatts: adapter ? 47.4 : nil, batteryWatts: batteryWatts,
                           systemWatts: 17.4, sourceLabel: "", live: batteryWatts != nil)
    }

    @Test func capturesTransitionsWithTheirOriginalWatts() throws {
        var history = PowerHistoryEvents()
        let battery = reading(adapter: false, batteryWatts: -22.7)
        let connected = reading(adapter: true, batteryWatts: 30)
        let assist = reading(adapter: true, batteryWatts: -11.897)
        let chip = try Sample.decode(Data(#"{"all_power":5.4948}"#.utf8),
                                     receivedAt: start.addingTimeInterval(7))
        let readings = [battery, connected, assist, assist, battery]
        for (index, reading) in readings.enumerated() {
            history.record(reading, at: start.addingTimeInterval(Double(index * 3) + 2),
                           chipSample: chip, maximumChipAge: 3)
        }
        #expect(history.events.map(\.kind) == [.connected, .batteryAssisted, .disconnected])
        #expect(history.events[0].reading.batteryWatts == 30)
        #expect(history.events[1].reading.batteryWatts == -11.897)
        #expect(history.events[1].chipSample?.total == 5.4948)
        #expect(history.events[0].chipSample == nil)
        #expect(history.events[2].chipSample == nil)
        #expect(history.events[2].reading.adapterWatts == nil)
    }

    @Test func plugInWhileAssistingSharesOneTimestamp() {
        var history = PowerHistoryEvents()
        history.record(reading(adapter: false, batteryWatts: -20), at: start,
                       chipSample: nil, maximumChipAge: 3)
        history.record(reading(adapter: true, batteryWatts: -10), at: start.addingTimeInterval(3),
                       chipSample: nil, maximumChipAge: 3)
        #expect(history.events.map(\.kind) == [.connectedWithBatteryAssist])
    }

    @Test func missingPowerDoesNotDuplicateEventsAndVeryOldEventsExpire() {
        var history = PowerHistoryEvents()
        for (index, watts) in [0.0, -3.0, nil, -4.0, 0.0, -2.0].enumerated() {
            history.record(reading(adapter: true, batteryWatts: watts),
                           at: start.addingTimeInterval(Double(index * 3)),
                           chipSample: nil, maximumChipAge: 3)
        }
        #expect(history.events.map(\.kind) == [.batteryAssisted, .batteryAssisted])
        history.record(reading(adapter: true, batteryWatts: -5),
                       at: start.addingTimeInterval(604), chipSample: nil, maximumChipAge: 3)
        #expect(history.events.map(\.date) == [start.addingTimeInterval(15)])
    }

    @Test func sleepGapsResetsAndDesktopDoNotInventEvents() {
        var history = PowerHistoryEvents()
        let laptop = reading(adapter: false, batteryWatts: nil)
        let connected = reading(adapter: true, batteryWatts: nil)
        let desktop = reading(adapter: true, batteryWatts: nil, hasBattery: false)
        history.record(laptop, at: start, chipSample: nil, maximumChipAge: 3)
        history.record(connected, at: start.addingTimeInterval(60), chipSample: nil, maximumChipAge: 3)
        history.resetContinuity()
        history.record(laptop, at: start.addingTimeInterval(63), chipSample: nil, maximumChipAge: 3)
        history.record(desktop, at: start.addingTimeInterval(66), chipSample: nil, maximumChipAge: 3)
        history.record(connected, at: start.addingTimeInterval(69), chipSample: nil, maximumChipAge: 3)
        #expect(history.events.isEmpty)
        history.record(laptop, at: start.addingTimeInterval(72), chipSample: nil, maximumChipAge: 3)
        #expect(history.events.map(\.kind) == [.disconnected])
    }

    @Test func eventBeyondLastChipSampleKeepsChartAndAverageInWindow() throws {
        let old = try Sample.decode(Data(#"{"all_power":20}"#.utf8), receivedAt: start)
        let recent = try Sample.decode(Data(#"{"all_power":4}"#.utf8),
                                       receivedAt: start.addingTimeInterval(599))
        let chart = PowerChartSnapshot.build(history: [old, recent], intervalMillis: 2000)
        let newTime = start.addingTimeInterval(601)
        let event = PowerHistoryEvent(date: newTime, kind: .connected,
                                     reading: reading(adapter: true, batteryWatts: 0),
                                     chipSample: nil)
        let advanced = chart.including([event])
        #expect(advanced.timeline.end == newTime)
        #expect(advanced.points.map(\.power) == [4])
        #expect(advanced.average == 4)
    }

    @Test func nearbyEventSymbolsRemainIndividuallySelectable() throws {
        let end = start.addingTimeInterval(9)
        let timeline = TrendTimeWindow(endingAt: end)
        let events = [PowerHistoryEventKind.connected, .batteryAssisted, .disconnected]
            .enumerated().map { index, kind in
                PowerHistoryEvent(date: start.addingTimeInterval(Double(index * 3)), kind: kind,
                                  reading: reading(adapter: true, batteryWatts: 0), chipSample: nil)
            }
        let markers = PowerTrendGeometry.eventMarkers(events, timeline: timeline, width: 400, showsSymbols: true)
        #expect(markers.map(\.guideX) == [394, 396, 398])
        let positions = try markers.map { try #require($0.symbolPosition) }
        #expect(Set(positions.map(\.y)).count == 3)
        for (event, position) in zip(events, positions) {
            #expect(PowerTrendGeometry.event(at: position, in: markers, showsSymbols: true) == event.date)
        }
    }
}
