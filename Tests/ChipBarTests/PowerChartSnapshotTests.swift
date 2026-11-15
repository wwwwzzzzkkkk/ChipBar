import Foundation
import Testing
@testable import ChipBar
import ChipBarCore

struct PowerChartSnapshotTests {
    private func sample(_ power: Double, at date: Date) throws -> Sample {
        let data = Data("{\"all_power\":\(power)}".utf8)
        return try Sample.decode(data, receivedAt: date)
    }

    @Test func cachedChartKeepsMeanMaxAndGapSegments() throws {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let samples = try [
            sample(10, at: start),
            sample(20, at: start.addingTimeInterval(2)),
            sample(30, at: start.addingTimeInterval(10))
        ]
        let result = PowerChartSnapshot.build(history: samples, intervalMillis: 2000)
        #expect(result.points.count == 3)
        #expect(result.points.map(\.segment) == [0, 0, 1])
        #expect(result.average == 20)
        #expect(abs(result.maximum - 34.5) < 0.001)
        #expect(result.timeline.end == samples.last?.date)
    }

    @Test func subWattChartsPreserveMinimumYScale() throws {
        let at = Date(timeIntervalSince1970: 1_720_000_000)
        let result = PowerChartSnapshot.build(
            history: try [sample(0.2, at: at)], intervalMillis: 2000)
        #expect(result.maximum == 1)
    }

    @Test func cachedChartExcludesOutOfWindowPointsButRetainsWindowStatistics() throws {
        let end = Date(timeIntervalSince1970: 1_720_000_800)
        let samples = try [
            sample(5, at: end.addingTimeInterval(-700)),
            sample(15, at: end)
        ]
        let result = PowerChartSnapshot.build(history: samples, intervalMillis: 2000)
        #expect(result.points.count == 1)
        #expect(result.points.first?.power == 15)
        #expect(result.average == 10)
    }
}
