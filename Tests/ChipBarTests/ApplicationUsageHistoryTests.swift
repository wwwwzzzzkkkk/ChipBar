import Foundation
import Testing
import ChipBarCore
@testable import ChipBar

struct ApplicationUsageHistoryTests {
    private let date = Date(timeIntervalSince1970: 1_795_400_000)

    @Test func ranksApplicationsByEachMetricAndKeepsHistoricalSamples() throws {
        var counters = ActivityAccumulator()
        let baseline = processes(cpu: [0, 0, 0, 0, 0])
        _ = counters.update(processes: baseline, clients: [], time: 10)
        let earlier = counters.update(processes: processes(cpu: [2, 4, 1, 3, 7]), clients: [], time: 15)
        let later = counters.update(processes: processes(cpu: [8, 4, 2, 3, 14]), clients: [], time: 20)
        let laterDate = date.addingTimeInterval(5)
        let window = TrendTimeWindow(endingAt: laterDate)
        var history = ApplicationUsageHistory()
        let recordedEarlier = history.record(snapshot(earlier, at: 15), at: date, includesCPU: true)
        let recordedLater = history.record(snapshot(later, at: 20), at: laterDate, includesCPU: true)
        #expect(recordedEarlier)
        #expect(recordedLater)
        let first = try #require(history.nearest(to: date.addingTimeInterval(1), in: window))
        let second = try #require(history.nearest(to: laterDate, in: window))
        #expect(first.date == date)
        #expect(first.cpu.map(\.name) == ["App 2", "App 4", "App 1"])
        #expect(first.cpu.first?.cpuPercent == 80)
        #expect(first.memory.map(\.name) == ["App 4", "App 3", "App 2"])
        #expect(second.cpu.first?.name == "App 1")
        #expect(second.cpu.first?.cpuPercent == 120)
        #expect(history.nearest(to: date.addingTimeInterval(-8), in: window) == nil)
    }

    @Test func skipsExtraSamplesAndDropsOldFramesWithoutFillingGaps() throws {
        var counters = ActivityAccumulator()
        let rows = counters.update(processes: processes(cpu: [0, 0, 0, 0, 0]), clients: [], time: 10)
        var history = ApplicationUsageHistory()
        let started = history.record(snapshot(rows, at: 10), at: date, includesCPU: false)
        let extra = history.record(snapshot(rows, at: 12), at: date.addingTimeInterval(2), includesCPU: true)
        #expect(started)
        #expect(!extra)
        let end = date.addingTimeInterval(601)
        let resumed = history.record(snapshot(rows, at: 611), at: end, includesCPU: false)
        #expect(resumed)
        #expect(history.nearest(to: date, in: .init(endingAt: date)) == nil)
        let afterGap = try #require(history.nearest(to: end, in: .init(endingAt: end)))
        #expect(afterGap.cpu.isEmpty)
        #expect(afterGap.memory.count == 3)
    }

    private func processes(cpu: [Double]) -> [ActivityProcess] {
        cpu.enumerated().map { offset, seconds in
            let index = offset + 1
            return ActivityProcess(pid: Int32(index), birth: 1, group: "app-\(index)", name: "App \(index)",
                                   appPath: index == 5 ? nil : "/Applications/App \(index).app",
                                   cpuSeconds: seconds, physicalBytes: UInt64(index) * 1_000_000)
        }
    }

    private func snapshot(_ rows: [ApplicationActivityRow], at uptime: TimeInterval) -> ActivitySnapshot {
        ActivitySnapshot(sampledAt: uptime, rows: rows, processCount: rows.count, readableCPUCount: rows.count,
                         readableMemoryCount: rows.count, approximateMemoryCount: 0, gpuClientCount: 0,
                         gpuSampled: false, neuralSupported: false)
    }
}
