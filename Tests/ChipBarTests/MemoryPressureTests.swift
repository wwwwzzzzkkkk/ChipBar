import Dispatch
import Testing
@testable import ChipBar

@MainActor struct MemoryPressureTests {
    @Test func mapsSystemPressureEventsToStatusLevels() {
        #expect(Monitor.memoryPressureLevel(for: .normal) == .normal)
        #expect(Monitor.memoryPressureLevel(for: .warning) == .warning)
        #expect(Monitor.memoryPressureLevel(for: .critical) == .critical)
        #expect(Monitor.memoryPressureLevel(for: []) == .unknown)
    }

    @Test func pressureRingColorsTrackSystemPressureNotRamUsedPercentage() {
        #expect(MemoryPressureRingStyle.tone(for: .unknown) == .neutral)
        #expect(MemoryPressureRingStyle.tone(for: .normal) == .green)
        #expect(MemoryPressureRingStyle.tone(for: .warning) == .yellow)
        #expect(MemoryPressureRingStyle.tone(for: .critical) == .red)
        // Reuse the actual kernel / dispatch mapping, not percent thresholds.
        #expect(MemoryPressureRingStyle.tone(
            for: Monitor.memoryPressureLevel(forSystemValue: 1) ?? .unknown) == .green)
        #expect(MemoryPressureRingStyle.tone(
            for: Monitor.memoryPressureLevel(forSystemValue: 2) ?? .unknown) == .yellow)
    }

    @Test func combinedEventsKeepTheMoreUrgentPressureLevel() {
        #expect(Monitor.memoryPressureLevel(for: [.normal, .warning]) == .warning)
        #expect(Monitor.memoryPressureLevel(for: [.normal, .critical]) == .critical)
    }

    @Test func mapsKernelPressureLevelsAndRejectsUnknownValues() {
        // Sysctl values use dispatch pressure flags: 1=normal, 2=warning, 4=critical.
        // Keep XNU's non-conflicting 0/3 ordinal aliases.
        #expect(Monitor.memoryPressureLevel(forSystemValue: 0) == .normal)
        #expect(Monitor.memoryPressureLevel(forSystemValue: 1) == .normal)
        #expect(Monitor.memoryPressureLevel(forSystemValue: 2) == .warning)
        #expect(Monitor.memoryPressureLevel(forSystemValue: 3) == .critical)
        #expect(Monitor.memoryPressureLevel(forSystemValue: 4) == .critical)
        #expect(Monitor.memoryPressureLevel(forSystemValue: 5) == nil)
    }
}
