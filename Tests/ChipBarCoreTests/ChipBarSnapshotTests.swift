import Foundation
import Testing
@testable import ChipBarCore

struct ChipBarSnapshotTests {
    @Test func previewHasExactlyFortyPowerSamplesAndFifteenCores() {
        let sample = ChipBarSnapshot.preview
        #expect(sample.chipPower == 11.6)
        #expect(sample.avgPower == 6.2)
        #expect(sample.cpu.percent == 29)
        #expect(sample.gpu.percent == 42)
        #expect(sample.mem.percent == 84)
        #expect(sample.powerSeries.count == 40)
        #expect(sample.cores.count == 15)
        #expect(sample.performanceCoreCount == 10)
        #expect(sample.volumes.count == 2)
        #expect(sample.volumes[0].freeBytes == 142_230_000_000)
        #expect(sample.volumes[1].freeBytes == 1_370_000_000_000)
    }

    @Test func roundTripPreservesOptionalPowerAndVolumeData() throws {
        var sample = ChipBarSnapshot.preview
        sample.internalPower = nil
        sample.volumes[0].readMBs = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let copied = try decoder.decode(ChipBarSnapshot.self, from: encoder.encode(sample))
        #expect(copied.internalPower == nil)
        #expect(copied.volumes[0].readMBs == nil)
        #expect(copied.powerSeries.count == 40)
        #expect(copied.cores.count == 15)
    }

    @Test func staleAtThreeMinutesAndOneSecond() {
        let sample = ChipBarSnapshot.preview
        #expect(!sample.isStale(at: sample.timestamp.addingTimeInterval(179)))
        #expect(sample.isStale(at: sample.timestamp.addingTimeInterval(181)))
    }

    @Test func capacityFractionsClampAndNeverOverflow() {
        let volume = ChipBarSnapshot.Volume(
            name: "Empty", freeBytes: 250, totalBytes: 100,
            readMBs: nil, writeMBs: nil)
        #expect(volume.usedPercent == 0)
        let full = ChipBarSnapshot.Volume(
            name: "Full", freeBytes: 0, totalBytes: 100,
            readMBs: nil, writeMBs: nil)
        #expect(full.usedPercent == 100)
    }

    @Test func originalAndNewKindsAreDifferent() {
        #expect(ChipBarSnapshotStore.newOverviewKind == "ChipBar.Overview")
        #expect(ChipBarSnapshotStore.newStorageKind == "ChipBar.Storage")
        #expect(ChipBarSnapshotStore.newOverviewKind != "local.chipbar.telemetry.overview")
        #expect(ChipBarSnapshotStore.newStorageKind != "local.chipbar.telemetry.storage")
    }
}
