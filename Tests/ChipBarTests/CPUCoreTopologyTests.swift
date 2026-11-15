import Testing
@testable import ChipBar

struct CPUCoreTopologyTests {
    @Test func verifiedSuperAndPerformanceClustersKeepDistinctNames() {
        let topology = CPUCoreTopology.verifiedLabels(
            levels: [CPUCoreTier(name: "Super", count: 2),
                     CPUCoreTier(name: "Performance", count: 3)],
            clusterTypesByID: [0: "P", 1: "P", 2: "M", 3: "M", 4: "M"],
            logicalCPUCount: 5)
        #expect(topology[0] == "超级核")
        #expect(topology[1] == "超级核")
        #expect(topology[2] == "性能核")
        #expect(topology.count == 5)
    }

    @Test func traditionalPerformanceEfficiencyDeviceMapsBothClasses() {
        let labels = CPUCoreTopology.verifiedLabels(
            levels: [CPUCoreTier(name: "Performance", count: 2),
                     CPUCoreTier(name: "Efficiency", count: 2)],
            clusterTypesByID: [0: "E", 1: "P", 2: "E", 3: "P"],
            logicalCPUCount: 4)
        #expect(labels[0] == "能效核")
        #expect(labels[1] == "性能核")
        #expect(labels[2] == "能效核")
    }

    @Test func doesNotGuessLogicalIdsWhenMachineTopologyCannotBeVerified() {
        let levels = [CPUCoreTier(name: "Super", count: 2),
                      CPUCoreTier(name: "Performance", count: 2)]
        #expect(CPUCoreTopology.verifiedLabels(
            levels: levels, clusterTypesByID: [:], logicalCPUCount: 4).isEmpty)
        #expect(CPUCoreTopology.verifiedLabels(
            levels: levels,
            clusterTypesByID: [0: "P", 1: "P", 2: "M", 3: "E"],
            logicalCPUCount: 4).isEmpty)
    }
}
