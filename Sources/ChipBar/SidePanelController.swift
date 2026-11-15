import AppKit
import SwiftUI
import QuartzCore
import Combine

@MainActor private final class ChipBarSideWindow: NSPanel {
    var escape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { escape?() }
}

/// A second, independent native glass window. Resource and SMC samplers mount
/// only while it is visible; the main menu retains its size and cached layout.
@MainActor final class ChipBarSidePanelController {
    private let panel = ChipBarSideWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
    private let scrollView = NSScrollView()
    private let host = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
    private let state: DashboardState
    private let monitor: Monitor
    private let onClose: () -> Void
    private var transition = UUID()
    private var lastOpenedOnRight = true
    private var mountTask: Task<Void, Never>?
    private var clusterFitTask: Task<Void, Never>?
    private var measuredClusterContentHeight: CGFloat = 0
    private var resetClusterScrollOnFit = false
    private var clusterOpeningAnimationInProgress = false
    private var clusterDisclosureAnimationDeadline: TimeInterval = 0
    private var clusterAnchoredTop: CGFloat?
    private var clusterLayoutSubscription: AnyCancellable?
    private var clusterTaskSubscription: AnyCancellable?
    private var externalTaskSubscription: AnyCancellable?
    private var taskDisclosureSubscription: AnyCancellable?

    var isKeyWindow: Bool { panel.isKeyWindow }
    var isVisible: Bool { panel.isVisible }
    private var openedKind: DashboardSidePanelKind?
    private weak var parentWindow: NSWindow?
    func owns(_ other: NSWindow?) -> Bool { other === panel }

    init(monitor: Monitor, state: DashboardState, delegate: NSWindowDelegate,
         onClose: @escaping () -> Void) {
        self.state = state
        self.monitor = monitor
        self.onClose = onClose
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.focusRingType = .none
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.focusRingType = .none
        // NSHostingView exposes a mutable isFlipped property, not an
        // overridable one. Pin the document origin at the top edge.
        host.isFlipped = true
        scrollView.documentView = host
        host.setFrameSize(NSSize(width: SidePanelLayout.width,
                                 height: SidePanelLayout.applicationHeight))
        let material = PanelMaterialView(contentView: scrollView)
        panel.contentView = material
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.title = "ChipBar 侧边卡片"
        panel.delegate = delegate
        panel.escape = onClose
        let cluster = ClusterMonitorService.shared
        clusterLayoutSubscription = Publishers.CombineLatest4(
            cluster.$nearby.map(\.count),
            cluster.$peers.map { $0.map { "\($0.id):\($0.tasks.count):\($0.tasks.filter { $0.progress != nil }.count)" }.joined(separator: ";") },
            cluster.$pairingCandidate.map { $0 == nil ? 0 : 1 },
            cluster.$enabled
        )
        .map { values in "\(values.0):\(values.1):\(values.2):\(values.3)" }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.scheduleClusterFit() }
        clusterTaskSubscription = cluster.$observedOpenFASTTasks
            .map { "\($0.count):\($0.filter { $0.progress != nil }.count)" }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleClusterFit() }
        externalTaskSubscription = cluster.$externalTasks
            .map { "\($0.count):\($0.filter { $0.progress != nil }.count)" }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleClusterFit() }
        taskDisclosureSubscription = cluster.$taskLayoutVersion
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Animate only the disclosure rows. Never resize the native
                // window 15 times while SwiftUI is animating their height.
                self.clusterDisclosureAnimationDeadline =
                    ProcessInfo.processInfo.systemUptime
                    + SidePanelLayout.clusterDisclosureAnimationDuration + 0.02
                self.scheduleClusterFit()
            }
        // The hosted view is mounted on demand to avoid reading processes or SMC on startup.
    }

    func show(_ kind: DashboardSidePanelKind, beside parent: NSWindow) {
        guard let screen = parent.screen ?? NSScreen.main else { return }
        let priorKind = openedKind
        // Discovery activation previously happened in SwiftUI.onAppear,
        // *after* measuring the first frame. Start before measuring instead.
        // The window controller owns the read-only monitor's visibility.
        if kind == .cluster {
            ClusterMonitorService.shared.setPanelVisible(true)
        } else if priorKind == .cluster {
            ClusterMonitorService.shared.setPanelVisible(false)
        }
        transition = UUID()
        clusterOpeningAnimationInProgress = false
        clusterDisclosureAnimationDeadline = 0
        mountTask?.cancel()
        clusterFitTask?.cancel()
        measuredClusterContentHeight = 0
        resetClusterScrollOnFit = kind == .cluster
        clusterAnchoredTop = nil
        let token = transition
        openedKind = kind
        scrollView.verticalScrollElasticity = kind == .cluster ? .none : .automatic
        scrollView.hasVerticalScroller = false
        parentWindow = parent
        let visible = screen.visibleFrame
        // Adopt the parent appearance before pre-layout so Liquid Glass does
        // not make an extra light/dark material pass after first presentation.
        panel.appearance = parent.appearance
        host.appearance = parent.appearance
        panel.contentView?.appearance = parent.appearance
        let width = SidePanelLayout.width(for: kind)
        let eagerCluster = SidePanelOpeningPolicy.presentsFinalContentBeforeShowing(kind)
        let desiredHeight: CGFloat
        if eagerCluster {
            // The cluster is lightweight: construct and measure the actual
            // content while the NSPanel is still hidden. Showing a 310pt
            // loading shell and swapping it after 90ms caused a visible flash
            // followed by a second window-size correction.
            host.setFrameSize(NSSize(width: width,
                                     height: SidePanelLayout.clusterHeight))
            host.rootView = AnyView(DashboardSidePanelView(
                monitor: monitor, state: state, close: onClose,
                kindOverride: kind,
                onClusterContentHeightChange: { [weak self] contentHeight in
                    self?.scheduleClusterFit(measuredHeight: contentHeight)
                }
            ))
            host.layoutSubtreeIfNeeded()
            let fitted = ceil(host.fittingSize.height)
            desiredHeight = fitted.isFinite && fitted > 0
                ? min(10_000, fitted) : SidePanelLayout.clusterHeight
            measuredClusterContentHeight = desiredHeight
        } else {
            desiredHeight = SidePanelLayout.height(for: kind)
        }
        let height = eagerCluster
            ? ClusterSidecarSizing.windowHeight(content: desiredHeight,
                                               available: visible.height)
            : min(desiredHeight, max(200, visible.height - 16))
        host.setFrameSize(NSSize(width: width,
                                 height: max(desiredHeight, height)))
        if eagerCluster {
            scrollView.hasVerticalScroller = desiredHeight > height + 2
            host.layoutSubtreeIfNeeded()
        }
        let spacing: CGFloat = 9
        let rightSpace = visible.maxX - parent.frame.maxX - 8
        let leftSpace = parent.frame.minX - visible.minX - 8
        let openRight = rightSpace >= width + spacing || rightSpace >= leftSpace
        lastOpenedOnRight = openRight
        let desiredX = openRight ? parent.frame.maxX + spacing : parent.frame.minX - width - spacing
        let x = min(max(visible.minX + 8, desiredX), visible.maxX - width - 8)
        let top = min(visible.maxY - 8, parent.frame.maxY)
        if eagerCluster { clusterAnchoredTop = top }
        let y = max(visible.minY + 8, top - height)
        let target = NSRect(x: x, y: y, width: width, height: height)
        // Cluster mounts its final glass content before becoming visible.
        // Animate only horizontal position: alpha fading the transparent
        // NSPanel triggers another Liquid Glass compositing pass (a flash).
        if !eagerCluster {
            host.rootView = AnyView(SidePanelLoadingView(kind: kind))
        }
        let clusterMotion = eagerCluster
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let openingCluster = eagerCluster && !panel.isVisible
        if !panel.isVisible {
            if eagerCluster {
                let slide: CGFloat = openRight
                    ? -SidePanelOpeningPolicy.clusterSlidePoints
                    : SidePanelOpeningPolicy.clusterSlidePoints
                panel.setFrame(clusterMotion ? target.offsetBy(dx: slide, dy: 0) : target,
                               display: true)
                panel.alphaValue = 1
                clusterOpeningAnimationInProgress = clusterMotion
            } else {
                let offset: CGFloat = openRight ? -14 : 14
                panel.setFrame(target.offsetBy(dx: offset, dy: 0), display: false)
                panel.alphaValue = 0
            }
            panel.makeKeyAndOrderFront(nil)
        } else {
            if eagerCluster {
                panel.setFrame(target, display: true)
                panel.alphaValue = 1
            }
            panel.makeKeyAndOrderFront(nil)
        }
        if eagerCluster {
            scrollClusterToTop()
            resetClusterScrollOnFit = false
            if openingCluster && clusterMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = SidePanelOpeningPolicy.clusterSlideDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(target, display: true)
                } completionHandler: {
                    Task { @MainActor [weak self] in
                        guard let self, self.transition == token else { return }
                        self.clusterOpeningAnimationInProgress = false
                        self.scheduleClusterFit()
                        self.panel.invalidateShadow()
                    }
                }
            } else {
                scheduleClusterFit()
            }
            return
        }
        mountTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(90)) }
            catch { return }
            guard let self, self.transition == token, self.panel.isVisible,
                  self.openedKind == kind else { return }
            self.host.rootView = AnyView(DashboardSidePanelView(
                monitor: self.monitor, state: self.state, close: self.onClose,
                onClusterContentHeightChange: { [weak self] height in
                    self?.scheduleClusterFit(measuredHeight: height)
                }
            ))
            self.mountTask = nil
            if kind == .cluster { self.scheduleClusterFit(resetScroll: true) }
        }
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard motion else {
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.30, 1.0)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: {
            Task { @MainActor [weak self] in self?.panel.invalidateShadow() }
        }
    }

    /// The live SwiftUI view reports its natural content height via a
    /// PreferenceKey. Never temporarily compress the NSHostingView to 1pt:
    /// that changes the scroll document origin and clips its first rows.
    /// Shrink-wrap on large displays; only scroll on small displays.
    private func scheduleClusterFit(measuredHeight: CGFloat? = nil,
                                    resetScroll: Bool = false) {
        if let measuredHeight, measuredHeight.isFinite, measuredHeight > 0 {
            measuredClusterContentHeight = min(10_000, measuredHeight)
        }
        if resetScroll { resetClusterScrollOnFit = true }
        guard openedKind == .cluster, panel.isVisible else { return }
        // Only the task rows animate. Wait until their transition ends,
        // then fit the native NSPanel once. Repeated frame updates were
        // moving the entire glass container during every disclosure.
        guard !clusterOpeningAnimationInProgress else { return }
        clusterFitTask?.cancel()
        let token = transition
        let remaining = clusterDisclosureAnimationDeadline
            - ProcessInfo.processInfo.systemUptime
        let delayMilliseconds = remaining > 0
            ? max(1, Int((remaining * 1000).rounded(.up))) : 75
        clusterFitTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(delayMilliseconds)) }
            catch { return }
            guard let self, self.transition == token,
                  self.openedKind == .cluster, self.panel.isVisible,
                  let visible = (self.parentWindow?.screen ?? self.panel.screen)?.visibleFrame else {
                return
            }
            let width = SidePanelLayout.width(for: .cluster)
            let measured = self.measuredClusterContentHeight
            // Fallback for the very first geometry pass only. No viewport
            // reset, and no forced hard-coded maximum window height.
            let natural = measured > 0 ? measured : self.host.fittingSize.height
            let content = natural.isFinite && natural > 0
                ? min(10_000, ceil(natural)) : SidePanelLayout.clusterHeight
            let height = ClusterSidecarSizing.windowHeight(
                content: content, available: visible.height)
            let old = self.panel.frame
            // Lock the top edge captured at opening. Parent menu geometry
            // can change while the selected tile re-renders, but it must not
            // drag the Cluster window (or its content) upward.
            let top = ClusterSidecarSizing.stableTop(
                openedAt: self.clusterAnchoredTop ?? old.maxY,
                visibleMaxY: visible.maxY)
            let y = ClusterSidecarSizing.bottomY(
                anchoredTop: top, height: height, visibleMinY: visible.minY)
            // Document must be at least as tall as the viewport. If longer,
            // NSScrollView can scroll; otherwise there is no empty padding.
            self.host.setFrameSize(NSSize(width: width,
                                         height: max(content, height)))
            // Overlay scrollbars only when the screen cannot show the full
            // document. The glass tile width stays unchanged.
            self.scrollView.hasVerticalScroller = content > height + 2
            let frame = NSRect(x: old.minX, y: y, width: width, height: height)
            if abs(old.height - height) > 1 || abs(old.minY - y) > 1 {
                self.panel.setFrame(frame, display: true)
            }
            // The flipped document itself keeps content at top (y=0).
            // Do not issue an additional scroll(to:) for every geometry
            // change; that was visibly shifting the whole card.
            if self.resetClusterScrollOnFit {
                self.scrollClusterToTop()
                self.resetClusterScrollOnFit = false
            }
            self.clusterFitTask = nil
        }
    }

    /// AppKit scroll coordinates are not always top-origin: flipped
    /// NSHostingViews use 0, nonflipped document views use max offset.
    /// Scroll only during initial presentation, never during disclosure
    /// or live telemetry updates.
    private func scrollClusterToTop() {
        let clip = scrollView.contentView
        let topY = ClusterSidecarSizing.topScrollOffset(
            documentHeight: host.frame.height,
            viewportHeight: clip.bounds.height,
            isFlipped: host.isFlipped)
        clip.scroll(to: NSPoint(x: 0, y: topY))
        scrollView.reflectScrolledClipView(clip)
    }

    func hide(animated: Bool = true) {
        if openedKind == .cluster {
            ClusterMonitorService.shared.setPanelVisible(false)
        }
        transition = UUID()
        openedKind = nil
        mountTask?.cancel()
        mountTask = nil
        clusterFitTask?.cancel()
        clusterFitTask = nil
        measuredClusterContentHeight = 0
        resetClusterScrollOnFit = false
        clusterOpeningAnimationInProgress = false
        clusterDisclosureAnimationDeadline = 0
        clusterAnchoredTop = nil
        let token = transition
        guard panel.isVisible else {
            host.rootView = AnyView(EmptyView())
            return
        }
        let complete: () -> Void = { [weak self] in
            guard let self, self.transition == token else { return }
            self.panel.orderOut(nil)
            // Cancel on-demand process and power sampling by unmounting.
            self.host.rootView = AnyView(EmptyView())
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 0
            complete()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: lastOpenedOnRight ? -10 : 10, dy: 0), display: true)
        } completionHandler: {
            Task { @MainActor in complete() }
        }
    }
}
