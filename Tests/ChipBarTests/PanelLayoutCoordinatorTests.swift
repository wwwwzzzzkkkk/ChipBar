import Foundation
import Testing
@testable import ChipBar

@MainActor struct PanelLayoutCoordinatorTests {
    @Test func burstsOfSamplesTriggerOneGeometryRefresh() async throws {
        var invocations = 0
        let coordinator = PanelLayoutCoordinator { invocations += 1 }
        for _ in 0..<30 { coordinator.request() }
        try await Task.sleep(for: .milliseconds(330))
        #expect(invocations == 1)
        #expect(coordinator.requests == 30)
        #expect(coordinator.applied == 1)
        coordinator.cancelPending()
    }

    @Test func panelRefitIsNotScheduledBySamplesWithoutStructureChanges() async throws {
        // Unrelated power readings are published through the Monitor and
        // should never enqueue window fitting work; this coordinator only
        // responds when explicitly asked for structural changes.
        var fits = 0
        let coordinator = PanelLayoutCoordinator { fits += 1 }
        try await Task.sleep(for: .milliseconds(240))
        #expect(fits == 0)
        coordinator.request()
        // A busy hosted macOS CI runner can delay the MainActor beyond
        // minimumSpacing. Wait for the actual callback with a bounded
        // deadline instead of assuming it ran within 240 ms.
        for _ in 0..<100 {
            if fits == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fits == 1)
        #expect(coordinator.applied == 1)
        coordinator.cancelPending()
    }

    @Test func scrollingDefersSizingUntilIdle() {
        #expect(!PanelLayoutCoordinator.canApply(afterScrollIdle: 0))
        #expect(!PanelLayoutCoordinator.canApply(afterScrollIdle: 0.18))
        #expect(!PanelLayoutCoordinator.canApply(afterScrollIdle: 0.279))
        #expect(PanelLayoutCoordinator.canApply(afterScrollIdle: 0.28))
        #expect(PanelLayoutCoordinator.canApply(afterScrollIdle: 1.0))
    }

    @Test func canceledSizingCannotOverwriteNewPageGeometry() async throws {
        var invocations = 0
        let coordinator = PanelLayoutCoordinator { invocations += 1 }
        coordinator.request()
        coordinator.cancelPending()
        try await Task.sleep(for: .milliseconds(300))
        #expect(invocations == 0)
    }
}
