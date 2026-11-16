import Foundation
import Testing
@testable import ChipBar

struct ClusterSidecarSizingTests {
    @Test func everySidecardMountsFinalContentBeforeItsFirstVisibleFrame() {
        for kind in [DashboardSidePanelKind.cluster, .power, .applications, .externalDisk] {
            #expect(SidePanelOpeningPolicy.presentsFinalContentBeforeShowing(kind))
        }
        #expect(SidePanelLayout.clusterDisclosureAnimationDuration > 0)
    }

    @Test func taskDisclosurePinsWindowAndSmallFirstFitCorrectionsAreIgnored() {
        #expect(!ClusterSidecarSizing.shouldResizeWindow(
            from: 420, to: 780, available: 1100, userDisclosurePinned: true))
        #expect(ClusterSidecarSizing.shouldResizeWindow(
            from: 420, to: 780, available: 1100, userDisclosurePinned: false))
        #expect(!ClusterSidecarSizing.shouldResizeWindow(
            from: 420, to: 426, available: 1100, userDisclosurePinned: false))
        // A screen-size change is still allowed to shrink an overlong panel.
        #expect(ClusterSidecarSizing.shouldResizeWindow(
            from: 700, to: 480, available: 500, userDisclosurePinned: true))
    }

    @Test func disclosurePreservesCurrentScrollInsteadOfJumpingBackToTitle() {
        #expect(ClusterSidecarSizing.preservedScrollOffset(
            160, documentHeight: 1100, viewportHeight: 510, isFlipped: true) == 160)
        #expect(ClusterSidecarSizing.preservedScrollOffset(
            160, documentHeight: 570, viewportHeight: 510, isFlipped: true) == 60)
        #expect(ClusterSidecarSizing.preservedScrollOffset(
            0, documentHeight: 1100, viewportHeight: 510, isFlipped: true) == 0)
    }

    @Test func clusterTopIsIndependentOfParentResize() {
        let opened: CGFloat = 890
        #expect(ClusterSidecarSizing.stableTop(openedAt: opened, visibleMaxY: 1100) == 890)
        #expect(ClusterSidecarSizing.stableTop(openedAt: opened, visibleMaxY: 800) == 792)
    }

    @Test func resizedPanelKeepsTopWithoutDiscardingManualScroll() {
        #expect(ClusterSidecarSizing.isAtTop(
            offsetY: 0, documentHeight: 850, viewportHeight: 510, isFlipped: true))
        #expect(!ClusterSidecarSizing.isAtTop(
            offsetY: 150, documentHeight: 850, viewportHeight: 510, isFlipped: true))
        #expect(ClusterSidecarSizing.isAtTop(
            offsetY: 340, documentHeight: 850, viewportHeight: 510, isFlipped: false))
        #expect(!ClusterSidecarSizing.isAtTop(
            offsetY: 80, documentHeight: 850, viewportHeight: 510, isFlipped: false))
    }

    @Test func scrollTopUsesFlippedViewCoordinateSystem() {
        #expect(ClusterSidecarSizing.topScrollOffset(
            documentHeight: 850, viewportHeight: 510, isFlipped: true) == 0)
        #expect(ClusterSidecarSizing.topScrollOffset(
            documentHeight: 850, viewportHeight: 510, isFlipped: false) == 340)
        #expect(ClusterSidecarSizing.topScrollOffset(
            documentHeight: 210, viewportHeight: 510, isFlipped: false) == 0)
    }

    @Test func compactContentDoesNotLeaveLargeEmptyViewport() {
        #expect(ClusterSidecarSizing.windowHeight(content: 340, available: 1100) == 340)
        #expect(ClusterSidecarSizing.windowHeight(content: 620, available: 1100) == 620)
        #expect(ClusterSidecarSizing.windowHeight(content: 310, available: 1100) == 310)
    }

    @Test func canFitNewlyDiscoveredNodesBeforeUserDisclosure() {
        let folded = ClusterSidecarSizing.windowHeight(content: 410, available: 1000)
        let expanded = ClusterSidecarSizing.windowHeight(content: 780, available: 1000)
        #expect(expanded > folded)
        #expect(expanded == 780)
        #expect(ClusterSidecarSizing.windowHeight(content: 410, available: 1000) == folded)
    }

    @Test func shortDisplaysCapToVisibleHeightAndRequireInternalScroll() {
        #expect(ClusterSidecarSizing.windowHeight(content: 950, available: 610) == 594)
        #expect(ClusterSidecarSizing.windowHeight(content: 125, available: 600) == 210)
        #expect(ClusterSidecarSizing.windowHeight(content: .infinity, available: 600) == 210)
    }

    @Test func panelKeepsTopAnchorUntilReachingScreenBottom() {
        #expect(ClusterSidecarSizing.bottomY(
            anchoredTop: 980, height: 620, visibleMinY: 24) == 360)
        #expect(ClusterSidecarSizing.bottomY(
            anchoredTop: 510, height: 600, visibleMinY: 24) == 32)
    }
}
