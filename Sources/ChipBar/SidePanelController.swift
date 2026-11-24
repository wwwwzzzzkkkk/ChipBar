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
    private var relocationTask: Task<Void, Never>?
    private var closeMotionTask: Task<Void, Never>?
    private var navigationDeadline: TimeInterval = 0
    private var openedOnRight = true
    private var parentGeometrySubscription: AnyCancellable?
    private var lastParentHorizontalFrame: CGRect?
    private var lastVisibleFrame: CGRect?
    private let pageMotionKey = "chipbar.sidecar.page-motion"
    private var contentFitTask: Task<Void, Never>?
    private var measuredContentHeight: CGFloat = 0
    private var resetClusterScrollOnFit = false
    // User interactions pin the native window; only its document grows.
    private var clusterViewportPinned = false
    private var clusterDisclosureAnimationDeadline: TimeInterval = 0
    private var contentAnchoredTop: CGFloat?
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
        // Re-evaluate only horizontal geometry and display bounds, not every
        // telemetry-driven change of the dashboard's intrinsic height.
        let center = NotificationCenter.default
        parentGeometrySubscription = Publishers.Merge4(
            center.publisher(for: NSWindow.didMoveNotification),
            center.publisher(for: NSWindow.didResizeNotification),
            center.publisher(for: NSWindow.didChangeScreenNotification),
            center.publisher(for: NSApplication.didChangeScreenParametersNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] note in
            guard let self, let parent = self.parentWindow,
                  note.name == NSApplication.didChangeScreenParametersNotification
                    || (note.object as? NSWindow) === parent,
                  self.panel.isVisible, let kind = self.state.sidePanel,
                  let visible = (parent.screen ?? NSScreen.main)?.visibleFrame else { return }
            let horizontal = CGRect(x: parent.frame.minX, y: 0,
                                    width: parent.frame.width, height: 1)
            guard self.lastParentHorizontalFrame != horizontal
                    || self.lastVisibleFrame != visible else { return }
            self.show(kind, beside: parent)
        }
        // The hosted view is mounted on demand to avoid reading processes or SMC on startup.
    }

    func show(_ kind: DashboardSidePanelKind, beside parent: NSWindow) {
        present(kind, beside: parent, unfolding: false)
    }

    private func present(_ kind: DashboardSidePanelKind, beside parent: NSWindow,
                         unfolding: Bool) {
        guard let screen = parent.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = SidePanelLayout.width(for: kind)
        lastParentHorizontalFrame = CGRect(x: parent.frame.minX, y: 0,
                                           width: parent.frame.width, height: 1)
        lastVisibleFrame = visible
        guard let hint = SidePanelPlacement.choose(parent: parent.frame, visible: visible,
            preferredWidth: width, preferredHeight: SidePanelLayout.height(for: kind)) else {
            // Do not cover Home when neither side has a usable viewport.
            hide(animated: false)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state.sidePanel == kind else { return }
                self.onClose()
            }
            return
        }
        let priorKind = openedKind
        let wasVisible = panel.isVisible
        let isSwitch = wasVisible && priorKind != nil && priorKind != kind
        let wasRelocating = relocationTask != nil
        relocationTask?.cancel()
        relocationTask = nil
        closeMotionTask?.cancel()
        closeMotionTask = nil
        let interrupted = contentPresentation()

        let needsRelocation = wasVisible && SidePanelPlacement.requiresRelocation(
            from: panel.frame, to: hint, parent: parent.frame, visible: visible)
        let preservingMotion = wasVisible && priorKind == kind && !needsRelocation && !wasRelocating
            && navigationDeadline > ProcessInfo.processInfo.systemUptime
        if !preservingMotion {
            scrollView.contentView.layer?.removeAnimation(forKey: pageMotionKey)
        }

        // Never resize a native glass window on a frame timer. The
        // compositor animates its clipped content; the window changes
        // geometry once, while hidden for a cross-side transfer.
        var expandAtDestination = unfolding
        if needsRelocation {
            let oldFrame = panel.frame
            let departureVisible = panel.screen?.visibleFrame ?? visible
            let safeBounds = departureVisible.insetBy(dx: SidePanelPlacement.edgeInset,
                                                      dy: SidePanelPlacement.edgeInset)
            if !unfolding, safeBounds.contains(oldFrame), !oldFrame.intersects(parent.frame) {
                let oldSide: SidePanelPlacement.Side = openedOnRight ? .right : .left
                transition = UUID()
                let token = transition
                contentFitTask?.cancel()
                contentFitTask = nil
                navigationDeadline = ProcessInfo.processInfo.systemUptime
                    + SidePanelNavigationMotion.relocationDuration
                animateContent(
                    from: interrupted.offset,
                    to: SidePanelNavigationMotion.edgeOffset(on: oldSide, relocating: true),
                    fromOpacity: interrupted.opacity, toOpacity: SidePanelNavigationMotion.exitOpacity,
                    duration: SidePanelNavigationMotion.relocationDuration,
                    entering: false)
                relocationTask = Task { @MainActor [weak self, weak parent] in
                    do { try await Task.sleep(for: .milliseconds(
                        Int(SidePanelNavigationMotion.relocationDuration * 1000))) }
                    catch { return }
                    guard let self, let parent, self.transition == token,
                          !Task.isCancelled else { return }
                    self.relocationTask = nil
                    self.panel.orderOut(nil)
                    self.present(kind, beside: parent, unfolding: true)
                }
                return
            }
            // A display change or older invalid position can already
            // intersect Home. Remove it immediately rather than animating
            // an invalid frame; animate only its arrival on the legal side.
            panel.orderOut(nil)
            expandAtDestination = true
        }
        let switchingInPlace = isSwitch && panel.isVisible
        // Discovery is activated before the first intrinsic measurement.
        if kind == .cluster {
            ClusterMonitorService.shared.setPanelVisible(true)
        } else if priorKind == .cluster {
            ClusterMonitorService.shared.setPanelVisible(false)
        }
        transition = UUID()
        let token = transition
        if !preservingMotion { navigationDeadline = 0 }
        clusterViewportPinned = false
        clusterDisclosureAnimationDeadline = 0
        contentFitTask?.cancel()
        contentFitTask = nil
        measuredContentHeight = 0
        resetClusterScrollOnFit = kind == .cluster
        contentAnchoredTop = nil
        openedKind = kind
        scrollView.verticalScrollElasticity = kind == .cluster ? .none : .automatic
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = hint.needsHorizontalScroll
        parentWindow = parent

        panel.appearance = parent.appearance
        host.appearance = parent.appearance
        panel.contentView?.appearance = parent.appearance
        let isCluster = kind == .cluster

        // Render the actual page and resolve the @Published selection race
        // while the native glass window is still hidden. Replacing a loading
        // shell after a 90ms delay caused a second visible composition pass.
        // The clip layer is the only surface that transitions. Its old and new
        // content slide inside the existing rounded glass material.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if switchingInPlace, let priorKind {
            let push = CATransition()
            push.type = .push
            push.subtype = SidePanelNavigationMotion.forward(from: priorKind, to: kind,
                order: DashboardTileLayoutModel.shared.arrangement.order)
                ? .fromRight : .fromLeft
            push.duration = SidePanelNavigationMotion.duration
            push.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.75, 0.30, 1.0)
            scrollView.contentView.layer?.add(push, forKey: pageMotionKey)
        }
        host.setFrameSize(NSSize(width: width, height: SidePanelLayout.height(for: kind)))
        host.rootView = AnyView(DashboardSidePanelView(
            monitor: monitor, state: state, close: onClose,
            kindOverride: kind,
            onContentHeightChange: { [weak self] height in
                guard let self, self.transition == token, kind.fitsContentHeight else { return }
                self.scheduleContentFit(measuredHeight: height)
            }
        ))
        let desiredHeight: CGFloat
        if kind.fitsContentHeight {
            // Fit the document before the first visible frame.
            host.layoutSubtreeIfNeeded()
            let fitted = ceil(host.fittingSize.height)
            desiredHeight = fitted.isFinite && fitted > 0
                ? min(10_000, fitted) : SidePanelLayout.height(for: kind)
            measuredContentHeight = desiredHeight
        } else {
            desiredHeight = SidePanelLayout.height(for: kind)
        }
        let preferredHeight = isCluster
            ? ClusterSidecarSizing.windowHeight(content: desiredHeight, available: visible.height)
            : desiredHeight
        guard let placement = SidePanelPlacement.choose(
            parent: parent.frame, visible: visible, preferredWidth: width,
            preferredHeight: preferredHeight,
            top: switchingInPlace ? panel.frame.maxY : parent.frame.maxY) else { return }
        let target = placement.frame
        let height = target.height
        let documentSize = NSSize(width: width, height: max(desiredHeight, height))
        if host.frame.size != documentSize { host.setFrameSize(documentSize) }
        scrollView.hasVerticalScroller = desiredHeight > height + 2
        scrollView.hasHorizontalScroller = placement.needsHorizontalScroll
        host.layoutSubtreeIfNeeded()

        let openRight = placement.side == .right
        openedOnRight = openRight
        if kind.fitsContentHeight { contentAnchoredTop = target.maxY }

        // Commit the final legal geometry once, without synchronous
        // display. Core Animation owns the slide, not a 16ms MainActor loop.
        if SidePanelNavigationMotion.needsFrameCommit(from: panel.frame, to: target) {
            panel.setFrame(target, display: false)
        }
        let resumingDeparture = wasVisible && !expandAtDestination && (priorKind == nil || wasRelocating)
        let arriving = !switchingInPlace && (!wasVisible || expandAtDestination || resumingDeparture)
        if switchingInPlace || arriving {
            navigationDeadline = ProcessInfo.processInfo.systemUptime
                + (switchingInPlace ? SidePanelNavigationMotion.duration
                                    : SidePanelNavigationMotion.enterDuration)
        }
        panel.alphaValue = 1
        scrollClusterToTop()
        if isCluster { resetClusterScrollOnFit = false }
        if arriving {
            let startOffset = resumingDeparture ? interrupted.offset
                : SidePanelNavigationMotion.edgeOffset(on: placement.side, relocating: expandAtDestination)
            let startOpacity = resumingDeparture ? interrupted.opacity : SidePanelNavigationMotion.exitOpacity
            animateContent(
                from: startOffset, to: 0, fromOpacity: startOpacity, toOpacity: 1,
                duration: SidePanelNavigationMotion.enterDuration, entering: true)
        }
        panel.makeKeyAndOrderFront(nil)
        if kind == .power { scheduleContentFit() }
    }

    /// Retarget an interrupted edge transition from the displayed values.
    private func contentPresentation() -> (offset: CGFloat, opacity: Float) {
        guard let layer = scrollView.contentView.layer,
              let shown = layer.presentation() else { return (0, 1) }
        return (shown.transform.m41 - layer.transform.m41, shown.opacity)
    }

    /// Transform and opacity animations affect only the clipped content
    /// surface. The rounded NSGlassEffectView remains at its final geometry.
    private func animateContent(from: CGFloat, to: CGFloat,
                                fromOpacity: Float, toOpacity: Float,
                                duration: TimeInterval, entering: Bool) {
        guard let layer = scrollView.contentView.layer else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = from
        slide.toValue = to
        slide.isAdditive = true
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fromOpacity
        opacity.toValue = toOpacity
        slide.duration = duration
        opacity.duration = duration
        let group = CAAnimationGroup()
        group.animations = [slide, opacity]
        group.duration = duration
        group.timingFunction = entering
            ? CAMediaTimingFunction(controlPoints: 0.20, 0.70, 0.25, 1.0)
            : CAMediaTimingFunction(controlPoints: 0.40, 0.0, 0.75, 1.0)
        if !entering {
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
        }
        layer.add(group, forKey: pageMotionKey)
    }

    private func scheduleClusterFit() {
        guard openedKind == .cluster else { return }
        scheduleContentFit()
    }

    /// The hosted document reports its natural height independently of the viewport.
    private func scheduleContentFit(measuredHeight: CGFloat? = nil) {
        if let measuredHeight, measuredHeight.isFinite, measuredHeight > 0 {
            measuredContentHeight = min(10_000, measuredHeight)
        }
        guard let kind = openedKind, kind.fitsContentHeight, panel.isVisible else { return }
        // Power follows SwiftUI's measured animation; Cluster still fits
        // after its task disclosures settle. Native navigation takes priority.
        contentFitTask?.cancel()
        let token = transition
        let remaining = max(clusterDisclosureAnimationDeadline, navigationDeadline)
            - ProcessInfo.processInfo.systemUptime
        let delayMilliseconds = remaining > 0
            ? max(16, Int((remaining * 1000).rounded(.up)) + 16) : (kind == .power ? 0 : 75)
        contentFitTask = Task { @MainActor [weak self] in
            if delayMilliseconds > 0 {
                do { try await Task.sleep(for: .milliseconds(delayMilliseconds)) }
                catch { return }
            }
            guard !Task.isCancelled, let self, self.transition == token,
                  self.openedKind == kind, self.panel.isVisible,
                  let visible = (self.parentWindow?.screen ?? self.panel.screen)?.visibleFrame else {
                return
            }
            // The geometry driver owns the panel until the page transition
            // ends. A layout preference must never race its final frame.
            if self.relocationTask != nil {
                self.scheduleContentFit()
                return
            }
            let width = SidePanelLayout.width(for: kind)
            let measured = self.measuredContentHeight
            let natural = measured > 0 ? measured : self.host.fittingSize.height
            let content = natural.isFinite && natural > 0
                ? min(10_000, ceil(natural)) : SidePanelLayout.height(for: kind)
            let old = self.panel.frame
            let isCluster = kind == .cluster
            let proposed = isCluster
                ? ClusterSidecarSizing.windowHeight(content: content, available: visible.height)
                : min(content, max(1, visible.height - SidePanelPlacement.edgeInset * 2))
            let resizeWindow = isCluster
                ? ClusterSidecarSizing.shouldResizeWindow(
                    from: old.height, to: proposed, available: visible.height,
                    userDisclosurePinned: self.clusterViewportPinned)
                : abs(old.height - proposed) > 1
            let height = resizeWindow ? proposed : old.height
            let clip = self.scrollView.contentView
            let previousScrollY = clip.bounds.origin.y
            let previousScrollX = clip.bounds.origin.x

            // Keep the full document available when its viewport is capped
            // by the screen or pinned by a Cluster task disclosure.
            let size = NSSize(width: width, height: max(content, height))
            if self.host.frame.size != size { self.host.setFrameSize(size) }
            let needsScroll = content > height + 2
            if self.scrollView.hasVerticalScroller != needsScroll {
                self.scrollView.hasVerticalScroller = needsScroll
            }
            if resizeWindow {
                let top = ClusterSidecarSizing.stableTop(
                    openedAt: self.contentAnchoredTop ?? old.maxY,
                    visibleMaxY: visible.maxY)
                let y = ClusterSidecarSizing.bottomY(
                    anchoredTop: top, height: height, visibleMinY: visible.minY)
                let frame = NSRect(x: old.minX, y: y, width: old.width, height: height)
                self.panel.setFrame(frame, display: false)
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
                let horizontal = min(max(0, previousScrollX),
                                     max(0, self.host.frame.width - clip.bounds.width))
                if abs(clip.bounds.origin.y - offset) > 0.5
                    || abs(clip.bounds.origin.x - horizontal) > 0.5 {
                    clip.scroll(to: NSPoint(x: horizontal, y: offset))
                    self.scrollView.reflectScrolledClipView(clip)
                }
            }
            self.contentFitTask = nil
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
        relocationTask?.cancel()
        relocationTask = nil
        closeMotionTask?.cancel()
        closeMotionTask = nil
        contentFitTask?.cancel()
        contentFitTask = nil
        measuredContentHeight = 0
        resetClusterScrollOnFit = false
        clusterViewportPinned = false
        clusterDisclosureAnimationDeadline = 0
        navigationDeadline = 0
        contentAnchoredTop = nil
        let interrupted = contentPresentation()
        scrollView.contentView.layer?.removeAnimation(forKey: pageMotionKey)
        // Keep the glass itself opaque. Only the content retreats; an
        // interrupted close cancels this task before it can hide a reopened page.
        guard animated, panel.isVisible else {
            panel.orderOut(nil)
            host.rootView = AnyView(EmptyView())
            return
        }
        animateContent(from: interrupted.offset,
            to: SidePanelNavigationMotion.edgeOffset(on: openedOnRight ? .right : .left),
            fromOpacity: interrupted.opacity, toOpacity: SidePanelNavigationMotion.exitOpacity,
            duration: SidePanelNavigationMotion.enterDuration, entering: false)
        closeMotionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(
                Int(SidePanelNavigationMotion.enterDuration * 1000))) }
            catch { return }
            guard let self, self.transition == token, !Task.isCancelled else { return }
            self.panel.orderOut(nil)
            self.scrollView.contentView.layer?.removeAnimation(forKey: self.pageMotionKey)
            self.host.rootView = AnyView(EmptyView())
            self.closeMotionTask = nil
        }
    }
}
