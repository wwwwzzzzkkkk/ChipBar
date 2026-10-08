import AppKit
import SwiftUI
import Combine

/// AppKit owns status text and popup geometry; SwiftUI owns the dashboard.
@MainActor final class MenuController: NSObject {
    private let monitor: Monitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let scrollView = NSScrollView()
    private let dashboardState = DashboardState()
    private var hostingView: NSHostingView<AnyView>!
    private var subscription: AnyCancellable?
    private var measuredHeight: CGFloat = 0
    private var maximumHeight: CGFloat = 850
    private var lastSettingsVisible = false

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "ChipBar")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover)
        }
        hostingView = NSHostingView<AnyView>(rootView: AnyView(
            Dashboard(monitor: monitor, state: dashboardState)
                .background(Color(nsColor: .windowBackgroundColor))))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = hostingView
        let controller = NSViewController()
        controller.view = scrollView
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        refresh()
        subscription = Publishers.Merge(monitor.objectWillChange, dashboardState.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    private func refresh(forceLayout: Bool = false) {
        if let button = statusItem.button {
            button.title = " " + monitor.menuText
            button.toolTip = "ChipBar · \(monitor.hardware) · \(monitor.menuText)"
            button.setAccessibilityLabel("ChipBar \(monitor.menuMetric.title) \(monitor.menuText)")
        }
        guard forceLayout || popover.isShown || measuredHeight == 0 else { return }
        hostingView.layoutSubtreeIfNeeded()
        let height = ceil(hostingView.fittingSize.height)
        guard height.isFinite, height > 0 else { return }
        measuredHeight = height
        let visibleHeight = min(height, maximumHeight)
        hostingView.setFrameSize(NSSize(width: 390, height: height))
        let size = NSSize(width: 390, height: visibleHeight)
        // Resize the popover before its root view. Otherwise AppKit sees an already
        // resized content view and leaves the actual window at its old height.
        popover.contentSize = size
        scrollView.setFrameSize(size)
        if dashboardState.showSettings != lastSettingsVisible {
            let offset = dashboardState.showSettings ? max(0, height - visibleHeight) : 0
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            lastSettingsVisible = dashboardState.showSettings
        }
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        let screen = button.window?.screen ?? NSScreen.main
        maximumHeight = max(250, (screen?.visibleFrame.height ?? 900) - 24)
        refresh(forceLayout: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Uses the actual status button and attached popover, not a preview window.
    func verifyUI(directory: String) {
        guard monitor.connected else { failVerification("UI verification needs live macmon data.") }
        togglePopover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try capture(view: statusItem.button!, path: directory + "/menu-bar.png")
                try capture(view: scrollView, path: directory + "/popover.png")
                let collapsedHeight = popover.contentSize.height
                dashboardState.showSettings = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                    do {
                        try capture(view: scrollView, path: directory + "/popover-settings.png")
                        if let view = scrollView.window?.contentView { try capture(view: view, path: directory + "/window-settings.png") }
                        let result: [String: Any] = [
                            "title": statusItem.button!.title, "menuText": monitor.menuText,
                            "statusWidth": statusItem.button!.bounds.width,
                            "collapsedHeight": collapsedHeight,
                            "settingsHeight": popover.contentSize.height,
                            "measuredSettingsHeight": measuredHeight,
                            "viewHeight": scrollView.bounds.height,
                            "windowHeight": scrollView.window?.frame.height ?? 0,
                            "windowContentHeight": scrollView.window?.contentView?.bounds.height ?? 0,
                            "preferredHeight": popover.contentViewController?.preferredContentSize.height ?? 0,
                            "popoverVisible": popover.isShown, "maximumHeight": maximumHeight
                        ]
                        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                        try data.write(to: URL(fileURLWithPath: directory + "/layout.json"))
                        guard statusItem.button!.title.contains("W"), popover.isShown,
                              popover.contentSize.height > collapsedHeight,
                              (scrollView.window?.frame.height ?? 0) >= scrollView.bounds.height,
                              abs(scrollView.bounds.height - min(measuredHeight, maximumHeight)) < 1 else {
                            failVerification("Menu title or popover sizing verification failed.")
                        }
                        monitor.stop(forQuit: true)
                        NSApplication.shared.terminate(nil)
                    } catch { failVerification(error.localizedDescription) }
                }
            } catch { failVerification(error.localizedDescription) }
        }
    }

    private func failVerification(_ message: String) -> Never {
        monitor.stop(forQuit: true)
        fputs(message + "\n", stderr)
        exit(1)
    }

    private func capture(view: NSView, path: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "ChipBar.UI", code: 2)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ChipBar.UI", code: 3)
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
