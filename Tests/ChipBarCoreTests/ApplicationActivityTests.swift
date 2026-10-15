import Testing
@testable import ChipBarCore

struct ApplicationActivityTests {
    private func process(_ pid: Int32 = 1, birth: UInt64 = 10, cpu: Double? = 0, group: String = "App", neural: UInt64? = nil) -> ActivityProcess {
        ActivityProcess(pid: pid, birth: birth, group: group, name: group, cpuSeconds: cpu, neuralBytes: neural)
    }

    @Test func cpuUsesDeltasGroupsHelpersAndAllowsMultipleCores() {
        var model = ActivityAccumulator()
        let initial = model.update(processes: [process(cpu: 100), process(2, cpu: 10)], clients: [], time: 1)
        #expect(initial[0].cpuPercent == nil)
        let rows = model.update(processes: [process(cpu: 104), process(2, cpu: 11)], clients: [], time: 3)
        #expect(rows.count == 1)
        #expect(rows[0].cpuPercent == 250)
        #expect(rows[0].processCount == 2)
    }

    @Test func pidReuseCounterResetAndMissingReadRebaseline() {
        var model = ActivityAccumulator()
        _ = model.update(processes: [process(cpu: 100)], clients: [], time: 1)
        #expect(model.update(processes: [process(birth: 11, cpu: 200)], clients: [], time: 2)[0].cpuPercent == nil)
        #expect(model.update(processes: [process(birth: 11, cpu: 1)], clients: [], time: 3)[0].cpuPercent == nil)
        _ = model.update(processes: [], clients: [], time: 4)
        #expect(model.update(processes: [process(birth: 11, cpu: 3)], clients: [], time: 5)[0].cpuPercent == nil)
    }

    @Test func gpuClientsDeltaResetAndArrayShape() {
        var model = ActivityAccumulator()
        let p = process()
        _ = model.update(processes: [p], clients: [ActivityGPUClient(id: 1, pid: 1, nanoseconds: [9_000_000_000])], time: 1)
        let next = model.update(processes: [p], clients: [ActivityGPUClient(id: 1, pid: 1, nanoseconds: [9_500_000_000])], time: 2)
        #expect(next[0].gpuPercent == 50)
        #expect(model.update(processes: [p], clients: [ActivityGPUClient(id: 1, pid: 1, nanoseconds: [1])], time: 3)[0].gpuPercent == nil)
        #expect(model.update(processes: [p], clients: [ActivityGPUClient(id: 1, pid: 1, nanoseconds: [2, 5_000_000_000])], time: 4)[0].gpuPercent == nil)
        #expect(model.update(processes: [p], clients: [], time: 5)[0].gpuPercent == nil)
    }

    @Test func gpuOverlapAndNeuralMemoryAreNotClampedOrConfused() {
        var model = ActivityAccumulator()
        let p = process(neural: 1024)
        _ = model.update(processes: [p], clients: [ActivityGPUClient(id: 1, pid: 1, nanoseconds: [0, 0])], time: 1)
        let rows = model.update(processes: [p], clients: [ActivityGPUClient(id: 1, pid: 1, nanoseconds: [1_000_000_000, 1_000_000_000])], time: 2)
        #expect(rows[0].gpuPercent == 200)
        #expect(rows[0].neuralBytes == 1024)
    }

    @Test func longGapsAndReusedPidDoNotInheritGPUWork() {
        var model = ActivityAccumulator()
        let c = ActivityGPUClient(id: 1, pid: 1, nanoseconds: [1_000_000_000])
        _ = model.update(processes: [process()], clients: [c], time: 1)
        let newer = ActivityGPUClient(id: 1, pid: 1, nanoseconds: [2_000_000_000])
        #expect(model.update(processes: [process(birth: 11)], clients: [newer], time: 2)[0].gpuPercent == nil)
        let rows = model.update(processes: [process(birth: 11, cpu: 10)], clients: [newer], time: 100)
        #expect(rows[0].gpuPercent == nil)
        #expect(rows[0].cpuPercent == nil)
    }
}
