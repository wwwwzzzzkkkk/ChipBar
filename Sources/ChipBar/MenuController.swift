import AppKit
import SwiftUI
import Combine

@MainActor private final class MenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// A transparent native panel lets the system glass sample the actual desktop,
/// rather than the opaque backing of an NSPopover. The dashboard stays unchanged.
@MainActor final class MenuController: NSObject, NSWindowDelegate {
    private let monitor: Monitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private let scrollView = NSScrollView()
    private let dashboardState = DashboardState()
    private var hostingView: NSHostingView<AnyView>!
    private var dashboardMounted = false
    private var panelRequestedVisible = false
    private var panelTransition = UUID()
    private var panelMaterial: PanelMaterialView!
    private var subscription: AnyCancellable?
    private var measuredHeight: CGFloat = 0
    private var maximumHeight: CGFloat = 850
    private var lastSettingsVisible = false
    private var menuTracking = false
    private var localEvents: Any?
    private var globalEvents: Any?
    private var observers: [NSObjectProtocol] = []

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "ChipBar")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.target = self
            button.action = #selector(togglePanel)
        }
        hostingView = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = hostingView
        panelMaterial = PanelMaterialView(contentView: scrollView)
        panel.contentView = panelMaterial
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.title = "ChipBar"
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.hidePanel() }
        installDismissalHandlers()
        refresh()
        subscription = Publishers.Merge(monitor.objectWillChange, dashboardState.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    private func installDismissalHandlers() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalEvents = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.menuTracking else { return }
                self.hidePanel()
            }
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: [clicks, .keyDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53, !self.menuTracking {
                self.hidePanel()
                return nil
            }
            if event.type != .keyDown, !self.menuTracking, NSApplication.shared.modalWindow == nil,
               event.window !== self.panel, event.window !== self.statusItem.button?.window {
                self.hidePanel()
            }
            return event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = false }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            let clickedStatusItem = MainActor.assumeIsolated { self?.isStatusItemClick ?? false }
            Task { @MainActor in
                guard let self, !clickedStatusItem, !self.menuTracking, NSApplication.shared.modalWindow == nil else { return }
                self.hidePanel()
            }
        })
    }

    private func refresh(forceLayout: Bool = false) {
        if let button = statusItem.button {
            button.title = " " + monitor.menuText
            button.toolTip = "ChipBar · \(monitor.hardware) · \(monitor.menuText)"
            button.setAccessibilityLabel("ChipBar \(monitor.menuMetric.title) \(monitor.menuText)")
        }
        guard dashboardMounted, forceLayout || panel.isVisible else { return }
        hostingView.layoutSubtreeIfNeeded()
        let height = ceil(hostingView.fittingSize.height)
        guard height.isFinite, height > 0 else { return }
        measuredHeight = height
        hostingView.setFrameSize(NSSize(width: 390, height: height))
        let size = NSSize(width: 390, height: min(height, maximumHeight))
        panel.setContentSize(size)
        panelMaterial.setFrameSize(size)
        panelMaterial.layoutSubtreeIfNeeded()
        scrollView.setFrameSize(size)
        if panel.isVisible { positionPanel() }
        if dashboardState.showSettings != lastSettingsVisible {
            let offset = dashboardState.showSettings ? max(0, height - size.height) : 0
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            lastSettingsVisible = dashboardState.showSettings
        }
    }

    private func anchor() -> (NSRect, NSScreen)? {
        guard let button = statusItem.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return nil }
        return (window.convertToScreen(button.convert(button.bounds, to: nil)), screen)
    }

    private func positionPanel() {
        guard let (rect, screen) = anchor() else { return }
        let visible = screen.visibleFrame
        let x = min(max(rect.maxX - panel.frame.width, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        let top = min(rect.minY - 6, visible.maxY - 6)
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 8, top - panel.frame.height)))
    }

    @objc private func togglePanel() {
        if panelRequestedVisible { hidePanel(); return }
        guard let (rect, screen) = anchor() else { return }
        maximumHeight = max(250, min(rect.minY - 6, screen.visibleFrame.maxY - 6) - screen.visibleFrame.minY - 8)
        if !dashboardMounted {
            hostingView.rootView = AnyView(Dashboard(monitor: monitor, state: dashboardState))
            dashboardMounted = true
        }
        refresh(forceLayout: true)
        positionPanel()
        if !panel.isVisible { panel.alphaValue = 0 }
        panelRequestedVisible = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.displayIfNeeded()
        animatePanel(visible: true)
    }

    private func hidePanel(animated: Bool = true) {
        guard panelRequestedVisible else { return }
        panelRequestedVisible = false
        animatePanel(visible: false, animated: animated)
    }

    private func animatePanel(visible: Bool, animated: Bool = true) {
        let token = UUID()
        panelTransition = token
        statusItem.button?.highlight(visible)
        let complete: () -> Void = { [weak self] in
            guard let self, self.panelTransition == token else { return }
            if visible {
                self.statusItem.button?.highlight(true)
            } else {
                self.panel.orderOut(nil)
                self.removeDashboard()
            }
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = visible ? 1 : 0
            complete()
            return
        }
        // AppKit animates opacity on the existing window; reversing a transition
        // keeps its current opacity. Old completions cannot hide a reopened panel.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.16 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = visible ? 1 : 0
        } completionHandler: {
            Task { @MainActor in complete() }
        }
    }

    private func removeDashboard() {
        guard dashboardMounted else { return }
        // Hidden NSPanel content still observes Monitor. Remove the dashboard so
        // it cannot keep updating offscreen; settings live separately.
        hostingView.rootView = AnyView(EmptyView())
        dashboardMounted = false
        measuredHeight = 0
        lastSettingsVisible = false
    }

    func windowDidResignKey(_ notification: Notification) {
        if !menuTracking, !isStatusItemClick { hidePanel() }
    }

    private var isStatusItemClick: Bool {
        guard let event = NSApplication.shared.currentEvent,
              [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(event.type),
              let (rect, _) = anchor() else { return false }
        return rect.contains(NSEvent.mouseLocation)
    }

    /// Exercise the actual status item and glass panel, using live metrics.
    func verifyUI(directory: String) {
        if CommandLine.arguments.contains("--light") { panel.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { panel.appearance = NSAppearance(named: .darkAqua) }
        guard monitor.connected else { failVerification("UI verification needs live macmon data.") }
        statusItem.button?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try capture(view: statusItem.button!, path: directory + "/menu-bar.png")
                try capture(view: panelMaterial, path: directory + "/popover.png")
                captureScreenWindow(path: directory + "/screen-popover.png")
                let collapsedHeight = panel.frame.height
                dashboardState.showSettings = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                    do {
                        try capture(view: panelMaterial, path: directory + "/popover-settings.png")
                        captureScreenWindow(path: directory + "/screen-settings.png")
                        let result: [String: Any] = [
                            "title": statusItem.button!.title, "menuText": monitor.menuText,
                            "statusWidth": statusItem.button!.bounds.width,
                            "collapsedHeight": collapsedHeight, "settingsHeight": panel.frame.height,
                            "measuredSettingsHeight": measuredHeight, "viewHeight": scrollView.bounds.height,
                            "windowHeight": panel.frame.height, "panelVisible": panel.isVisible,
                            "maximumHeight": maximumHeight, "material": panelMaterial.materialName,
                            "materialClass": panelMaterial.materialClassName,
                            "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                            "hostingOpaque": hostingView.isOpaque, "windowOpaque": panel.isOpaque,
                            "appearance": String(describing: panelMaterial.effectiveAppearance.name),
                            "windowId": panel.windowNumber, "frame": NSStringFromRect(panel.frame),
                            "screenFrame": NSStringFromRect(panel.screen?.frame ?? .zero),
                            "onActiveSpace": panel.isOnActiveSpace,
                            "sharing": panel.sharingType.rawValue,
                            "cgWindow": ((CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? []).filter { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
                        ]
                        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                        try data.write(to: URL(fileURLWithPath: directory + "/layout.json"))
                        guard statusItem.button!.title.contains("W"), panel.isVisible,
                              panel.frame.height > collapsedHeight,
                              abs(scrollView.bounds.height - min(measuredHeight, maximumHeight)) < 1 else {
                            failVerification("Menu title or panel sizing verification failed.")
                        }
                        Task { @MainActor in await self.verifyPanelTransitions(directory: directory) }
                    } catch { failVerification(error.localizedDescription) }
                }
            } catch { failVerification(error.localizedDescription) }
        }
    }

    private func verifyPanelTransitions(directory: String) async {
        statusItem.button?.performClick(nil)
        guard !panelRequestedVisible else { failVerification("Second status click did not request dismissal.") }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let closingAlpha = panel.alphaValue
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !panel.isVisible, !dashboardMounted, panel.alphaValue == 0 else {
            failVerification("Animated panel dismissal failed.")
        }
        statusItem.button?.performClick(nil)
        try? await Task.sleep(nanoseconds: 60_000_000)
        let openingAlpha = panel.alphaValue
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard panel.isVisible, dashboardMounted, dashboardState.showSettings, panel.alphaValue == 1 else {
            failVerification("Panel reopening or settings preservation failed.")
        }
        // Close, then reopen while fade-out is still in flight.
        togglePanel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        togglePanel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard panelRequestedVisible, panel.isVisible, dashboardMounted, panel.alphaValue == 1 else {
            failVerification("Interrupted close hid a reopened panel.")
        }
        // Rapid reversals must end in the requested state, with one window.
        for _ in 0..<10 {
            togglePanel()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard panelRequestedVisible, panel.isVisible, panel.alphaValue == 1 else {
            failVerification("Rapid status toggles left the wrong panel state.")
        }
        panel.cancelOperation(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !panel.isVisible, !dashboardMounted else { failVerification("Escape dismissal failed.") }
        togglePanel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
            NSApplication.shared.postEvent(event, atStart: true)
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !panel.isVisible, !dashboardMounted else { failVerification("Outside click dismissal failed.") }
        togglePanel()
        hidePanel(animated: false)
        guard !panel.isVisible, !dashboardMounted else { failVerification("Immediate dismissal failed.") }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !panel.isVisible, !dashboardMounted else { failVerification("Old animation undid immediate dismissal.") }
        let result: [String: Any] = [
            "openingAlphaAt60ms": openingAlpha,
            "closingAlphaAt60ms": closingAlpha,
            "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "toggleAndDismissalChecksPassed": true,
            "dashboardUnmountedAfterDismissal": !dashboardMounted
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: directory + "/transitions.json"))
        } catch { failVerification(error.localizedDescription) }
        monitor.stop(forQuit: true)
        NSApplication.shared.terminate(nil)
    }

    private func failVerification(_ message: String) -> Never {
        monitor.stop(forQuit: true)
        fputs(message + "\n", stderr)
        exit(1)
    }

    // WindowServer capture includes blur/refraction omitted by bitmap caching.
    private func captureScreenWindow(path: String) {
        guard CGPreflightScreenCaptureAccess() else { return }
        panel.displayIfNeeded()
        CATransaction.flush()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(panel.windowNumber), path]
        do { try process.run(); process.waitUntilExit() } catch { return }
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
