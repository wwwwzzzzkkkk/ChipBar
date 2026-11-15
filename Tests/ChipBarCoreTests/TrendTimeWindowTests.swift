import Foundation
import Testing
@testable import ChipBarCore

struct TrendTimeWindowTests {
    private let singapore = TimeZone(secondsFromGMT: 8 * 3600)!

    @Test func usesExactlyTenMinutesRegardlessOfNumberOfSamples() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let axis = TrendTimeWindow(endingAt: end)
        #expect(axis.end.timeIntervalSince(axis.start) == 600)
        #expect(axis.midpoint.timeIntervalSince(axis.start) == 300)
        #expect(axis.ticks.count == 3)
        #expect(axis.fraction(for: axis.start) == 0)
        #expect(axis.fraction(for: axis.midpoint) == 0.5)
        #expect(axis.fraction(for: axis.end) == 1)

        // One minute of startup samples must use only the rightmost 10%.
        let sample = end.addingTimeInterval(-60)
        #expect(abs((axis.fraction(for: sample) ?? 0) - 0.9) < 0.00001)
        #expect(axis.fraction(for: end.addingTimeInterval(-601)) == nil)
        #expect(axis.fraction(for: end.addingTimeInterval(1)) == nil)
    }

    @Test func labelsShowLocalTwentyFourHourClockAcrossMidnight() throws {
        let formatter = ISO8601DateFormatter()
        let end = try #require(formatter.date(from: "2026-10-28T16:03:00Z"))
        let axis = TrendTimeWindow(endingAt: end)
        #expect(axis.ticks.map { TrendTimeWindow.clockLabel($0, timeZone: singapore) }
                == ["23:53", "23:58", "00:03"])
    }

    @Test func labelsShowHoursRatherThanConfusingMinutesAndSeconds() throws {
        let formatter = ISO8601DateFormatter()
        let end = try #require(formatter.date(from: "2026-10-28T00:08:59Z"))
        let axis = TrendTimeWindow(endingAt: end)
        #expect(TrendTimeWindow.clockLabel(axis.end, timeZone: singapore) == "08:08")
        #expect(TrendTimeWindow.clockLabel(axis.start, timeZone: singapore) == "07:58")
        #expect(TrendTimeWindow.clockLabel(end.addingTimeInterval(-75),
                                           timeZone: singapore) == "08:07")
    }
}
