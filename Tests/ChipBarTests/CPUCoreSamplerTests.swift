import Darwin
import Testing
@testable import ChipBar

struct CPUCoreSamplerTests {
    @Test func calculatesIndependentBusyTimePerLogicalCore() throws {
        // Mach tick order: USER, SYSTEM, IDLE, NICE
        let old = CPUCoreTickSample(ticks: [[100, 10, 200, 0], [100, 10, 200, 0]])
        let now = CPUCoreTickSample(ticks: [[150, 40, 220, 0], [110, 20, 280, 0]])
        let usage = try #require(CPUCoreTickSample.usage(previous: old, current: now))
        #expect(usage.count == 2)
        #expect(abs(usage[0] - 80) < 0.001)
        #expect(abs(usage[1] - 20) < 0.001)
    }

    @Test func handlesZeroElapsedTicksAndCounterWrap() throws {
        let start = CPUCoreTickSample(ticks: [[UInt32.max - 4, 0, 0, 0]])
        let end = CPUCoreTickSample(ticks: [[5, 0, 10, 0]])
        let usage = try #require(CPUCoreTickSample.usage(previous: start, current: end))
        #expect(usage.count == 1)
        #expect(usage[0] >= 0 && usage[0] <= 100)
        let idle = try #require(CPUCoreTickSample.usage(previous: start, current: start))
        #expect(idle == [0])
    }

    @Test func ignoresChangedProcessorTopology() {
        #expect(CPUCoreTickSample.usage(
            previous: CPUCoreTickSample(ticks: [[0, 0, 0, 0]]),
            current: CPUCoreTickSample(ticks: [[0, 0, 0, 0], [0, 0, 0, 0]])) == nil)
    }

    @Test func macOSCanReadPerCoreTicksWithoutPrivileges() async {
        let sampler = CPUCoreSampler()
        #expect(await sampler.read() == nil)
        try? await Task.sleep(for: .milliseconds(30))
        if let values = await sampler.read() {
            #expect(!values.isEmpty)
            #expect(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 100 })
        }
    }
}
