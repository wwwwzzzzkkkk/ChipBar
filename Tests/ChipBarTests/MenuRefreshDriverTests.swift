import Foundation
import Testing
import ChipBarCore
@testable import ChipBar

@MainActor struct MenuRefreshDriverTests {
    func frame(_ power: String, _ rate: String) -> MenuSnapshot {
        MenuSnapshot(readouts: [MenuReadout("power", power, "POWER"),
                               MenuReadout("network", rate, "↑0B/s", pairedValues: true)])
    }

    func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Menu refresh did not finish")
    }

    @Test func presentsCompleteFrameAfterAcquisitionAndIgnoresIntermediateValues() async throws {
        var latest = frame("1W", "↓1K/s")
        var continuation: CheckedContinuation<Void, Never>?
        var frames: [MenuSnapshot] = []
        var reads = 0
        let driver = MenuRefreshDriver(read: {
            reads += 1
            await withCheckedContinuation { continuation = $0 }
            return latest
        }, render: { frames.append($0) })
        defer { driver.stop() }
        driver.start(every: 10, active: true)
        try await waitUntil { continuation != nil }
        latest = frame("2W", "↓1K/s")
        #expect(frames.isEmpty)
        latest = frame("2W", "↓9M/s")
        #expect(frames.isEmpty)
        continuation?.resume(); continuation = nil
        try await waitUntil { frames.count == 1 }
        #expect(frames == [latest])
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads == 1)
    }

    @Test func cancelledAcquisitionCannotOverwritePauseOrPreferenceChange() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        var frames: [MenuSnapshot] = []
        let old = frame("9W", "↓9M/s")
        let paused = frame("暂停", "—")
        let driver = MenuRefreshDriver(read: {
            await withCheckedContinuation { continuation = $0 }
            return old
        }, render: { frames.append($0) })
        driver.start(every: 2, active: true)
        try await waitUntil { continuation != nil }
        driver.start(every: 2, active: false)
        driver.display(paused)
        continuation?.resume(); continuation = nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(frames == [paused])
    }

    @Test func onlyNetworkAndDiskReadoutsRequireAdditionalPolling() {
        #expect(!MenuRefreshDriver.needsPeriodicSources([.logo, .power]))
        #expect(!MenuRefreshDriver.needsPeriodicSources([.logo, .power, .memory, .fans]))
        #expect(MenuRefreshDriver.needsPeriodicSources([.network]))
        #expect(MenuRefreshDriver.needsPeriodicSources([.power, .disk]))
        #expect(MenuRefreshDriver.needsPeriodicSources([.externalDisk]))
    }

    @Test func identicalSnapshotsDoNotRenderAgain() {
        var renders = 0
        let first = frame("1W", "↓1K/s")
        let driver = MenuRefreshDriver(read: { first }, render: { _ in renders += 1 })
        for _ in 0..<1000 { driver.display(first) }
        #expect(renders == 1)
        driver.display(frame("2W", "↓1K/s"))
        #expect(renders == 2)
    }
}
