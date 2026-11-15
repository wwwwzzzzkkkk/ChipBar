import Foundation
import Testing
import ChipBarCore
@testable import ChipBar

struct DiskMenuTests {
    let now = Date(timeIntervalSince1970: 1_000)

    func snapshot() -> DiskActivitySnapshot {
        var accumulator = DiskRateAccumulator()
        _ = accumulator.update([
            "disk0": DiskCounters(identity: 1, readBytes: 0, writtenBytes: 0),
            "disk4": DiskCounters(identity: 4, readBytes: 0, writtenBytes: 0),
            "disk5": DiskCounters(identity: 5, readBytes: 0, writtenBytes: 0)
        ], time: 1)
        let rates = accumulator.update([
            "disk0": DiskCounters(identity: 1, readBytes: 100_000_000, writtenBytes: 20_000_000),
            "disk4": DiskCounters(identity: 4, readBytes: 40_000_000, writtenBytes: 8_000_000),
            "disk5": DiskCounters(identity: 5, readBytes: 10_000_000, writtenBytes: 4_000_000)
        ], time: 2)
        return DiskActivitySnapshot(rates: rates, connected: ["disk0", "disk4", "disk5"],
                                    external: ["disk4", "disk5"], date: now)
    }

    @Test func externalColumnExcludesInternalDiskAndSumsExternalDisks() {
        let data = snapshot()
        let total = data.menuRates(at: now)
        let external = data.menuRates(externalOnly: true, at: now)
        #expect(total.read == 150_000_000)
        #expect(total.write == 32_000_000)
        #expect(external.read == 50_000_000)
        #expect(external.write == 12_000_000)
        #expect(data.externalMenuReadout(at: now) ==
                MenuReadout("externalDisk", "ER 50.0M/s", "EW 12.0M/s", pairedValues: true))
    }

    @Test func noExternalDiskOrDisconnectedDiskDoesNotLeaveAColumn() {
        var data = snapshot()
        data.external = []
        #expect(data.externalMenuReadout(at: now) == nil)
        data.external = ["disk4"]
        data.connected = ["disk0"]
        #expect(data.externalMenuReadout(at: now) == nil)
        #expect(data.menuRates(externalOnly: true, at: now).read == nil)
        #expect(data.menuRates(at: now).read == 100_000_000)
    }

    @Test func unknownCountersAndStaleDataAreNotReportedAsZero() {
        var data = snapshot()
        data.rates = [:]
        #expect(data.externalMenuReadout(at: now)?.top == "ER —")
        data = snapshot()
        let later = now.addingTimeInterval(7)
        #expect(data.menuRates(at: later).read == nil)
        #expect(data.externalMenuReadout(at: later)?.bottom == "EW —")
        #expect(data.externalMenuReadout(at: later, maximumAge: 30)?.top == "ER 50.0M/s")
    }

    @Test func measuredIdleDiskStillReportsZero() {
        var accumulator = DiskRateAccumulator()
        let counters = ["disk4": DiskCounters(identity: 4, readBytes: 10, writtenBytes: 20)]
        _ = accumulator.update(counters, time: 1)
        let rates = accumulator.update(counters, time: 2)
        let data = DiskActivitySnapshot(rates: rates, connected: ["disk4"], external: ["disk4"], date: now)
        #expect(data.externalMenuReadout(at: now)?.top == "ER 0B/s")
        #expect(data.externalMenuReadout(at: now)?.bottom == "EW 0B/s")
    }

    @Test func tenSecondIntervalAllowsSchedulerToleranceButLongGapsReset() {
        var accumulator = DiskRateAccumulator()
        _ = accumulator.update(["disk4": DiskCounters(identity: 4, readBytes: 0, writtenBytes: 0)], time: 10)
        let rates = accumulator.update([
            "disk4": DiskCounters(identity: 4, readBytes: 10_100_000, writtenBytes: 20_200_000)
        ], time: 20.1)
        #expect(abs((rates["disk4"]?.readMB ?? -1) - 1) < 0.0001)
        #expect(abs((rates["disk4"]?.writeMB ?? -1) - 2) < 0.0001)
        #expect(accumulator.update([
            "disk4": DiskCounters(identity: 4, readBytes: 10_100_000, writtenBytes: 20_200_000)
        ], time: 35.2).isEmpty)
    }
}
