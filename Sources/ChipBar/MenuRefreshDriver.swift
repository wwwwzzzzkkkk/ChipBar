import Foundation
import ChipBarCore

struct MenuSnapshot: Equatable {
    var readouts: [MenuReadout] = []
    var showsLogo = true
    var tooltip = ""
    var accessibilityLabel = ""
}

/// Acquisition may finish at different times; only a complete snapshot reaches AppKit.
@MainActor final class MenuRefreshDriver {
    private let read: () async -> MenuSnapshot
    private let render: (MenuSnapshot) -> Void
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var last: MenuSnapshot?

    /// Live chip samples already publish changes through Monitor. Only net/disk
    /// counters require their own periodic acquisition and display clock.
    static func needsPeriodicSources(_ items: Set<MenuContent>) -> Bool {
        items.contains(.network) || items.contains(.disk) || items.contains(.externalDisk)
    }

    init(read: @escaping () async -> MenuSnapshot, render: @escaping (MenuSnapshot) -> Void) {
        self.read = read; self.render = render
    }

    func display(_ snapshot: MenuSnapshot) {
        guard snapshot != last else { return }
        last = snapshot
        render(snapshot)
    }

    func start(every interval: TimeInterval, active: Bool) {
        stop()
        guard active else { return }
        let token = generation
        worker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let read = self?.read else { return }
                let snapshot = await read()
                guard !Task.isCancelled, self?.generation == token else { return }
                self?.display(snapshot)
                do {
                    try await Task.sleep(for: .seconds(interval), tolerance: .milliseconds(100))
                } catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        worker?.cancel(); worker = nil
    }

    deinit { worker?.cancel() }
}
