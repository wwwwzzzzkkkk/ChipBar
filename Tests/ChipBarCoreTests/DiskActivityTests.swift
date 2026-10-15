import Testing
@testable import ChipBarCore

struct DiskActivityTests {
    @Test func ratesUseRealIntervalAndResetForReplacementOrMissingDisk() throws {
        var accumulator = DiskRateAccumulator()
        func counters(_ identity: UInt64 = 1, _ read: UInt64, _ write: UInt64) -> [String: DiskCounters] {
            ["disk4": DiskCounters(identity: identity, readBytes: read, writtenBytes: write)]
        }
        #expect(accumulator.update(counters(1, 0, 0), time: 10).isEmpty)
        let rate = try #require(accumulator.update(counters(1, 4_000_000, 1_000_000), time: 12)["disk4"])
        #expect(rate.readMB == 2)
        #expect(rate.writeMB == 0.5)
        #expect(accumulator.update(counters(2, 9_000_000, 9_000_000), time: 14).isEmpty)
        #expect(accumulator.update(counters(2, 0, 0), time: 16).isEmpty)
        #expect(accumulator.update([:], time: 18).isEmpty)
        #expect(accumulator.update(counters(2, 0, 0), time: 20).isEmpty)
        #expect(accumulator.update(counters(2, 0, 0), time: 22)["disk4"]?.readMB == 0)
        #expect(accumulator.update(counters(2, 10, 10), time: 40).isEmpty)
    }
    @Test func invalidSpaceIsUnavailableRatherThanZero() {
        #expect(DiskVolumeSpace(id: "v", name: "Zark", total: 0, available: 0, apfs: true) == nil)
        #expect(DiskVolumeSpace(id: "v", name: "Zark", total: 100, available: 101, apfs: true) == nil)
        #expect(DiskVolumeSpace(id: "v", name: "Zark", total: 100, available: -1, apfs: true) == nil)
        #expect(DiskVolumeSpace(id: "v", name: "Zark", total: 100, available: 0, apfs: true)?.availableFraction == 0)
    }
}
