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
    private let revealMask = CALayer()
    private let revealKey = "chipbar.sidecar.reveal"
    private var revealCleanupTask: Task<Void, Never>?
    private var revealStart: RevealPresentation?
    private var contentFitTask: Task<Void, Never>?
    private var measuredContentHeight: CGFloat = 0
    private var resetClusterScrollOnFit = false
    // User interactions pin the native window; only its document grows.
    private var clusterViewportPinned = false
    private var clusterDisclosureAnimationDeadline: TimeInterval = 0
    private var contentAnchoredTop: CGFloat?
    private var powerScrollSubscription: AnyCancellable?
    private var powerViewportTracksScroll = false
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
        let center = NotificationCenter.default
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        powerScrollSubscription = center.publisher(for: NSView.boundsDidChangeNotification, object: clip)
            .map { ($0.object as? NSClipView)?.bounds.origin.y }
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.openedKind == .power, self.powerViewportTracksScroll else { return }
                self.scheduleContentFit()
            }
        // Re-evaluate only horizontal geometry and display bounds, not every
        // telemetry-driven change of the dashboard's intrinsic height.
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
        let interrupted = revealPresentation()

        let needsRelocation = wasVisible && SidePanelPlacement.requiresRelocation(
            from: panel.frame, to: hint, parent: parent.frame, visible: visible)
        let preservingMotion = wasVisible && priorKind == kind && !needsRelocation && !wasRelocating
            && navigationDeadline > ProcessInfo.processInfo.systemUptime
        if !preservingMotion {
            scrollView.contentView.layer?.removeAnimation(forKey: pageMotionKey)
        }

        // The compositor reveals the glass and content together. Only commit
        // a new window frame once, while hidden for a cross-side transfer.
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
                let duration = animateReveal(from: interrupted, opening: false, side: oldSide)
                navigationDeadline = ProcessInfo.processInfo.systemUptime + duration
                relocationTask = Task { @MainActor [weak self, weak parent] in
                    do { try await Task.sleep(for: .seconds(duration)) }
                    catch { return }
                    guard let self, let parent, self.transition == token,
                          !Task.isCancelled else { return }
                    self.relocationTask = nil
                    self.panel.orderOut(nil)
                    self.clearReveal()
                    self.present(kind, beside: parent, unfolding: true)
                }
                return
            }
            // A display change or older invalid position can already
            // intersect Home. Remove it immediately rather than animating
            // an invalid frame; animate only its arrival on the legal side.
            panel.orderOut(nil)
            clearReveal()
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
        powerViewportTracksScroll = false
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
        // shell after a delay would cause a second visible composition pass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
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
        let requestedTop = switchingInPlace ? panel.frame.maxY : parent.frame.maxY
        let preferredHeight: CGFloat
        switch kind {
        case .cluster:
            preferredHeight = ClusterSidecarSizing.windowHeight(content: desiredHeight, available: visible.height)
        case .power:
            preferredHeight = SidePanelPlacement.powerViewportHeight(
                content: desiredHeight, anchoredTop: requestedTop, visible: visible)
        default:
            preferredHeight = desiredHeight
        }
        guard let placement = SidePanelPlacement.choose(
            parent: parent.frame, visible: visible, preferredWidth: width,
            preferredHeight: preferredHeight, top: requestedTop) else { return }
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
        let arriving = !wasVisible || expandAtDestination
        let resuming = !arriving && (priorKind == nil || wasRelocating || interrupted.fraction < 1)
        panel.alphaValue = 1
        scrollClusterToTop()
        if isCluster { resetClusterScrollOnFit = false }
        if arriving || resuming {
            panel.contentView?.layoutSubtreeIfNeeded()
            let duration = animateReveal(from: arriving ? .closed : interrupted,
                                         opening: true, side: placement.side)
            navigationDeadline = ProcessInfo.processInfo.systemUptime + duration
        } else if switchingInPlace {
            let duration = animatePageFromSeam(placement.side)
            navigationDeadline = ProcessInfo.processInfo.systemUptime + duration
        }
        // Pointer navigation can leave Home key, so its Liquid Glass stays
        // active. Keyboard navigation still needs focus in the destination.
        let eventType = NSApp.currentEvent?.type
        if parent.isKeyWindow && eventType != .keyDown && eventType != .keyUp {
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        if kind == .power { scheduleContentFit() }
    }

    private struct RevealPresentation {
        let fraction: CGFloat
        let opacity: Float
        static let closed = Self(fraction: 0, opacity: 0)
    }

    /// Read the compositor's current width before reversing, including when
    /// a second click lands before the first rendered frame.
    private func revealPresentation() -> RevealPresentation {
        guard panel.isVisible else { return .closed }
        let content = scrollView.contentView.layer
        let opacity = (content?.presentation() ?? content)?.opacity ?? 1
        guard panel.contentView?.layer?.mask === revealMask else {
            return RevealPresentation(fraction: 1, opacity: opacity)
        }
        guard let renderedMask = revealMask.presentation() else {
            return revealStart ?? RevealPresentation(fraction: 1, opacity: opacity)
        }
        let width = max(1, panel.contentView?.bounds.width ?? 0)
        return RevealPresentation(fraction: min(1, max(0, renderedMask.bounds.width / width)),
                                  opacity: opacity)
    }

    private func revealTiming(opening: Bool) -> CAMediaTimingFunction {
        let (x1, y1, x2, y2) = SidePanelNavigationMotion.timing(opening: opening)
        return CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }

    private func clearReveal() {
        revealCleanupTask?.cancel()
        revealCleanupTask = nil
        revealStart = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.removeAnimation(forKey: revealKey)
        panel.contentView?.layer?.mask = nil
        scrollView.contentView.layer?.removeAnimation(forKey: revealKey)
        scrollView.contentView.layer?.opacity = 1
        panel.ignoresMouseEvents = false
        CATransaction.commit()
    }

    private func animateReveal(from start: RevealPresentation, opening: Bool,
                               side: SidePanelPlacement.Side) -> TimeInterval {
        clearReveal()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let view = panel.contentView, let material = view.layer,
              let content = scrollView.contentView.layer,
              view.bounds.width > 0, view.bounds.height > 0 else { return 0 }
        let target: CGFloat = opening ? 1 : 0
        let duration = SidePanelNavigationMotion.revealDuration(from: start.fraction, to: target)
        let size = view.bounds.size
        let seam = SidePanelNavigationMotion.seamAnchor(on: side)
        let easing = revealTiming(opening: opening)
        revealStart = start

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Keep the NSPanel and the material at their final size. Only the
        // mask edge moves, with the edge nearest Home held at the seam.
        revealMask.backgroundColor = NSColor.black.cgColor
        revealMask.cornerRadius = material.cornerRadius
        revealMask.cornerCurve = .continuous
        revealMask.anchorPoint = CGPoint(x: seam, y: 0.5)
        revealMask.position = CGPoint(x: size.width * seam, y: size.height / 2)
        revealMask.bounds = CGRect(x: 0, y: 0, width: size.width * target, height: size.height)
        material.mask = revealMask
        let width = CABasicAnimation(keyPath: "bounds.size.width")
        width.fromValue = size.width * start.fraction
        width.toValue = size.width * target
        width.timingFunction = easing
        width.duration = duration
        revealMask.add(width, forKey: revealKey)

        // Give the text a head start on closing and hold it during the first
        // part of a fresh opening, so the revealed edge seldom cuts a label.
        content.opacity = opening ? 1 : 0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = opening ? [start.opacity, start.opacity, 1] : [start.opacity, 0, 0]
        let delay = 0.30 * (1 - start.fraction)
        fade.keyTimes = opening ? [0, NSNumber(value: delay), 1] : [0, 0.40, 1]
        fade.duration = duration
        fade.timingFunction = easing
        content.add(fade, forKey: revealKey)
        panel.ignoresMouseEvents = true

        if opening {
            revealCleanupTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(duration)) }
                catch { return }
                self?.clearReveal()
            }
        }
        return duration
    }

    /// A switch between two open pages keeps their shared glass in place.
    private func animatePageFromSeam(_ side: SidePanelPlacement.Side) -> TimeInterval {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let content = scrollView.contentView.layer else { return 0 }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = SidePanelNavigationMotion.edgeOffset(on: side)
        slide.toValue = 0
        slide.isAdditive = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.30
        fade.toValue = 1
        let duration = SidePanelNavigationMotion.enterDuration
        slide.duration = duration
        fade.duration = duration
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = duration
        group.timingFunction = revealTiming(opening: true)
        content.add(group, forKey: pageMotionKey)
        return duration
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
            let clip = self.scrollView.contentView
            let previousScrollY = clip.bounds.origin.y
            let previousScrollX = clip.bounds.origin.x
            let isCluster = kind == .cluster
            let top = ClusterSidecarSizing.stableTop(
                openedAt: self.contentAnchoredTop ?? old.maxY,
                visibleMaxY: visible.maxY)
            let available = isCluster
                ? ClusterSidecarSizing.windowHeight(content: content, available: visible.height)
                : SidePanelPlacement.powerViewportHeight(content: content, anchoredTop: top, visible: visible)
            // Shrink from the bottom even when a disclosure is clicked after
            // scrolling down. Let the viewport grow again as the user scrolls up.
            let remainingContent = max(1, content - max(0, previousScrollY))
            self.powerViewportTracksScroll = !isCluster && remainingContent < available
            let proposed = self.powerViewportTracksScroll ? remainingContent : available
            let resizeWindow = isCluster
                ? ClusterSidecarSizing.shouldResizeWindow(
                    from: old.height, to: proposed, available: visible.height,
                    userDisclosurePinned: self.clusterViewportPinned)
                : abs(old.height - proposed) >= 0.5
            let height = resizeWindow ? proposed : old.height
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            // Keep the full document available when its viewport is capped
            // by the screen or pinned by a Cluster task disclosure.
            let size = NSSize(width: width, height: max(content, height))
            if self.host.frame.size != size { self.host.setFrameSize(size) }
            let needsScroll = content > height + 2
            if self.scrollView.hasVerticalScroller != needsScroll {
                self.scrollView.hasVerticalScroller = needsScroll
            }
            if resizeWindow {
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
        let interrupted = revealPresentation()
        scrollView.contentView.layer?.removeAnimation(forKey: pageMotionKey)
        guard animated, panel.isVisible else {
            panel.orderOut(nil)
            clearReveal()
            host.rootView = AnyView(EmptyView())
            return
        }
        let duration = animateReveal(from: interrupted, opening: false,
                                     side: openedOnRight ? .right : .left)
        closeMotionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) }
            catch { return }
            guard let self, self.transition == token, !Task.isCancelled else { return }
            self.panel.orderOut(nil)
            self.clearReveal()
            self.scrollView.contentView.layer?.removeAnimation(forKey: self.pageMotionKey)
            self.host.rootView = AnyView(EmptyView())
            self.closeMotionTask = nil
        }
    }
}
