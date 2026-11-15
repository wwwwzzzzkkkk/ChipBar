import AppKit

/// AppKit window fittingSize is expensive when SwiftUI includes a long live
/// history chart. Hardware samples should NEVER force this operation every
/// frame while the user is scrolling a glass NSScrollView.
@MainActor final class PanelLayoutCoordinator {
    private let apply: () -> Void
    private var worker: Task<Void, Never>?
    private var lastScrollAt: TimeInterval = -.infinity
    private(set) var requests = 0
    private(set) var applied = 0

    static let minimumSpacing: TimeInterval = 0.18
    static let scrollIdleDelay: TimeInterval = 0.28

    /// Deterministic rule independent of runner scheduling and frame timing.
    static func canApply(afterScrollIdle seconds: TimeInterval) -> Bool {
        seconds >= scrollIdleDelay
    }

    init(apply: @escaping () -> Void) { self.apply = apply }

    func noteScroll() {
        lastScrollAt = ProcessInfo.processInfo.systemUptime
    }

    func request() {
        requests += 1
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            repeat {
                do { try await Task.sleep(for: .seconds(Self.minimumSpacing)) }
                catch { self?.worker = nil; return }
                guard let self else { return }
                let sinceScroll = ProcessInfo.processInfo.systemUptime - self.lastScrollAt
                if Self.canApply(afterScrollIdle: sinceScroll) { break }
            } while !Task.isCancelled
            guard let self, !Task.isCancelled else { return }
            self.worker = nil
            self.applied += 1
            self.apply()
        }
    }

    /// Force a structural event immediately, e.g. first popover open.
    /// A stale coalesced refresh must not override the new geometry.
    func cancelPending() {
        worker?.cancel()
        worker = nil
    }
}
