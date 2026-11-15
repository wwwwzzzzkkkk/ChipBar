import SwiftUI

enum DashboardSidePanelKind: String, Equatable {
    case applications
    case power
    case externalDisk
    case cluster
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
    // Power page is scrollable inside a stable native window; expanding a port
    // must never resize the parent menu or its glass sidecar.
    static let powerHeight: CGFloat = 640
    static let diskHeight: CGFloat = 410
    static let clusterHeight: CGFloat = 310
    static let clusterDisclosureAnimationDuration = 0.24

    static func width(for kind: DashboardSidePanelKind?) -> CGFloat {
        kind == .power ? powerWidth : kind == .cluster ? 378 : width
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
        }
    }
}

/// Keep Cluster's first frame stable. Other pages retain their previous
/// fast-to-open placeholder strategy to avoid delaying expensive samplers.
enum SidePanelOpeningPolicy {
    static let clusterSlidePoints: CGFloat = 12
    static let clusterSlideDuration: TimeInterval = 0.24

    static func presentsFinalContentBeforeShowing(_ kind: DashboardSidePanelKind) -> Bool {
        kind == .cluster
    }
}

struct SidePanelLoadingView: View {
    let kind: DashboardSidePanelKind
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(kind == .power ? "电源与功率" :
                  kind == .externalDisk ? "外置硬盘" :
                  kind == .cluster ? "计算集群" : "应用占用",
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
private struct ClusterSidecarContentHeightKey: PreferenceKey {
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
    /// An explicit kind lets the Cluster render its final content *before*
    /// the NSPanel becomes visible, rather than flashing the old/empty page.
    var kindOverride: DashboardSidePanelKind? = nil
    var onClusterContentHeightChange: ((CGFloat) -> Void)? = nil

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
        // proposes a shorter viewport. Only cluster uses this intrinsic fit.
        .fixedSize(horizontal: false, vertical: displayedKind == .cluster)
        // A flexible maxHeight here made the preferred height equal to the
        // old scroll viewport, not the actual tiles, and fed stale dimensions
        // back into the AppKit window.
        .background {
            if displayedKind == .cluster {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ClusterSidecarContentHeightKey.self,
                        value: geometry.size.height
                    )
                }
            }
        }
        .onPreferenceChange(ClusterSidecarContentHeightKey.self) { height in
            if displayedKind == .cluster, height.isFinite, height > 0 {
                onClusterContentHeightChange?(height)
            }
        }
        .buttonStyle(ChipBarPressStyle())
    }
}
