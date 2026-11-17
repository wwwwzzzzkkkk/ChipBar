import AppKit
import SwiftUI
import Combine
import QuartzCore

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
    private var frameMotionTask: Task<Void, Never>?
    private var closeMotionTask: Task<Void, Never>?
    private var navigationDeadline: TimeInterval = 0
    private var openedOnRight = true
    private let pageMotionKey = "chipbar.sidecar.page-motion"
    private var clusterFitTask: Task<Void, Never>?
    private var measuredClusterContentHeight: CGFloat = 0
    private var resetClusterScrollOnFit = false
    // User interactions pin the native window; only its document grows.
    private var clusterViewportPinned = false
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
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = true
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
                // Pin the NSPanel when its SwiftUI rows are manually expanded.
                self.clusterViewportPinned = true
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
        let wasVisible = panel.isVisible
        let isSwitch = wasVisible && priorKind != nil && priorKind != kind
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        frameMotionTask?.cancel()
        frameMotionTask = nil
        closeMotionTask?.cancel()
        closeMotionTask = nil
        scrollView.contentView.layer?.removeAnimation(forKey: pageMotionKey)
        // Discovery is activated before the first intrinsic measurement.
        if kind == .cluster {
            ClusterMonitorService.shared.setPanelVisible(true)
        } else if priorKind == .cluster {
            ClusterMonitorService.shared.setPanelVisible(false)
        }
        transition = UUID()
        let token = transition
        navigationDeadline = motion && isSwitch
            ? ProcessInfo.processInfo.systemUptime + SidePanelNavigationMotion.duration : 0
        clusterViewportPinned = false
        clusterDisclosureAnimationDeadline = 0
        clusterFitTask?.cancel()
        clusterFitTask = nil
        measuredClusterContentHeight = 0
        resetClusterScrollOnFit = kind == .cluster
        clusterAnchoredTop = nil
        openedKind = kind
        scrollView.verticalScrollElasticity = kind == .cluster ? .none : .automatic
        scrollView.hasVerticalScroller = false
        parentWindow = parent
        let visible = screen.visibleFrame

        panel.appearance = parent.appearance
        host.appearance = parent.appearance
        panel.contentView?.appearance = parent.appearance
        let width = SidePanelLayout.width(for: kind)
        let isCluster = kind == .cluster

        // Render the actual page and resolve the @Published selection race
        // while the native glass window is still hidden. Replacing a loading
        // shell after a 90ms delay caused a second visible composition pass.
        // The clip layer is the only surface that transitions. Its old and new
        // content slide inside the existing rounded glass material.
        if motion, isSwitch, let priorKind {
            let push = CATransition()
            push.type = .push
            push.subtype = SidePanelNavigationMotion.forward(from: priorKind, to: kind)
                ? .fromRight : .fromLeft
            push.duration = SidePanelNavigationMotion.duration
            push.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1)
            scrollView.contentView.layer?.add(push, forKey: pageMotionKey)
        }
        host.setFrameSize(NSSize(width: width, height: SidePanelLayout.height(for: kind)))
        host.rootView = AnyView(DashboardSidePanelView(
            monitor: monitor, state: state, close: onClose,
            kindOverride: kind,
            onClusterContentHeightChange: { [weak self] height in
                self?.scheduleClusterFit(measuredHeight: height)
            }
        ))
        host.layoutSubtreeIfNeeded()
        let desiredHeight: CGFloat
        if isCluster {
            let fitted = ceil(host.fittingSize.height)
            desiredHeight = fitted.isFinite && fitted > 0
                ? min(10_000, fitted) : SidePanelLayout.clusterHeight
            measuredClusterContentHeight = desiredHeight
        } else {
            desiredHeight = SidePanelLayout.height(for: kind)
        }
        let height = isCluster
            ? ClusterSidecarSizing.windowHeight(content: desiredHeight,
                                                available: visible.height)
            : min(desiredHeight, max(200, visible.height - 16))
        host.setFrameSize(NSSize(width: width, height: max(desiredHeight, height)))
        if isCluster {
            scrollView.hasVerticalScroller = desiredHeight > height + 2
        }
        host.layoutSubtreeIfNeeded()

        let spacing: CGFloat = 9
        let rightSpace = visible.maxX - parent.frame.maxX - 8
        let leftSpace = parent.frame.minX - visible.minX - 8
        // A page switch must not re-anchor to a parent window that has just
        // changed layout. Keep the existing near edge and top during the morph.
        let openRight = isSwitch ? openedOnRight :
            (rightSpace >= width + spacing || rightSpace >= leftSpace)
        openedOnRight = openRight
        let desiredX = isSwitch
            ? (openRight ? panel.frame.minX : panel.frame.maxX - width)
            : (openRight ? parent.frame.maxX + spacing : parent.frame.minX - width - spacing)
        let x = min(max(visible.minX + 8, desiredX), visible.maxX - width - 8)
        let top = min(visible.maxY - 8, isSwitch ? panel.frame.maxY : parent.frame.maxY)
        if isCluster { clusterAnchoredTop = top }
        let y = max(visible.minY + 8, top - height)
        let target = NSRect(x: x, y: y, width: width, height: height)

        // A single, interruptible size morph is allowed only for an explicit
        // page change. No NSPanel alpha animation or sliding window origin.
        // Disclosure/telemetry never drives this animation.
        if motion && isSwitch {
            morphFrame(to: target, token: token)
        } else {
            panel.setFrame(target, display: false)
        }
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        scrollClusterToTop()
        if isCluster { resetClusterScrollOnFit = false }
        if motion && !isSwitch {
            let entry = CABasicAnimation(keyPath: "transform.translation.x")
            entry.fromValue = openRight ? -SidePanelNavigationMotion.enterDistance
                : SidePanelNavigationMotion.enterDistance
            entry.toValue = 0
            entry.isAdditive = true
            entry.duration = SidePanelNavigationMotion.enterDuration
            entry.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.contentView.layer?.add(entry, forKey: pageMotionKey)
        }
    }

    /// Own exactly one size animator. A rapid click cancels it and retargets
    /// from the currently displayed frame rather than its stale destination.
    private func morphFrame(to target: NSRect, token: UUID) {
        let start = panel.frame
        guard start != target else { return }
        let began = ProcessInfo.processInfo.systemUptime
        let duration = SidePanelNavigationMotion.duration
        frameMotionTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.transition == token {
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / duration)
                let eased = CGFloat(DisclosurePanelSizing.easeInOutProgress(progress))
                func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
                let frame = NSRect(x: lerp(start.minX, target.minX),
                                   y: lerp(start.minY, target.minY),
                                   width: lerp(start.width, target.width),
                                   height: lerp(start.height, target.height))
                self.panel.setFrame(frame, display: true)
                if progress >= 1 {
                    self.frameMotionTask = nil
                    return
                }
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
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
        clusterFitTask?.cancel()
        let token = transition
        let remaining = max(clusterDisclosureAnimationDeadline, navigationDeadline)
            - ProcessInfo.processInfo.systemUptime
        let delayMilliseconds = remaining > 0
            ? max(16, Int((remaining * 1000).rounded(.up)) + 16) : 75
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
            let natural = measured > 0 ? measured : self.host.fittingSize.height
            let content = natural.isFinite && natural > 0
                ? min(10_000, ceil(natural)) : SidePanelLayout.clusterHeight
            let old = self.panel.frame
            let proposed = ClusterSidecarSizing.windowHeight(
                content: content, available: visible.height)
            let resizeWindow = ClusterSidecarSizing.shouldResizeWindow(
                from: old.height, to: proposed, available: visible.height,
                userDisclosurePinned: self.clusterViewportPinned)
            let height = resizeWindow ? proposed : old.height
            let clip = self.scrollView.contentView
            let previousScrollY = clip.bounds.origin.y

            // The scroll document expands to hold all real task rows. A user
            // disclosure never resizes/repositions NSPanel: its scroll viewport
            // stays fixed, so nothing under the pointer moves unexpectedly.
            self.host.setFrameSize(NSSize(width: width,
                                         height: max(content, height)))
            self.scrollView.hasVerticalScroller = content > height + 2
            if resizeWindow {
                let top = ClusterSidecarSizing.stableTop(
                    openedAt: self.clusterAnchoredTop ?? old.maxY,
                    visibleMaxY: visible.maxY)
                let y = ClusterSidecarSizing.bottomY(
                    anchoredTop: top, height: height, visibleMinY: visible.minY)
                let frame = NSRect(x: old.minX, y: y, width: width, height: height)
                self.panel.setFrame(frame, display: true)
            }
            self.scrollView.layoutSubtreeIfNeeded()
            if self.resetClusterScrollOnFit {
                self.scrollClusterToTop()
                self.resetClusterScrollOnFit = false
            } else {
                // NSScrollView can relocate the clip origin when its document
                // height changes. Restore the user's position, clamped only
                // when collapsing makes the prior offset impossible.
                let offset = ClusterSidecarSizing.preservedScrollOffset(
                    previousScrollY, documentHeight: self.host.frame.height,
                    viewportHeight: clip.bounds.height, isFlipped: self.host.isFlipped)
                if abs(clip.bounds.origin.y - offset) > 0.5 {
                    clip.scroll(to: NSPoint(x: 0, y: offset))
                    self.scrollView.reflectScrolledClipView(clip)
                }
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
        let token = transition
        openedKind = nil
        frameMotionTask?.cancel()
        frameMotionTask = nil
        closeMotionTask?.cancel()
        closeMotionTask = nil
        clusterFitTask?.cancel()
        clusterFitTask = nil
        measuredClusterContentHeight = 0
        resetClusterScrollOnFit = false
        clusterViewportPinned = false
        clusterDisclosureAnimationDeadline = 0
        navigationDeadline = 0
        clusterAnchoredTop = nil
        scrollView.contentView.layer?.removeAnimation(forKey: pageMotionKey)
        // Keep the glass itself opaque. Only the content retreats; an
        // interrupted close cancels this task before it can hide a reopened page.
        guard animated, panel.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            host.rootView = AnyView(EmptyView())
            return
        }
        let leave = CABasicAnimation(keyPath: "transform.translation.x")
        leave.fromValue = 0
        leave.toValue = openedOnRight ? -SidePanelNavigationMotion.enterDistance
            : SidePanelNavigationMotion.enterDistance
        leave.isAdditive = true
        leave.duration = SidePanelNavigationMotion.enterDuration
        leave.timingFunction = CAMediaTimingFunction(name: .easeIn)
        scrollView.contentView.layer?.add(leave, forKey: pageMotionKey)
        closeMotionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard let self, self.transition == token, !Task.isCancelled else { return }
            self.panel.orderOut(nil)
            self.host.rootView = AnyView(EmptyView())
            self.closeMotionTask = nil
        }
    }
}
