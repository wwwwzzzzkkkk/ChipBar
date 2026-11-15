import Testing
@testable import ChipBarCore

struct ApplicationActivityTests {
    @Test func applicationSnapshotsStayFreshForTenSeconds() {
        #expect(ApplicationActivityCachePolicy.isFresh(sampledAt: 100, now: 110))
        #expect(!ApplicationActivityCachePolicy.isFresh(sampledAt: 100, now: 110.001))
        #expect(!ApplicationActivityCachePolicy.isFresh(sampledAt: 100, now: 99.9))
    }

    private func process(_ pid: Int32 = 1, birth: UInt64 = 10, cpu: Double? = 0,
                         group: String = "App", neural: UInt64? = nil, physical: UInt64? = nil,
                         approximate: Bool = false) -> ActivityProcess {
        ActivityProcess(pid: pid, birth: birth, group: group, name: group,
                        cpuSeconds: cpu, neuralBytes: neural, physicalBytes: physical,
                        memoryIsRSSApproximation: approximate)
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

    @Test func physicalMemorySumsHelpersAndWorksOnFirstSample() {
        var model = ActivityAccumulator()
        let rows = model.update(processes: [
            process(1, cpu: nil, group: "Mail", physical: 900_000_000),
            process(2, cpu: nil, group: "Mail", physical: 200_000_000),
            process(3, cpu: nil, group: "Editor", physical: 125_000_000),
            process(4, cpu: nil, group: "Restricted")
        ], clients: [], time: 1)
        let mail = rows.first { $0.id == "Mail" }
        let editor = rows.first { $0.id == "Editor" }
        let restricted = rows.first { $0.id == "Restricted" }
        #expect(mail?.physicalBytes == 1_100_000_000)
        #expect(mail?.processCount == 2)
        #expect(mail?.cpuPercent == nil)
        #expect(editor?.physicalBytes == 125_000_000)
        #expect(restricted?.physicalBytes == nil)
    }

    @Test func physicalMemoryIsCurrentNotAccumulatedAndCannotOverflow() {
        var model = ActivityAccumulator()
        _ = model.update(processes: [process(1, physical: 600)], clients: [], time: 1)
        let next = model.update(processes: [process(1, physical: 900)], clients: [], time: 3)
        #expect(next.first?.physicalBytes == 900)
        let overflow = model.update(processes: [
            process(1, physical: UInt64.max),
            process(2, physical: 2)
        ], clients: [], time: 4)
        #expect(overflow.first?.physicalBytes == UInt64.max)
    }

    @Test func zeroFootprintsAreMissingNotFalseZeroMemory() {
        var model = ActivityAccumulator()
        let rows = model.update(processes: [
            process(1, group: "App", physical: 0),
            process(2, group: "App", physical: nil),
            process(3, group: "Other", physical: 12_000_000)
        ], clients: [], time: 1)
        #expect(rows.first { $0.id == "App" }?.physicalBytes == nil)
        #expect(rows.first { $0.id == "Other" }?.physicalBytes == 12_000_000)
    }

    @Test func rssFallbackSourcePropagatesAcrossHelperProcesses() {
        var model = ActivityAccumulator()
        let rows = model.update(processes: [
            process(1, group: "App", physical: 20_000_000),
            process(2, group: "App", physical: 40_000_000, approximate: true)
        ], clients: [], time: 1)
        #expect(rows.count == 1)
        #expect(rows[0].physicalBytes == 60_000_000)
        #expect(rows[0].memoryIsRSSApproximation)
    }

    @Test func memoryFormattingRejectsFakeZeroAndPreservesByteScale() {
        #expect(ApplicationMemoryDisplay.text(bytes: nil, approximate: false) == "—")
        #expect(ApplicationMemoryDisplay.text(bytes: 0, approximate: false) == "—")
        #expect(ApplicationMemoryDisplay.text(bytes: 12, approximate: false) == "—")
        #expect(ApplicationMemoryDisplay.text(bytes: 32_768, approximate: false) == "—")
        #expect(ApplicationMemoryDisplay.text(bytes: 65_536, approximate: false) == "65.5 KB")
        #expect(ApplicationMemoryDisplay.text(bytes: 374_700_000, approximate: false) == "374.7 MB")
        #expect(ApplicationMemoryDisplay.text(bytes: 1_100_000_000, approximate: true) == "≈1.10 GB")
    }

    @Test func memoryAggregationAndFormattingUseIdenticalBytes() {
        var model = ActivityAccumulator()
        let rows = model.update(processes: [
            process(1, group: "Chrome", physical: 455_500_000),
            process(2, group: "Chrome", physical: 1_100_000_000),
            process(3, group: "ChatGPT", physical: 374_700_000)
        ], clients: [], time: 1)
        let chrome = rows.first { $0.id == "Chrome" }
        #expect(chrome?.physicalBytes == 1_555_500_000)
        #expect(ApplicationMemoryDisplay.text(bytes: chrome?.physicalBytes,
            approximate: chrome?.memoryIsRSSApproximation ?? false) == "1.56 GB")
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
