import SwiftUI

enum DashboardSidePanelKind: String, Equatable {
    case applications
    case power
    case externalDisk
    case cluster
    case powerHistory

    var fitsContentHeight: Bool { self == .power || self == .cluster }
}

/// Shared native-window sizing for each independent tile page.
enum SidePanelLayout {
    static let width: CGFloat = 314
    // 420pt window - 24pt panel margins - 24pt tile padding = 372pt canvas.
    // App ranking and disk detail retain their existing compact widths.
    static let powerWidth: CGFloat = 420
    static let padding: CGFloat = 12
    static let contentWidth: CGFloat = width - 2 * padding
    static let applicationHeight: CGFloat = 250
    // Opening estimate used only until the native window measures its content.
    static let powerHeight: CGFloat = 360
    static let diskHeight: CGFloat = 334
    static let clusterHeight: CGFloat = 310
    static let powerHistoryHeight: CGFloat = 400
    static let clusterDisclosureAnimationDuration = SidePanelNavigationMotion.enterDuration

    static func width(for kind: DashboardSidePanelKind?) -> CGFloat {
        switch kind {
        case .power: return powerWidth
        case .cluster: return 378
        case .powerHistory: return 480
        default: return width
        }
    }

    static func contentWidth(for kind: DashboardSidePanelKind?) -> CGFloat {
        width(for: kind) - 2 * padding
    }

    static func height(for kind: DashboardSidePanelKind) -> CGFloat {
        switch kind {
        case .applications: return applicationHeight
        case .power: return powerHeight
        case .externalDisk: return diskHeight
        case .cluster: return clusterHeight
        case .powerHistory: return powerHistoryHeight
        }
    }
}

/// Locate a sidecar in a genuinely free screen interval. Clamping a full
/// right-hand frame to the screen edge can push it back over the dashboard.
enum SidePanelPlacement {
    static let gap: CGFloat = 9
    static let edgeInset: CGFloat = 8
    static let minimumViewportWidth: CGFloat = 90
    enum Side: Equatable { case left, right }

    struct Result: Equatable {
        let side: Side
        let frame: CGRect
        let documentWidth: CGFloat
        var needsHorizontalScroll: Bool { frame.width + 1 < documentWidth }
    }

    /// A power sidecar can add rows only in the space below its top edge.
    /// Additional content belongs in the scroll document.
    static func powerViewportHeight(content: CGFloat, anchoredTop: CGFloat, visible: CGRect) -> CGFloat {
        let top = min(anchoredTop, visible.maxY - edgeInset)
        return min(content, max(1, top - visible.minY - edgeInset))
    }

    static func choose(parent: CGRect, visible: CGRect, preferredWidth: CGFloat,
                       preferredHeight: CGFloat, top: CGFloat? = nil) -> Result? {
        let bounds = visible.insetBy(dx: edgeInset, dy: edgeInset)
        guard bounds.width > 0, bounds.height > 0,
              preferredWidth.isFinite, preferredWidth > 0,
              preferredHeight.isFinite, preferredHeight > 0 else { return nil }
        let rightEdge = max(bounds.minX, parent.maxX + gap)
        let leftEdge = min(bounds.maxX, parent.minX - gap)
        let right = max(0, bounds.maxX - rightEdge)
        let left = max(0, leftEdge - bounds.minX)
        let side: Side
        // Prefer right only when the FULL destination page fits. A narrower
        // previous page is not evidence that the next page can fit there.
        if right >= preferredWidth { side = .right }
        else if left >= preferredWidth { side = .left }
        else { side = right >= left ? .right : .left }
        let available = side == .right ? right : left
        guard available >= min(minimumViewportWidth, preferredWidth) else { return nil }
        let width = min(preferredWidth, available)
        let height = min(preferredHeight, bounds.height)
        let x = side == .right ? rightEdge : leftEdge - width
        let y = min(bounds.maxY - height, max(bounds.minY, (top ?? parent.maxY) - height))
        return Result(side: side, frame: CGRect(x: x, y: y, width: width, height: height),
                      documentWidth: preferredWidth)
    }

    static func side(of frame: CGRect, beside parent: CGRect) -> Side? {
        if frame.minX >= parent.maxX + gap - 0.5 { return .right }
        if frame.maxX <= parent.minX - gap + 0.5 { return .left }
        return nil
    }

    /// Legacy geometry helper used by regression fixtures. Production now
    /// animates the clipped content instead of folding the native window.
    static func folded(_ frame: CGRect, side: Side) -> CGRect {
        let width = min(frame.width, 22)
        return CGRect(x: side == .right ? frame.minX : frame.maxX - width,
                      y: frame.minY, width: width, height: frame.height)
    }

    static func isLegal(_ frame: CGRect, beside parent: CGRect, visible: CGRect) -> Bool {
        visible.insetBy(dx: edgeInset, dy: edgeInset).contains(frame)
            && side(of: frame, beside: parent) != nil
    }

    static func requiresRelocation(from frame: CGRect, to result: Result,
                                   parent: CGRect, visible: CGRect) -> Bool {
        !isLegal(frame, beside: parent, visible: visible)
            || side(of: frame, beside: parent) != result.side
    }
}

/// Every sidecar mounts the correct real view before its first visible frame.
/// A delayed placeholder and alpha/position animation make translucent glass
/// surfaces visibly flicker, even if the data is already available.
enum SidePanelOpeningPolicy {
    static func presentsFinalContentBeforeShowing(_ kind: DashboardSidePanelKind) -> Bool {
        true
    }
}

/// Shared timing and fixed seam for every sidecar.
enum SidePanelNavigationMotion {
    static let enterDuration: TimeInterval = 0.27
    static let exitDuration: TimeInterval = 0.235

    /// One native frame commit is enough: the render server owns every
    /// intermediate content frame, including on high-refresh displays.
    static func needsFrameCommit(from current: CGRect, to target: CGRect) -> Bool {
        current != target
    }

    static func seamAnchor(on side: SidePanelPlacement.Side) -> CGFloat {
        side == .right ? 0 : 1
    }

    static func edgeOffset(on side: SidePanelPlacement.Side) -> CGFloat {
        side == .right ? -8 : 8
    }

    static func revealDuration(from start: CGFloat, to end: CGFloat) -> TimeInterval {
        let fullDuration = start < end ? enterDuration : exitDuration
        return fullDuration * max(0.35, sqrt(abs(end - start)))
    }

    static func timing(opening: Bool) -> (Double, Double, Double, Double) {
        opening ? (0.20, 0.70, 0.25, 1) : (0.40, 0, 0.75, 1)
    }

    static func animation(opening: Bool) -> Animation {
        let (x1, y1, x2, y2) = timing(opening: opening)
        return .timingCurve(x1, y1, x2, y2, duration: opening ? enterDuration : exitDuration)
    }

    /// Interpolate all frame edges with the same easing. When top or the near
    /// horizontal edge is shared, that edge remains fixed throughout.
    static func interpolatedFrame(from start: CGRect, to target: CGRect,
                                  progress: Double) -> CGRect {
        if progress <= 0 { return start }
        if progress >= 1 { return target }
        let t = CGFloat(DisclosurePanelSizing.easeInOutProgress(progress))
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return CGRect(x: lerp(start.minX, target.minX),
                      y: lerp(start.minY, target.minY),
                      width: lerp(start.width, target.width),
                      height: lerp(start.height, target.height))
    }
}

struct SidePanelLoadingView: View {
    let kind: DashboardSidePanelKind
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(ChipBarLocale.localized(kind == .power ? "电源与功率" :
                  kind == .externalDisk ? "外置硬盘" :
                  kind == .cluster ? "计算集群" : "应用占用"),
                  systemImage: kind == .power ? "bolt.horizontal.circle" :
                  kind == .externalDisk ? "externaldrive" :
                  kind == .cluster ? "point.3.connected.trianglepath.dotted" : "square.stack.3d.up")
                .font(.headline)
                .frame(height: 28)
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.045))
                .frame(height: kind == .applications ? 165 : 105)
                .overlay { ProgressView().controlSize(.small) }
        }
        .frame(width: SidePanelLayout.contentWidth(for: kind), alignment: .topLeading)
        .padding(SidePanelLayout.padding)
    }
}

/// Measures the SwiftUI content's intrinsic height independently of the
/// AppKit scroll viewport. Only the Cluster sidecar consumes this preference.
private struct SidePanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Pure sizing logic shared by the sidecar and its regression tests.
/// There is intentionally no arbitrary 540pt cap: tall displays can show
/// every node and task; compact displays scroll within the screen bounds.
enum ClusterSidecarSizing {
    static let minimumHeight: CGFloat = 210
    static let edgeInset: CGFloat = 8
    // AppKit/SwiftUI can disagree by a few points on the first intrinsic fit.
    // Those corrections are visual noise, not new content worth moving a panel.
    static let resizeTolerance: CGFloat = 14

    static func shouldResizeWindow(from current: CGFloat, to proposed: CGFloat,
                                   available: CGFloat, userDisclosurePinned: Bool) -> Bool {
        guard current.isFinite, proposed.isFinite, available.isFinite else { return false }
        if current > max(1, available - edgeInset * 2) + 1 { return true }
        return !userDisclosurePinned && abs(current - proposed) > resizeTolerance
    }

    static func preservedScrollOffset(_ current: CGFloat, documentHeight: CGFloat,
                                      viewportHeight: CGFloat, isFlipped: Bool) -> CGFloat {
        let maximum = max(0, documentHeight - viewportHeight)
        guard current.isFinite else { return topScrollOffset(
            documentHeight: documentHeight, viewportHeight: viewportHeight,
            isFlipped: isFlipped) }
        return min(max(0, current), maximum)
    }

    static func windowHeight(content: CGFloat, available: CGFloat) -> CGFloat {
        let limit = max(1, available - edgeInset * 2)
        guard content.isFinite, content > 0 else {
            return min(minimumHeight, limit)
        }
        return min(max(minimumHeight, ceil(content)), limit)
    }

    static func stableTop(openedAt: CGFloat, visibleMaxY: CGFloat) -> CGFloat {
        min(visibleMaxY - edgeInset, openedAt)
    }

    static func bottomY(anchoredTop: CGFloat, height: CGFloat, visibleMinY: CGFloat) -> CGFloat {
        max(visibleMinY + edgeInset, anchoredTop - height)
    }

    /// Preserve the title when a window resizes, without stealing a user's
    /// scroll position when they are inspecting task details further down.
    static func isAtTop(offsetY: CGFloat, documentHeight: CGFloat,
                        viewportHeight: CGFloat, isFlipped: Bool) -> Bool {
        abs(offsetY - topScrollOffset(documentHeight: documentHeight,
                                     viewportHeight: viewportHeight,
                                     isFlipped: isFlipped)) <= 2
    }

    /// NSScrollView's content origin depends on the document view's flipped
    /// coordinate system. Scrolling to y=0 can show the *bottom* on some Macs.
    static func topScrollOffset(documentHeight: CGFloat, viewportHeight: CGFloat,
                                isFlipped: Bool) -> CGFloat {
        isFlipped ? 0 : max(0, documentHeight - viewportHeight)
    }
}

struct DashboardSidePanelView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var state: DashboardState
    var close: () -> Void
    /// @Published delivers the new panel selection before storage changes.
    /// Explicit kind avoids @Published's didSet timing: the sidecar always
    /// mounts the selected page before its native window becomes visible.
    var kindOverride: DashboardSidePanelKind? = nil
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    private var displayedKind: DashboardSidePanelKind? {
        kindOverride ?? state.sidePanel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch displayedKind {
            case .applications:
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(Color(red: 0.22, green: 0.65, blue: 0.79))
                    Text("应用占用").font(.headline)
                    Spacer(minLength: 0)
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel("关闭侧边卡片")
                }
                .frame(height: 28)
                ApplicationUsageSection(monitor: monitor, state: state,
                                        showsDisclosure: false)
            case .power:
                PowerSupplyDetailView(monitor: monitor,
                                      active: !monitor.paused && !monitor.sleeping,
                                      close: close)
            case .powerHistory:
                PowerHistoryDetailView(monitor: monitor, selection: $state.powerHistorySelection,
                                       close: close)
            case .externalDisk:
                if let id = state.selectedExternalVolumeID {
                    ExternalDiskDetailView(volumeID: id, ssd: monitor.ssd, close: close)
                }
            case .cluster:
                ClusterMonitorPanel(monitor: monitor, close: close)
            case nil:
                EmptyView()
            }
        }
        .frame(width: SidePanelLayout.contentWidth(for: displayedKind), alignment: .topLeading)
        .padding(SidePanelLayout.padding)
        // Fit the full vertical content even if the NSScrollView currently
        // proposes a shorter viewport.
        .fixedSize(horizontal: false, vertical: displayedKind?.fitsContentHeight == true)
        // A flexible maxHeight here made the preferred height equal to the
        // old scroll viewport, not the actual tiles, and fed stale dimensions
        // back into the AppKit window.
        .background {
            if displayedKind?.fitsContentHeight == true {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SidePanelContentHeightKey.self,
                        value: geometry.size.height
                    )
                }
            }
        }
        .onPreferenceChange(SidePanelContentHeightKey.self) { height in
            if displayedKind?.fitsContentHeight == true, height.isFinite, height > 0 {
                onContentHeightChange?(height)
            }
        }
        // A disclosure can update SwiftUI's intrinsic size before AppKit
        // catches up. Keep the document top-aligned even between those updates.
        .frame(minHeight: displayedKind == .power ? 0 : nil,
               maxHeight: displayedKind == .power ? .infinity : nil,
               alignment: .topLeading)
        .buttonStyle(ChipBarPressStyle())
    }
}
