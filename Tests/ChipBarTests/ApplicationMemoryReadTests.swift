import Darwin
import Foundation
import Testing
import ChipBarCore
@testable import ChipBar

struct ApplicationMemoryReadTests {
    @Test func currentProcessMustHaveNonzeroMemory() {
        // Core-only fixtures cannot detect an OS returning 0 for every
        // ri_phys_footprint. Run the real reader on the macOS CI machine.
        let reading = ProcessMemoryReader.read(pid: getpid(), initialFootprint: nil)
        #expect(reading.bytes != nil)
        #expect((reading.bytes ?? 0) > 1_000_000)
    }

    @Test func knownFootprintIsPreferredWithoutApproximation() {
        let reading = ProcessMemoryReader.read(pid: getpid(), initialFootprint: 128_000_000)
        #expect(reading.bytes == 128_000_000)
        #expect(!reading.approximate)
    }

    @Test func tinyPositiveFootprintsAreRejected() {
        // Regression: on the reported M5 Pro system the UI showed 0.0 KB
        // for Chrome, ChatGPT, etc. A positive single-digit libproc value
        // must not bypass the alternative memory readers.
        #expect(!ProcessMemoryReader.isPlausible(nil))
        #expect(!ProcessMemoryReader.isPlausible(0))
        #expect(!ProcessMemoryReader.isPlausible(1))
        #expect(!ProcessMemoryReader.isPlausible(42))
        #expect(!ProcessMemoryReader.isPlausible(32_768))
        #expect(ProcessMemoryReader.isPlausible(65_536))
    }

    @Test func tinyReportedFootprintFallsBackToRealMemory() {
        let result = ProcessMemoryReader.read(pid: getpid(), initialFootprint: 1)
        #expect((result.bytes ?? 0) > 1_000_000)
    }

    @Test func actualV6FootprintIsValidatedAgainstPlausibleBytes() {
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V6,
                UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        let rawFootprint: UInt64? = status == 0 ? usage.ri_phys_footprint : nil
        let result = ProcessMemoryReader.read(pid: getpid(), initialFootprint: rawFootprint)
        #expect((result.bytes ?? 0) > 1_000_000)
        #expect(ProcessMemoryReader.isPlausible(result.bytes))
    }

    @Test func invalidProcessDoesNotCreateFakeMemory() {
        let reading = ProcessMemoryReader.read(pid: -1, initialFootprint: nil)
        #expect(reading.bytes == nil)
        #expect(!reading.approximate)
    }

    @Test func cpuMemoryAndANERankingsSkipExpensiveGPUWalk() async {
        let snapshot = await ApplicationActivitySampler().sample(includeGPU: false)
        #expect(!snapshot.gpuSampled)
        #expect(snapshot.gpuClientCount == 0)
        #expect(snapshot.rows.allSatisfy { $0.gpuPercent == nil })
        #expect(snapshot.readableCPUCount > 0)
        #expect(snapshot.readableMemoryCount > 0)
    }

    @Test func switchingToGPUForcesFreshRegistryScan() {
        let now: TimeInterval = 100
        let rows: [ChipBarCore.ApplicationActivityRow] = []
        let cpuOnly = ActivitySnapshot(sampledAt: now, rows: rows, processCount: 0,
            readableCPUCount: 0, readableMemoryCount: 0, approximateMemoryCount: 0,
            gpuClientCount: 0, gpuSampled: false, neuralSupported: false)
        #expect(!ApplicationActivitySamplingPolicy.needsRefresh(cpuOnly, includeGPU: false, now: now))
        #expect(ApplicationActivitySamplingPolicy.needsRefresh(cpuOnly, includeGPU: true, now: now))

        let gpuReady = ActivitySnapshot(sampledAt: now, rows: rows, processCount: 0,
            readableCPUCount: 0, readableMemoryCount: 0, approximateMemoryCount: 0,
            gpuClientCount: 0, gpuSampled: true, neuralSupported: false)
        #expect(!ApplicationActivitySamplingPolicy.needsRefresh(gpuReady, includeGPU: true, now: now))
        #expect(ApplicationActivitySamplingPolicy.needsRefresh(gpuReady, includeGPU: true, now: now + 11))
    }

    @Test func liveApplicationScanContainsNonzeroMemory() async {
        let snapshot = await ApplicationActivitySampler().sample()
        #expect(snapshot.readableMemoryCount > 0)
        #expect(snapshot.rows.contains { ($0.physicalBytes ?? 0) > 1_000_000 })
        #expect(snapshot.rows.allSatisfy { $0.physicalBytes == nil || ($0.physicalBytes ?? 0) >= ProcessMemoryReader.minimumPlausibleBytes })
    }
}
