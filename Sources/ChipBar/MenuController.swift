import AppKit
import SwiftUI
import Combine
import ChipBarCore

/// Page transitions hold the outgoing viewport until the slide completes;
/// the destination then returns to its natural content height.
enum DashboardViewportHeight {
    static func fitted(content: CGFloat, maximum: CGFloat, pinned: CGFloat?) -> CGFloat {
        min(pinned ?? content, maximum)
    }
}

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
    private let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let scrollView = NSScrollView()
    private let dashboardState = DashboardState()
    private var hostingView: NSHostingView<AnyView>!
    private var dashboardMounted = false
    private var panelRequestedVisible = false
    private var panelTransition = UUID()
    private var autoDismissal: Task<Void, Never>?
    private var mouseDownTarget: Bool?
    private var mouseSequence = UUID()
    private var mouseSequenceStartedAt: TimeInterval = 0
    private var mouseReleaseCleanup: Task<Void, Never>?
    private var panelMaterial: PanelMaterialView!
    private var subscription: AnyCancellable?
    private var layoutSubscription: AnyCancellable?
    private var tileEditorSubscription: AnyCancellable?
    private lazy var layoutCoordinator = PanelLayoutCoordinator { [weak self] in
        self?.refresh()
    }
    private var scrollObserver: NSObjectProtocol?
    private var menuPreferences: AnyCancellable?
    private var menuRefresh: MenuRefreshDriver!
    private var sidePanelSubscription: AnyCancellable?
    private var sidePanelController: ChipBarSidePanelController?
    private var disclosureSubscription: AnyCancellable?
    private var settingsNavigationSubscription: AnyCancellable?
    private var systemDisclosureSubscription: AnyCancellable?
    private var navigationViewportHeight: CGFloat?
    // While the user is editing/reordering, retain the exact glass-window
    // viewport size for the rest of the current menu session. Only the
    // scrollable document may grow; selecting/dragging must never recenter the
    // NSPanel or shift the entire page vertically.
    private var tileEditViewportHeight: CGFloat?
    /// The system disclosure predicts the first expansion immediately and
    /// caches measured heights for subsequent openings in the same process.
    private var systemCollapsedDocumentHeight: CGFloat?
    private var systemExpandedDocumentHeight: CGFloat?
    private var monitoringPageHeight: CGFloat?
    private var settingsPageHeight: CGFloat?
    private var navigationResizeInFlight = false
    private var navigationTask: Task<Void, Never>?
    private var navigationToken = UUID()
    private var resetScrollForPage = false
    private struct DisclosureTransition {
        let start: (applications: Double, ssd: Double)
        let target: (applications: Double, ssd: Double)
        let began: TimeInterval
        let collapsedDocumentHeight: CGFloat
        let token: UUID
    }
    private var disclosureTransition: DisclosureTransition?
    // Reuse the previously measured, structurally equivalent Home height on
    // subsequent opens. The SwiftUI tree still remounts so hidden dashboards
    // never continue rendering, but costly NSHostingView.fittingSize is skipped.
    private struct HomeLayoutKey: Equatable {
        var status: String
        var error: String?
        var connected: Bool
        var volumeIDs: [String]
        var externalIDs: [String]
        var tileLayoutRevision: Int
    }
    private var cachedHomeLayout: (key: HomeLayoutKey, height: CGFloat)?

    private var homeLayoutKey: HomeLayoutKey? {
        guard !dashboardState.showSettings, !dashboardState.showSystemDetails,
              !dashboardState.showSSDDetails else { return nil }
        let storage = ExternalStorageCapacityModel.shared
        return HomeLayoutKey(status: monitor.status, error: monitor.error,
                             connected: monitor.connected,
                             volumeIDs: storage.volumes.map(\.id),
                             externalIDs: (storage.activity?.external ?? []).sorted(),
                             tileLayoutRevision: DashboardTileLayoutModel.shared.layoutRevision)
    }

    private func openProfileMark(_ phase: String, since start: TimeInterval) {
        guard CommandLine.arguments.contains("--profile-open") else { return }
        let millis = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        NSLog("ChipBar open: %@ %.1f ms", phase, millis)
    }

    private var measuredHeight: CGFloat = 0
    private var maximumHeight: CGFloat = 850
    private var menuTracking = false
    private var localEvents: Any?
    private var globalEvents: Any?
    private var observers: [NSObjectProtocol] = []
    private let compactMenu = CompactMenuView()
    private var mouseQATrace: [[String: Any]]?

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()
        // First app launch after an update gives PlugInKit a chance to elect
        // the actual Xcode-built extension, without blocking menu startup.
        ChipBarWidgetRegistrationModel.shared.ensureOnFirstLaunch()
        if let button = statusItem.button {
            compactMenu.autoresizingMask = [.width, .height]
            compactMenu.setAccessibilityElement(false)
            button.addSubview(compactMenu)
            button.target = self
            button.action = #selector(togglePanel)
        }
        hostingView = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
        // Never show the bright system scroll indicator over Liquid Glass.
        // NSScrollView still handles trackpad/wheel and momentum events when
        // vertical scroller chrome is disabled.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .automatic
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.focusRingType = .none
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.focusRingType = .none
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = hostingView
        panelMaterial = PanelMaterialView(contentView: scrollView)
        panel.contentView = panelMaterial
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.title = "ChipBar"
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.hidePanel(animated: true) }
        // A bounds change (including momentum scroll) defers costly layout
        // fitting until the user's scroll settles. Programmatic scrolls are
        // harmless: they simply extend the brief quiet period.
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.layoutCoordinator.noteScroll() }
        }
        sidePanelController = ChipBarSidePanelController(
            monitor: monitor, state: dashboardState, delegate: self,
            onClose: { [weak self] in self?.dashboardState.sidePanel = nil })
        installDismissalHandlers()
        menuRefresh = MenuRefreshDriver(read: { [weak monitor] in
            await monitor?.sampleMenuSources()
            return monitor?.menuSnapshot ?? MenuSnapshot()
        }, render: { [weak self] snapshot in self?.renderMenu(snapshot) })
        configureMenuRefresh()
        menuPreferences = Publishers.MergeMany([
            monitor.$menuItems.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            monitor.$menuMetric.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            monitor.$interval.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            monitor.$paused.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            monitor.$sleeping.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            monitor.ssd.$enabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            monitor.ssd.$showInMenu.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]).debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.configureMenuRefresh() }
        refresh()
        subscription = monitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Keep network/disk frames atomic: they are rendered by their
                // acquisition driver after all asynchronous reads complete.
                if !MenuRefreshDriver.needsPeriodicSources(self.monitor.menuItems) {
                    self.menuRefresh.display(self.monitor.menuSnapshot)
                }
            }

        // Power samples, sparkline history and animation frames do not change
        // the panel's intrinsic height. Recomputing NSHostingView.fittingSize
        // on every hardware sample was redundant (and expensive on glass).
        // Refit only when content may actually add/remove or wrap a section.
        layoutSubscription = Publishers.MergeMany([
            monitor.$status.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            monitor.$error.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            monitor.$connected.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            monitor.$paused.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            monitor.$sleeping.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            monitor.ssd.$enabled.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            monitor.ssd.$status.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            monitor.ssd.$readings.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dashboardState.$ssdDetailsHeight.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            DashboardTileLayoutModel.shared.$layoutRevision.dropFirst()
                .removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .chipBarStorageLayoutDidChange)
                .map { _ in () }.eraseToAnyPublisher()
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self, self.dashboardMounted && self.panelRequestedVisible else { return }
            // Existing coordinator coalesces requests without adding any
            // delay to disclosure, glass or spring animation timing.
            self.layoutCoordinator.request()
        }
        tileEditorSubscription = DashboardTileLayoutModel.shared.$editing
            .dropFirst()
            .sink { [weak self] editing in
                guard let self, editing, self.panelRequestedVisible,
                      self.tileEditViewportHeight == nil else { return }
                self.tileEditViewportHeight = self.panel.frame.height
            }

        // Synchronous main-thread state delivery: resetForOpening() happens
        // before the panel is presented, so it cannot queue stale navigation.
        // The application ranking lives in its own NSPanel, so changing it
        // must never resize the original menu or invalidate Home's layout cache.
        disclosureSubscription = dashboardState.$showSSDDetails.dropFirst()
            .sink { [weak self] ssd in
                self?.animateDisclosure(applications: false, ssd: ssd)
            }
        sidePanelSubscription = dashboardState.$sidePanel.dropFirst()
            .sink { [weak self] side in
                guard let self else { return }
                guard self.panelRequestedVisible else {
                    self.sidePanelController?.hide(animated: false)
                    return
                }
                if let side {
                    // @Published emits the NEW value before its storage changes.
                    // Pass the selection directly instead of reading stale
                    // DashboardState inside the side-window controller.
                    self.autoDismissal?.cancel()
                    self.sidePanelController?.show(side, beside: self.panel)
                } else {
                    self.sidePanelController?.hide()
                    if !self.panel.isKeyWindow { self.panel.makeKeyAndOrderFront(nil) }
                }
            }
        settingsNavigationSubscription = dashboardState.$showSettings
            .dropFirst()
            .sink { [weak self] _ in self?.navigateBetweenPages() }
        systemDisclosureSubscription = dashboardState.$showSystemDetails
            .dropFirst()
            .sink { [weak self] _ in self?.navigateBetweenPages() }
    }

    /// The same viewport is shared by Home, System Details, and Settings.
    /// Page navigation changes only the SwiftUI content; AppKit never changes
    /// the glass NSPanel frame mid-slide. This avoids two-stage fitting
    /// corrections, vertical hops, and Liquid Glass frame compositing hitches.
    private func navigateBetweenPages() {
        if dashboardState.sidePanel != nil { dashboardState.sidePanel = nil }
        guard dashboardMounted, panelRequestedVisible else { return }
        navigationTask?.cancel()
        layoutCoordinator.cancelPending()
        let token = UUID()
        navigationToken = token
        disclosureTransition = nil
        // Pin the visible window height during all secondary page navigation.
        // The pages scroll natively inside this unchanged viewport.
        navigationViewportHeight = panel.frame.height
        navigationResizeInFlight = true
        // Do not scroll the *outgoing* page to its top when the user clicks
        // Settings at the bottom of Home. That instant offset reset was visible
        // as a vertical hop immediately before the horizontal page transition.
        // Reset the new page only after the navigation animation finishes.
        resetScrollForPage = true
        navigationTask = Task { @MainActor [weak self] in
            // SwiftUI commits the destination after this callback. Prepare
            // its document height and top offset before the page slide ends,
            // not in the last frame (which caused Settings/Back to jump).
            await Task.yield()
            guard let self, self.navigationToken == token,
                  self.dashboardMounted, self.panelRequestedVisible,
                  !Task.isCancelled else { return }
            self.prepareNavigationDocument()
            do { try await Task.sleep(for: .milliseconds(270)) }
            catch { return }
            guard self.navigationToken == token,
                  self.dashboardMounted, self.panelRequestedVisible else { return }
            self.navigationTask = nil
            self.navigationResizeInFlight = false
            // The outgoing Home viewport was pinned only for the page slide.
            // Release it after navigation so shorter Settings content can
            // shrink the native glass panel instead of leaving a large void.
            self.navigationViewportHeight = nil
            self.refresh(forceLayout: true, animateResize: true)
        }
    }

    /// The viewport remains fixed throughout the horizontal page transition.
    /// Prepare the incoming page's *scrollable document* at the start, so its
    /// content never snaps from an old page's bottom offset at completion.
    private func prepareNavigationDocument() {
        guard dashboardMounted, panelRequestedVisible,
              let viewportHeight = navigationViewportHeight else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        hostingView.layoutSubtreeIfNeeded()
        let height = ceil(hostingView.fittingSize.height)
        guard height.isFinite, height > 0 else { return }
        measuredHeight = height
        let documentHeight = max(viewportHeight, height)
        let documentSize = NSSize(width: DashboardLayout.width, height: documentHeight)
        if hostingView.frame.size != documentSize { hostingView.setFrameSize(documentSize) }
        let maximumOffset = max(0, documentHeight - viewportHeight)
        let topY = hostingView.isFlipped ? 0 : maximumOffset
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: topY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        resetScrollForPage = false
    }

    private func animateDisclosure(applications: Bool, ssd: Bool) {
        let target = (applications: applications ? 1.0 : 0.0,
                      ssd: ssd ? 1.0 : 0.0)
        let start = currentDisclosureValues()
        guard dashboardMounted, panelRequestedVisible, !dashboardState.showSettings,
              !dashboardState.showSystemDetails,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            disclosureTransition = nil
            if dashboardState.showSystemDetails &&
                !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                withAnimation(ChipBarMotion.disclosure) {
                    dashboardState.ssdExpansion = target.ssd
                }
            } else {
                dashboardState.ssdExpansion = target.ssd
            }
            dashboardState.applicationsExpansion = target.applications
            if dashboardMounted {
                hostingView.needsLayout = true
                refresh()
                panel.invalidateShadow()
            }
            return
        }
        let collapsedHeight = disclosureTransition?.collapsedDocumentHeight
            ?? DisclosurePanelSizing.collapsedDocumentHeight(
                measuredHeight: measuredHeight,
                applications: dashboardState.applicationsExpansion,
                ssd: dashboardState.ssdExpansion,
                ssdDetailsHeight: dashboardState.ssdDetailsHeight)
        let targetDocumentHeight = DisclosurePanelSizing.expandedDocumentHeight(
            collapsedHeight: collapsedHeight,
            applications: target.applications, ssd: target.ssd,
            ssdDetailsHeight: dashboardState.ssdDetailsHeight)
        let targetHeight = min(maximumHeight, targetDocumentHeight)
        let token = UUID()
        disclosureTransition = DisclosureTransition(start: start, target: target,
            began: ProcessInfo.processInfo.systemUptime,
            collapsedDocumentHeight: collapsedHeight, token: token)
        withAnimation(.timingCurve(0.42, 0, 0.58, 1, duration: DashboardMotion.duration)) {
            dashboardState.applicationsExpansion = target.applications
            dashboardState.ssdExpansion = target.ssd
        }
        if navigationViewportHeight != nil { navigationViewportHeight = targetHeight }
        // Grow the scroll document ahead of the glass window so the additional
        // application rows never get clipped, then compact it only after the
        // window has settled. This also avoids a second resize at completion.
        let documentSize = NSSize(width: DashboardLayout.width,
            height: max(hostingView.frame.height, targetDocumentHeight))
        if hostingView.frame.size != documentSize {
            let clip = scrollView.contentView
            let viewport = clip.bounds.height
            let oldMaximum = max(0, hostingView.frame.height - viewport)
            let oldTop = hostingView.isFlipped
                ? clip.bounds.origin.y : oldMaximum - clip.bounds.origin.y
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostingView.setFrameSize(documentSize)
            let newMaximum = max(0, documentSize.height - viewport)
            let clampedTop = min(newMaximum, max(0, oldTop))
            clip.scroll(to: NSPoint(x: 0,
                y: hostingView.isFlipped ? clampedTop : newMaximum - clampedTop))
            scrollView.reflectScrolledClipView(clip)
            CATransaction.commit()
        }
        if let frame = panelFrame(size: NSSize(width: panel.frame.width, height: targetHeight)) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DashboardMotion.duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.disclosureTransition?.token == token else { return }
                    self.disclosureTransition = nil
                    self.refresh()
                    self.panel.invalidateShadow()
                }
            }
        } else {
            disclosureTransition = nil
            refresh()
        }
    }

    private func currentDisclosureValues() -> (applications: Double, ssd: Double) {
        guard let transition = disclosureTransition else {
            return (dashboardState.applicationsExpansion, dashboardState.ssdExpansion)
        }
        let t = min(1, max(0, (ProcessInfo.processInfo.systemUptime - transition.began) / DashboardMotion.duration))
        let eased = DisclosurePanelSizing.easeInOutProgress(t)
        return (
            transition.start.applications + (transition.target.applications - transition.start.applications) * eased,
            transition.start.ssd + (transition.target.ssd - transition.start.ssd) * eased
        )
    }

    private func installDismissalHandlers() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let releases: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        globalEvents = NSEvent.addGlobalMonitorForEvents(matching: [clicks, releases]) { [weak self] event in
            let fromMenuBarOrRelease = MainActor.assumeIsolated {
                self?.recordMouseQA("globalMouseEvent", event: event)
                if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type) {
                    self?.finishUnclaimedMousePress(event)
                    return true
                }
                return self?.isMenuBarEvent(event) ?? false
            }
            // WindowServer hosts the menu bar and can deliver this same click
            // globally before forwarding it to our NSStatusBarButton.
            guard !fromMenuBarOrRelease else { return }
            MainActor.assumeIsolated { self?.dismissForFocusLoss() }
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: [clicks, releases, .keyDown]) { [weak self] event in
            self?.recordMouseQA("localEvent", event: event)
            if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type) {
                self?.finishUnclaimedMousePress(event)
                return event
            }
            if event.type != .keyDown, self?.isStatusButtonEvent(event) == true {
                self?.autoDismissal?.cancel()
                self?.autoDismissal = nil
                self?.mouseReleaseCleanup?.cancel()
                self?.mouseSequence = UUID()
                self?.mouseSequenceStartedAt = event.timestamp
                self?.mouseDownTarget = !(self?.panelRequestedVisible ?? false)
                return event
            }
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53, !self.menuTracking {
                self.hidePanel(animated: false)
                return nil
            }
            if event.type != .keyDown, !self.menuTracking, NSApplication.shared.modalWindow == nil,
               event.window !== self.panel,
               !(self.sidePanelController?.owns(event.window) ?? false),
               !self.isStatusButtonEvent(event) {
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
            MainActor.assumeIsolated {
                self?.recordMouseQA("applicationResignedActive")
                self?.dismissForFocusLoss()
            }
        })
    }

    private func configureMenuRefresh() {
        menuRefresh.display(monitor.menuSnapshot)
        // CPU/GPU/ANE data arrives via Monitor's published samples. Only
        // network and disk rates need a second, separately sampled clock.
        let needsCounters = MenuRefreshDriver.needsPeriodicSources(monitor.menuItems)
        menuRefresh.start(every: Double(monitor.interval) / 1000,
                          active: !monitor.paused && !monitor.sleeping && needsCounters)
    }

    private func renderMenu(_ snapshot: MenuSnapshot) {
        guard let button = statusItem.button else { return }
        let width = compactMenu.update(snapshot.readouts, showsLogo: snapshot.showsLogo)
        if statusItem.length != width { statusItem.length = width }
        if compactMenu.frame != button.bounds { compactMenu.frame = button.bounds }
        button.toolTip = snapshot.tooltip
        button.setAccessibilityLabel(snapshot.accessibilityLabel)
    }

    private func refresh(forceLayout: Bool = false, animateResize: Bool = false) {
        if forceLayout { layoutCoordinator.cancelPending() }
        guard dashboardMounted, forceLayout || panel.isVisible else { return }
        // Sensor/status updates may arrive during a tile lift. Do not ask
        // NSHostingView.fittingSize to reflow a live spring animation and
        // inadvertently recenter the entire glass window while dragging.
        if !forceLayout && DashboardTileLayoutModel.shared.editing &&
           !dashboardState.showSettings && !dashboardState.showSystemDetails {
            return
        }
        guard forceLayout || disclosureTransition == nil else { return }
        guard !navigationResizeInFlight else { return }
        let switchingPage = resetScrollForPage
        let oldViewportHeight = scrollView.contentView.bounds.height
        let oldY = scrollView.contentView.bounds.origin.y
        let topOffset = hostingView.isFlipped ? oldY : max(0, hostingView.frame.height - oldViewportHeight - oldY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // fittingSize performs the required SwiftUI measurement; a full
        // layoutSubtreeIfNeeded immediately before it repeats expensive work.
        let height = ceil(hostingView.fittingSize.height)
        guard height.isFinite, height > 0 else { return }
        let contentHeightChanged = height != measuredHeight
        measuredHeight = height
        if let key = homeLayoutKey {
            cachedHomeLayout = (key, height)
        }
        let onHome = !dashboardState.showSettings && !dashboardState.showSystemDetails
        let pinnedHeight = onHome ? tileEditViewportHeight : nil
        let size = NSSize(width: DashboardLayout.width,
                          height: DashboardViewportHeight.fitted(
                              content: height, maximum: maximumHeight,
                              pinned: navigationViewportHeight ?? pinnedHeight))
        // A short destination page still needs a full viewport-sized document,
        // otherwise NSClipView can retain an invalid origin on the next return.
        let documentHeight = max(height, size.height)
        let documentSize = NSSize(width: DashboardLayout.width, height: documentHeight)
        if hostingView.frame.size != documentSize { hostingView.setFrameSize(documentSize) }
        if let frame = panelFrame(size: size), contentHeightChanged || forceLayout {
            if frame != panel.frame {
                if animateResize && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = DashboardMotion.navigationResize
                        context.timingFunction = DashboardMotion.navigationSpringCurve
                        panel.animator().setFrame(frame, display: true)
                    }
                } else {
                    panel.setFrame(frame, display: false)
                }
            }
            panelMaterial.layoutSubtreeIfNeeded()
        }
        if switchingPage || contentHeightChanged || oldViewportHeight != size.height || forceLayout {
            let maximumOffset = max(0, documentHeight - size.height)
            let offset = switchingPage ? 0 : min(maximumOffset, max(0, topOffset))
            let y = hostingView.isFlipped ? offset : maximumOffset - offset
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if switchingPage { resetScrollForPage = false }
    }

    private func anchor() -> (NSRect, NSScreen)? {
        guard let button = statusItem.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return nil }
        return (window.convertToScreen(button.convert(button.bounds, to: nil)), screen)
    }

    private func panelFrame(size: NSSize) -> NSRect? {
        guard let (rect, screen) = anchor() else { return nil }
        let visible = screen.visibleFrame
        let x = min(max(rect.maxX - size.width, visible.minX + 8), visible.maxX - size.width - 8)
        let top = (CommandLine.arguments.contains("--disclosure-only") || CommandLine.arguments.contains("--ssd-disclosure-only"))
            ? visible.maxY - 6 : min(rect.minY - 6, visible.maxY - 6)
        return NSRect(x: x, y: max(visible.minY + 8, top - size.height), width: size.width, height: size.height)
    }

    private func positionPanel() {
        if let frame = panelFrame(size: panel.frame.size), frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
    }

    /// Lock the AppKit glass and its SwiftUI content to one effective
    /// system appearance for the entire menu-panel session. NSPanel may
    /// acquire/relinquish key focus when a Picker is opened; that should not
    /// temporarily repaint one page dark and the next page light.
    private func synchronizeAppearanceForOpen() {
        let requested: NSAppearance.Name
        if CommandLine.arguments.contains("--light") {
            requested = .aqua
        } else if CommandLine.arguments.contains("--dark") {
            requested = .darkAqua
        } else {
            let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            requested = match == .darkAqua ? .darkAqua : .aqua
        }
        guard let appearance = NSAppearance(named: requested) else { return }
        panel.appearance = appearance
        panelMaterial.appearance = appearance
        hostingView.appearance = appearance
    }

    /// Open the existing menu-panel navigation from a WidgetKit deep link.
    /// No hardware sampling or view architecture changes are required.
    func openWidgetURL(_ url: URL) {
        guard url.scheme?.lowercased() == "chipbar" else { return }
        if !panelRequestedVisible { togglePanel() }
        guard panelRequestedVisible else { return }
        switch url.host?.lowercased() {
        case "main", nil:
            dashboardState.sidePanel = nil
            dashboardState.showSettings = false
            dashboardState.showSystemDetails = false
        case "power":
            dashboardState.showSettings = false
            dashboardState.showSystemDetails = false
            dashboardState.sidePanel = .power
        case "disk":
            let requested = url.path.removingPercentEncoding?
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            let drive = ExternalStorageCapacityModel.shared.volumes.first {
                $0.volume.name == requested
            }
            if let drive {
                dashboardState.showSettings = false
                dashboardState.showSystemDetails = false
                dashboardState.selectedExternalVolumeID = drive.id
                dashboardState.sidePanel = .externalDisk
            } else {
                // Macintosh HD is on Home; the external-disk details panel
                // accepts only a verified external volume ID.
                dashboardState.sidePanel = nil
                dashboardState.showSettings = false
                dashboardState.showSystemDetails = false
            }
        default:
            return
        }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePanel() {
        let openedAt = ProcessInfo.processInfo.systemUptime
        recordMouseQA("buttonAction")
        let shouldOpen = mouseDownTarget ?? !panelRequestedVisible
        mouseDownTarget = nil
        mouseReleaseCleanup?.cancel(); mouseReleaseCleanup = nil
        autoDismissal?.cancel(); autoDismissal = nil
        if !shouldOpen { hidePanel(); return }
        guard let (rect, screen) = anchor() else { return }
        maximumHeight = max(250, min(rect.minY - 6, screen.visibleFrame.maxY - 6) - screen.visibleFrame.minY - 8)
        synchronizeAppearanceForOpen()
        // Restore the initial dashboard on EVERY opening, including a rapid
        // close -> reopen while the NSPanel fade-out is still in progress.
        layoutCoordinator.cancelPending()
        navigationTask?.cancel()
        navigationTask = nil
        navigationToken = UUID()
        navigationResizeInFlight = false
        navigationViewportHeight = nil
        tileEditViewportHeight = nil
        disclosureTransition = nil
        resetScrollForPage = true
        withTransaction(Transaction(animation: nil)) {
            dashboardState.resetForOpening()
            // The layout order is persistent, but a new opening must not
            // retain a selected/lifted tile or an unfinished drag.
            DashboardTileLayoutModel.shared.finishEditing(reduceMotion: true)
        }
        if !dashboardMounted {
            hostingView.rootView = AnyView(Dashboard(monitor: monitor, state: dashboardState))
            if CommandLine.arguments.contains("--light") {
                hostingView.rootView = AnyView(hostingView.rootView.environment(\.colorScheme, .light))
            } else if CommandLine.arguments.contains("--dark") {
                hostingView.rootView = AnyView(hostingView.rootView.environment(\.colorScheme, .dark))
            }
            dashboardMounted = true
        }
        monitor.setDashboardVisible(true)
        // Most panel opens use identical structural content. Reuse the exact
        // prior height rather than synchronously recomputing every SwiftUI
        // body's fittingSize while the user is clicking the status item.
        var usedCachedHeight = false
        if let key = homeLayoutKey, let cached = cachedHomeLayout,
           cached.key == key, cached.height > 0 {
            let viewportHeight = min(cached.height, maximumHeight)
            let documentHeight = max(cached.height, viewportHeight)
            let documentSize = NSSize(width: DashboardLayout.width, height: documentHeight)
            if hostingView.frame.size != documentSize {
                hostingView.setFrameSize(documentSize)
            }
            if let frame = panelFrame(size: NSSize(width: DashboardLayout.width,
                                                   height: viewportHeight)),
               panel.frame != frame {
                panel.setFrame(frame, display: false)
            }
            let maximumOffset = max(0, documentHeight - viewportHeight)
            scrollView.contentView.scroll(to: NSPoint(
                x: 0, y: hostingView.isFlipped ? 0 : maximumOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            measuredHeight = cached.height
            resetScrollForPage = false
            usedCachedHeight = true
        } else {
            refresh(forceLayout: true)
        }
        openProfileMark(usedCachedHeight ? "cached geometry" : "full geometry", since: openedAt)
        positionPanel()
        if !panel.isVisible { panel.alphaValue = 0 }
        panelRequestedVisible = true
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        panel.displayIfNeeded()
        openProfileMark("first display", since: openedAt)
        animatePanel(visible: true)
    }

    private func hidePanel(animated: Bool = true) {
        tileEditViewportHeight = nil
        autoDismissal?.cancel(); autoDismissal = nil
        mouseDownTarget = nil
        mouseReleaseCleanup?.cancel(); mouseReleaseCleanup = nil
        guard panelRequestedVisible else { return }
        panelRequestedVisible = false
        sidePanelController?.hide(animated: false)
        monitor.setDashboardVisible(false)
        animatePanel(visible: false, animated: animated)
    }

    private func animatePanel(visible: Bool, animated: Bool = true) {
        let token = UUID()
        panelTransition = token
        statusItem.button?.highlight(false)
        compactMenu.needsDisplay = true
        let complete: () -> Void = { [weak self] in
            guard let self, self.panelTransition == token else { return }
            if visible {
                self.statusItem.button?.highlight(false)
                self.panel.invalidateShadow()
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
            context.duration = visible ? DashboardMotion.popoverEnter : DashboardMotion.popoverExit
            context.timingFunction = DashboardMotion.popoverCurve
            panel.animator().alphaValue = visible ? 1 : 0
        } completionHandler: {
            Task { @MainActor in complete() }
        }
    }

    private func removeDashboard() {
        layoutCoordinator.cancelPending()
        guard dashboardMounted else { return }
        disclosureTransition = nil
        // Hidden NSPanel content still observes Monitor. Remove the dashboard so
        // it cannot keep updating offscreen; settings live separately.
        hostingView.rootView = AnyView(EmptyView())
        dashboardMounted = false
        measuredHeight = 0
        navigationTask?.cancel()
        navigationTask = nil
        navigationToken = UUID()
        navigationResizeInFlight = false
        navigationViewportHeight = nil
        resetScrollForPage = false
    }

    func windowDidResignKey(_ notification: Notification) {
        recordMouseQA("panelResignedKey")
        // Moving keyboard focus from Home to its sidecard is internal
        // navigation, not an outside click. Ignore it until the next event.
        if let window = notification.object as? NSWindow,
           window === panel,
           sidePanelController?.isVisible == true { return }
        dismissForFocusLoss()
    }

    private func dismissForFocusLoss() {
        guard panelRequestedVisible, mouseDownTarget == nil else { return }
        autoDismissal?.cancel()
        let transition = panelTransition
        // Let WindowServer finish forwarding a status-button press. Native mouse
        // down freezes its toggle target and cancels this speculative dismissal.
        autoDismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard let self, self.panelTransition == transition, !self.menuTracking, self.mouseDownTarget == nil,
                  NSApplication.shared.modalWindow == nil,
                  !self.panel.isKeyWindow,
                  !(self.sidePanelController?.isKeyWindow ?? false) else { return }
            self.hidePanel()
        }
    }

    private func isMenuBarEvent(_ event: NSEvent) -> Bool {
        // The hosted menu-bar window is separate from the button's virtual
        // NSWindow. Its layer is stable even when live cursor/frame values lag.
        if event.windowNumber > 0, event.windowNumber <= Int(UInt32.max),
           let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(event.windowNumber)) as? [[String: Any]],
           windows.contains(where: { ($0[kCGWindowLayer as String] as? Int) == NSWindow.Level.mainMenu.rawValue }) {
            return true
        }
        return isStatusButtonEvent(event)
    }

    private func isStatusButtonEvent(_ event: NSEvent) -> Bool {
        guard let window = statusItem.button?.window else { return false }
        return event.window === window || event.windowNumber > 0 && event.windowNumber == window.windowNumber
    }

    private func finishUnclaimedMousePress(_ event: NSEvent) {
        guard mouseDownTarget != nil, event.timestamp >= mouseSequenceStartedAt else { return }
        mouseReleaseCleanup?.cancel()
        let sequence = mouseSequence
        mouseReleaseCleanup = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard let self, self.mouseSequence == sequence, self.mouseDownTarget != nil else { return }
            self.mouseDownTarget = nil
            if !self.panel.isKeyWindow { self.dismissForFocusLoss() }
        }
    }

    private var pointerOverStatusItem: Bool {
        anchor()?.0.contains(NSEvent.mouseLocation) ?? false
    }

    private func recordMouseQA(_ name: String, event: NSEvent? = nil) {
        guard mouseQATrace != nil else { return }
        let event = event ?? NSApplication.shared.currentEvent
        mouseQATrace?.append([
            "event": name, "time": ProcessInfo.processInfo.systemUptime,
            "eventType": event?.type.rawValue ?? 0, "eventWindow": event?.windowNumber ?? 0,
            "statusWindow": statusItem.button?.window?.windowNumber ?? 0,
            "pressedMouseButtons": NSEvent.pressedMouseButtons,
            "requestedVisible": panelRequestedVisible, "panelVisible": panel.isVisible,
            "pointerOverStatusItem": anchor()?.0.contains(NSEvent.mouseLocation) ?? false
        ])
    }

    /// Send mouse down/up through WindowServer rather than invoking a button action.
    func verifyMouseClicks(directory: String) async {
        guard CGPreflightPostEventAccess() else { failVerification("Mouse QA needs existing event-posting permission.") }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else {
            failVerification("Mouse QA requires an unlocked desktop.")
        }
        hidePanel(animated: false)
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !panelRequestedVisible, !panel.isVisible else { failVerification("Mouse QA could not reset the panel.") }
        mouseQATrace = []
        let originalPosition = CGEvent(source: nil)?.location
        defer { if let originalPosition { CGWarpMouseCursorPosition(originalPosition) } }
        var states: [Bool] = []
        var visibility: [Bool] = []
        let args = CommandLine.arguments
        let pressIndex = args.firstIndex(of: "--mouse-press-ms")
        let pressMilliseconds = pressIndex.flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil } ?? 100
        let driverIndex = args.firstIndex(of: "--mouse-driver")
        let driverPath = driverIndex.flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        let busyUI = args.contains("--busy-ui")
        let countIndex = args.firstIndex(of: "--mouse-click-count")
        let clickCount = countIndex.flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil } ?? 4
        guard (0...1000).contains(pressMilliseconds) else { failVerification("Mouse press must be 0–1000 milliseconds.") }
        guard (1...100).contains(clickCount) else { failVerification("Mouse click count must be 1–100.") }
        for _ in 0..<clickCount {
            guard let (rect, _) = anchor(), let top = NSScreen.screens.first?.frame.maxY else {
                failVerification("Cannot locate status item for mouse QA.")
            }
            var position = CGPoint(x: rect.midX, y: top - rect.midY)
            let application = AXUIElementCreateApplication(getpid())
            var extras: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &extras) == .success,
               let extras, CFGetTypeID(extras) == AXUIElementGetTypeID() {
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(unsafeBitCast(extras, to: AXUIElement.self), "AXChildren" as CFString, &children)
                if let item = (children as? [AXUIElement])?.first {
                    var origin: CFTypeRef?
                    var size: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, "AXPosition" as CFString, &origin)
                    AXUIElementCopyAttributeValue(item, "AXSize" as CFString, &size)
                    if let origin, let size {
                        var point = CGPoint.zero
                        var dimensions = CGSize.zero
                        AXValueGetValue(unsafeBitCast(origin, to: AXValue.self), .cgPoint, &point)
                        AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions)
                        position = CGPoint(x: point.x + dimensions.width / 2, y: point.y + dimensions.height / 2)
                    }
                }
            }
            if let driverPath {
                let driver = Process()
                driver.executableURL = URL(fileURLWithPath: driverPath)
                driver.arguments = [String(Double(position.x)), String(Double(position.y)), String(pressMilliseconds)]
                do { try driver.run() } catch { failVerification(error.localizedDescription) }
                // Only QA stalls the UI to exercise delivery after mouse release.
                if busyUI { usleep(useconds_t(700_000 + pressMilliseconds * 1000)) }
                while driver.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
                guard driver.terminationStatus == 0 else { failVerification("External mouse driver failed.") }
                try? await Task.sleep(nanoseconds: 450_000_000)
            } else {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 50_000_000)
                let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: position, mouseButton: .left)
                down?.setIntegerValueField(.mouseEventClickState, value: 1)
                down?.post(tap: .cghidEventTap)
                if pressMilliseconds > 0 { try? await Task.sleep(nanoseconds: UInt64(pressMilliseconds) * 1_000_000) }
                let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: position, mouseButton: .left)
                up?.setIntegerValueField(.mouseEventClickState, value: 1)
                up?.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
            states.append(panelRequestedVisible)
            visibility.append(panel.isVisible)
            recordMouseQA("clickCompleted")
        }
        let result: [String: Any] = ["pressMilliseconds": pressMilliseconds, "externalDriver": driverPath != nil, "busyUI": busyUI,
            "statesAfterClicks": states, "visibleAfterClicks": visibility, "trace": mouseQATrace ?? []]
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: directory + "/mouse-clicks.json"))
        } catch { failVerification(error.localizedDescription) }
        if let originalPosition { CGWarpMouseCursorPosition(originalPosition) }
        let expected = (0..<clickCount).map { $0.isMultiple(of: 2) }
        guard states == expected, visibility == states else {
            failVerification("Actual mouse clicks did not alternate open/closed: \(states)")
        }
        monitor.stop(forQuit: true)
        NSApplication.shared.terminate(nil)
    }

    /// Exercise the actual status item and glass panel, using live metrics.
    func verifyUI(directory: String) {
        if CommandLine.arguments.contains("--light") { panel.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { panel.appearance = NSAppearance(named: .darkAqua) }
        guard monitor.connected else { failVerification("UI verification needs live macmon data.") }
        if (CommandLine.arguments.contains("--disclosure-only") || CommandLine.arguments.contains("--ssd-disclosure-only") || CommandLine.arguments.contains("--system-disclosure-only") || CommandLine.arguments.contains("--scroll-only")) { menuTracking = true }
        let previousApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier
        statusItem.button?.performClick(nil)
        if CommandLine.arguments.contains("--scroll-only") {
            maximumHeight = min(maximumHeight, 400)
            refresh(forceLayout: true)
            Task { @MainActor in await self.verifySettingsScrolling(directory: directory) }
            return
        }
        if (CommandLine.arguments.contains("--disclosure-only") || CommandLine.arguments.contains("--ssd-disclosure-only") || CommandLine.arguments.contains("--system-disclosure-only")) {
            // A fixed preview viewport also works when the menu-bar host is hidden.
            maximumHeight = min(850, (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 850) - 16
            refresh(forceLayout: true)
            Task { @MainActor in await self.verifyDisclosures(directory: directory, previousApplication: previousApplication) }
            return
        }
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
                        guard monitor.menuText.contains("W"), panel.isVisible,
                              dashboardState.showSettings,
                              abs(panel.frame.height - min(measuredHeight, maximumHeight)) < 2,
                              hostingView.frame.height >= panel.frame.height - 2,
                              abs(scrollView.bounds.height - panel.frame.height) < 2 else {
                            failVerification("Menu title or panel sizing verification failed.")
                        }
                        Task { @MainActor in await self.verifyPanelTransitions(directory: directory) }
                    } catch { failVerification(error.localizedDescription) }
                }
            } catch { failVerification(error.localizedDescription) }
        }
    }

    /// Regression: a periodic refresh must not scroll an open settings panel back down.
    private func verifySettingsScrolling(directory: String) async {
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            dashboardState.showSettings = true
            try await Task.sleep(nanoseconds: 800_000_000)
            refresh()
            let maxOffset = max(0, hostingView.frame.height - scrollView.contentView.bounds.height)
            guard dashboardState.showSettings, navigationViewportHeight != nil else {
                failVerification("Settings navigation did not settle.")
            }
            let expectedTop: CGFloat = hostingView.isFlipped ? 0 : maxOffset
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: expectedTop))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            let before = scrollView.contentView.bounds.origin.y
            for _ in 0..<4 {
                refresh()
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            let after = scrollView.contentView.bounds.origin.y
            guard abs(after - before) < 1 else { failVerification("Refreshing settings moved the user's scroll position.") }
            try capture(view: statusItem.button!, path: directory + "/compact-menu.png")
            try capture(view: panelMaterial, path: directory + "/settings-scrolled-top.png")
            let result: [String: Any] = ["scrollBefore": before, "scrollAfter": after, "maximumOffset": maxOffset,
                                         "statusWidth": statusItem.length, "menuText": monitor.menuText,
                                         "settingsOpen": dashboardState.showSettings, "refreshes": 4]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory + "/scroll-regression.json"))
            monitor.stop(forQuit: true)
            NSApplication.shared.terminate(nil)
        } catch { failVerification(error.localizedDescription) }
    }

    /// Short visual check for content disclosure, without running menu stress checks.
    private func verifyDisclosures(directory: String, previousApplication: pid_t?) async {
        let ssdOnly = CommandLine.arguments.contains("--ssd-disclosure-only")
        let systemOnly = CommandLine.arguments.contains("--system-disclosure-only")
        func toggleDetail() {
            if systemOnly { dashboardState.showSystemDetails.toggle() }
            else if ssdOnly { dashboardState.showSSDDetails.toggle() }
            else { dashboardState.toggleApplications() }
        }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try await Task.sleep(nanoseconds: 2_600_000_000)
            guard panel.isVisible, dashboardMounted else { failVerification("Disclosure panel was dismissed before capture.") }
            var frames: [[String: Any]] = []
            func record(_ name: String) throws {
                frames.append(["state": name, "height": panel.frame.height, "top": panel.frame.maxY,
                               "alpha": panel.alphaValue, "mounted": dashboardMounted,
                               "previousApplication": previousApplication ?? -1,
                               "frontmostApplication": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                               "chipbarActive": NSApplication.shared.isActive,
                               "hostingY": hostingView.frame.origin.y, "hostingHeight": hostingView.frame.height,
                               "clipY": scrollView.contentView.bounds.origin.y, "flipped": hostingView.isFlipped,
                               "applicationsExpansion": dashboardState.applicationsExpansion,
                               "settingsScreen": dashboardState.showSettings,
                               "systemDetails": dashboardState.showSystemDetails,
                               "ssdExpansion": dashboardState.ssdExpansion,
                               "ssdDetailsHeight": dashboardState.ssdDetailsHeight,
                               "scrollBorder": scrollView.borderType.rawValue,
                               "cornerClipped": panelMaterial.layer?.masksToBounds ?? false])
                try capture(view: panelMaterial, path: directory + "/\(name).png")
            }
            try record("collapsed")
            toggleDetail()
            try await Task.sleep(nanoseconds: 90_000_000)
            try record("expanding")
            try await Task.sleep(nanoseconds: 300_000_000)
            try record("expanded")
            toggleDetail()
            try await Task.sleep(nanoseconds: 90_000_000)
            try record("collapsing")
            try await Task.sleep(nanoseconds: systemOnly ? 330_000_000 : 260_000_000)
            try record("collapsed-again")
            if systemOnly, let firstTop = frames.first?["top"] as? CGFloat,
               let firstHeight = frames.first?["height"] as? CGFloat {
                guard frames.allSatisfy({
                    abs(($0["top"] as? CGFloat ?? firstTop) - firstTop) < 1 &&
                    abs(($0["height"] as? CGFloat ?? firstHeight) - firstHeight) < 1
                }) else {
                    failVerification("System page navigation resized or moved the shared glass window.")
                }
            }
            if !ssdOnly && !systemOnly {
                func verifyPage(_ settings: Bool) {
                    hostingView.layoutSubtreeIfNeeded()
                    let content = ceil(hostingView.fittingSize.height)
                    let scrollHeight = scrollView.contentView.bounds.height
                    let originalHeight = frames.first?["height"] as? CGFloat ?? panel.frame.height
                    guard dashboardState.showSettings == settings,
                          navigationViewportHeight != nil, navigationTask == nil,
                          !navigationResizeInFlight,
                          panel.isVisible, panel.alphaValue == 1,
                          abs(panel.frame.height - originalHeight) < 2,
                          abs(scrollHeight - panel.frame.height) < 2,
                          hostingView.frame.height >= max(content, scrollHeight) - 2,
                          abs(panel.frame.width - DashboardLayout.width) < 1 else {
                        failVerification("Page transition resized fixed viewport or left truncated content.")
                    }
                }
                dashboardState.toggleSettings()
                try await Task.sleep(nanoseconds: 350_000_000)
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    guard navigationResizeInFlight || navigationTask == nil else {
                        failVerification("Settings resize did not start after the page slide.")
                    }
                }
                try await Task.sleep(nanoseconds: 410_000_000)
                verifyPage(true)
                try record("settings")
                dashboardState.toggleSettings()
                try await Task.sleep(nanoseconds: 350_000_000)
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    guard navigationResizeInFlight || navigationTask == nil else {
                        failVerification("Dashboard resize did not start after the page slide.")
                    }
                }
                try await Task.sleep(nanoseconds: 410_000_000)
                verifyPage(false)
                try record("settings-closed")
                // Reversing before the previous slide completes must still
                // settle on the final page and restore the correct full height.
                for _ in 0..<6 {
                    dashboardState.toggleSettings()
                    try await Task.sleep(nanoseconds: 55_000_000)
                }
                try await Task.sleep(nanoseconds: 760_000_000)
                verifyPage(false)
                try record("settings-fast-reversals")
            }
            captureScreenWindow(path: directory + "/rounded-window-shadow.png", includeShadow: true)
            let data = try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: directory + "/disclosures.json"))
            monitor.stop(forQuit: true)
            NSApplication.shared.terminate(nil)
        } catch { failVerification(error.localizedDescription) }
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
        guard panel.isVisible, dashboardMounted, !dashboardState.showSettings, panel.alphaValue == 1 else {
            failVerification("Panel reopening did not restore its default home screen.")
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
    private func captureScreenWindow(path: String, includeShadow: Bool = false) {
        guard CGPreflightScreenCaptureAccess() else { return }
        panel.displayIfNeeded()
        CATransaction.flush()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x"] + (includeShadow ? [] : ["-o"]) + ["-l", String(panel.windowNumber), path]
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
